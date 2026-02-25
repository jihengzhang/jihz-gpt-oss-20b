#!/bin/bash

# 启用调试模式：显示每条命令及其参数
# set -x

# vLLM 启动脚本 - GPT-OSS-20B 部署
# 支持平台: x86_64 (RTX PRO 6000) 和 aarch64 (Jetson Thor)
#
# 用法:
#   ./start_vllm.sh --start    启动 vLLM 服务
#   ./start_vllm.sh --stop     停止 vLLM 服务
#   ./start_vllm.sh --restart  重启 vLLM 服务

# ==================== 硬件自动检测 ====================
ARCH=$(uname -m)

if [ "$ARCH" = "aarch64" ]; then
  # ---- Jetson Thor (aarch64) ----
  HW_NAME="NVIDIA Jetson Thor"
  HW_DESC="128GB 统一内存, 单 GPU"
  export CUDA_VISIBLE_DEVICES=0
  # CUDA 13.0 库路径（提供 libcudart.so.12 兼容软链接）
  export LD_LIBRARY_PATH=/usr/local/cuda-13.0/targets/sbsa-linux/lib:${LD_LIBRARY_PATH}
  # 使用系统 CUDA 13.0 的 ptxas，Triton 捆绑的 ptxas 不支持 sm_110a (Blackwell)
  export TRITON_PTXAS_PATH=/usr/local/cuda-13.0/bin/ptxas
  CONDA_ENV="env_vllm2"
  GPU_MEMORY_UTILIZATION=0.65
  TENSOR_PARALLEL_SIZE=1
  MAX_MODEL_LEN=1024
  MAX_NUM_SEQS=32
else
  # ---- x86_64 (RTX PRO 6000 等) ----
  HW_NAME="x86_64 Server"
  HW_DESC="2x NVIDIA RTX PRO 6000, 195GB 总显存"
  export CUDA_VISIBLE_DEVICES=1,2
  export CUDA_DEVICE_ORDER=PCI_BUS_ID
  CONDA_ENV="gpt-oss-env"
  GPU_MEMORY_UTILIZATION=0.4
  TENSOR_PARALLEL_SIZE=2
  MAX_MODEL_LEN=2048
  MAX_NUM_SEQS=256
fi

echo "检测到硬件平台: $HW_NAME ($ARCH)"

# ==================== 通用环境变量 ====================
# 启用 PyTorch 内存分配器的可扩展段，避免内存碎片化
export PYTORCH_ALLOC_CONF=expandable_segments:True
# 设置 tiktoken 缓存目录，使用本地 tokenizer 文件
export TIKTOKEN_CACHE_DIR="/home/tester/jihz-gpt-oss-20b"
# HuggingFace 中国镜像配置（用于下载vocab文件）
export HF_ENDPOINT=https://hf-mirror.com
# 如果使用其他镜像源，请取消以下注释并修改
# export HF_ENDPOINT=https://hf.xwall.us.kg
# openai_harmony 使用 tiktoken-rs (Rust), 需要 TIKTOKEN_ENCODINGS_BASE 指向本地 vocab 目录
# 避免 Rust TLS 栈在 Jetson 上下载 openaipublic.blob.core.windows.net 失败
export TIKTOKEN_ENCODINGS_BASE="/home/tester/jihz-gpt-oss-20b/tiktoken_vocab"

# ==================== 模型配置 ====================
MODEL_PATH="/home/tester/jihz-gpt-oss-20b/gpt-oss-20b"
HF_REPO_ID="openai/gpt-oss-20b"
TIKTOKEN_VOCAB_DIR="/home/tester/jihz-gpt-oss-20b/tiktoken_vocab"
TIKTOKEN_VOCAB_FILE="$TIKTOKEN_VOCAB_DIR/o200k_base.tiktoken"
TIKTOKEN_VOCAB_SHA256="446a9538cb6c348e3516120d7c08b09f57c36495e2acfffe59a5bf8b0cfb1a2d"
TIKTOKEN_VOCAB_URL="https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken"
PORT=8010
PID_FILE="vllm.pid"
# ==================== 函数定义 ====================

