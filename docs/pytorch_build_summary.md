# PyTorch sm_110 (NVIDIA Thor) 编译记录

## 背景

**目标**：让 vllm 在 Jetson Thor 上运行  
**问题**：所有预编译 PyTorch wheel 仅支持 sm_80/sm_90/sm_100/sm_120，不支持 Jetson Thor 的 sm_110  
**解决方案**：从源码编译 PyTorch，加入 `TORCH_CUDA_ARCH_LIST="11.0"`

---

## 环境信息

| 项目 | 值 |
|------|-----|
| 硬件 | NVIDIA Jetson Thor (sbsa-linux, aarch64) |
| GPU Compute Capability | sm_110 |
| CUDA 版本 | 13.0.48 |
| nvcc 路径 | `/usr/local/cuda-13.0/bin/nvcc` |
| CUDA 库路径 | `/usr/local/cuda-13.0/targets/sbsa-linux/lib/` |
| Python | 3.12 |
| conda 环境 | `env_vllm2` |
| PyTorch 目标版本 | 2.9.1 |
| 磁盘空间 | 851GB 可用 |
| 内存 | 122GB |
| CPU 核心 | 14 核 |

---

## 已完成的操作

### 1. 源码获取
```bash
# 从 Gitee 镜像克隆（GitHub 直连速度不稳定）
git clone --depth 1 --branch v2.9.1 https://gitee.com/mirrors/pytorch.git /tmp/pytorch-src
```
- 源码位置：`/tmp/pytorch-src`
- 克隆方式：`--depth 1`（浅克隆，节省时间）

### 2. 子模块初始化
```bash
cd /tmp/pytorch-src

# 第一轮：初始化所有顶层子模块
git submodule update --init --recursive --depth 1

# 手动补克隆失败的子模块（网络超时导致）
for sub in \
  third_party/XNNPACK \
  third_party/cutlass \
  third_party/flash-attention \
  third_party/flatbuffers \
  third_party/nlohmann \
  third_party/onnx \
  third_party/opentelemetry-cpp \
  third_party/pocketfft \
  third_party/protobuf \
  third_party/psimd \
  third_party/pthreadpool \
  third_party/pybind11; do
    git submodule update --init --depth 1 "$sub"
done
```

### 3. 未完成的子模块
- `third_party/python-peachpy` — 克隆未稳定完成，需要重新克隆
  - URL: `https://github.com/malfet/PeachPy.git`
- `third_party/kineto/libkineto/third_party/dynolog` — 可忽略（非核心依赖）

### 4. conda 环境准备
```bash
conda create -n env_vllm2 python=3.12 -y
conda activate env_vllm2

# 安装编译依赖
pip install cmake ninja pyyaml setuptools wheel astunparse numpy expecttest hypothesis scikit-build-core maturin

# 安装 vllm（已成功，但 PyTorch 是 CPU 版）
pip install vllm==0.14.0 --extra-index-url https://download.pytorch.org/whl/cu128

# CUDA 12 兼容软链接（已创建）
sudo ln -sf /usr/local/cuda-13.0/targets/sbsa-linux/lib/libcudart.so.13 \
            /usr/local/cuda-13.0/targets/sbsa-linux/lib/libcudart.so.12
```

---

## 编译命令（待执行）

在另一个 VSCode 窗口用 git 管理好 `/tmp/pytorch-src` 后，执行以下命令：

```bash
# 1. 激活环境
source ~/miniconda3/etc/profile.d/conda.sh && conda activate env_vllm2

# 2. 设置环境变量
export CUDA_HOME=/usr/local/cuda-13.0
export PATH=$CUDA_HOME/bin:$PATH
export LD_LIBRARY_PATH=$CUDA_HOME/targets/sbsa-linux/lib:$LD_LIBRARY_PATH
export TORCH_CUDA_ARCH_LIST="11.0"
export USE_CUDA=1
export USE_CUDNN=0
export USE_MKLDNN=0
export MAX_JOBS=8
export PYTORCH_BUILD_VERSION=2.9.1
export PYTORCH_BUILD_NUMBER=1
export USE_PRIORITIZED_TEXT_FOR_LD=1

# 3. 清除之前失败的构建缓存
cd /tmp/pytorch-src
rm -rf build

# 4. 开始编译（在 screen 中运行，防止断线）
screen -S pytorch_build
python setup.py bdist_wheel 2>&1 | tee /tmp/torch_build.log

# 5. 安装生成的 wheel
pip install dist/torch-*.whl --force-reinstall

# 6. 验证
python -c "
import torch
print('版本:', torch.__version__)
print('CUDA available:', torch.cuda.is_available())
print('arch list:', torch.cuda.get_arch_list())
print('GPU:', torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'N/A')
t = torch.zeros(1, device='cuda')
print('GPU tensor test:', t)
"
```

