#!/bin/bash
# gpt-oss 智能依赖安装脚本
# 自动检测硬件环境并选择最佳安装策略

set -e  # 遇到错误立即退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}======================================"
echo "gpt-oss 智能依赖安装脚本"
echo -e "======================================${NC}\n"

# ============================================
# 环境检测
# ============================================

# 检测硬件架构
ARCH=$(uname -m)
echo -e "${YELLOW}检测到架构: ${BLUE}$ARCH${NC}"

# 检测操作系统
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    echo -e "${YELLOW}操作系统: ${BLUE}$PRETTY_NAME${NC}"
else
    echo -e "${RED}无法检测操作系统${NC}"
    exit 1
fi

# 检测 NVIDIA GPU
HAS_GPU=false
GPU_INFO=""
if command -v nvidia-smi &> /dev/null; then
    if nvidia-smi &> /dev/null; then
        HAS_GPU=true
        GPU_INFO=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1)
        echo -e "${GREEN}✓ 检测到 NVIDIA GPU: ${BLUE}$GPU_INFO${NC}"
    else
        echo -e "${YELLOW}⚠ nvidia-smi 存在但无法运行${NC}"
    fi
else
    echo -e "${YELLOW}⚠ 未检测到 NVIDIA GPU${NC}"
fi

# 检测 CUDA
HAS_CUDA=false
HAS_NVCC=false
CUDA_VERSION=""

if command -v nvcc &> /dev/null; then
    HAS_CUDA=true
    HAS_NVCC=true
    CUDA_VERSION=$(nvcc --version | grep "release" | awk '{print $5}' | sed 's/,//')
    echo -e "${GREEN}✓ CUDA Toolkit: ${BLUE}$CUDA_VERSION${NC}"
elif [ -d "/usr/local/cuda" ] || ls /usr/local/cuda-* 2>/dev/null | grep -q "cuda"; then
    HAS_CUDA=true
    echo -e "${GREEN}✓ 检测到 CUDA 安装目录${NC}"
    # 尝试从目录获取 nvcc
    for cuda_dir in /usr/local/cuda-* /usr/local/cuda; do
        if [ -f "$cuda_dir/bin/nvcc" ]; then
            HAS_NVCC=true
            CUDA_VERSION=$("$cuda_dir/bin/nvcc" --version | grep "release" | awk '{print $5}' | sed 's/,//')
            echo -e "${YELLOW}  找到 nvcc: ${BLUE}$cuda_dir/bin/nvcc (v$CUDA_VERSION)${NC}"
            # 设置临时环境
            export CUDA_HOME="$cuda_dir"
            export PATH="$CUDA_HOME/bin:$PATH"
            export LD_LIBRARY_PATH="$CUDA_HOME/lib64:$LD_LIBRARY_PATH"
            break
        fi
    done
else
    echo -e "${YELLOW}⚠ 未检测到 CUDA${NC}"
fi

# 判断平台类型
PLATFORM=""
INSTALL_STRATEGY=""

if [[ "$ARCH" == "aarch64" ]] || [[ "$ARCH" == "arm64" ]]; then
    PLATFORM="ARM64"
    if $HAS_GPU; then
        INSTALL_STRATEGY="jetson"
        echo -e "\n${BLUE}平台判断: NVIDIA Jetson (ARM64 + GPU)${NC}"
    else
        INSTALL_STRATEGY="arm64_cpu"
        echo -e "\n${BLUE}平台判断: ARM64 (无 GPU)${NC}"
    fi
elif [[ "$ARCH" == "x86_64" ]]; then
    PLATFORM="x86_64"
    if $HAS_GPU; then
        INSTALL_STRATEGY="x86_gpu"
        echo -e "\n${BLUE}平台判断: x86_64 + NVIDIA GPU${NC}"
    else
        INSTALL_STRATEGY="x86_cpu"
        echo -e "\n${BLUE}平台判断: x86_64 (无 GPU)${NC}"
    fi
else
    PLATFORM="unknown"
    INSTALL_STRATEGY="generic"
    echo -e "\n${YELLOW}平台判断: 未知架构 ($ARCH)${NC}"
fi

echo ""

echo -e "${YELLOW}[1/4] 安装系统依赖...${NC}"

