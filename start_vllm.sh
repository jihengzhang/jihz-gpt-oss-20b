#!/bin/bash

# 启用调试模式：显示每条命令及其参数
# set -x

# vLLM 启动脚本 - GPT-OSS-20B 部署
# 硬件配置: 2x NVIDIA RTX PRO 6000 (97.5GB 每块)
# 优化策略: 双GPU张量并行 + BFloat16精度
# 
# 用法:
#   ./start_vllm.sh --start    启动 vLLM 服务
#   ./start_vllm.sh --stop     停止 vLLM 服务
#   ./start_vllm.sh --restart  重启 vLLM 服务

export CUDA_VISIBLE_DEVICES=1,2
# 设置 GPU 顺序为 PCI 总线顺序，避免设备混乱
export CUDA_DEVICE_ORDER=PCI_BUS_ID
# 启用 PyTorch 内存分配器的可扩展段，避免内存碎片化
export PYTORCH_ALLOC_CONF=expandable_segments:True
# 设置 tiktoken 缓存目录，使用本地 tokenizer 文件
export TIKTOKEN_CACHE_DIR="/home/tester/jihz-gpt-oss-20b"
# HuggingFace 中国镜像配置（用于下载vocab文件）
export HF_ENDPOINT=https://hf-mirror.com

# 如果使用其他镜像源，请取消以下注释并修改
# export HF_ENDPOINT=https://hf.xwall.us.kg 

# ==================== 模型配置 ====================
MODEL_PATH="/home/tester/jihz-gpt-oss-20b/gpt-oss-20b"
PORT=8010
PID_FILE="vllm.pid"

# ==================== 函数定义 ====================

# 启动 vLLM 服务
start_vllm() {
  echo "=========================================="
  echo "启动 GPT-OSS-20B vLLM 服务器"
  echo "=========================================="
  echo "模型路径: $MODEL_PATH"
  echo "GPU 配置: 2x NVIDIA RTX PRO 6000 (195GB 总显存)"
  echo "精度模式: BFloat16 (精度优化)"
  echo "最大序列长度: 2048 tokens"
  echo "张量并行: 1 GPU"
  echo "显存利用率: 50%"
  echo "API 端口: $PORT"
  echo "=========================================="

  # 检查是否已经运行
  if [ -f "$PID_FILE" ]; then
    EXISTING_PID=$(cat "$PID_FILE")
    if ps -p "$EXISTING_PID" > /dev/null 2>&1; then
      echo "✗ vLLM 已在运行 (PID: $EXISTING_PID)"
      return 1
    fi
  fi

  # 以后台进程方式启动（daemon），所有输出重定向到 log.txt
  nohup conda run -p /home/tester/miniconda3/envs/gpt-oss-env \
    vllm serve "$MODEL_PATH" \
    --port "$PORT" \
    --served-model-name gpt-oss-20b \
    --dtype bfloat16 \
    --max-model-len 2048 \
    --tensor-parallel-size 1 \
    --gpu-memory-utilization 0.4 > log.txt 2>&1 &

  # 打印进程 ID
  echo "vLLM 服务器启动中（后台进程）..."
  sleep 2
  VLLM_PID=$(pgrep -f "vllm serve.*$MODEL_PATH" | head -1)
  if [ -n "$VLLM_PID" ]; then
    echo "$VLLM_PID" > "$PID_FILE"
    echo "✓ vLLM 进程已启动，PID: $VLLM_PID"
    echo "✓ 日志文件: ./log.txt"
    echo "✓ API 地址: http://localhost:$PORT/v1/models"
    return 0
  else
    echo "✗ vLLM 启动失败，请查看日志：tail -f log.txt"
    return 1
  fi
}

# 停止 vLLM 服务
stop_vllm() {
  echo "停止 GPT-OSS-20B vLLM 服务器..."
  
  if [ -f "$PID_FILE" ]; then
    VLLM_PID=$(cat "$PID_FILE")
    if ps -p "$VLLM_PID" > /dev/null 2>&1; then
      kill "$VLLM_PID"
      sleep 1
      if ps -p "$VLLM_PID" > /dev/null 2>&1; then
        kill -9 "$VLLM_PID"
        echo "✓ vLLM 进程已强制终止 (PID: $VLLM_PID)"
      else
        echo "✓ vLLM 进程已停止 (PID: $VLLM_PID)"
      fi
      rm -f "$PID_FILE"
    else
      echo "✗ PID 文件存在但进程不运行，清理 PID 文件"
      rm -f "$PID_FILE"
    fi
  else
    # 直接查找进程
    VLLM_PID=$(pgrep -f "vllm serve.*$MODEL_PATH" | head -1)
    if [ -n "$VLLM_PID" ]; then
      kill "$VLLM_PID"
      sleep 1
      if ps -p "$VLLM_PID" > /dev/null 2>&1; then
        kill -9 "$VLLM_PID"
        echo "✓ vLLM 进程已强制终止 (PID: $VLLM_PID)"
      else
        echo "✓ vLLM 进程已停止 (PID: $VLLM_PID)"
      fi
    else
      echo "✗ vLLM 服务未运行"
      return 1
    fi
  fi
  return 0
}

# 重启 vLLM 服务
restart_vllm() {
  echo "重启 GPT-OSS-20B vLLM 服务器..."
  stop_vllm
  sleep 2
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
  if [ -f "$PID_FILE" ]; then
    VLLM_PID=$(cat "$PID_FILE")
    if ps -p "$VLLM_PID" > /dev/null 2>&1; then
      echo "✓ vLLM 服务运行中 (PID: $VLLM_PID)"
      echo "  API 地址: http://localhost:$PORT/v1/models"
      echo "  日志文件: ./log.txt"
      return 0
    else
      echo "✗ PID 文件存在但进程未运行，请执行: $0 --start"
      return 1
    fi
  else
    VLLM_PID=$(pgrep -f "vllm serve.*$MODEL_PATH" | head -1)
    if [ -n "$VLLM_PID" ]; then
      echo "✓ vLLM 服务运行中 (PID: $VLLM_PID)"
      echo "  API 地址: http://localhost:$PORT/v1/models"
      echo "  日志文件: ./log.txt"
      return 0
    else
      echo "✗ vLLM 服务未运行"
      return 1
    fi
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