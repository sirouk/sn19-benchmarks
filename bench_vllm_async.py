#!/usr/bin/env python3
"""
True async concurrent benchmark for vLLM servers.
This demonstrates proper async concurrency vs process-based parallelism.
"""

import asyncio
import aiohttp
import argparse
import random
import time
import statistics
import sys
import subprocess
from typing import List, Dict, Any, Optional
from dataclasses import dataclass
from collections import defaultdict


@dataclass
class RequestMetrics:
    """Metrics for a single request."""

    ttft: float  # Time to first token
    total_time: float
    tokens: int
    tps: float  # Tokens per second
    request_id: int
    start_time: float


class VLLMBenchmark:
    """Async concurrent benchmark for vLLM servers."""

    def __init__(
        self, model: str, port: int, prompt: str = "100 word story about balloons"
    ):
        self.model = model
        self.port = port
        self.prompt = prompt
        self.url = f"http://127.0.0.1:{port}/v1/completions"
        self.metrics: List[RequestMetrics] = []

    async def single_request(
        self,
        session: aiohttp.ClientSession,
        request_id: int,
        semaphore: asyncio.Semaphore,
    ) -> Optional[RequestMetrics]:
        """Execute a single completion request with proper async concurrency control."""

        async with semaphore:  # Control concurrency here
            payload = {
                "model": self.model,
                "prompt": self.prompt,
                "temperature": 0.0,
                "stream": True,
                "seed": random.randint(1, 1_000_000),
            }

            start_time = time.time()
            first_token_time = None
            tokens = 0

            try:
                async with session.post(self.url, json=payload) as resp:
                    if resp.status != 200:
                        print(
                            f"Request {request_id} failed: HTTP {resp.status}",
                            file=sys.stderr,
                        )
                        return None

                    async for chunk in resp.content:
                        if not chunk.strip():
                            continue
                        if first_token_time is None:
                            first_token_time = time.time()
                        tokens += 1

            except asyncio.CancelledError:
                raise  # Let cancellation propagate
            except Exception as e:
                print(f"Request {request_id} failed: {e}", file=sys.stderr)
                return None

            total_time = time.time() - start_time
            ttft = first_token_time - start_time if first_token_time else 0

            return RequestMetrics(
                ttft=ttft,
                total_time=total_time,
                tokens=tokens,
                tps=tokens / total_time if total_time > 0 else 0,
                request_id=request_id,
                start_time=start_time,
            )

    async def run_concurrent_batch(
        self, concurrency: int, num_requests: int, timeout: Optional[float] = None
    ) -> List[RequestMetrics]:
        """
        Run a batch of requests with TRUE async concurrency.

        This is the key difference from the shell script:
        - Uses a single process with async I/O
        - Semaphore controls max concurrent requests
        - All requests share the same event loop
        - Much lower overhead than process-based parallelism
        """

        # Create semaphore to limit concurrent requests
        semaphore = asyncio.Semaphore(concurrency)

        # Create session with connection pooling
        connector = aiohttp.TCPConnector(
            limit=concurrency * 2,  # Total connection pool
            limit_per_host=concurrency,  # Per-host limit
        )

        timeout_config = aiohttp.ClientTimeout(total=timeout) if timeout else None

        async with aiohttp.ClientSession(
            connector=connector, timeout=timeout_config
        ) as session:
            # Create all tasks
            tasks = [
                self.single_request(session, i, semaphore) for i in range(num_requests)
            ]

            # Run them concurrently
            results = await asyncio.gather(*tasks, return_exceptions=True)

        # Filter out failures and exceptions
        valid_results = [r for r in results if isinstance(r, RequestMetrics)]

        return valid_results

    def print_statistics(self, results: List[RequestMetrics], label: str = ""):
        """Print detailed statistics for a set of results."""
        if not results:
            print(f"{label}No successful requests")
            return

        ttfts = [r.ttft for r in results]
        total_times = [r.total_time for r in results]
        tps_values = [r.tps for r in results]

        print(f"{label}Successful requests: {len(results)}")
        print(
            f"{label}TTFT  - p50: {statistics.median(ttfts):.3f}s, "
            f"p95: {statistics.quantiles(ttfts, n=20)[18] if len(ttfts) > 1 else ttfts[0]:.3f}s, "
            f"min: {min(ttfts):.3f}s, max: {max(ttfts):.3f}s"
        )
        print(
            f"{label}Total - p50: {statistics.median(total_times):.3f}s, "
            f"p95: {statistics.quantiles(total_times, n=20)[18] if len(total_times) > 1 else total_times[0]:.3f}s, "
            f"min: {min(total_times):.3f}s, max: {max(total_times):.3f}s"
        )
        print(
            f"{label}TPS   - p50: {statistics.median(tps_values):.1f}, "
            f"p95: {statistics.quantiles(tps_values, n=20)[18] if len(tps_values) > 1 else tps_values[0]:.1f}, "
            f"min: {min(tps_values):.1f}, max: {max(tps_values):.1f}"
        )

    async def benchmark_suite(
        self, concurrency_levels: List[int] = [1, 5, 10, 20], runs_per_level: int = 3
    ):
        """Run a complete benchmark suite with multiple concurrency levels."""

        for concurrency in concurrency_levels:
            print(f"\n{'=' * 60}")
            print(f"Concurrency Level: {concurrency}")
            print(f"{'=' * 60}")

            all_results = []

            for run in range(1, runs_per_level + 1):
                print(f"\n--- Run {run}/{runs_per_level} ---")

                start_time = time.time()
                results = await self.run_concurrent_batch(concurrency, concurrency)
                batch_time = time.time() - start_time

                print(f"Batch completed in {batch_time:.2f}s")
                self.print_statistics(results, "  ")

                all_results.extend(results)

            if all_results:
                print(f"\n--- Aggregate Statistics (all {runs_per_level} runs) ---")
                self.print_statistics(all_results, "  ")


