#!/usr/bin/env bash
# apply-kernel-patches.sh — 把 config/patches/*.patch 幂等地应用到 upstream/radxa-kernel
#
# 为什么需要它：
#   不把「就地改 upstream 工作树」当作事实来源。我们自己的内核改动一律以
#   config/patches/NNNN-*.patch 形式入库，并在每次构建前由本脚本打上去，
#   保证 upstream 工作树保持可被 git 校验的干净状态、且从零可复现。
#
# 幂等：用 `git apply --reverse --check` 判断补丁是否已应用；已应用则跳过。
# 失败即 loud：补丁既未应用又无法干净应用（上下文冲突）时直接退出非 0。
#
# 用法：
#   ./config/apply-kernel-patches.sh            # 应用到 upstream/radxa-kernel
#   KERNEL_DIR=<dir> ./config/apply-kernel-patches.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_DIR="${KERNEL_DIR:-$REPO_ROOT/upstream/radxa-kernel}"
PATCH_DIR="${PATCH_DIR:-$REPO_ROOT/config/patches}"

[[ -d "$KERNEL_DIR/.git" ]] || { echo "ERROR: 不是 git 工作树: $KERNEL_DIR" >&2; exit 1; }
[[ -d "$PATCH_DIR" ]] || { echo "ERROR: 补丁目录不存在: $PATCH_DIR" >&2; exit 1; }

shopt -s nullglob
patches=("$PATCH_DIR"/*.patch)
if [[ ${#patches[@]} -eq 0 ]]; then
	echo "== 内核补丁：$PATCH_DIR 下无补丁，跳过 =="
	exit 0
fi

echo "== 内核补丁 → $KERNEL_DIR =="
applied=0; skipped=0
for p in "${patches[@]}"; do
	name="$(basename "$p")"
	if git -C "$KERNEL_DIR" apply --reverse --check "$p" >/dev/null 2>&1; then
		echo "  SKIP $name（已应用）"
		skipped=$((skipped + 1))
		continue
	fi
	if ! git -C "$KERNEL_DIR" apply --check "$p" >/dev/null 2>&1; then
		echo "ERROR: $name 既未应用也无法干净应用（upstream 变了？）" >&2
		git -C "$KERNEL_DIR" apply --check --verbose "$p" >&2 || true
		exit 1
	fi
	git -C "$KERNEL_DIR" apply "$p"
	echo "  OK   $name"
	applied=$((applied + 1))
done
echo "== 内核补丁：应用 $applied，跳过 $skipped =="
