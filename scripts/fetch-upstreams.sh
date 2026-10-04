#!/usr/bin/env bash
#
# fetch-upstreams.sh — 按 upstream.lock 重建只读上游输入。
#
# 做两件事：
#   1) 把 radxa/kernel 浅克隆到 upstream/radxa-kernel，并校验 HEAD == 钉死 commit；
#   2) 校验 vendor 的 steamos/tools/extract_rootfs.py 与上游 sha256 一致。
#
# 只读：本脚本只 init/fetch/checkout，**绝不** push 或改动任何上游仓库（用户硬约束）。
# 幂等：已在钉死 commit 则跳过。
#
# 用法：scripts/fetch-upstreams.sh
#   KERNEL_DIR=<path>  覆盖内核落点（默认 upstream/radxa-kernel）
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
cd "$REPO_ROOT"

LOCK="$REPO_ROOT/upstream.lock"
[[ -f "$LOCK" ]] || { echo "ERROR: 缺 $LOCK" >&2; exit 1; }
# shellcheck disable=SC1090
source "$LOCK"

PROG="$(basename "$0")"
log() { printf '\033[1;34m[%s]\033[0m %s\n' "$PROG" "$*" >&2; }
die() { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "$PROG" "$*" >&2; exit 1; }

KERNEL_DIR="${KERNEL_DIR:-$REPO_ROOT/upstream/radxa-kernel}"

# ── 1. radxa/kernel ──────────────────────────────────────────────────────────
kernel_at_pin() {
  [[ -d "$KERNEL_DIR/.git" ]] && \
    [[ "$(git -C "$KERNEL_DIR" rev-parse HEAD 2>/dev/null || true)" == "$RADXA_KERNEL_COMMIT" ]]
}

if kernel_at_pin; then
  log "radxa/kernel 已在钉死 commit ${RADXA_KERNEL_COMMIT:0:12}（跳过）"
else
  log "克隆 radxa/kernel @ ${RADXA_KERNEL_COMMIT:0:12}（分支 $RADXA_KERNEL_BRANCH）"
  rm -rf "$KERNEL_DIR"
  mkdir -p "$(dirname "$KERNEL_DIR")"
  git init -q "$KERNEL_DIR"
  git -C "$KERNEL_DIR" remote add origin "$RADXA_KERNEL_URL"
  # 优先按 SHA 直接抓（GitHub 允许抓可达 commit）；失败则浅抓分支再 deepen。
  if ! git -C "$KERNEL_DIR" fetch -q --depth 1 origin "$RADXA_KERNEL_COMMIT" 2>/dev/null; then
    log "  按 SHA 抓取失败，改为浅抓分支并 deepen…"
    git -C "$KERNEL_DIR" fetch -q --depth 1 origin "$RADXA_KERNEL_BRANCH"
    git -C "$KERNEL_DIR" fetch -q --deepen 500 origin "$RADXA_KERNEL_BRANCH"
    git -C "$KERNEL_DIR" fetch -q origin "$RADXA_KERNEL_COMMIT"
  fi
  git -C "$KERNEL_DIR" checkout -q --detach "$RADXA_KERNEL_COMMIT"
  kernel_at_pin || die "radxa/kernel 未落在钉死 commit（HEAD=$(git -C "$KERNEL_DIR" rev-parse HEAD 2>/dev/null || echo '?'）)"
  log "  OK  radxa/kernel @ $(git -C "$KERNEL_DIR" rev-parse --short HEAD)"
fi

# ── 2. vendor 提取器完整性（对 hashtagbasit 上游的锚点）───────────────────────
PY="$REPO_ROOT/steamos/tools/extract_rootfs.py"
[[ -f "$PY" ]] || die "缺 vendor 提取器 $PY"
got="$(sha256sum "$PY" | awk '{print $1}')"
if [[ "$got" != "$HASHTAGB_PY_SHA256" ]]; then
  die "extract_rootfs.py sha256 不符：
  期望 $HASHTAGB_PY_SHA256
  实际 $got
  （vendor 副本被改过？重新 vendor 并同步 upstream.lock）"
fi
log "OK  steamos/tools/extract_rootfs.py 与上游 sha256 一致"

log "上游就绪（只读；未做任何 push）"
