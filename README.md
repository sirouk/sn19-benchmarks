# vLLM Server Benchmarking Tools

Simple tools for starting and benchmarking vLLM inference servers with true async concurrency testing.

## TL;DR

```bash
# Terminal 1: Start a vLLM server
bash <(curl -s https://raw.githubusercontent.com/sirouk/sn19-benchmarks/refs/heads/main/start_vllm.sh)

# Terminal 2: Benchmark it
bash <(curl -s https://raw.githubusercontent.com/sirouk/sn19-benchmarks/refs/heads/main/bench_vllm.sh)
```

Both scripts handle all setup automatically - just run and follow the prompts!

## Features

- **True Async Concurrency**: Single-process async I/O instead of process parallelism
- **Auto Setup**: Both scripts handle environment setup automatically
- **Remote/Local Testing**: Benchmark local or remote vLLM servers
- **Statistical Analysis**: p50/p95 percentiles, TTFT, TPS metrics
- **Multi-GPU Support**: Tensor parallelism for distributed inference

## Detailed Usage

### Starting a vLLM Server

The start script will prompt for configuration:
- **Hugging Face token** (for gated models)
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

The script automatically:
- Clones/updates the sn19-benchmarks repository
- Sets up Python 3.12 environment with `uv`
- Installs vLLM and dependencies
- Auto-detects CUDA architecture for optimal configuration
- Starts the server with platform-specific optimizations

### Running Benchmarks

The benchmark script offers two modes:

#### Mode 1: Local Server Auto-detection (Default)
Automatically detects and lists running vLLM servers on the local machine.

#### Mode 2: Remote Server Testing
Connect to any vLLM server by providing:
- **Server IP** (defaults to localhost)
- **Port** (defaults to 7011)

Both modes test with:
- **Concurrency levels**: Default 1, 5, 10, 20 requests
- **Multiple runs**: 3 runs per level for consistency
- **Key metrics**:
  - **TTFT** (Time To First Token)
  - **TPS** (Tokens Per Second)
  - **Total time** per request
  - **p50/p95 percentiles**

### Advanced Options

#### Custom Concurrency Levels
```bash
# Test with specific concurrency
./bench_vllm.sh 50

# If using locally with multiple servers
./bench_vllm.sh 50 2  # Concurrency 50, server #2
```

#### Python Async Benchmark
For more control, use the standalone Python script:
```bash
./bench_vllm_async.py -c 5,10,20,50 --runs 5 --continuous
```

## Example Output

```
Benchmark Configuration
======================
1) Auto-detect local vLLM servers
2) Connect to remote/specific server

Select option [1-2]: 1
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

## Requirements

- Python 3.8+
- bash shell
- For GPU: NVIDIA drivers and CUDA (auto-detected)
- For Mac: Runs in CPU mode with Metal acceleration

## Technical Notes

### Benchmarking Architecture
- Uses single Python process with async I/O for true concurrency
- Connection pooling for efficient HTTP connection reuse
- Semaphore-based concurrency limiting
- Streaming response processing for accurate TTFT measurement

### Server Configuration
- **Multi-GPU**: Set tensor parallel size > 1 to distribute model across GPUs
- **Memory**: 0.97 (97%) recommended for dedicated inference servers
- **Platform detection**: Auto-configures for Mac (Metal) or Linux (CUDA)
- **CUDA optimization**: Auto-detects compute capability for optimal torch backend

## Troubleshooting

### Server Issues
1. Ensure vLLM server is running: `ps aux | grep vllm`
2. Check server health: `curl http://localhost:7011/health`
3. Verify model loaded: `curl http://localhost:7011/v1/models`

### Benchmark Issues
1. Check network connectivity to server
2. Ensure sufficient client resources for concurrent requests
3. Try reducing concurrency level if seeing failures

### Environment Issues
1. Scripts auto-install `uv` package manager if not present
2. Python 3.12 is automatically configured
3. Dependencies are installed in isolated `.venv`

## Repository

Both scripts are maintained at: https://github.com/sirouk/sn19-benchmarks