case "$OS" in
    ubuntu|debian)
        echo "检测到 Ubuntu/Debian 系统"
        sudo apt-get update
        sudo apt-get install -y \
            portaudio19-dev \
            python3-dev \
            build-essential \
            gcc \
            g++ \
            cmake \
            git \
            wget \
            curl
        ;;
    centos|rhel|fedora)
        echo "检测到 RHEL/CentOS/Fedora 系统"
        sudo yum install -y \
            portaudio-devel \
            python3-devel \
            gcc \
            gcc-c++ \
            cmake \
            git \
            wget \
            curl
        ;;
    *)
        echo -e "${RED}不支持的操作系统: $OS${NC}"
        echo "请手动安装以下依赖："
        echo "  - portaudio 开发库"
        echo "  - python 开发头文件"
        echo "  - 编译工具链（gcc, g++, cmake）"
        exit 1
        ;;
esac

echo -e "${GREEN}✓ 系统依赖安装完成${NC}\n"

echo -e "${YELLOW}[2/4] 检查 Conda 环境...${NC}"

if ! command -v conda &> /dev/null; then
    echo -e "${RED}错误：未找到 conda 命令${NC}"
    echo "请先安装 Miniconda 或 Anaconda："
    echo "https://docs.conda.io/en/latest/miniconda.html"
    exit 1
fi

ENV_NAME="env_vllm"

if conda env list | grep -q "^${ENV_NAME} "; then
    echo "环境 ${ENV_NAME} 已存在"
else
    echo "创建 Conda 环境: ${ENV_NAME}"
    conda create -n ${ENV_NAME} python=3.12 -y
fi

echo -e "${GREEN}✓ Conda 环境就绪${NC}\n"

# ============================================
# [2.5/4] 安装和配置 CUDA Toolkit（如果需要）
# ============================================

if [[ "$INSTALL_STRATEGY" == "jetson" ]] || [[ "$INSTALL_STRATEGY" == "x86_gpu" ]]; then
    echo -e "${YELLOW}[2.5/4] 检查 CUDA 开发工具...${NC}"
    
    if ! $HAS_NVCC; then
        echo -e "${YELLOW}⚠ 未检测到 nvcc 编译器${NC}"
        
        if [[ "$PLATFORM" == "ARM64" ]] && $HAS_GPU; then
            # Jetson 平台
            echo -e "${YELLOW}检测到 Jetson 平台，尝试安装 CUDA Toolkit...${NC}"
            
            # 检查可用的 CUDA toolkit 版本
            if apt-cache search cuda-toolkit-13-0 &>/dev/null; then
                echo "准备安装 cuda-toolkit-13-0..."
                echo -e "${YELLOW}注意：这将下载约 3GB 文件并占用约 5GB 磁盘空间${NC}"
                read -p "是否继续安装 CUDA Toolkit？(y/n) " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    sudo apt-get update
                    if sudo apt-get install -y cuda-toolkit-13-0; then
                        echo -e "${GREEN}✓ CUDA Toolkit 13.0 安装成功${NC}"
                        HAS_NVCC=true
                        CUDA_VERSION="13.0"
                        
                        # 设置 CUDA 环境
                        export CUDA_HOME=/usr/local/cuda-13.0
                        export PATH=$CUDA_HOME/bin:$PATH
                        export LD_LIBRARY_PATH=$CUDA_HOME/lib64:$LD_LIBRARY_PATH
                        
                        # 验证
                        if command -v nvcc &> /dev/null; then
                            nvcc --version
                        fi
                    else
                        echo -e "${RED}✗ CUDA Toolkit 安装失败${NC}"
                    fi
                else
                    echo -e "${YELLOW}跳过 CUDA Toolkit 安装${NC}"
                    echo -e "${YELLOW}  注意：从源码编译 vLLM 需要 nvcc 编译器${NC}"
                fi
            fi
        elif [[ "$PLATFORM" == "x86_64" ]] && $HAS_GPU; then
            # x86_64 平台
            echo -e "${YELLOW}x86_64 平台建议从 NVIDIA 官网下载 CUDA Toolkit：${NC}"
            echo "  https://developer.nvidia.com/cuda-downloads"
        fi
    else
        echo -e "${GREEN}✓ CUDA 开发工具已就绪 (nvcc v$CUDA_VERSION)${NC}"
    fi
    
    # 为 conda 环境配置 CUDA 环境变量
    if $HAS_NVCC && [ -n "$CUDA_HOME" ]; then
        echo -e "\n${YELLOW}配置 Conda 环境的 CUDA 环境变量...${NC}"
        
        # 激活环境以获取 CONDA_PREFIX
        eval "$(conda shell.bash hook)"
        conda activate ${ENV_NAME}
        
        CUDA_ENV_FILE="$CONDA_PREFIX/etc/conda/activate.d/cuda_env.sh"
        mkdir -p "$CONDA_PREFIX/etc/conda/activate.d"
        
        cat > "$CUDA_ENV_FILE" << EOF
