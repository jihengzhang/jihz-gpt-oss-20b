#!/bin/bash

# vLLM 启动脚本
# 解决 GPU 兼容性问题 - mxfp4 量化需要计算能力 8.0+，但当前 GPU (Quadro RTX 5000) 只有 7.5

# 设置 GPU 顺序
export CUDA_DEVICE_ORDER=PCI_BUS_ID
export CUDA_VISIBLE_DEVICES=0,1

# 模型路径
MODEL_PATH="/home/tester/AI_Tool/gpt-oss/gpt-oss-20b"

# 启动参数说明:
# --dtype float16: 使用 FP16 精度（不使用 mxfp4 量化）
# --max-model-len 4096: 限制最大序列长度以节省内存
# --tensor-parallel-size 2: 使用 2 个 GPU 进行张量并行
# --gpu-memory-utilization 0.9: 使用 90% GPU 内存
# --port 8010: API 端口

echo "正在启动 vLLM 服务器..."
echo "模型: $MODEL_PATH"
echo "GPU: $CUDA_VISIBLE_DEVICES (Quadro RTX 5000 x2)"
echo "端口: 8010"
echo ""

conda run -p /home/tester/miniconda3/envs/gpt-oss-env \
  python -m vllm.entrypoints.openai.api_server \
  --model "$MODEL_PATH" \
  --port 8010 \
  --dtype float16 \
  --max-model-len 4096 \
  --tensor-parallel-size 2 \
  --gpu-memory-utilization 0.9

# 如果内存不足，可以尝试:
# --max-model-len 2048  (更小的上下文)
# --tensor-parallel-size 1  (只使用一个 GPU)
# --gpu-memory-utilization 0.8  (使用更少的 GPU 内存)
