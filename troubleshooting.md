# vLLM GPT-OSS-20B 故障排查指南

> **最后更新**: 2026年1月16日  
> **维护者**: gpt-oss 项目团队  
> 本文档记录了所有已知问题、根本原因和解决方案

---

## 📋 目录

- [问题1：nohup: ignoring input 警告](#问题1nohup-ignoring-input-警告)
- [问题2：进程状态检查不可靠](#问题2进程状态检查不可靠)
- [问题3：启动过程缺乏可视化反馈](#问题3启动过程缺乏可视化反馈)
- [问题4：vLLM显存溢出(OOM)](#问题4vllm显存溢出oom)
- [问题5：API无法连接](#问题5api无法连接)
- [问题6：分词器加载失败](#问题6分词器加载失败)
- [问题7：vLLM安装依赖冲突](#问题7vllm安装依赖冲突)
- [快速参考](#快速参考)

---

## 问题1：nohup: ignoring input 警告

### 症状
```
nohup: ignoring input
```
日志文件中出现此警告信息，导致日志混乱。

### 根本原因
`nohup` 命令用于后台运行程序，当标准输入(stdin)没有被重定向时，nohup会发出警告。这是因为程序无法从终端读取输入，但nohup仍然将stdin指向终端。

### 解决方案

**修改前**（有警告）：
```bash
nohup conda run -p /path/to/env vllm serve ... > log.txt 2>&1 &
```

**修改后**（无警告）：
```bash
nohup conda run -p /path/to/env vllm serve ... < /dev/null > log.txt 2>&1 &
```

#### 详细解释
```bash
< /dev/null      # 将stdin重定向到空设备（程序无法读取输入）
> log.txt        # stdout重定向到日志文件（标准输出）
2>&1             # stderr重定向到stdout（错误输出合并到日志）
&                # 后台运行
```

### 应用位置
- [start_vllm.sh](start_vllm.sh) - 第61行

### 预防方法
- 所有 `nohup` 命令都应该包含 `< /dev/null` 重定向
- 确保stdout和stderr都被重定向到日志文件

---

## 问题2：进程状态检查不可靠

### 症状
- 通过PID文件判断进程是否运行，但PID文件丢失时无法检测进程
- 进程被意外终止时，PID文件仍然存在导致状态判断错误
- 多个vLLM实例启动时互相干扰

### 根本原因
依赖PID文件来判断进程状态有以下缺陷：
1. **文件可能丢失** - 重启机器、清理临时文件时PID文件可能被删除
2. **状态不同步** - PID文件记录的进程号可能已被其他程序重用
3. **无法检测crash** - 进程意外退出时PID文件仍然存在

### 解决方案

**改进前**（基于PID文件）：
```bash
if [ -f "$PID_FILE" ]; then
  EXISTING_PID=$(cat "$PID_FILE")
  if ps -p "$EXISTING_PID" > /dev/null 2>&1; then
    # 进程在运行
  fi
fi
```

**改进后**（基于ps aux）：
```bash
# 通过直接查询进程表来检查进程
VLLM_PID=$(ps aux | grep -E "vllm serve.*$MODEL_PATH" | grep -v grep | awk '{print $2}' | head -1)
if [ -n "$VLLM_PID" ]; then
  # 进程在运行
fi
```

#### 关键改进点
1. **不依赖PID文件** - 直接从进程表查询，实时准确
2. **模式匹配** - 通过完整命令行匹配确保找到正确的进程
3. **单一真实来源** - 系统进程表是唯一的事实来源

### 应用位置
- [start_vllm.sh](start_vllm.sh) - `start_vllm()`, `stop_vllm()`, `status_vllm()` 函数

### 命令语法详解
```bash
ps aux                          # 列出所有进程
| grep -E "vllm serve.*$MODEL_PATH"  # 匹配vLLM serve + 模型路径
| grep -v grep                  # 排除grep命令本身
| awk '{print $2}'              # 提取PID列（第2列）
| head -1                       # 只取第一个（避免多个实例）
```

---

## 问题3：启动过程缺乏可视化反馈

### 症状
- 启动vLLM后无法看到进度
- 不知道服务是否正在加载模型
- 无法判断启动成功还是失败
- 用户被迫后台查看日志

### 根本原因
原始脚本在启动后只做简单检查，不显示实时日志或加载进度。这导致：
1. **不确定性** - 用户不知道发生了什么
2. **诊断困难** - 启动失败时无法快速定位问题
3. **用户体验差** - 缺乏交互反馈

### 解决方案

实现**智能启动监控机制**：

```bash
# 1. 启动进程到后台
nohup conda run ... vllm serve ... < /dev/null > log.txt 2>&1 &

# 2. 实时显示日志
tail -f log.txt &
TAIL_PID=$!

# 3. 定期检查进程和API
TIMEOUT=30
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
  sleep 1
  ELAPSED=$((ELAPSED + 1))
  
  # 3a. 检查进程是否存在
  VLLM_PID=$(ps aux | grep -E "vllm serve.*$MODEL_PATH" | grep -v grep | awk '{print $2}' | head -1)
  if [ -z "$VLLM_PID" ]; then
    # 进程已崩溃
    kill $TAIL_PID 2>/dev/null
    echo "✗ vLLM 进程启动失败"
    return 1
  fi
  
  # 3b. 检查API是否开始响应
  if curl -s "http://localhost:$PORT/v1/models" > /dev/null 2>&1; then
    # 服务已启动完成
    kill $TAIL_PID 2>/dev/null
    echo "✓ vLLM 进程已启动，PID: $VLLM_PID"
    return 0
  fi
done

# 4. 处理超时情况
kill $TAIL_PID 2>/dev/null
echo "✗ vLLM 启动超时（${TIMEOUT}秒内未响应）"
```

#### 核心优势
1. **实时日志反馈** - 用户可看到模型加载进度
2. **双重检查** - 检查进程存在性 + API响应
3. **智能超时** - 30秒超时平衡等待时间和及时反馈
4. **Ctrl+C友好** - 用户可随时中断日志显示

### 应用位置
- [start_vllm.sh](start_vllm.sh) - `start_vllm()` 函数（第77-125行）

### 启动输出效果
```
==========================================
启动 GPT-OSS-20B vLLM 服务器
==========================================
...
vLLM 服务器启动中（后台进程）...
==========================================
实时日志输出（Ctrl+C 继续）：
==========================================
[2026-01-16 10:30:45] INFO: Loading model from ./gpt-oss-20b
[2026-01-16 10:30:47] INFO: Initializing weights...
[2026-01-16 10:31:02] INFO: vLLM server started on port 8010
==========================================
✓ vLLM 进程已启动，PID: 12345
✓ 日志文件: ./log.txt
✓ API 地址: http://localhost:8010/v1/models
```

---

## 问题4：vLLM显存溢出(OOM)

### 症状
```
RuntimeError: CUDA out of memory. Tried to allocate XXX GiB
```

### 根本原因
GPT-OSS-20B是一个大模型，显存占用受以下因素影响：
1. **序列长度** (`--max-model-len`) - 越长显存占用越多
2. **显存利用率** (`--gpu-memory-utilization`) - 设置过高导致OOM
3. **精度** (`--dtype`) - float32 > float16 > bfloat16 > fp8
4. **批处理大小** - 并发处理的请求数

### 解决方案

#### 快速修复（立即降低显存占用）
```bash
# 在 start_vllm.sh 中修改以下参数：

# 方案1：降低显存利用率
--gpu-memory-utilization 0.3    # 从 0.4 降到 0.3

# 方案2：减少序列长度
--max-model-len 1024            # 从 2048 降到 1024

# 方案3：使用量化推理
--quantization fp8              # 节省显存25-50%

# 方案4：启用CPU卸载
--cpu-offload-gb 10             # 虚拟扩展10GB显存
```

#### 分级方案
| 方案 | 显存节省 | 性能影响 | 适用场景 |
|------|---------|---------|---------|
| 降低利用率 0.4→0.3 | ~5-10% | 无 | 首选方案 |
| 减少序列长度 | ~15-30% | 中等 | 不需要长上下文 |
| 使用fp8量化 | ~25-50% | 中等 | 可接受精度下降 |
| CPU卸载 | 虚拟+40-80GB | 严重 | 应急方案 |

#### 根本解决方案
1. **增加GPU显存** - 升级到H100等更大显存GPU
2. **使用张量并行** - `--tensor-parallel-size 2` 分散到多GPU
3. **量化模型** - 预量化模型到int4

### 应用位置
- [start_vllm.sh](start_vllm.sh) - 第62-67行参数配置

### 监控显存使用
```bash
# 启动前检查GPU状态
nvidia-smi

# 启动后监控实时显存
watch -n 1 nvidia-smi
```

---

## 问题5：API无法连接

### 症状
```
curl: (7) Failed to connect to localhost port 8010: Connection refused
```

### 根本原因
| 原因 | 判断方法 | 解决方案 |
|------|---------|---------|
| vLLM服务未启动 | `ps aux \| grep vllm` | 运行 `./start_vllm.sh --start` |
| 端口被占用 | `lsof -i :8010` | 改变PORT或杀死占用进程 |
| 服务还在启动 | 查看日志 | 等待30秒后重试 |
| 防火墙阻止 | 检查防火墙规则 | 开放端口8010 |
| 模型加载失败 | 查看 log.txt | 检查错误日志 |

### 解决方案

**诊断步骤**：
```bash
# 1. 检查vLLM进程是否运行
./start_vllm.sh --status

# 2. 如果未运行，启动服务
./start_vllm.sh --start

# 3. 等待启动完成（查看实时日志）
tail -f log.txt

# 4. 验证API响应
curl http://localhost:8010/v1/models

# 5. 完整测试
curl http://localhost:8010/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-oss-20b",
    "messages": [{"role": "user", "content": "hello"}],
    "max_tokens": 100
  }'
```

### 应用位置
- [start_vllm.sh](start_vllm.sh) - `--status` 选项
- 模型日志：[log.txt](log.txt)

---

## 问题6：分词器加载失败

### 症状
```
FileNotFoundError: ... tokenizer.json not found
ConnectionError: Couldn't connect to HuggingFace hub
```

### 根本原因
1. **模型未下载** - gpt-oss-20b模型文件不完整
2. **网络问题** - 无法从HuggingFace下载tokenizer
3. **缓存问题** - tokenizer缓存损坏

### 解决方案

**步骤1：检查模型完整性**
```bash
ls -lh gpt-oss-20b/
# 应该包含：
# - model-00000-of-00002.safetensors
# - model-00001-of-00002.safetensors
# - tokenizer.json
# - config.json
# - ...
```

**步骤2：重新下载模型（使用国内镜像加速）**
```bash
export HF_ENDPOINT=https://hf-mirror.com
hf download openai/gpt-oss-20b --local-dir ./gpt-oss-20b

# 或使用其他镜像：
# https://hf-mirror.com
# https://mirrors.ustc.edu.cn/hugging-face-models
```

**步骤3：清理tokenizer缓存**
```bash
rm -rf ~/.cache/huggingface/hub/
rm -rf ~/.cache/huggingface/token_files/
```

**步骤4：重新启动**
```bash
./start_vllm.sh --stop
./start_vllm.sh --start
```

### 环境变量配置
在 [start_vllm.sh](start_vllm.sh) 中已配置：
```bash
export TIKTOKEN_CACHE_DIR="/home/tester/jihz-gpt-oss-20b"
export HF_ENDPOINT=https://hf-mirror.com
```

### 应用位置
- [start_vllm.sh](start_vllm.sh) - 第18-22行

---

## 快速参考

### 常用命令
```bash
# 启动服务
./start_vllm.sh --start

# 停止服务
./start_vllm.sh --stop

# 重启服务
./start_vllm.sh --restart

# 查看状态
./start_vllm.sh --status

# 查看日志
tail -f log.txt

# 测试API
curl http://localhost:8010/v1/models
```

### 快速诊断
```bash
# 一键诊断脚本
./start_vllm.sh --status
ps aux | grep vllm
nvidia-smi
curl http://localhost:8010/v1/models
tail -50 log.txt
```

### 性能优化参数
```bash
# 当前推荐配置（均衡）
--dtype bfloat16                # 精度：float16, bfloat16, fp8
--max-model-len 2048            # 序列长度：512, 1024, 2048, 4096
--tensor-parallel-size 1        # 张量并行：1, 2 (根据GPU数)
--gpu-memory-utilization 0.4    # 显存利用率：0.3, 0.4, 0.5, 0.7, 0.9

# 高性能配置（需要足够显存）
--dtype bfloat16
--max-model-len 4096
--tensor-parallel-size 2
--gpu-memory-utilization 0.8

# 低显存配置（显存紧张）
--dtype fp8
--max-model-len 1024
--tensor-parallel-size 1
--gpu-memory-utilization 0.3
```

### 关键文件
| 文件 | 用途 |
|------|------|
| [start_vllm.sh](start_vllm.sh) | 主启动脚本 |
| [log.txt](log.txt) | 实时日志 |
| nohup.out | nohup的备用日志 |
| [vllm.pid](vllm.pid) | 进程ID记录（可选） |

---

## 问题提交模板

如果遇到新问题，请按照以下模板提交：

```
## 问题描述
[简明扼要的问题说明]

## 症状
[具体表现和错误信息]

## 复现步骤
1. ...
2. ...
3. ...

## 环境信息
- 系统：[Linux/Windows/macOS]
- GPU：[型号和显存]
- vLLM版本：[版本号]
- Python版本：[版本号]

## 日志
[相关日志片段]

## 已尝试的解决方案
[之前尝试过什么]
```

---

## 问题7：vLLM安装依赖冲突

### 症状
```
ERROR: pip's dependency resolver does not currently take into account all the packages
outlines 0.1.11 requires outlines_core==0.1.26
vLLM 0.13.0 requires outlines_core==0.2.11
```

### 根本原因
| 原因 | 说明 |
|------|------|
| **outlines vs outlines_core** | vLLM 仅需 `outlines_core 0.2.11`，但 `outlines 0.1.11` 要求旧版本 `0.1.26` |
| **xformers 版本冲突** | xformers 0.0.30 依赖 torch 2.7.0，但 vLLM 要求 torch 2.9.0 |
| **numpy 版本限制** | 多个包（opencv, numba）对 numpy 有上限要求 (< 2.3) |

### 安装历史与错误

1. **初始尝试uv虚拟环境**：
   - 命令：`uv venv --python 3.12 --seed`
   - 错误：uv未安装（exit code 127）
   - 解决：安装uv或改用conda

2. **使用pip搜索版本**：
   - 命令：`pip search vllm`
   - 错误：exit code 1（命令已弃用）
   - 解决：使用 `pip index versions vllm` 查看版本

3. **直接pip安装vLLM**：
   - 命令：`pip install vllm==0.10.0`
   - 错误：exit code 1（依赖冲突或环境问题）
   - 解决：切换到conda隔离环境

4. **端口冲突**：
   - 命令：`vllm serve openai/gpt-oss-20b`
   - 错误：Address already in use (端口8000被占用)
   - 解决：使用 `--port 8010` 指定不同端口

5. **模型下载超时**：
   - 启动时从HuggingFace下载模型失败
   - 错误：网络超时或连接失败
   - 原因：网络不稳定或模型大（gpt-oss-20b ~40GB）
   - 解决：手动下载或使用国内镜像

### 解决方案

**最佳实践**：

```bash
# 1. 创建隔离环境（强烈推荐）
conda create -n gpt-oss-env python=3.12

# 2. 激活环境
conda activate gpt-oss-env

# 3. 使用精确版本号安装（避免冲突）
pip install vllm==0.13.0 \
  torch==2.9.0 \
  transformers==4.57.3 \
  numpy='>=1.24.0,<2.3'

# 4. 删除冲突的包
pip uninstall -y outlines xformers

# 5. 验证依赖完整性
pip check  # 应返回 "No broken requirements found."

# 6. 从本地模型启动
vllm serve ./gpt-oss-20b --port 8010
```

**pyproject.toml精确版本配置**：

```toml
[project.optional-dependencies]
vllm = [
  "vllm==0.13.0",
  "torch==2.9.0",
  "transformers>=4.57.0,<5.0.0",
  "numpy>=1.24.0,<2.3",
  "outlines_core==0.2.11",
]
```

---

## 相关文档

- [README.md](README.md) - 项目主文档
- [项目说明.md](项目说明.md) - 项目详细说明
- [DEPLOYMENT_SUMMARY.md](DEPLOYMENT_SUMMARY.md) - 部署总结
- [vLLM官方文档](https://docs.vllm.ai/) - vLLM官方参考

---

**最后更新**: 2026年1月16日  
**文档版本**: v1.1  
**维护者**: gpt-oss 项目团队