# CUDA 环境变量（自动生成）
export CUDA_HOME=$CUDA_HOME
export PATH=\$CUDA_HOME/bin:\$PATH
export LD_LIBRARY_PATH=\$CUDA_HOME/lib64:\$LD_LIBRARY_PATH
EOF
        
        echo -e "${GREEN}✓ CUDA 环境变量已保存到 Conda 环境${NC}"
        echo "  位置: $CUDA_ENV_FILE"
        
        # 立即应用环境变量
        source "$CUDA_ENV_FILE"
    fi
    
    echo ""
fi

echo -e "${YELLOW}[3/4] 配置 pip 国内镜像...${NC}"

# 创建 pip 配置目录
mkdir -p ~/.pip

# 写入配置
cat > ~/.pip/pip.conf << 'EOF'
[global]
index-url = https://pypi.tuna.tsinghua.edu.cn/simple
extra-index-url = 
    https://mirrors.aliyun.com/pypi/simple/
    https://mirrors.cloud.tencent.com/pypi/simple/
    https://pypi.mirrors.ustc.edu.cn/simple/

[install]
trusted-host = 
    pypi.tuna.tsinghua.edu.cn
    mirrors.aliyun.com
    mirrors.cloud.tencent.com
    pypi.mirrors.ustc.edu.cn
timeout = 120
EOF

echo -e "${GREEN}✓ pip 镜像配置完成${NC}\n"

echo -e "${YELLOW}[4/4] 安装 Python 依赖包...${NC}"

# 根据平台显示安装策略
echo -e "\n${BLUE}安装策略: ${NC}"
case "$INSTALL_STRATEGY" in
    jetson)
        echo "  • Jetson 平台（ARM64 + GPU）"
        echo "  • 将尝试安装 vLLM（可能需要额外配置）"
        echo "  • 如果 vLLM 失败，将提供 Transformers 作为备选"
        ;;
    arm64_cpu)
        echo "  • ARM64 平台（无 GPU）"
        echo "  • 将跳过 vLLM（需要 NVIDIA GPU）"
        echo "  • 使用 Transformers + PyTorch CPU 版本"
        ;;
    x86_gpu)
        echo "  • x86_64 + NVIDIA GPU"
        echo "  • 完整安装：PyTorch (CUDA) + vLLM + Transformers"
        echo "  • 这是推荐配置"
        ;;
    x86_cpu)
        echo "  • x86_64（无 GPU）"
        echo "  • 将跳过 vLLM（需要 NVIDIA GPU）"
        echo "  • 使用 Transformers + PyTorch CPU 版本"
        ;;
    *)
        echo "  • 通用安装策略"
        ;;
esac

echo ""
read -p "是否继续安装 Python 依赖？(y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}安装已取消${NC}"
    exit 0
fi

# 激活环境
eval "$(conda shell.bash hook)"
conda activate ${ENV_NAME}

echo -e "\n${YELLOW}升级 pip...${NC}"
pip install --upgrade pip

# ============================================
# 根据平台安装依赖
# ============================================

install_success=true