# 检查并自动下载 tiktoken vocab 文件（openai_harmony 所需）
ensure_tiktoken_vocab() {
  mkdir -p "$TIKTOKEN_VOCAB_DIR"

  # 检查文件是否存在且 SHA256 正确
  if [ -f "$TIKTOKEN_VOCAB_FILE" ]; then
    ACTUAL_HASH=$(sha256sum "$TIKTOKEN_VOCAB_FILE" | awk '{print $1}')
    if [ "$ACTUAL_HASH" = "$TIKTOKEN_VOCAB_SHA256" ]; then
      echo "✓ tiktoken vocab 文件已就绪"
      return 0
    else
      echo "⚠ tiktoken vocab 文件哈希不匹配，重新下载..."
      rm -f "$TIKTOKEN_VOCAB_FILE"
    fi
  fi

  echo "下载 tiktoken vocab 文件..."
  echo "  来源: $TIKTOKEN_VOCAB_URL"
  curl -L --max-time 120 --retry 3 -o "$TIKTOKEN_VOCAB_FILE" "$TIKTOKEN_VOCAB_URL"
  if [ $? -ne 0 ]; then
    echo "✗ tiktoken vocab 下载失败"
    return 1
  fi

  ACTUAL_HASH=$(sha256sum "$TIKTOKEN_VOCAB_FILE" | awk '{print $1}')
  if [ "$ACTUAL_HASH" != "$TIKTOKEN_VOCAB_SHA256" ]; then
    echo "✗ tiktoken vocab 哈希校验失败 (got: $ACTUAL_HASH)"
    rm -f "$TIKTOKEN_VOCAB_FILE"
    return 1
  fi

  echo "✓ tiktoken vocab 下载完成"
  return 0
}

# 检查并自动下载模型权重
ensure_model_weights() {
  # 检查是否已存在 .safetensors 权重文件
  WEIGHT_COUNT=$(find "$MODEL_PATH" -maxdepth 1 -name "*.safetensors" 2>/dev/null | wc -l)
  if [ "$WEIGHT_COUNT" -gt 0 ]; then
    echo "✓ 模型权重已存在 ($WEIGHT_COUNT 个 safetensors 文件)"
    return 0
  fi

  echo "=========================================="
  echo "未检测到模型权重文件，开始自动下载..."
  echo "  来源: HuggingFace 仓库 $HF_REPO_ID"
  echo "  镜像: $HF_ENDPOINT"
  echo "  目标: $MODEL_PATH"
  echo "=========================================="

  # 确保目标目录存在
  mkdir -p "$MODEL_PATH"

  # 使用 conda 环境中的 huggingface-cli 下载
  # --local-dir-use-symlinks False 避免只下载到缓存而目录内为软链接
  (
    source /home/tester/miniconda3/bin/activate "$CONDA_ENV"
    huggingface-cli download "$HF_REPO_ID" \
      --local-dir "$MODEL_PATH" \
      --local-dir-use-symlinks False \
      --include "*.safetensors" "*.safetensors.index.json" \
        "config.json" "generation_config.json" \
        "tokenizer.json" "tokenizer_config.json" \
        "special_tokens_map.json" "chat_template.jinja"
  )
  DOWNLOAD_STATUS=$?

  if [ $DOWNLOAD_STATUS -ne 0 ]; then
    echo "✗ 模型权重下载失败（退出码: $DOWNLOAD_STATUS）"
    echo "  请手动执行："
    echo "    huggingface-cli download $HF_REPO_ID --local-dir $MODEL_PATH"
    return 1
  fi

  # 再次确认
  WEIGHT_COUNT=$(find "$MODEL_PATH" -maxdepth 1 -name "*.safetensors" 2>/dev/null | wc -l)
  if [ "$WEIGHT_COUNT" -eq 0 ]; then
    echo "✗ 下载完成但未找到 safetensors 文件，请检查网络或镜像源"
    return 1
  fi

  echo "=========================================="
  echo "✓ 模型权重下载完成 ($WEIGHT_COUNT 个文件)"
  echo "=========================================="
  return 0
}

