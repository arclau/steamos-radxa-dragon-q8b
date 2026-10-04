#!/usr/bin/env bash
#
# build-initramfs.sh — 组装 Q8B 的 busybox initramfs（cpio+gzip），供 UEFI 引导使用。
#
# 产出：steamos/initramfs/out/initrd.gz  （放到 ESP，BLS 条目里用 `initrd /q8b/initrd.gz`）
#
# 为什么需要它：SteamOS 的 /etc 是 overlayfs，必须在 switch_root 前挂好
# （见 steamos/initramfs/init 顶部注释）。Radxa OS 可省，SteamOS 不能省。
#
# 依赖：aarch64 **静态** busybox、cpio、gzip。
#   BUSYBOX=<path>  指定静态 aarch64 busybox；不给则按下方候选表自动找。
#
# 来源与溯源：
#   steamos/initramfs/init 改编自 SteamOS-ARM-Handhelds
#     ref/steamos-arm-handhelds/external-and-mods/kernel-common/initramfs/init
#   构建方式同其 external-and-mods/kernel-common/build.sh:252-268。
#   busybox 需为 aarch64 静态；仓库内置副本：
#     steamos/initramfs/tools/busybox-aarch64   （发布/CI 用，见该目录说明）
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${SRC_DIR:-$HERE}"
OUT="${OUT:-$SRC_DIR/out/initrd.gz}"
WORK="${WORK:-$SRC_DIR/out/work}"
# 本项目运行时固件落点。initramfs 需要从中挑「早期固件」内置。
REPO_ROOT="$(cd "$SRC_DIR/../.." && pwd)"
FIRMWARE_DIR="${FIRMWARE_DIR:-$REPO_ROOT/firmware/lib/firmware}"

PROG="$(basename "$0")"
log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$PROG" "$*" >&2; }
die()  { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "$PROG" "$*" >&2; exit 1; }

# ── 找静态 aarch64 busybox ────────────────────────────────────────────────
# 顺序：$BUSYBOX → 仓库内置 → 报错并给获取方法。
default_busybox_candidates=(
  "$SRC_DIR/tools/busybox-aarch64"
)

pick_busybox() {
  if [[ -n "${BUSYBOX:-}" ]]; then
    [[ -f "$BUSYBOX" ]] || die "BUSYBOX 不存在: $BUSYBOX"
    echo "$BUSYBOX"; return
  fi
  for c in "${default_busybox_candidates[@]}"; do
    [[ -f "$c" ]] && { echo "$c"; return; }
  done
  return 1
}

BB="$(pick_busybox)" || die "找不到静态 aarch64 busybox。
  - 给 BUSYBOX=<path>；或
  - 从 busybox 源码配置静态 + aarch64-linux-gnu- 交叉编译；或
  - 从发行版取 aarch64 静态包（如 Alpine/Ubuntu busybox-static:arm64）。"

# 校验：必须是 aarch64 且静态
info="$(file -b "$BB" 2>/dev/null || true)"
case "$info" in
  *aarch64*) : ;;
  *) die "busybox 不是 aarch64：$BB（$info）" ;;
esac
case "$info" in
  *"statically linked"*) : ;;
  *) die "busybox 不是静态链接：$BB（$info）。initramfs 里没有动态链接器。" ;;
esac
log "busybox: $BB"
log "  $info"

[[ -f "$SRC_DIR/init" ]] || die "缺 $SRC_DIR/init"
command -v cpio >/dev/null || die "缺 cpio：sudo apt-get install -y cpio"
command -v gzip >/dev/null || die "缺 gzip"

# ── 组装 ──────────────────────────────────────────────────────────────────
rm -rf "$WORK"; mkdir -p "$WORK/root"/{bin,dev,proc,sys}
cp "$BB" "$WORK/root/bin/busybox"
install -m0755 "$SRC_DIR/init" "$WORK/root/init"

# ── 内置「早期固件」——GPU（关键，别删）───────────────────────────────────────
# 为什么必须放 initramfs 而不是只靠 rootfs：
#   CONFIG_DRM_FBDEV_EMULATION=y 时，DRM 的 fbdev 客户端会在 msm_drm_bind
#   （device_initcall，实测 ~0.75s）期间就 open DRM → msm_open→load_gpu→adreno_load_fw。
#   而内建 msm 在 device_initcall 跑，早于本 init 挂真 rootfs；rootfs 里的固件此时取不到
#   → request_firmware 返回 -ENOENT → msm_open 里 `if (!priv->gpu)` 因错误指针非 NULL 而
#   不再重试 → GPU 永久不亮（gamescope/Steam UI 无渲染）。
#   initramfs 在 rootfs_initcall 就解包（早于 device_initcall），故固件放这里最稳。
# 证据：真机串口 `msm_dpu ... failed to load a660_sqe.fw`。
# 固件名权威来源：drivers/gpu/drm/msm/adreno/a6xx_catalog.c a690 条目
#   （[ADRENO_FW_SQE]="a660_sqe.fw"、[ADRENO_FW_GMU]="a660_gmu.bin"）+ 板级 DT
#   &gpu_zap_shader firmware-name（qcom/sc8280xp/LENOVO/21BX/qcdxkmsuc8280.mbn）。
EARLY_FW=(
  qcom/a660_sqe.fw
  qcom/a660_gmu.bin
  qcom/sc8280xp/LENOVO/21BX/qcdxkmsuc8280.mbn
)
for _f in "${EARLY_FW[@]}"; do
  _src="$FIRMWARE_DIR/$_f"
  [[ -f "$_src" ]] || die "缺早期固件: $_src"
  install -D -m0644 "$_src" "$WORK/root/lib/firmware/$_f"
done
unset _f _src
log "内置早期固件 ${#EARLY_FW[@]} 个（GPU a660 SQE/GMU + zap）→ /lib/firmware/"

log "打包 cpio (newc) ..."
( cd "$WORK/root" && find . | cpio -o -H newc --owner=0:0 2>/dev/null ) > "$WORK/initrd.cpio"
mkdir -p "$(dirname "$OUT")"
gzip -9 -n -c "$WORK/initrd.cpio" > "$OUT"
log "完成: $OUT  ($(du -h "$OUT" | cut -f1))"
log "用法: make-q8b-image.sh 里给 INITRD=$OUT（SteamOS rootfs 必需；Radxa OS 可省）"
