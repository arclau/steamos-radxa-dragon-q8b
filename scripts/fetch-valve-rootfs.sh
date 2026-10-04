#!/usr/bin/env bash
#
# fetch-valve-rootfs.sh — 下载并重组 Valve 官方 SteamOS ARM（Steam Frame / Deckard）rootfs.img。
#
# 全部按 upstream.lock 钉死并校验：
#   1) 下载 RAUC bundle <bundle>.raucb（小，~2MB），校验 sha256；
#   2) unsquashfs 取 bundle/{rootfs.img.caibx,manifest.raucm}；
#   3) 用 steamos/tools/extract_rootfs.py 从 casync store 重组 rootfs.img；
#   4) 校验 rootfs.img 的 sha256（取自 Valve manifest）。
#
# 产物：build/dl/steamos-<build>/rootfs.img（幂等：已存在且校验通过则跳过）。
# 依赖：curl、unsquashfs(squashfs-tools)、python3 + requests + zstandard。
# 说明：本脚本只下载、不向上游推送任何东西。
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

command -v curl       >/dev/null || die "缺 curl"
command -v unsquashfs >/dev/null || die "缺 unsquashfs（apt install squashfs-tools）"
command -v python3    >/dev/null || die "缺 python3"
python3 -c 'import requests, zstandard' 2>/dev/null \
  || die "缺 python 依赖（pip install requests zstandard）"

DL_DIR="${DL_DIR:-$REPO_ROOT/build/dl/steamos-${STEAMOS_BUILD}}"
RAUCB="$DL_DIR/${STEAMOS_BUNDLE}.raucb"
BUNDLE_DIR="$DL_DIR/bundle"
IMG="$DL_DIR/rootfs.img"
EXTRACTOR="$REPO_ROOT/steamos/tools/extract_rootfs.py"

[[ -f "$EXTRACTOR" ]] || die "缺 vendor 提取器 $EXTRACTOR"

mkdir -p "$DL_DIR"
sha256_of() { sha256sum "$1" | awk '{print $1}'; }

# ── 已完成？────────────────────────────────────────────────────────────────
if [[ -s "$IMG" ]] && [[ "$(sha256_of "$IMG")" == "$STEAMOS_ROOTFS_SHA256" ]]; then
  log "rootfs.img 已就绪并校验通过（跳过）：$IMG"
  exit 0
fi

# ── 1. RAUC bundle ─────────────────────────────────────────────────────────
if [[ ! -s "$RAUCB" ]] || [[ "$(sha256_of "$RAUCB")" != "$STEAMOS_RAUCB_SHA256" ]]; then
  log "下载 ${STEAMOS_BUNDLE}.raucb"
  curl -fL --retry 5 --retry-delay 3 --connect-timeout 30 \
    -o "$RAUCB.part" "$STEAMOS_BASE_URL/${STEAMOS_BUNDLE}.raucb" \
    || die "下载 .raucb 失败：$STEAMOS_BASE_URL/${STEAMOS_BUNDLE}.raucb"
  mv -f "$RAUCB.part" "$RAUCB"
fi
got="$(sha256_of "$RAUCB")"
if [[ "$got" != "$STEAMOS_RAUCB_SHA256" ]]; then
  die ".raucb sha256 不符：
  期望 $STEAMOS_RAUCB_SHA256
  实际 $got"
fi
log "OK  .raucb sha256 校验通过"

# ── 2. 解出 caibx + manifest ───────────────────────────────────────────────
if [[ ! -s "$BUNDLE_DIR/rootfs.img.caibx" ]]; then
  log "unsquashfs → $BUNDLE_DIR"
  rm -rf "$BUNDLE_DIR"
  unsquashfs -q -d "$BUNDLE_DIR" "$RAUCB" || die "unsquashfs 失败"
fi
[[ -s "$BUNDLE_DIR/rootfs.img.caibx" ]] || die "缺 $BUNDLE_DIR/rootfs.img.caibx"

sha="$(sed -n '/^\[image.rootfs\]/,/^\[/{s/^sha256=//p}' "$BUNDLE_DIR/manifest.raucm" | head -1)"
[[ -n "$sha" ]] || die "无法从 manifest.raucm 读出 rootfs sha256"
if [[ "$sha" != "$STEAMOS_ROOTFS_SHA256" ]]; then
  die "manifest sha256 ($sha) 与 upstream.lock ($STEAMOS_ROOTFS_SHA256) 不一致；请更新锁后重试"
fi

# ── 3. 重组 rootfs.img ─────────────────────────────────────────────────────
log "重组 rootfs.img（casync；目标 sha256 ${sha:0:12}…）"
rm -f "$IMG"
python3 "$EXTRACTOR" \
  --caibx "$BUNDLE_DIR/rootfs.img.caibx" --output "$IMG" \
  --store "$STEAMOS_BASE_URL/${STEAMOS_BUNDLE}.castr" \
  --store "$STEAMOS_FALLBACK_STORE" \
  --expected-sha256 "$sha" || die "extract_rootfs.py 失败"

# ── 4. 校验 ────────────────────────────────────────────────────────────────
got="$(sha256_of "$IMG")"
[[ "$got" == "$STEAMOS_ROOTFS_SHA256" ]] || die "rootfs.img sha256 不符：
  期望 $STEAMOS_ROOTFS_SHA256
  实际 $got"
size="$(stat -c%s "$IMG")"
[[ "$size" == "$STEAMOS_ROOTFS_SIZE" ]] || log "注意：大小 $size != 锁中 $STEAMOS_ROOTFS_SIZE（继续）"
log "OK  rootfs.img 就绪：$IMG（$size 字节）"
