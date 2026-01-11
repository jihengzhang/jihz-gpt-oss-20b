# vLLM 安装记录

## 概述
本文档记录了在 gpt-oss 项目中成功安装 vLLM 0.13.0 的完整过程和解决的依赖冲突问题。

## 环境信息
- **操作系统**: Linux
- **Python 版本**: 3.13.11
- **环境类型**: Conda (gpt-oss-env)
- **vLLM 目标版本**: 0.13.0

## 安装过程

### 第一步：优化项目依赖结构

#### 问题分析
原始 `pyproject.toml` 将所有依赖（包括 FastAPI、Docker、Jupyter 等重量级包）都放在核心依赖中，导致：
- 基础安装过于臃肿
- 不同后端的依赖混在一起
- 缺少版本上限约束，容易出现破坏性更新

#### 解决方案
重构 `pyproject.toml`，采用模块化依赖管理：

**核心依赖（最小化）**:
```toml
dependencies = [
  "openai-harmony>=0.0.8",
  "tiktoken>=0.9.0",
  "aiohttp>=3.12.14",
  "chz>=0.3.0",
  "pydantic>=2.11.7,<3.0.0",
  "structlog>=25.4.0",
  "tenacity>=9.1.2",
  "requests>=2.31.0",
  "termcolor>=2.0.0",
]
```

**可选依赖组分类**:
- `server`: FastAPI + Uvicorn (API 服务)
- `web`: Docker + html2text + lxml (网页工具)
- `jupyter`: Jupyter 集成
- `torch`: PyTorch 推理后端
- `triton`: Triton 推理后端
- `vllm`: vLLM 高性能服务
- `metal`: Apple Silicon 支持
- `test`: 测试工具
- `eval`: 评估框架
- `mcp`: MCP 服务器支持
- `all`: 完整安装
- `dev`: 开发工具

### 第二步：初次安装 vLLM

执行命令：
```bash
pip install vllm==0.13.0
```

成功安装的关键包：
- vllm==0.13.0
- torch==2.9.0
- transformers==4.57.3
- triton==3.5.0
- 大量 NVIDIA CUDA 相关库（cublas, cudnn, cusparse 等）

### 第三步：解决依赖冲突

#### 遇到的冲突

**冲突 1: outlines_core 版本冲突**
```
outlines 0.1.11 requires outlines_core==0.1.26
vLLM 0.13.0 requires outlines_core==0.2.11
```

**冲突 2: xformers 与 torch 版本不匹配**
```
xformers 0.0.30 requires torch==2.7.0
但安装的是 torch==2.9.0 (vLLM 要求)
```

#### 解决步骤

1. **分析 vLLM 的精确依赖**:
   ```bash
   pip show vllm | grep Requires
   ```
   
   发现 vLLM 依赖 `outlines_core` 但不依赖 `outlines`

2. **移除冲突的包**:
   ```bash
   pip uninstall outlines xformers -y
   ```

3. **强制安装精确版本的 PyTorch 生态**:
   ```bash
   pip install "torch==2.9.0" "torchaudio==2.9.0" "torchvision==0.24.0" \
               "numpy<2.3,>=1.24" --force-reinstall --no-deps
   ```

4. **验证依赖完整性**:
   ```bash
   pip check
   ```
   输出: `No broken requirements found.`

### 第四步：更新依赖配置

在 `pyproject.toml` 中添加精确的 vLLM 依赖组：

```toml
[project.optional-dependencies]
# vLLM inference backend (high-performance serving)
# Note: vLLM has strict version requirements, use exact versions to avoid conflicts
vllm = [
  "vllm==0.13.0",
  "torch==2.9.0",
  "torchaudio==2.9.0",
  "torchvision==0.24.0",
  "transformers>=4.57.0,<5.0.0",
  "tokenizers>=0.22.0",
  "numpy>=1.24.0,<2.3",
  "outlines_core==0.2.11",
]
```

## 最终安装的关键版本

| 包名 | 版本 | 说明 |
|------|------|------|
| vllm | 0.13.0 | 核心推理引擎 |
| torch | 2.9.0 | PyTorch (vLLM 严格要求) |
| torchaudio | 2.9.0 | 音频处理库 |
| torchvision | 0.24.0 | 视觉处理库 |
| transformers | 4.57.3 | Hugging Face 模型库 |
| triton | 3.5.0 | GPU 内核优化 |
| numpy | 2.2.6 | 数值计算 (< 2.3) |
| outlines_core | 0.2.11 | 结构化生成 (vLLM 要求) |
| tokenizers | 0.22.2 | 快速分词器 |

## 关键经验总结

### 1. 依赖冲突的根本原因
- **outlines vs outlines_core**: vLLM 只需要 `outlines_core`，而 `outlines` 包要求旧版本，两者冲突
- **xformers**: 安装时会自动拉取，但版本可能与 vLLM 要求的 torch 不兼容
- **numpy 版本**: vLLM 生态中多个包（opencv, numba）对 numpy 有上限要求 (< 2.3)

### 2. 最佳实践

✅ **推荐做法**:
- 使用精确版本号固定核心依赖（torch, vllm）
- 为不同后端创建独立的可选依赖组
- 添加版本上限避免破坏性更新
- 使用 `pip check` 验证依赖完整性

❌ **避免**:
- 不要同时安装 `outlines` 和 vLLM
- 不要在 vLLM 环境中使用过于宽泛的版本范围（如 `torch>=2.7`）
- 不要忽略依赖冲突警告

### 3. 安装命令参考

**最小化安装**:
```bash
pip install -e .
```

**安装 vLLM 后端**:
```bash
pip install -e ".[vllm]"
```

**安装所有功能**:
```bash
pip install -e ".[all]"
```

**开发环境**:
```bash
pip install -e ".[dev]"
```

## 依赖冲突检查清单

在添加新依赖前，检查：

1. ✅ 是否与 vLLM 的 torch 版本要求冲突？
2. ✅ 是否引入了 `outlines` 包？
3. ✅ numpy 版本是否 < 2.3？
4. ✅ 是否需要 CUDA 库？确保版本一致
5. ✅ 运行 `pip check` 验证

## 常见问题

### Q1: 为什么不能使用 torch 2.9.1+？
**A**: vLLM 0.13.0 严格要求 torch==2.9.0，且 torchaudio 和 torchvision 也绑定此版本。

### Q2: 可以使用虚拟环境吗？
**A**: 强烈推荐！使用 conda 或 venv 隔离环境，避免全局污染。

### Q3: 遇到 CUDA 相关错误怎么办？
**A**: 确保系统有兼容的 NVIDIA 驱动。vLLM 会自动安装 CUDA 12.8 相关库。

### Q4: 如何验证安装成功？
**A**: 
```python
import vllm
print(vllm.__version__)  # 应显示 0.13.0
```

## 相关文件

- [pyproject.toml](pyproject.toml) - 项目依赖配置
- [README.md](README.md) - 项目主文档

## 更新日志

- **2026-01-12**: 
  - 重构依赖结构，实现模块化管理
  - 成功解决 vLLM 0.13.0 依赖冲突
  - 添加精确版本约束
  - 创建本安装文档
