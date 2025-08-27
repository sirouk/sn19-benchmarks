# vLLM Server Benchmarking Tools

Simple tools for starting and benchmarking vLLM inference servers with true async concurrency testing.

## TL;DR - Fastest Setup

```bash
# Start a vLLM server (prompts for settings)
bash <(curl -s https://raw.githubusercontent.com/sirouk/sn19-benchmarks/refs/heads/main/start_vllm.sh)

# In another terminal, benchmark it
git clone https://github.com/sirouk/sn19-benchmarks && cd sn19-benchmarks && ./bench_vllm.sh
```

## Quick Start

### 1. Start a vLLM Server

#### One-liner Installation & Start
```bash
bash <(curl -s https://raw.githubusercontent.com/sirouk/sn19-benchmarks/refs/heads/main/start_vllm.sh)
```

#### Or run locally if already cloned:
```bash
./start_vllm.sh
```

The script will prompt you for:
- **Hugging Face token** (required for gated models)
- **vLLM version** (defaults to v0.9.2)
- **Port** (defaults to 7011)
- **Model selection**:
  1. Qwen/QwQ-32B
  2. OpenGVLab/InternVL3-14B
  3. casperhansen/mistral-nemo-instruct-2407-awq
  4. deepseek-ai/DeepSeek-R1-0528-Qwen3-8B
  5. unsloth/Llama-3.2-3B-Instruct (default)
- **Memory percentage** (defaults to 0.97)
- **Tensor parallel size** (defaults to 1) - for multi-GPU setups

The script will:
- Clone/update the sn19-benchmarks repository
- Set up a fresh Python 3.12 virtual environment using `uv`
- Install vLLM and dependencies (auto-detecting CUDA architecture)
- Configure platform-specific settings (GPU/CPU mode)
- Start the server with optimized settings (float16 precision)

### 2. Benchmark the Server

Once your vLLM server is running, benchmark it:

#### Quick setup & run benchmark:
```bash
# Clone and run benchmark (if not already cloned)
git clone https://github.com/sirouk/sn19-benchmarks && cd sn19-benchmarks && ./bench_vllm.sh
```

#### Or if already in the sn19-benchmarks directory:
```bash
# Interactive mode - will prompt for server selection if multiple are running
./bench_vllm.sh

# Test with specific concurrency level (e.g., 10 concurrent requests)
./bench_vllm.sh 10

# Test specific concurrency and select server directly (e.g., concurrency 10, server #1)
./bench_vllm.sh 10 1
```

## What the Benchmark Tests

The benchmark uses **true async concurrency** (not process parallelism) to test:

- **Concurrency levels**: Default tests 1, 5, 10, and 20 concurrent requests
- **Multiple runs**: 3 runs per concurrency level for consistency
- **Key metrics**:
  - **TTFT** (Time To First Token) - How fast the model starts responding
  - **TPS** (Tokens Per Second) - Generation throughput
  - **Total time** - End-to-end request completion
  - **p50/p95 percentiles** - Statistical distribution of performance

## Example Output

```
Detected vLLM servers:
  1) unsloth/Llama-3.2-3B-Instruct (port 7011)

Using model: unsloth/Llama-3.2-3B-Instruct (port 7011)

==================================================
Testing with concurrency level: 10
==================================================

Run 1/3:
  Batch completed in 4.23s
  TTFT: min=0.021s, median=0.098s, max=0.412s
  Total: min=1.234s, median=2.456s, max=4.123s
  TPS: min=45.2, median=68.5, max=89.1

Aggregate stats for concurrency=10:
  TTFT p50: 0.095s, p95: 0.389s
  TPS p50: 67.8, p95: 85.3
```

## Advanced Usage

For more control, use the Python async benchmark directly:

```bash
# Install if not already available
pip install aiohttp

# Run with custom settings
./bench_vllm_async.py -c 5,10,20,50 --runs 5
```

## Requirements

- Python 3.8+
- bash shell
- For GPU: NVIDIA drivers and CUDA (auto-detected)
- For Mac: Runs in CPU mode with Metal acceleration

## Notes

### Benchmarking
- The benchmark creates a single Python process with async I/O for true concurrency testing
- Connection pooling is used to efficiently reuse HTTP connections
- Results show both individual run statistics and aggregated metrics
- Press 'y' after each benchmark to run again, or 'N' to exit

### Server Configuration
- **Multi-GPU**: Set tensor parallel size > 1 to distribute model across GPUs
- **Memory**: 0.97 (97%) is recommended for dedicated inference servers
- **Platform detection**: Automatically configures for Mac (Metal) or Linux (CUDA)
- **CUDA optimization**: Auto-detects compute capability for optimal torch backend

## Troubleshooting

If no servers are detected:
1. Ensure your vLLM server is running (`ps aux | grep vllm`)
2. Check that the server started successfully
3. Verify the port is accessible (`curl http://localhost:7011/health`)

If benchmarks fail:
1. Check server logs for errors
2. Ensure sufficient memory is available
3. Try reducing concurrency level
