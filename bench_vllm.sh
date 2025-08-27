#!/usr/bin/env bash

# Display version info
echo "=================================="
echo "sn19-benchmarks bench_vllm.sh"  
echo "Repo: https://github.com/sirouk/sn19-benchmarks"
echo "Script Version: 2025-01-27-v2"
echo "=================================="
echo

# vLLM Benchmark Script with true async concurrency
# Can be run via curl or locally
# Usage: 
#   bash <(curl -s https://raw.githubusercontent.com/sirouk/sn19-benchmarks/refs/heads/main/bench_vllm.sh)
#   ./bench_vllm.sh [concurrency] [server_ordinal]

set -euo pipefail  # Better error handling

########################################
# Setup Environment (if needed)
########################################
setup_environment() {
    # Check if we're already in the right place with a venv
    if [[ -f .venv/bin/activate ]] && [[ -f bench_vllm.sh ]]; then
        echo "Environment already set up, activating..."
        source .venv/bin/activate
        return 0
    fi
    
    echo "Setting up benchmark environment..."
    
    # Get situated in the right directory
    cd $HOME
    if [ -d sn19-benchmarks ]; then
        cd ./sn19-benchmarks
        git pull
    else
        git clone https://github.com/sirouk/sn19-benchmarks
        cd ./sn19-benchmarks
    fi
    
    # Show current git commit for verification
    echo "Current git commit: $(git rev-parse --short HEAD)"
    echo "Commit date: $(git log -1 --format=%ci)"
    echo
    
    # Check if venv exists and has aiohttp
    if [[ -f .venv/bin/activate ]]; then
        source .venv/bin/activate
        if python3 -c "import aiohttp" 2>/dev/null; then
            echo "Environment ready!"
            return 0
        fi
    fi
    
    # Setup fresh environment if needed
    echo "Installing dependencies..."
    
    # Install uv if not present
    if ! command -v uv &> /dev/null; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
        # Source the uv environment instead of .bashrc
        export PATH="$HOME/.local/bin:$PATH"
    fi
    
    # Create venv if it doesn't exist
    if [[ ! -f .venv/bin/activate ]]; then
        uv venv --python 3.12 --seed
    fi
    
    source .venv/bin/activate
    
    # Install minimal requirements for benchmarking
    uv pip install -q aiohttp
    
    echo "Environment setup complete!"
}

########################################
# Get Server Configuration
########################################
get_server_config() {
    # Prompt for IP address
    read -p "Enter server IP address (defaults to localhost): " SERVER_IP
    SERVER_IP=${SERVER_IP:-localhost}
    
    # Prompt for port
    read -p "Enter server port (defaults to 7011): " PORT
    PORT=${PORT:-7011}
    
    # Test connection and get model info
    echo "Testing connection to http://${SERVER_IP}:${PORT}/v1/models ..."
    
    MODEL_INFO=$(curl -s "http://${SERVER_IP}:${PORT}/v1/models" 2>/dev/null || echo "{}")
    
    if [[ "$MODEL_INFO" == "{}" ]] || [[ -z "$MODEL_INFO" ]]; then
        echo "WARNING: Could not connect to server at ${SERVER_IP}:${PORT}"
        echo "Proceeding anyway - benchmark will fail if server is not accessible"
        TEST_MODEL="unknown"
    else
        # Try to extract model name from response
        TEST_MODEL=$(echo "$MODEL_INFO" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if 'data' in data and len(data['data']) > 0:
        print(data['data'][0].get('id', 'unknown'))
    else:
        print('unknown')
except:
    print('unknown')
" 2>/dev/null || echo "unknown")
        echo "Detected model: $TEST_MODEL"
    fi
}

########################################
# Auto-detect local servers (fallback)
########################################
detect_local_servers() {
    local procs=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && procs+=("$line")
    done < <(ps -ewwo pid,args | grep -E "vllm\.entrypoints\.openai\.api_server" | grep -v grep || true)
    
    if [[ ${#procs[@]} -eq 0 ]]; then
        return 1
    fi
    
    MODELS=()
    PORTS=()
    
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
    
    return 0
}

########################################
# Main execution
########################################

# Setup environment first
setup_environment

# Parse command line arguments (for backward compatibility)
USER_CONCURRENCY="${1:-}"
ORD_INPUT="${2:-}"

# Check if we should auto-detect local servers or prompt for remote
echo "Benchmark Configuration"
echo "======================"
echo "1) Auto-detect local vLLM servers"
echo "2) Connect to remote/specific server"
echo
read -p "Select option [1-2] (defaults to 1): " CONFIG_OPTION
CONFIG_OPTION=${CONFIG_OPTION:-1}

if [[ "$CONFIG_OPTION" == "1" ]]; then
    # Auto-detect local servers
    MODELS=()
    PORTS=()
    
    if detect_local_servers; then
        echo "Detected vLLM servers:" >&2
        for i in "${!MODELS[@]}"; do
            printf '  %d) %s (port %s)\n' "$((i+1))" "${MODELS[$i]}" "${PORTS[$i]}" >&2
        done
        echo >&2
        
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
        SERVER_IP="127.0.0.1"
        echo "Using model: $TEST_MODEL (port $PORT)"
    else
        echo "No local vLLM servers detected."
        echo "Switching to manual configuration..."
        get_server_config
    fi
else
    # Manual configuration
    get_server_config
fi

echo
echo "Starting benchmark against http://${SERVER_IP}:${PORT}"
echo "Model: ${TEST_MODEL}"
echo

########################################
# Run the Python benchmark
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
    url = "http://${SERVER_IP}:${PORT}/v1/completions"
    
    async with aiohttp.ClientSession() as session:
        tasks = []
        for _ in range(num_requests):
            payload = {
                "model": "${TEST_MODEL}",
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