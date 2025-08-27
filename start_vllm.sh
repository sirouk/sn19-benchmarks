#!/bin/bash

# First and foremost, prompt before doing any work!

# Prompt the user for their Hugging Face token
read -p "Enter your Hugging Face token: " HF_TOKEN
HF_TOKEN=${HF_TOKEN:-hf_YOGETYOUROWNTOKENBRUV}

# Prompt the user for the version of vLLM to use and default after 
read -p "Enter the version of vLLM to use (defaults to v0.9.2): " VLLM_VERSION
VLLM_VERSION=${VLLM_VERSION:-v0.9.2}

# Prompt the user for the port to use
read -p "Enter the port to use (defaults to 7011): " PORT
PORT=${PORT:-7011}

# Prompt the user which model to use among:
echo "Models available:
    1) Qwen/QwQ-32B
    2) OpenGVLab/InternVL3-14B
    3) casperhansen/mistral-nemo-instruct-2407-awq
    4) deepseek-ai/DeepSeek-R1-0528-Qwen3-8B
    5) unsloth/Llama-3.2-3B-Instruct
"
read -p "Enter the number of the model you want to use (defaults to 5): " model_number
model_number=${model_number:-5}

# Ask the user how much memory to use
read -p "Enter the percentage of memory to use (defaults to 0.97): " PERCENT_MEMORY_USED
PERCENT_MEMORY_USED=${PERCENT_MEMORY_USED:-0.97}

# Ask the user for the tensor parallel size
read -p "Enter the tensor parallel size (defaults to 1): " TENSOR_PARALLEL_SIZE
TENSOR_PARALLEL_SIZE=${TENSOR_PARALLEL_SIZE:-1}


# Get situated
cd $HOME
if [ -d sn19-benchmarks ]; then
    cd ./sn19-benchmarks
    git pull
else
git clone https://github.com/sirouk/sn19-benchmarks
    cd ./sn19-benchmarks
fi

# keep it fresh
rm -rf .venv
curl -LsSf https://astral.sh/uv/install.sh | sh
. $HOME/.bashrc
uv self update
uv venv --python 3.12 --seed
source .venv/bin/activate

# Install requirements
uv pip install -r requirements.txt

# Install vLLM requirements
wget -O vllm_requirements.txt https://raw.githubusercontent.com/vllm-project/vllm/refs/tags/${VLLM_VERSION}/requirements/common.txt
uv pip install -r vllm_requirements.txt

# Transformers with vLLM 0.9.2
if [ $VLLM_VERSION == "v0.9.2" ]; then
    uv pip install transformers==4.53.3
fi

# Get architecture or default to auto, install accordingly
CUDA_ARCH=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | tr -d '.' || echo "0")
uv pip install vllm==${VLLM_VERSION} --torch-backend=$([[ "$CUDA_ARCH" -ge 90 ]] && echo "cu128" || echo "auto")

# Verify vLLM installation
uv pip freeze | grep vllm


# Calculate memory in GB with percentage applied
PERCENT_INT=$(awk "BEGIN {print int(${PERCENT_MEMORY_USED}*100)}")
VLLM_CPU_KVCACHE_SPACE=$([[ "$(uname)" == "Darwin" ]] && echo $(($(sysctl -n hw.memsize)/1024/1024/1024*${PERCENT_INT}/100)) || free -g 2>/dev/null | awk -v pct="${PERCENT_MEMORY_USED}" '/^Mem:/{print int($2*pct)}' || echo $((16*${PERCENT_INT}/100)))

# Add platform-specific arguments
if [[ "$(uname)" == "Darwin" ]]; then
    VLLM_USE_V1=0;
    PLATFORM_ARGS="--enforce-eager"
else
    VLLM_USE_V1=1;
    PLATFORM_ARGS=""
fi

COMMON_ARGS="
    --tensor-parallel-size ${TENSOR_PARALLEL_SIZE} \
    --gpu-memory-utilization ${PERCENT_MEMORY_USED} \
    --max-logprobs 1 \
    --host 0.0.0.0 --port ${PORT} \
    ${PLATFORM_ARGS}
"

if [ $model_number -eq 1 ]; then
    MODEL_ARGS="
    --model Qwen/QwQ-32B \
    --tokenizer Qwen/QwQ-32B \
    --max-model-len 40000 \
    --dtype float16
    "
elif [ $model_number -eq 2 ]; then
    MODEL_ARGS="
    --model OpenGVLab/InternVL3-14B \
    --tokenizer OpenGVLab/InternVL3-14B \
    --max-model-len 12288 \
    --max-num-batched-tokens=19980 \
    --dtype float16 \    
    --limit-mm-per-prompt '{"image": 2}' \
    --trust-remote-code
    "
elif [ $model_number -eq 3 ]; then
    MODEL_ARGS="
    --model casperhansen/mistral-nemo-instruct-2407-awq \
    --tokenizer casperhansen/mistral-nemo-instruct-2407-awq \
    --max-model-len 32000 \
    --dtype float16
    "
elif [ $model_number -eq 4 ]; then
    MODEL_ARGS="
    --model deepseek-ai/DeepSeek-R1-0528-Qwen3-8B \
    --tokenizer deepseek-ai/DeepSeek-R1-0528-Qwen3-8B \
    --max-model-len 32000 \
    --dtype float16
    "
elif [ $model_number -eq 5 ]; then
    MODEL_ARGS="
    --model unsloth/Llama-3.2-3B-Instruct \
    --tokenizer tau-vision/llama-tokenizer-fix \
    --max-model-len 20000 \
    --dtype float16
    "
else
    echo "Invalid model number"
    exit 1
fi

echo "Starting vLLM server on port $PORT with model $MODEL_ARGS and args $COMMON_ARGS"
python3 -m vllm.entrypoints.openai.api_server $MODEL_ARGS $COMMON_ARGS