case "$INSTALL_STRATEGY" in
    jetson|x86_gpu)
        echo -e "\n${BLUE}=== 安装 GPU 版本依赖 ===${NC}"
        
        # 安装核心依赖（跳过 PyAudio）
        echo -e "${YELLOW}安装核心依赖（不包括 PyAudio）...${NC}"
        if grep -v "PyAudio" requirements.txt | pip install -r /dev/stdin; then
            echo -e "${GREEN}✓ 核心依赖安装成功${NC}"
        else
            echo -e "${RED}✗ 部分依赖安装失败${NC}"
            install_success=false
        fi
        
        # 诊断 vLLM
        echo -e "\n${YELLOW}诊断 vLLM...${NC}"
        if python -c "import vllm; print(f'vLLM {vllm.__version__}')" 2>/dev/null; then
            echo -e "${GREEN}✓ vLLM 导入成功${NC}"
        else
            echo -e "${YELLOW}⚠ vLLM 导入失败，诊断错误...${NC}"
            ERROR_MSG=$(python -c "import vllm" 2>&1) || true
            
            if echo "$ERROR_MSG" | grep -q "libcudart.so"; then
                echo -e "${YELLOW}检测到 CUDA 运行时库问题${NC}"
                
                # 尝试配置 CUDA 环境
                echo -e "${YELLOW}尝试配置 CUDA 环境...${NC}"
                
                # 查找 CUDA 库
                CUDA_LIB_PATHS=(
                    "/usr/local/cuda/lib64"
                    "/usr/local/cuda-12.1/lib64"
                    "/usr/local/cuda-12/lib64"
                    "$CONDA_PREFIX/lib"
                )
                
                CUDA_FOUND=false
                for lib_path in "${CUDA_LIB_PATHS[@]}"; do
                    if [ -f "$lib_path/libcudart.so.12" ] || [ -f "$lib_path/libcudart.so" ]; then
                        echo -e "${GREEN}✓ 找到 CUDA 库: $lib_path${NC}"
                        export LD_LIBRARY_PATH="$lib_path:$LD_LIBRARY_PATH"
                        CUDA_FOUND=true
                        break
                    fi
                done
                
                if ! $CUDA_FOUND; then
                    echo -e "${YELLOW}未找到系统 CUDA 库，尝试通过 Conda 安装...${NC}"
                    if conda install -c nvidia cuda-toolkit=12.1 -y; then
                        echo -e "${GREEN}✓ CUDA toolkit 安装成功${NC}"
                        export LD_LIBRARY_PATH="$CONDA_PREFIX/lib:$LD_LIBRARY_PATH"
                    else
                        echo -e "${RED}✗ CUDA toolkit 安装失败${NC}"
                    fi
                fi
                
                # 再次测试
                echo -e "\n${YELLOW}重新测试 vLLM...${NC}"
                if python -c "import vllm; print(f'vLLM {vllm.__version__}')" 2>/dev/null; then
                    echo -e "${GREEN}✓ vLLM 现在可以工作了！${NC}"
                    
                    # 保存环境变量配置
                    echo -e "\n${YELLOW}保存 CUDA 环境变量到 ~/.bashrc...${NC}"
                    if ! grep -q "LD_LIBRARY_PATH.*cuda" ~/.bashrc; then
                        echo "" >> ~/.bashrc
                        echo "# CUDA 环境变量（由 gpt-oss 安装脚本添加）" >> ~/.bashrc
                        echo "export LD_LIBRARY_PATH=$LD_LIBRARY_PATH" >> ~/.bashrc
                        echo -e "${GREEN}✓ 已添加到 ~/.bashrc${NC}"
                        echo -e "${YELLOW}  请运行: source ~/.bashrc${NC}"
                    fi
                else
                    echo -e "${RED}✗ vLLM 仍无法工作${NC}"
                    if [[ "$INSTALL_STRATEGY" == "jetson" ]]; then
                        echo -e "\n${YELLOW}Jetson 平台 vLLM 兼容性提示：${NC}"
                        echo "  • vLLM 主要为 x86_64 + NVIDIA GPU 优化"
                        echo "  • Jetson (ARM64) 支持可能需要额外配置"
                        echo "  • 建议使用 Transformers 作为替代（已安装）"
                    fi
                    install_success=false
                fi
            else
                echo -e "${RED}其他导入错误：${NC}"
                echo "$ERROR_MSG" | head -10
                install_success=false
            fi
        fi
        ;;
        
    arm64_cpu|x86_cpu)
        echo -e "\n${BLUE}=== 安装 CPU 版本依赖 ===${NC}"
        echo -e "${YELLOW}注意：跳过 vLLM（需要 NVIDIA GPU）${NC}"
        
        # 创建临时 requirements 文件（排除 vLLM 和 PyAudio）
        TEMP_REQ="/tmp/requirements_cpu.txt"
        grep -v -E "vllm|PyAudio" requirements.txt > $TEMP_REQ
        
        echo -e "${YELLOW}安装核心依赖...${NC}"
        if pip install -r $TEMP_REQ; then
            echo -e "${GREEN}✓ 核心依赖安装成功${NC}"
        else
            echo -e "${RED}✗ 部分依赖安装失败${NC}"
            install_success=false
        fi
        
        # 安装 CPU 版本的 PyTorch
        echo -e "\n${YELLOW}安装 PyTorch CPU 版本...${NC}"
        if pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu; then
            echo -e "${GREEN}✓ PyTorch CPU 版本安装成功${NC}"
        else
            echo -e "${RED}✗ PyTorch 安装失败${NC}"
            install_success=false
        fi
        
        rm -f $TEMP_REQ
        ;;
        
    *)
        echo -e "\n${YELLOW}使用标准安装流程...${NC}"
        if grep -v "PyAudio" requirements.txt | pip install -r /dev/stdin; then
            echo -e "${GREEN}✓ 依赖安装成功${NC}"
        else
            echo -e "${RED}✗ 部分依赖安装失败${NC}"
            install_success=false
        fi
        ;;
esac

# ============================================
# 验证安装
# ============================================

echo -e "\n${BLUE}=== 验证安装 ===${NC}"