# 启动 vLLM 服务
start_vllm() {
  echo "=========================================="
  echo "启动 GPT-OSS-20B vLLM 服务器"
  echo "=========================================="
  echo "模型路径: $MODEL_PATH"
  echo "硬件平台: $HW_NAME ($HW_DESC)"
  echo "精度模式: BFloat16 (精度优化)"
  echo "最大序列长度: $MAX_MODEL_LEN tokens"
  echo "张量并行: $TENSOR_PARALLEL_SIZE GPU"
  echo "显存利用率: $GPU_MEMORY_UTILIZATION"
  echo "API 端口: $PORT"
  echo "=========================================="

  # 确保 tiktoken vocab 文件已就绪（openai_harmony 运行时需要）
  ensure_tiktoken_vocab || return 1

  # 确保模型权重已下载
  ensure_model_weights || return 1

  # 检查可用内存（vLLM 需要约 gpu_memory_utilization * 总内存，此处约 98 GiB）
  AVAIL_GIB=$(awk '/MemAvailable/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
  REQUIRED_GIB=$(echo "$GPU_MEMORY_UTILIZATION * 122" | awk '{printf "%.0f", $1*$3}')
  if [ "$AVAIL_GIB" -lt "$REQUIRED_GIB" ]; then
    echo "⚠ 可用内存不足: ${AVAIL_GIB} GiB 可用，vLLM 约需 ${REQUIRED_GIB} GiB"
    echo "  尝试释放内核页缓存..."
    sudo sh -c 'sync && echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null
    AVAIL_GIB=$(awk '/MemAvailable/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
    echo "  释放后可用内存: ${AVAIL_GIB} GiB"
    if [ "$AVAIL_GIB" -lt "$REQUIRED_GIB" ]; then
      echo "✗ 内存仍然不足，请先重启系统或关闭其他占用内存的进程"
      return 1
    fi
    echo "✓ 内存已充足"
  else
    echo "✓ 可用内存充足: ${AVAIL_GIB} GiB"
  fi

  # 检查是否已经运行（通过ps aux检查）
  EXISTING_PID=$(ps aux | grep -E "vllm serve.*$MODEL_PATH" | grep -v grep | awk '{print $2}' | head -1)
  if [ -n "$EXISTING_PID" ]; then
    echo "✗ vLLM 已在运行 (PID: $EXISTING_PID)"
    return 1
  fi

  # 清空旧的日志文件
  > log.txt

  # 激活conda环境后，直接调用vllm serve命令
  # 所有输出重定向到log.txt
  {
    source /home/tester/miniconda3/bin/activate "$CONDA_ENV"
    nohup vllm serve "$MODEL_PATH" \
      --port "$PORT" \
      --served-model-name gpt-oss-20b \
      --dtype bfloat16 \
      --max-model-len "$MAX_MODEL_LEN" \
      --tensor-parallel-size "$TENSOR_PARALLEL_SIZE" \
      --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" \
      --max-num-seqs "$MAX_NUM_SEQS" < /dev/null > log.txt 2>&1 &
  }

  # 显示启动过程
  echo "vLLM 服务器启动中（后台进程）..."
  echo "=========================================="
  echo "实时日志输出（Ctrl+C 继续）："
  echo "=========================================="
  
  # 实时显示日志，等待服务启动或失败
  tail -f log.txt &
  TAIL_PID=$!
  
  # 等待服务启动（检查API是否响应或最多等待1200秒）
  # 首次启动需要 Triton/torch.compile 编译内核，耗时较长（Blackwell架构尤为明显）
  TIMEOUT=1200
  ELAPSED=0
  while [ $ELAPSED -lt $TIMEOUT ]; do
    sleep 1
    ELAPSED=$((ELAPSED + 1))
    
    # 检查vLLM进程是否存在
    VLLM_PID=$(ps aux | grep -E "vllm serve.*$MODEL_PATH" | grep -v grep | awk '{print $2}' | head -1)
    if [ -z "$VLLM_PID" ]; then
      # 进程已死亡，检查日志中是否有错误
      echo ""
      echo "✗ vLLM 进程启动失败"
      kill $TAIL_PID 2>/dev/null
      wait $TAIL_PID 2>/dev/null
      return 1
    fi
    
    # 检查API是否开始响应
    if curl -s "http://localhost:$PORT/v1/models" > /dev/null 2>&1; then
      # 服务已启动
      echo ""
      echo "=========================================="
      kill $TAIL_PID 2>/dev/null
      wait $TAIL_PID 2>/dev/null
      echo "=========================================="
      echo "$VLLM_PID" > "$PID_FILE"
      echo "✓ vLLM 进程已启动，PID: $VLLM_PID"
      echo "✓ 日志文件: ./log.txt"
      echo "✓ API 地址: http://localhost:$PORT/v1/models"
      return 0
    fi
  done
  
  # 超时
  echo ""
  echo "=========================================="
  kill $TAIL_PID 2>/dev/null
  wait $TAIL_PID 2>/dev/null
  echo "✗ vLLM 启动超时（${TIMEOUT}秒内未响应）"
  echo "✓ 进程仍在后台运行，请继续等待并查看日志：tail -f log.txt"
  
  # 再等待一次，确认进程还在
  VLLM_PID=$(ps aux | grep -E "vllm serve.*$MODEL_PATH" | grep -v grep | awk '{print $2}' | head -1)
  if [ -n "$VLLM_PID" ]; then
    echo "$VLLM_PID" > "$PID_FILE"
    echo "✓ vLLM 进程 PID: $VLLM_PID"
    return 0
  else
    echo "✗ vLLM 进程已退出"
    return 1
  fi
}

# 停止 vLLM 服务
stop_vllm() {
  echo "停止 GPT-OSS-20B vLLM 服务器..."
  
  # 通过ps aux查找进程
  VLLM_PID=$(ps aux | grep -E "vllm serve.*$MODEL_PATH" | grep -v grep | awk '{print $2}' | head -1)
  
  if [ -n "$VLLM_PID" ]; then
    kill "$VLLM_PID"
    sleep 2
    
    # 检查进程是否还在运行
    if ps -p "$VLLM_PID" > /dev/null 2>&1; then
      kill -9 "$VLLM_PID"
      echo "✓ vLLM 进程已强制终止 (PID: $VLLM_PID)"
    else
      echo "✓ vLLM 进程已停止 (PID: $VLLM_PID)"
    fi
    rm -f "$PID_FILE"
    # 释放内核页缓存，回收 CUDA 统一内存，为下次启动腾出空间
    echo "  释放内核页缓存..."
    sudo sh -c 'sync && echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null && echo "✓ 页缓存已释放" || echo "  (无 sudo 权限，跳过页缓存释放)"
    return 0
  else
    echo "✗ vLLM 服务未运行"
    rm -f "$PID_FILE"
    return 1
  fi
}

# 重启 vLLM 服务
restart_vllm() {
  echo "重启 GPT-OSS-20B vLLM 服务器..."
  stop_vllm
  
  # 显示等待进度（倒计时）
  echo "等待服务完全停止..."
  for i in {5..1}; do
    echo -ne "\r⏳ 等待中... ${i}秒"
    sleep 1
  done
  echo -e "\r✓ 服务已停止          "
  echo ""
  
  start_vllm
}

# 显示帮助信息
show_help() {
  cat << EOF
用法: $0 [选项]

选项:
  --start    启动 vLLM 服务
  --stop     停止 vLLM 服务
  --restart  重启 vLLM 服务
  --status   查看服务状态
  --help     显示此帮助信息

示例:
  $0 --start      # 启动服务
  $0 --stop       # 停止服务
  $0 --restart    # 重启服务

EOF
}

# 默认行为: 不指定选项时等同于 --start

# 查看服务状态
status_vllm() {
  # 通过ps aux查找进程
  VLLM_PID=$(ps aux | grep -E "vllm serve.*$MODEL_PATH" | grep -v grep | awk '{print $2}' | head -1)
  
  if [ -n "$VLLM_PID" ]; then
    echo "✓ vLLM 服务运行中 (PID: $VLLM_PID)"
    echo "  API 地址: http://localhost:$PORT/v1/models"
    echo "  日志文件: ./log.txt"
    return 0
  else
    echo "✗ vLLM 服务未运行"
    return 1
  fi
}

# ==================== 主程序 ====================

# 如果没有参数，显示帮助信息
if [ $# -eq 0 ]; then
  show_help
  return 0
fi

# 处理参数
case "$1" in
  --start)
    start_vllm
    return $?
    ;;
  --stop)
    stop_vllm
    return $?
    ;;
  --restart)
    restart_vllm
    return $?
    ;;
  --status)
    status_vllm
    return $?
    ;;
  --help|-h)
    show_help
    return 0
    ;;
  *)
    echo "未知选项: $1"
    show_help
    return 1
    ;;
esac

# ==================== 备选配置说明 ====================
# 如果仍然内存不足，可以尝试以下配置：
#
# 方案1: 进一步减小序列长度
# --max-model-len 1024
#
# 方案2: 单 GPU 模式（降低吞吐量但节省显存）
# export CUDA_VISIBLE_DEVICES=0
# --tensor-parallel-size 1
# --gpu-memory-utilization 0.9
#
# 方案3: 降低显存利用率
# --gpu-memory-utilization 0.75