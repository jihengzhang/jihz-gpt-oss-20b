#!/usr/bin/env bash
# =============================================================================
# build_pytorch.sh  —  一键完成 PyTorch 的克隆、子模块初始化、编译、安装
#
# 用法:
#   bash build_pytorch.sh              — 完整流程（如目录已存在则跳过克隆）
#   bash build_pytorch.sh --dry-run    — 只模拟运行，不执行真实编译
#   bash build_pytorch.sh --skip-clone — 跳过克隆，直接建立（CLONE_DIR 已存在）
#
# 可通过环境变量覆盖默认值：
#   PYTORCH_VERSION=2.9.1
#   CLONE_URL=https://gitee.com/mirrors/pytorch.git
#   CLONE_DIR=/tmp/pytorch-src
#   CONDA_ENV=env_vllm2
# =============================================================================
set -euo pipefail

# ── 可配置变量 ────────────────────────────────────────────
PYTORCH_VERSION="${PYTORCH_VERSION:-2.9.1}"
CLONE_URL="${CLONE_URL:-https://gitee.com/mirrors/pytorch.git}"
CLONE_DIR="${CLONE_DIR:-/tmp/pytorch-src}"
CONDA_ENV="${CONDA_ENV:-env_vllm2}"

REPO_DIR="$CLONE_DIR"
LOG_FILE="/tmp/torch_build.log"
MAX_RETRIES=5        # 非子模块错误的最大重试次数
MAX_ATTEMPTS=30      # 总尝试次数上限（含子模块修复循环），防死循环
DRY_RUN=false
SKIP_CLONE=false
RESUME=false

# 已知包含嵌套子模块的顶层子模块（初始化时需要 --recursive）
RECURSIVE_SUBS=(third_party/tensorpipe third_party/kineto)

for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]]    && DRY_RUN=true
  [[ "$arg" == "--skip-clone" ]] && SKIP_CLONE=true
  [[ "$arg" == "--resume" ]]     && RESUME=true && SKIP_CLONE=true
done

# ── 颜色输出 ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERR]${NC}   $*"; }

# ── 环境变量 ─────────────────────────────────────────────────────────────────
setup_env() {
  source ~/miniconda3/etc/profile.d/conda.sh 2>/dev/null || true
  conda activate "$CONDA_ENV" 2>/dev/null || true

  export CUDA_HOME=/usr/local/cuda-13.0
  export PATH=$CUDA_HOME/bin:$PATH
  export LD_LIBRARY_PATH=$CUDA_HOME/targets/sbsa-linux/lib:${LD_LIBRARY_PATH:-}
  # 让系统 g++ 也能找到 CUDA 头文件（torch_nvshmem 等目标用 g++ 编译）
  export CPLUS_INCLUDE_PATH=$CUDA_HOME/include:${CPLUS_INCLUDE_PATH:-}
  export C_INCLUDE_PATH=$CUDA_HOME/include:${C_INCLUDE_PATH:-}
  export TORCH_CUDA_ARCH_LIST="11.0"
  export USE_CUDA=1
  export USE_CUDNN=0
  export USE_MKLDNN=0
  export USE_NNPACK=0
  export USE_QNNPACK=0
  export MAX_JOBS=8
  export PYTORCH_BUILD_VERSION=2.9.1
  export PYTORCH_BUILD_NUMBER=1
  export USE_PRIORITIZED_TEXT_FOR_LD=1

  info "Python: $(python --version 2>&1)"
  info "nvcc:   $(nvcc --version 2>&1 | grep release)"
}

# ── 克隆源码及初始化顶层子模块 ────────────────────────────────
clone_repo() {
  if $SKIP_CLONE; then
    info "跳过克隆（--skip-clone）"
    return 0
  fi

  if [[ -d "$CLONE_DIR/.git" ]]; then
    local existing_tag
    existing_tag=$(git -C "$CLONE_DIR" describe --tags --exact-match 2>/dev/null || echo "unknown")
    ok "源码目录已存在: $CLONE_DIR (当前 tag: $existing_tag)，跳过克隆"
    return 0
  fi

  if [[ -d "$CLONE_DIR" ]] && [[ -n "$(ls -A "$CLONE_DIR" 2>/dev/null)" ]]; then
    warn "$CLONE_DIR 已存在且非空，但不是 git 仓库，跳过克隆"
    return 0
  fi

  info "=== 克隆 PyTorch v${PYTORCH_VERSION} ==="
  info "来源: $CLONE_URL"
  info "目标: $CLONE_DIR"

  if $DRY_RUN; then
    echo "[DRY-RUN] git clone --depth 1 --branch v${PYTORCH_VERSION} $CLONE_URL $CLONE_DIR"
    echo "[DRY-RUN] git -C $CLONE_DIR submodule update --init --depth 1"
    return 0
  fi

  git clone --depth 1 --branch "v${PYTORCH_VERSION}" "$CLONE_URL" "$CLONE_DIR" 2>&1
  ok "克隆完成"

  info "=== 初始化顶层子模块 ==="
  cd "$CLONE_DIR"
  git submodule update --init --depth 1 2>&1 | tail -5 || true
  ok "子模块初始化完成"
}