---

## 编译成功后需要重新安装 vllm

由于 vllm 0.14.0 的 `_C.abi3.so` 是针对 `torch==2.9.1` 编译的，编译新 torch 后需要一并重新安装：

```bash
# vllm 需要与 torch 同版本重新编译
pip install --no-binary :all: --no-build-isolation vllm==0.14.0
# 或直接重装预编译版（因为 abi 签名是 2.9.1）
pip install vllm==0.14.0 --force-reinstall
```

---

## 关键注意事项

1. **编译时间**：ARM64 + 14核预计 **2~4 小时**，请在 `screen` 或 `tmux` 中运行
2. **`python-peachpy`**：影响 x86 汇编优化，在 ARM64 上可以尝试跳过（`USE_NNPACK=0`）
3. **监控进度**：`tail -f /tmp/torch_build.log`
4. **进入 screen**：`screen -r pytorch_build`，退出用 `Ctrl+A D`（不要用 Ctrl+C）

---

## 跳过 python-peachpy 的可选方案

如果 `python-peachpy` 克隆仍然失败，可以禁用相关功能：

```bash
export USE_NNPACK=0
export USE_QNNPACK=0
python setup.py bdist_wheel
```

---

## 本地编译 Wheel 归档清单

> **归档目录**：`~/local_wheels/`  
> **编译日期**：2026-02-24  
> **平台**：aarch64 (sbsa-linux), Python 3.12, CUDA 13.0, sm_110

| 包名 | 文件名 | 大小 | SHA256 | 构建时间 |
|------|--------|------|--------|----------|
| PyTorch 2.9.1 | `torch-2.9.1-cp312-cp312-linux_aarch64.whl` | 261 MB | `02698a9b79a3be70c73ee1b30476c43df41c81a090ab5ae717a65b7add5c2b44` | 2026-02-23 |
| vLLM 0.14.1+cu130 | `vllm-0.14.1+cu130-cp312-cp312-linux_aarch64.whl` | 538 MB | `e5d87ec18360020457c88f71ed1741c59366247d1fb0a9ba80ab010e72abcd4a` | 2026-02-24 |
| torchvision 0.24.1 | `torchvision-0.24.1+d801a34-cp312-cp312-linux_aarch64.whl` | 1.7 MB | `202b58de403d9077264e82defd7b4cf907c387eb1a6e981866fcf9f06e1721aa` | 2026-02-24 |

### 重新安装命令

```bash
conda activate env_vllm2
pip install ~/local_wheels/torch-2.9.1-cp312-cp312-linux_aarch64.whl
pip install ~/local_wheels/torchvision-0.24.1+d801a34-cp312-cp312-linux_aarch64.whl --no-build-isolation
pip install ~/local_wheels/vllm-0.14.1+cu130-cp312-cp312-linux_aarch64.whl --no-build-isolation
```

### 源码位置（重新编译参考）

| 包 | 源码目录 | 来源标签/commit |
|----|----------|-----------------|
| PyTorch | `/tmp/pytorch-src` | `v2.9.1` |
| vLLM | `/tmp/vllm-src` | `v0.14.1` |
| torchvision | `/tmp/torchvision-src` | `v0.24.1` |
| CUTLASS | `/tmp/cutlass-4.2.1` | `v4.2.1`（vllm cmake 依赖） |

### 关键编译参数

```bash
# 通用环境变量
export CUDA_HOME=/usr/local/cuda-13.0
export TORCH_CUDA_ARCH_LIST="11.0"
export MAX_JOBS=8
export https_proxy=http://127.0.0.1:7897   # cmake FetchContent / huggingface 需要

# PyTorch 额外参数
export CPLUS_INCLUDE_PATH=$CUDA_HOME/include  # 解决 nvshmem 编译错误

# vLLM 额外参数（关键：不设置 VLLM_USE_PRECOMPILED）
export CMAKE_ARGS="-DFETCHCONTENT_SOURCE_DIR_CUTLASS=/tmp/cutlass-4.2.1"
unset VLLM_USE_PRECOMPILED
```
