#!/usr/bin/env bash

# Improved vLLM completion benchmark with true async concurrency
# Usage: ./bench_vllm_improved.sh [concurrency] [server_ordinal]

set -euo pipefail  # Better error handling

# Source venv if exists
[[ -f .venv/bin/activate ]] && source .venv/bin/activate

########################################
# 1. Detect running vLLM servers
########################################
detect_servers() {
    local procs=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && procs+=("$line")
    done < <(ps -ewwo pid,args | grep -E "vllm\.entrypoints\.openai\.api_server" | grep -v grep || true)
    
    if [[ ${#procs[@]} -eq 0 ]]; then
        echo "ERROR: No vLLM api_server processes found." >&2
        exit 1
    fi
    
    for line in "${procs[@]}"; do
        # Extract model name (same as original)
        local model=$(printf '%s' "$line" | sed -n 's/.*--model[ =]\([^ ]*\).*/\1/p')
        # Extract port - handle both --port=7011 and --port 7011 formats
        local port=$(printf '%s' "$line" | sed -n 's/.*--port[ =]\([0-9]\+\).*/\1/p')
        # If port not found with basic regex, try extracting from anywhere in the line
        if [[ -z "$port" ]]; then
            port=$(printf '%s' "$line" | grep -oE '\-\-port[ =]?[0-9]+' | grep -oE '[0-9]+$')
        fi
        model=${model:-unknown}
        port=${port:-8000}
        MODELS+=("$model")
        PORTS+=("$port")
    done
}

MODELS=()
PORTS=()
detect_servers

echo "Detected vLLM servers:" >&2
for i in "${!MODELS[@]}"; do
    printf '  %d) %s (port %s)\n' "$((i+1))" "${MODELS[$i]}" "${PORTS[$i]}" >&2
done
echo >&2

# Parse arguments
USER_CONCURRENCY="${1:-}"
ORD_INPUT="${2:-}"

# Select server
COUNT=${#MODELS[@]}
if [[ -n "$ORD_INPUT" && "$ORD_INPUT" =~ ^[0-9]+$ && $ORD_INPUT -ge 1 && $ORD_INPUT -le $COUNT ]]; then
    idx=$((ORD_INPUT - 1))
elif [[ $COUNT -gt 1 ]]; then
    read -rp "Select server [1-$COUNT]: " choice
    [[ "$choice" =~ ^[0-9]+$ && $choice -ge 1 && $choice -le $COUNT ]] || { echo "Invalid selection"; exit 1; }
    idx=$((choice - 1))
else
    idx=0
fi

TEST_MODEL="${MODELS[$idx]}"
PORT="${PORTS[$idx]}"
echo "Using model: $TEST_MODEL (port $PORT)"

########################################
# 2. Ensure Python requirements
########################################
python3 -c "
import subprocess, sys
try:
    import aiohttp
except ImportError:
    print('Installing aiohttp...', file=sys.stderr)
    subprocess.check_call([sys.executable, '-m', 'pip', 'install', '--quiet', 'aiohttp'])
"

########################################
# 3. Run improved async benchmark
########################################
python3 - <<EOF
import asyncio
import aiohttp
import random
import time
import statistics
import sys
from typing import List, Dict, Any

async def single_request(session: aiohttp.ClientSession, url: str, payload: Dict[str, Any]) -> Dict[str, float]:
    """Execute a single completion request and return timing metrics."""
    start = time.time()
    first_token_time = None
    tokens = 0
    
    try:
        async with session.post(url, json=payload) as resp:
            if resp.status != 200:
                print(f"HTTP {resp.status}: {await resp.text()}", file=sys.stderr)
                return {"error": 1}
            
            async for chunk in resp.content:
                if not chunk.strip():
                    continue
                if first_token_time is None:
                    first_token_time = time.time()
                tokens += 1
    except Exception as e:
        print(f"Request failed: {e}", file=sys.stderr)
        return {"error": 1}
    
    total_time = time.time() - start
    ttft = first_token_time - start if first_token_time else 0
    
    return {
        "ttft": ttft,
        "total_time": total_time,
        "tokens": tokens,
        "tps": tokens / total_time if total_time > 0 else 0
    }

async def concurrent_benchmark(concurrency: int, num_requests: int) -> List[Dict[str, float]]:
    """Run multiple concurrent requests and collect metrics."""
    url = "http://127.0.0.1:$PORT/v1/completions"
    
    async with aiohttp.ClientSession() as session:
        tasks = []
        for _ in range(num_requests):
            payload = {
                "model": "$TEST_MODEL",
                "prompt": "100 word story about balloons",
                "temperature": 0.0,
                "stream": True,
                "seed": random.randint(1, 1_000_000),
            }
            tasks.append(single_request(session, url, payload))
        
        # TRUE ASYNC CONCURRENCY: limit concurrent requests
        semaphore = asyncio.Semaphore(concurrency)
        
        async def limited_request(coro):
            async with semaphore:
                return await coro
        
        limited_tasks = [limited_request(task) for task in tasks]
        results = await asyncio.gather(*limited_tasks)
    
    return [r for r in results if "error" not in r]

async def main():
    # Parse concurrency levels
    concurrency_str = "${USER_CONCURRENCY:-}"
    if concurrency_str:
        concurrency_levels = [int(concurrency_str)]
    else:
        concurrency_levels = [1, 5, 10, 20]
    
    for concurrency in concurrency_levels:
        print(f"\n{'='*50}")
        print(f"Testing with concurrency level: {concurrency}")
        print(f"{'='*50}")
        
        all_results = []
        
        for run in range(1, 4):
            print(f"\nRun {run}/3:")
            start_time = time.time()
            
            # Run concurrent requests
            results = await concurrent_benchmark(concurrency, concurrency)
            
            batch_time = time.time() - start_time
            
            if results:
                ttfts = [r["ttft"] for r in results]
                total_times = [r["total_time"] for r in results]
                tps_values = [r["tps"] for r in results]
                
                print(f"  Batch completed in {batch_time:.2f}s")
                print(f"  TTFT: min={min(ttfts):.3f}s, median={statistics.median(ttfts):.3f}s, max={max(ttfts):.3f}s")
                print(f"  Total: min={min(total_times):.3f}s, median={statistics.median(total_times):.3f}s, max={max(total_times):.3f}s")
                print(f"  TPS: min={min(tps_values):.1f}, median={statistics.median(tps_values):.1f}, max={max(tps_values):.1f}")
                
                all_results.extend(results)
        
        # Aggregate statistics
        if all_results:
            print(f"\nAggregate stats for concurrency={concurrency}:")
            ttfts = [r["ttft"] for r in all_results]
            tps_values = [r["tps"] for r in all_results]
            print(f"  TTFT p50: {statistics.median(ttfts):.3f}s, p95: {statistics.quantiles(ttfts, n=20)[18]:.3f}s")
            print(f"  TPS p50: {statistics.median(tps_values):.1f}, p95: {statistics.quantiles(tps_values, n=20)[18]:.1f}")

if __name__ == "__main__":
    asyncio.run(main())
EOF

echo
read -n1 -rsp "Run again? [y/N] " ans; echo
[[ \$ans == [yY] ]] && exec "\$0" "\$@"