# 检查 PyTorch
if python -c "import torch; print(f'PyTorch: {torch.__version__}')" 2>/dev/null; then
    TORCH_VER=$(python -c "import torch; print(torch.__version__)" 2>/dev/null)
    echo -e "${GREEN}✓ PyTorch ${TORCH_VER}${NC}"
    
    # 检查 CUDA 支持
    if python -c "import torch; exit(0 if torch.cuda.is_available() else 1)" 2>/dev/null; then
        CUDA_VER=$(python -c "import torch; print(torch.version.cuda)" 2>/dev/null)
        GPU_COUNT=$(python -c "import torch; print(torch.cuda.device_count())" 2>/dev/null)
        echo -e "${GREEN}  └─ CUDA ${CUDA_VER}, ${GPU_COUNT} GPU(s)${NC}"
    else
        echo -e "${YELLOW}  └─ CPU only${NC}"
    fi
else
    echo -e "${RED}✗ PyTorch 未安装${NC}"
fi

# 检查 Transformers
if python -c "import transformers" 2>/dev/null; then
    TRANS_VER=$(python -c "import transformers; print(transformers.__version__)" 2>/dev/null)
    echo -e "${GREEN}✓ Transformers ${TRANS_VER}${NC}"
else
    echo -e "${RED}✗ Transformers 未安装${NC}"
fi

# 检查 vLLM
if python -c "import vllm" 2>/dev/null; then
    VLLM_VER=$(python -c "import vllm; print(vllm.__version__)" 2>/dev/null)
    echo -e "${GREEN}✓ vLLM ${VLLM_VER}${NC}"
else
    echo -e "${YELLOW}⚠ vLLM 未安装或无法导入${NC}"
fi

# ============================================
# 诊断和建议
# ============================================

echo -e "\n${BLUE}======================================"
echo "安装完成"
echo -e "======================================${NC}\n"

# 提供针对性建议
if $install_success; then
    echo -e "${GREEN}✓ 环境配置成功！${NC}\n"
    
    case "$INSTALL_STRATEGY" in
        x86_gpu)
            echo "推荐使用方案："
            echo "  1. vLLM (高性能): vllm serve openai/gpt-oss-20b"
            echo "  2. Transformers (易用): python -m gpt_oss.chat gpt-oss-20b/"
            ;;
        jetson)
            if python -c "import vllm" 2>/dev/null; then
                echo "推荐使用方案："
                echo "  1. vLLM: vllm serve openai/gpt-oss-20b"
                echo "  2. Transformers: python -m gpt_oss.chat gpt-oss-20b/"
                echo ""
                echo -e "${YELLOW}注意：Jetson 上 vLLM 性能需要实测验证${NC}"
            else
                echo "推荐使用方案："
                echo "  1. Transformers: python -m gpt_oss.chat gpt-oss-20b/"
                echo "  2. PyTorch: 使用项目中的 torch/ 目录"
                echo ""
                echo -e "${YELLOW}vLLM 在 Jetson 上需要额外配置，建议先使用 Transformers${NC}"
            fi
            ;;
        arm64_cpu|x86_cpu)
            echo "推荐使用方案："
            echo "  1. Transformers (CPU): python -m gpt_oss.chat gpt-oss-20b/"
            echo "  2. Ollama (本地): ollama run gpt-oss:20b"
            echo ""
            echo -e "${YELLOW}注意：CPU 推理速度较慢，建议使用量化模型${NC}"
            ;;
    esac
    
else
    echo -e "${YELLOW}⚠ 安装部分成功，但有一些问题${NC}\n"
    
    echo "故障排除："
    echo "  1. 查看上方错误信息"
    echo "  2. 检查 CUDA 配置: nvidia-smi"
    echo "  3. 查看文档: 项目说明.md"
    echo "  4. 手动安装失败的包"
fi

# 快速诊断命令
echo -e "\n${BLUE}快速诊断命令：${NC}"
echo "  • 检查环境: conda activate ${ENV_NAME} && python -c 'import torch, transformers; print(\"OK\")'"
echo "  • 测试 CUDA: python -c 'import torch; print(torch.cuda.is_available())'"
echo "  • 测试 vLLM: python -c 'import vllm; print(\"OK\")'"
echo "  • 查看 GPU: nvidia-smi"

# 环境变量提示
if [[ "$LD_LIBRARY_PATH" == *cuda* ]]; then
    echo -e "\n${YELLOW}重要：已修改 LD_LIBRARY_PATH，请运行：${NC}"
    echo "  source ~/.bashrc"
fi

echo -e "\n详细文档: ${BLUE}项目说明.md${NC}"
echo ""
