#!/usr/bin/env bash

# Display version info
echo "=================================="
echo "sn19-benchmarks bench_vllm.sh"  
echo "Repo: https://github.com/sirouk/sn19-benchmarks"
echo "Script Version: 2025-01-27-v6"
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
    
    # Always ensure uv is in PATH (it installs to ~/.local/bin)
    export PATH="$HOME/.local/bin:$PATH"
    
    # Install uv if not present
    if ! command -v uv &> /dev/null; then
        echo "Installing uv package manager..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
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
# Run benchmark function
########################################
run_benchmark() {
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

# Check if bench_vllm_async.py exists locally
if [[ -f bench_vllm_async.py ]]; then
    # Use the local file
    BENCH_SCRIPT="bench_vllm_async.py"
else
    # Download it if we don't have it (e.g., when running via curl)
    echo "Downloading benchmark script..."
    curl -s -o bench_vllm_async.py "https://raw.githubusercontent.com/sirouk/sn19-benchmarks/main/bench_vllm_async.py"
    BENCH_SCRIPT="bench_vllm_async.py"
fi

# Build command line arguments
BENCH_ARGS="-m \"${TEST_MODEL}\" -p ${PORT} -s ${SERVER_IP}"

# Add concurrency if specified
if [[ -n "${USER_CONCURRENCY:-}" ]]; then
    BENCH_ARGS="$BENCH_ARGS -c ${USER_CONCURRENCY}"
else
    BENCH_ARGS="$BENCH_ARGS -c 1,5,10,20"
fi

# Run the benchmark
echo "Running: python3 $BENCH_SCRIPT $BENCH_ARGS"
python3 "$BENCH_SCRIPT" $BENCH_ARGS
} # End of run_benchmark function

########################################
# Main execution
########################################

# Setup environment first
setup_environment

# Run benchmark in a loop
while true; do
    run_benchmark "$@"
    
    echo
    read -n1 -rsp "Run again? [y/N] " ans; echo
    if [[ $ans != [yY] ]]; then
        break
    fi
    echo  # Add spacing before next run
done