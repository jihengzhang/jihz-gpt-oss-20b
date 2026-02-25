#!/usr/bin/env bash
# =============================================================================
# build_torchvision.sh  —  从源码编译 torchvision（针对 CUDA 13.0 / sm_110 / Jetson Thor）
#
# 用法:
#   bash /tmp/build_torchvision.sh           — 完整编译
#   bash /tmp/build_torchvision.sh --dry-run — 模拟运行不执行真实编译
#
# 前提：PyTorch 已通过 build_pytorch.sh 编译并安装到 env_vllm2
# =============================================================================
set -euo pipefail

TORCHVISION_VERSION="${TORCHVISION_VERSION:-0.24.1}"
TORCHVISION_SRC="/tmp/torchvision-src"
CONDA_ENV="env_vllm2"
LOG_FILE="/tmp/build_torchvision.log"
DRY_RUN=false

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# ── 颜色输出 ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERR]${NC}   $*" >&2; }

# ── 环境设置 ──────────────────────────────────────────────────────────────────
setup_env() {
  source ~/miniconda3/etc/profile.d/conda.sh 2>/dev/null || true
  conda activate "$CONDA_ENV" 2>/dev/null || true

  # 代理（克隆时需要）
  export https_proxy=http://127.0.0.1:7897
  export http_proxy=http://127.0.0.1:7897

  export CUDA_HOME=/usr/local/cuda-13.0
  export PATH=$CUDA_HOME/bin:$PATH
  export LD_LIBRARY_PATH=$CUDA_HOME/targets/sbsa-linux/lib:${LD_LIBRARY_PATH:-}
  export TORCH_CUDA_ARCH_LIST="11.0"
  export MAX_JOBS=8

  info "Python : $(python --version 2>&1)"
  info "nvcc   : $(nvcc --version 2>&1 | grep release)"
  info "torch  : $(cd /tmp && python -c 'import torch; print(torch.__version__, "CUDA:", torch.version.cuda)' 2>&1)"
}

# ── 克隆源码 ──────────────────────────────────────────────────────────────────
clone_repo() {
  if [[ -d "$TORCHVISION_SRC/.git" ]]; then
    ok "源码目录已存在: $TORCHVISION_SRC，跳过克隆"
    return 0
  fi

  info "=== 克隆 torchvision v${TORCHVISION_VERSION} ==="
  if $DRY_RUN; then
    echo "[DRY-RUN] git clone --depth 1 --branch v${TORCHVISION_VERSION} https://github.com/pytorch/vision.git $TORCHVISION_SRC"
    return 0
  fi

  git clone --depth 1 --branch "v${TORCHVISION_VERSION}" \
    https://github.com/pytorch/vision.git "$TORCHVISION_SRC" 2>&1 | tail -5
  ok "克隆完成"
}

# ── 预检 ──────────────────────────────────────────────────────────────────────
preflight_check() {
  info "=== 预检 ==="

  local torch_ver
  torch_ver=$(cd /tmp && python -c "import torch; print(torch.__version__)" 2>/dev/null || echo "未安装")
  if [[ "$torch_ver" == "未安装" ]]; then
    err "PyTorch 未安装，请先运行 build_pytorch.sh"
    return 1
  fi
  ok "PyTorch: $torch_ver"

  local cuda_ok
  cuda_ok=$(cd /tmp && python -c "import torch; print(torch.cuda.is_available())" 2>/dev/null || echo "False")
  if [[ "$cuda_ok" != "True" ]]; then
    err "PyTorch 无法访问 CUDA，请检查安装"
    return 1
  fi
  ok "CUDA 可用"
}

# ── 编译安装 ──────────────────────────────────────────────────────────────────
build_torchvision() {
  info "=== 开始编译 torchvision ==="
  info "日志: $LOG_FILE"

  if $DRY_RUN; then
    echo "[DRY-RUN] pip uninstall torchvision -y"
    echo "[DRY-RUN] cd $TORCHVISION_SRC && pip install --no-build-isolation -v ."
    return 0
  fi

  info "卸载旧版 torchvision..."
  pip uninstall torchvision -y 2>/dev/null || true

  cd "$TORCHVISION_SRC"
  pip install --no-build-isolation -v . 2>&1 | tee "$LOG_FILE"
  local exit_code=${PIPESTATUS[0]}

  if [[ $exit_code -ne 0 ]]; then
    err "编译失败 (exit=$exit_code)"
    err "最后 30 行日志:"
    tail -30 "$LOG_FILE"
    return 1
  fi
  ok "编译完成"

  # 归档 wheel 到 ~/local_wheels/
  local wheel
  wheel=$(find /home/tester/.cache/pip/wheels -name "torchvision-*.whl" -newer "$TORCHVISION_SRC/setup.py" 2>/dev/null | head -1)
  if [[ -n "$wheel" ]]; then
    mkdir -p ~/local_wheels
    cp "$wheel" ~/local_wheels/
    ok "Wheel 已归档至 ~/local_wheels/$(basename "$wheel")"
  fi
}

# ── 验证 ──────────────────────────────────────────────────────────────────────
verify() {
  info "=== 验证安装 ==="
  cd /tmp  # 避免源码目录遮蔽已安装的包

  python -c "
import torchvision
print('torchvision 版本:', torchvision.__version__)
import torch
# 验证 torchvision::nms 算子已注册（之前 ABI 不匹配时此处报错）
import torchvision.ops
boxes = torch.tensor([[0,0,1,1],[0,0,0.9,0.9]], dtype=torch.float32, device='cuda')
scores = torch.tensor([0.9, 0.8], device='cuda')
keep = torchvision.ops.nms(boxes, scores, 0.5)
print('NMS 算子测试通过，保留索引:', keep.tolist())
" && ok "torchvision 验证通过" || { err "torchvision 验证失败"; return 1; }
}

# ── 主流程 ────────────────────────────────────────────────────────────────────
main() {
  info "torchvision 编译脚本 — $(date)"
  $DRY_RUN && warn "=== DRY-RUN 模式 ==="

  cd /tmp  # 中立目录，避免 pytorch-src 下的 torch/ 干扰

  setup_env
  clone_repo
  preflight_check
  build_torchvision
  verify

  ok "=============================="
  ok "  torchvision 编译安装完成！"
  ok "=============================="
}

main "$@"