def detect_vllm_servers():
    """Detect running vLLM servers - matches original bench_vllm.sh logic."""
    import re

    try:
        result = subprocess.run(
            ["ps", "-ewwo", "pid,args"], capture_output=True, text=True
        )

        servers = []
        for line in result.stdout.splitlines():
            if "vllm.entrypoints.openai.api_server" in line and "grep" not in line:
                # Extract model name (same as original bash script)
                model_match = re.search(r"--model[ =]([^ ]*)", line)
                model = model_match.group(1) if model_match else None

                # Extract port - handle both --port=7011 and --port 7011 formats
                port_match = re.search(r"--port[ =]([0-9]+)", line)
                port = port_match.group(1) if port_match else None

                # If port not found with basic regex, try extracting from anywhere in the line
                if not port:
                    port_match2 = re.search(r"--port[ =]?([0-9]+)", line)
                    if port_match2:
                        port = port_match2.group(1)

                # Use defaults if not found
                model = model if model else "unknown"
                port = int(port) if port else 8000

                servers.append({"model": model, "port": port})

        return servers
    except Exception as e:
        print(f"Error detecting servers: {e}", file=sys.stderr)
        return []


async def main():
    parser = argparse.ArgumentParser(
        description="True async concurrent benchmark for vLLM servers",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s                     # Interactive mode
  %(prog)s -c 10              # Test with concurrency 10
  %(prog)s -c 5,10,20         # Test multiple concurrency levels
  %(prog)s -m model -p 8000   # Specify model and port directly
  %(prog)s --continuous       # Run continuous benchmark
        """,
    )

    parser.add_argument(
        "-c",
        "--concurrency",
        help="Concurrency level(s) to test (comma-separated)",
        default="1,5,10,20",
    )
    parser.add_argument(
        "-r", "--runs", type=int, default=3, help="Number of runs per concurrency level"
    )
    parser.add_argument("-m", "--model", help="Model name to use")
    parser.add_argument("-p", "--port", type=int, help="Port number")
    parser.add_argument(
        "--prompt",
        default="100 word story about balloons",
        help="Prompt to use for testing",
    )
    parser.add_argument(
        "--continuous",
        action="store_true",
        help="Run continuous benchmark (loop until interrupted)",
    )

    args = parser.parse_args()

    # Determine model and port
    if args.model and args.port:
        model = args.model
        port = args.port
    else:
        servers = detect_vllm_servers()
        if not servers:
            print(
                "No vLLM servers detected. Please specify --model and --port",
                file=sys.stderr,
            )
            sys.exit(1)

        if len(servers) == 1:
            model = servers[0]["model"]
            port = servers[0]["port"]
        else:
            print("Multiple servers detected:")
            for i, server in enumerate(servers, 1):
                print(f"  {i}) {server['model']} (port {server['port']})")

            choice = input(f"Select server [1-{len(servers)}]: ")
            try:
                idx = int(choice) - 1
                model = servers[idx]["model"]
                port = servers[idx]["port"]
            except (ValueError, IndexError):
                print("Invalid selection", file=sys.stderr)
                sys.exit(1)

    print(f"Using model: {model} on port {port}")

    # Parse concurrency levels
    concurrency_levels = [int(c.strip()) for c in args.concurrency.split(",")]

    # Create benchmark instance
    benchmark = VLLMBenchmark(model, port, args.prompt)

    # Run benchmark
    while True:
        await benchmark.benchmark_suite(concurrency_levels, args.runs)

        if not args.continuous:
            break

        print("\n" + "=" * 60)
        response = input("Run again? [y/N]: ")
        if response.lower() != "y":
            break


if __name__ == "__main__":
    asyncio.run(main())