# ── 第一步：检查并补齐所有空的子模块 ─────────────────────────────────────────
fix_submodules() {
  info "=== 检查所有子模块 ==="
  cd "$REPO_DIR"

  # 先把子模块状态写到临时文件，避免 while 子 shell 无法修改外层数组的问题
  local tmp_status
  tmp_status=$(mktemp)
  git submodule status 2>/dev/null > "$tmp_status"

  local missing_subs=()

  while IFS= read -r line; do
    local status_char="${line:0:1}"
    local sub_path
    sub_path=$(echo "$line" | awk '{print $2}')
    [[ -z "$sub_path" ]] && continue

    local sub_fullpath="$REPO_DIR/$sub_path"

    # 未初始化 (-)
    if [[ "$status_char" == "-" ]]; then
      missing_subs+=("$sub_path")
      continue
    fi

    # 目录存在但为空（+ 或空格前缀都可能出现空目录）
    if [[ -d "$sub_fullpath" ]]; then
      local count
      count=$(find "$sub_fullpath" -maxdepth 0 -empty 2>/dev/null | wc -l)
      if [[ "$count" -gt 0 ]]; then
        missing_subs+=("$sub_path")
      fi
    fi
  done < "$tmp_status"
  rm -f "$tmp_status"

  if [[ ${#missing_subs[@]} -eq 0 ]]; then
    ok "所有子模块已就绪"
    return 0
  fi

  warn "发现 ${#missing_subs[@]} 个空/未初始化子模块，开始补克隆..."
  for sub in "${missing_subs[@]}"; do
    info "  初始化: $sub"
    local rec_flag=""
    for rsub in "${RECURSIVE_SUBS[@]}"; do
      [[ "$sub" == "$rsub" ]] && rec_flag="--recursive" && break
    done
    if $DRY_RUN; then
      echo "  [DRY-RUN] git submodule update --init $rec_flag --depth 1 $sub"
    else
      git submodule update --init $rec_flag --depth 1 "$sub" 2>&1 | tail -3 || \
        warn "  !! $sub 克隆失败，跳过（非核心依赖可忽略）"
    fi
  done
  ok "子模块补齐完成"
}

# ── 从编译日志里提取缺失的子模块路径 ─────────────────────────────────────────
# CMake 报错模式 1 (顶层子模块未初始化):
#   Could not find any of CMakeLists.txt ... in /tmp/pytorch-src/third_party/sleef
# CMake 报错模式 2 (嵌套子模块目录为空):
#   The source directory
#     /tmp/pytorch-src/third_party/tensorpipe/third_party/libuv
#   does not contain a CMakeLists.txt file.
extract_missing_from_log() {
  local log="$1"
  {
    # 模式 1： "in /path/to/third_party/xxx" 同行
    grep -oP "(?<=in )${REPO_DIR}/\S+" "$log" 2>/dev/null \
      | sed "s|${REPO_DIR}/||" || true

    # 模式 2：路径在独立行，下一行是 "does not contain a CMakeLists.txt"
    grep -B1 "does not contain a CMakeLists.txt" "$log" 2>/dev/null \
      | grep -oP "${REPO_DIR}/\S+" 2>/dev/null \
      | sed "s|${REPO_DIR}/||" \
      | sed 's|/$||' || true
  } | sort -u || true
}

# ── 运行一次编译，返回 0=成功 非0=失败 ────────────────────────────────────────
run_build() {
  local attempt="$1"
  info "=== 编译尝试 #${attempt} (日志: $LOG_FILE) ==="
  cd "$REPO_DIR"

  if $DRY_RUN; then
    info "[DRY-RUN] python setup.py bdist_wheel"
    # 模拟一次缺失子模块的报错，用于测试循环逻辑
    if [[ $attempt -eq 1 ]]; then
      echo "CMake Error: Could not find any of CMakeLists.txt in ${REPO_DIR}/third_party/sleef" >> "$LOG_FILE"
      echo "Did you run 'git submodule update --init --recursive'?" >> "$LOG_FILE"
      return 1
    fi
    return 0
  fi

  # 真实编译（不用 set -e，让我们捕获退出码）
  set +e
  python setup.py bdist_wheel 2>&1 | tee -a "$LOG_FILE"
  local rc=${PIPESTATUS[0]}
  set -e
  return $rc
}

# ── 主流程 ────────────────────────────────────────────────────────────────────
main() {
  info "PyTorch 自动编译脚本 — $(date)"
  $DRY_RUN && warn "=== DRY-RUN 模式，不执行真实编译 ==="

  # 0. 克隆源码（如已存在则跳过）
  clone_repo

  setup_env

  # 1. 主动检查并补齐子模块
  fix_submodules

  # 清空日志
  > "$LOG_FILE"

  # 必要时清除旧 build（如有残留）
  if [[ -d "$REPO_DIR/build" ]] && ! $DRY_RUN; then
    if $RESUME; then
      ok "--resume 模式：保留已有 build/ 目录，继续增量编译"
    else
      warn "发现旧 build/ 目录，清除..."
      rm -rf "$REPO_DIR/build"
    fi
  fi

  # 编译循环
  # - real_failures: 没有检测到子模块缺失的真实失败次数
  # - attempt: 总尝试次数（含子模块修复后的重试），防止无限循环
  local real_failures=0
  local attempt=0

  while true; do
    attempt=$((attempt + 1))
    if [[ $attempt -gt $MAX_ATTEMPTS ]]; then
      err "已达到总尝试上限 ($MAX_ATTEMPTS)，终止。"
      err "请查看日志: $LOG_FILE"
      return 1
    fi

    if run_build "$attempt"; then
      ok "=============================="
      ok "  编译成功！(第 ${attempt} 次尝试)"
      ok "=============================="

      # 安装
      local wheel
      wheel=$(ls "$REPO_DIR"/dist/torch-*.whl 2>/dev/null | head -1)
      if [[ -n "$wheel" ]]; then
        info "安装 wheel: $wheel"
        if ! $DRY_RUN; then
          pip install "$wheel" --force-reinstall

          # 归档 wheel 到 ~/local_wheels/
          mkdir -p ~/local_wheels
          cp "$wheel" ~/local_wheels/
          ok "Wheel 已归档至 ~/local_wheels/$(basename "$wheel")"

          # 切换到中立目录再验证，避免 $REPO_DIR/torch/ 覆盖已安装的包
          info "验证安装..."
          ( cd /tmp && python - <<'EOF'
import torch
print("版本:", torch.__version__)
print("CUDA available:", torch.cuda.is_available())
print("arch list:", torch.cuda.get_arch_list())
if torch.cuda.is_available():
    print("GPU:", torch.cuda.get_device_name(0))
EOF
          )
        else
          echo "[DRY-RUN] pip install $wheel"
          echo "[DRY-RUN] cp $wheel ~/local_wheels/"
        fi
      else
        warn "未找到 wheel 文件"
      fi
      return 0
    fi

    err "编译失败 (attempt=$attempt)，分析日志中的缺失子模块..."

    # 从日志提取缺失子模块
    local missing
    missing=$(extract_missing_from_log "$LOG_FILE")

    if [[ -z "$missing" ]]; then
      # 没有检测到子模块问题 → 真实失败，计入限制
      real_failures=$((real_failures + 1))
      if [[ $real_failures -ge $MAX_RETRIES ]]; then
        err "非子模块错误已达上限 ($MAX_RETRIES)，停止重试。"
        err "最后 30 行日志:"
        tail -30 "$LOG_FILE"
        return 1
      fi
      warn "非子模块错误 (real_failures=$real_failures/$MAX_RETRIES)，继续重试..."
    else
      # 找到并修复缺失子模块 → 不计入 real_failures
      info "检测到缺失子模块:"
      echo "$missing" | while read -r sub; do
        info "  -> $sub"
      done

      echo "$missing" | while read -r sub; do
        if [[ -n "$sub" ]]; then
          # 如果是嵌套路径，找到对应的顶层子模块并用 --recursive
          local top_sub
          top_sub=$(echo "$sub" | grep -oP "^third_party/[^/]+")
          local is_recursive=false
          for rsub in "${RECURSIVE_SUBS[@]}"; do
            [[ "$top_sub" == "$rsub" ]] && is_recursive=true && break
          done
          # 如果嵌套路径深度>2（third_party/foo/bar/...）也做 recursive
          local depth
          depth=$(echo "$sub" | tr -cd '/' | wc -c)
          [[ $depth -ge 2 ]] && is_recursive=true

          local init_target="$sub"
          if $is_recursive; then
            init_target="$top_sub"
            info "修复嵌套子模块 (recursive): $top_sub  [源于: $sub]"
          else
            info "修复子模块: $sub"
          fi

          if $DRY_RUN; then
            local flag=""
            $is_recursive && flag="--recursive "
            echo "[DRY-RUN] git submodule update --init ${flag}--depth 1 $init_target"
          else
            cd "$REPO_DIR"
            local extra_flag=""
            $is_recursive && extra_flag="--recursive"
            git submodule update --init $extra_flag --depth 1 "$init_target" 2>&1 | tail -3 || \
              warn "  !! $init_target 克隆失败，跳过"
          fi
        fi
      done
    fi

    info "等待 2 秒后重试... (attempt=$attempt, real_failures=$real_failures)"
    sleep 2

    # 清除 cmake 缓存，避免旧错误残留
    if ! $DRY_RUN; then
      rm -rf "$REPO_DIR/build/CMakeCache.txt" "$REPO_DIR/build/CMakeFiles" 2>/dev/null || true
    fi
    > "$LOG_FILE"  # 清空日志，避免上次报错干扰下次 grep

  done
}

main "$@"
