#!/usr/bin/env bash
#
# build-all.sh — 一条龙构建可刷写镜像（本地与 CI 共用入口）。
#
# 步骤：
#   fetch-upstreams → kernel-config → kernel → modules → firmware →
#   initramfs → fetch-rootfs → steamos-rootfs → steamos-image
#
# 用法：scripts/build-all.sh
#   TARGET=ufs|tf|nvme   目标介质（默认 ufs=4096B 扇区；tf/nvme=512B）
#   其余环境变量（OUT/SIZE/JOBS/…）原样透传给 make。
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
cd "$REPO_ROOT"

TARGET="${TARGET:-ufs}"
PROG="$(basename "$0")"
log() { printf '\033[1;34m[%s]\033[0m %s\n' "$PROG" "$*" >&2; }

log "1/9  上游（按 upstream.lock 重建；只读）"
./scripts/fetch-upstreams.sh

log "2/9  内核配置（defconfig + SteamOS 片段）"
make kernel-config

log "3/9  内核（Image + dtbs）"
make kernel

log "4/9  模块（strip 安装）"
make modules

log "5/9  运行时固件校验"
make firmware

log "6/9  initramfs"
make initramfs

log "7/9  Valve SteamOS rootfs（下载 + 重组）"
make fetch-rootfs

log "8/9  rootfs 去 Frame 化 + 引导器"
make steamos-rootfs

log "9/9  整盘镜像（TARGET=$TARGET）"
make steamos-image ROOTFS=build/steamos-rootfs BOOTLOADER=build/steamos-bootloader TARGET="$TARGET"

log "完成。产物："
ls -lh build/out/*.img 2>/dev/null || true
