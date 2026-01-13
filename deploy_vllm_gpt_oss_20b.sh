#!/bin/bash
set -e  # Exit immediately on any error

# Parameter-controlled deployment script for vLLM gpt-oss-20b
# Usage: ./deploy_vllm_gpt_oss_20b.sh [--create-env] [--install-vllm] [--install-gpt-oss] [--start-server] [--all]

# Download modle
#  HF_ENDPOINT=https://hf-mirror.com hf download openai/gpt-oss-20b --local-dir ./gpt-oss-20b

# ════════════════════════════════════════════════════════════════════════════════
# Configuration: Pip Mirror and Network Settings
# ════════════════════════════════════════════════════════════════════════════════
# Supported mirrors (choose based on your network):
#   - Tsinghua (清华):  https://pypi.tuna.tsinghua.edu.cn/simple   (fastest for China)
#   - USTC (中科大):    https://mirrors.ustc.edu.cn/pypi/web/simple
#   - Aliyun (阿里云):  https://mirrors.aliyun.com/pypi/simple/
#   - Tencent (腾讯):   https://mirrors.cloud.tencent.com/pypi/simple
PIP_MIRROR="https://pypi.tuna.tsinghua.edu.cn/simple"
PIP_TIMEOUT=180  # 3 minutes - sufficient for large packages like torch (2.5GB), vllm (500MB)
PIP_RETRIES=5    # Retry up to 5 times on network failure

# Default option flags
CREATE_ENV=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --create-env)
            CREATE_ENV=true
            shift
            ;;
        --install-uv)
            INSTALL_UV=true
            shift
            ;;
        --install-vllm)
            INSTALL_VLLM=true
            shift
            ;;
        --install-gpt-oss)
            INSTALL_GPT_OSS=true
            shift
            ;;
        --start-server)
            START_SERVER=true
            shift
            ;;
        --all)
            CREATE_ENV=true
            INSTALL_UV=true
            INSTALL_VLLM=true
            INSTALL_GPT_OSS=true
            START_SERVER=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --create-env      Create conda environment named gpt-oss-20b"
            echo "  --install-uv      Install uv package manager"
            echo "  --install-vllm    Install vLLM using pyproject.toml"
            echo "  --install-gpt-oss Install gpt-oss package"
            echo "  --start-server    Start vLLM server on port 8010"
            echo "  --all             Execute all steps"
            echo "  -h, --help        Show this help message"
            return 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use -h or --help for usage information."
            return 1
            ;;
    esac
done

# If no options provided, show help
if [ "$CREATE_ENV" = false ] && [ "$INSTALL_UV" = false ] && [ "$INSTALL_VLLM" = false ] && [ "$INSTALL_GPT_OSS" = false ] && [ "$START_SERVER" = false ]; then
    echo "No options specified. Here are the available options:"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  --create-env      Create conda environment named gpt-oss-20b with Python 3.12"
    echo "  --install-uv      Install uv package manager"
    echo "  --install-vllm    Install vLLM using pyproject.toml"
    echo "  --install-gpt-oss Install gpt-oss package"
    echo "  --start-server    Start vLLM server on port 8010"
    echo "  --all             Execute all steps"
    echo "  --help, -h        Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --all                                    # Execute all steps"
    echo "  $0 --create-env --install-uv --install-vllm # Execute specific steps"
    echo "  $0 --start-server                           # Only start the server"
    return 0
fi

echo "Starting vLLM gpt-oss-20b deployment script..."
echo ""

# Step 1: Create conda environment
if [ "$CREATE_ENV" = true ]; then
    echo "Step 1: Checking/Creating conda environment 'gpt-oss-20b' with Python 3.12..."
    if conda env list | grep -q "^gpt-oss-20b "; then
        echo "✓ Conda environment 'gpt-oss-20b' already exists. Skipping creation."
    else
        conda create -n gpt-oss-20b python=3.12 -y
        echo "✓ Conda environment 'gpt-oss-20b' created."
    fi
    echo "To activate: conda activate gpt-oss-20b"
    echo ""
fi

# Step 2: Ensure pip is available
if [ "$INSTALL_UV" = true ]; then
    echo "Step 2: Ensuring pip is available..."
    if command -v pip &> /dev/null; then
        echo "✓ pip is available: $(pip --version)"
    else
        echo "✓ pip should be installed with Python 3.12"
    fi
    echo ""
