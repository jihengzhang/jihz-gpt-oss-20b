#!/bin/bash

# vLLM 启动脚本 - GPT-OSS-20B 部署
# 硬件配置: 2x Quadro RTX 5000 (15GB 每块, Compute Capability 7.5)
# 优化策略: 双GPU张量并行 + FP16精度 + 内存优化

# ==================== 环境变量配置 ====================
# 排除不兼容的 GPU (Quadro P620 compute capability 6.1)
export CUDA_VISIBLE_DEVICES=0,1
# 设置 GPU 顺序为 PCI 总线顺序，避免设备混乱
export CUDA_DEVICE_ORDER=PCI_BUS_ID
# 启用 PyTorch 内存分配器的可扩展段，避免内存碎片化
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

# ==================== 模型配置 ====================
MODEL_PATH="/home/tester/AI_Tool/gpt-oss/gpt-oss-20b"
PORT=8010

# ==================== 启动信息 ====================
echo "=========================================="
echo "启动 GPT-OSS-20B vLLM 服务器"
echo "=========================================="
echo "模型路径: $MODEL_PATH"
echo "GPU 配置: 2x Quadro RTX 5000 (30GB 总显存)"
echo "精度模式: FP16 (半精度)"
echo "最大序列长度: 2048 tokens"
echo "张量并行: 2 GPUs"
echo "显存利用率: 85%"
echo "API 端口: $PORT"
echo "=========================================="
echo ""

# ==================== 启动 vLLM ====================
conda run -p /home/tester/miniconda3/envs/gpt-oss-env \
  python -m vllm.entrypoints.openai.api_server \
  --model "$MODEL_PATH" \
  --port "$PORT" \
  --dtype half \
  --max-model-len 2048 \
  --tensor-parallel-size 2 \
  --gpu-memory-utilization 0.85 \
  --trust-remote-code

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