fivll

# Step 3: Install vLLM with pyproject.toml
if [ "$INSTALL_VLLM" = true ]; then
    echo "Step 3: Checking/Installing vLLM using pyproject.toml..."
    if [ "$CREATE_ENV" = true ]; then
        conda activate gpt-oss-20b
    fi
    if python3 -c "import vllm" 2>/dev/null; then
        echo "✓ vLLM is already installed: $(python3 -c 'import vllm; print(vllm.__version__)' 2>/dev/null || echo 'version unknown')"
    else
        echo "Installing vLLM and dependencies from pyproject.toml..."
        echo "Using mirror: $PIP_MIRROR"
        echo "Timeout: ${PIP_TIMEOUT}s, Retries: ${PIP_RETRIES}"
        echo "Note: Large packages may take several minutes to download. Progress shown below:"
        echo "════════════════════════════════════════════════════════════════════"
        pip install -i "$PIP_MIRROR" --default-timeout=$PIP_TIMEOUT --retries=$PIP_RETRIES -vv -e .[vllm]
        INSTALL_STATUS=$?
        echo "════════════════════════════════════════════════════════════════════"
        if [ $INSTALL_STATUS -eq 0 ]; then
            echo "✓ vLLM and dependencies installed."
        else
            echo "✗ Installation failed with mirror: $PIP_MIRROR"
            echo "Try changing PIP_MIRROR to one of:"
            echo "  - USTC:    https://mirrors.ustc.edu.cn/pypi/web/simple"
            echo "  - Aliyun:  https://mirrors.aliyun.com/pypi/simple/"
            echo "  - Tencent: https://mirrors.cloud.tencent.com/pypi/simple"
            return 1
        fi
    fi
    echo ""
fi

# Step 4: Install gpt-oss
if [ "$INSTALL_GPT_OSS" = true ]; then
    echo "Step 4: Checking/Installing gpt-oss package..."
    if [ "$CREATE_ENV" = true ]; then
        conda activate gpt-oss-20b
    fi
    if python3 -c "import gpt_oss" 2>/dev/null; then
        echo "✓ gpt-oss is already installed: $(python3 -c 'import gpt_oss; print(gpt_oss.__version__ if hasattr(gpt_oss, "__version__") else "installed")' 2>/dev/null)"
    else
        echo "Installing gpt-oss package..."
        echo "Using mirror: $PIP_MIRROR"
        echo "Timeout: ${PIP_TIMEOUT}s, Retries: ${PIP_RETRIES}"
        echo "Note: Progress and detailed information shown below:"
        echo "════════════════════════════════════════════════════════════════════"
        pip install -i "$PIP_MIRROR" --default-timeout=$PIP_TIMEOUT --retries=$PIP_RETRIES -vv -e .
        INSTALL_STATUS=$?
        echo "════════════════════════════════════════════════════════════════════"
        if [ $INSTALL_STATUS -eq 0 ]; then
            echo "✓ gpt-oss installed."
        else
            echo "✗ Installation failed with mirror: $PIP_MIRROR"
            echo "Try changing PIP_MIRROR to one of:"
            echo "  - USTC:    https://mirrors.ustc.edu.cn/pypi/web/simple"
            echo "  - Aliyun:  https://mirrors.aliyun.com/pypi/simple/"
            echo "  - Tencent: https://mirrors.cloud.tencent.com/pypi/simple"
            return 1
        fi
    fi
    echo ""
fi

# Step 5: Start vLLM server
if [ "$START_SERVER" = true ]; then
    echo "Step 5: Starting vLLM server for gpt-oss-20b on port 8010..."
    if [ "$CREATE_ENV" = true ]; then
        conda activate gpt-oss-20b
    fi
    echo "Note: This will run in the foreground. Use Ctrl+C to stop."
    echo "Command: vllm serve openai/gpt-oss-20b --port 8010"
    vllm serve openai/gpt-oss-20b --port 8010
fi

echo "Deployment script completed!"
if [ "$CREATE_ENV" = true ]; then
    echo "Remember to activate the environment for future use: conda activate gpt-oss-20b"
fi