#!/usr/bin/env bash
#
# prepare-steamos-rootfs.sh — 把 Valve SteamOS ARM 的 rootfs.img 变成可打包的 rootfs 目录，
#                             并顺带产出 ESP 引导器目录（systemd-boot）。
#
# 流水线（P4/P5 的落地脚本）：
#   rootfs.img (btrfs, ro)
#     → loop 只读挂载 → rsync -aHAX --numeric-ids 到目录（保留 xattr/硬链/setuid）
#     → 应用 steamos/apply-sc8280xp-overlay.sh（去 Frame 化 + 压平布局）
#     → 从 /usr/lib/systemd/boot/efi/systemd-bootaa64.efi 产出 BOOTLOADER 目录
#   产物交给 scripts/make-q8b-image.sh（ESP_MOUNT=/efi WRITE_FSTAB=0）。
#
# 用法（必须 root；脚本会自己 sudo 重入）：
#   steamos/prepare-steamos-rootfs.sh <rootfs.img> <out-dir> [<bootloader-out-dir>]
#
#   例：
#     steamos/prepare-steamos-rootfs.sh \
#       build/dl/steamos-20260925.6175226/rootfs.img \
#       build/steamos-rootfs \
#       build/steamos-bootloader
#
# 说明：
#   - <out-dir> 会被**清空重建**（它是构建产物目录，别指向你的数据目录）。
#   - SteamOS rootfs 是 **btrfs**；rsync 出来的是普通文件，最终打进 ext4 的 p3。
#   - 每台设备首启的 machine-id / 启用服务由 overlay 处理；见 apply-sc8280xp-overlay.sh。
#
set -euo pipefail

IMG="${1:-}"
OUT="${2:-}"
BO="${3:-}"
if [[ -z "$IMG" || -z "$OUT" ]]; then
  echo "用法: $0 <rootfs.img> <out-dir> [<bootloader-out-dir>]" >&2
  exit 1
fi
[[ -f "$IMG" ]] || { echo "ERROR: rootfs.img 不存在: $IMG" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/.." && pwd)"

# 安全闸：out-dir 不能是 / 、空、/data、或项目根（这些会被 rm -rf）。
# 用 $PROJ 而非硬编码路径，保证在 CI/fork 的任何检出路径下都成立。
case "$OUT" in
  /|""|/data|"$PROJ") echo "ERROR: 拒绝把 out-dir 设为 '$OUT'（会被清空）" >&2; exit 1;;
esac
case "$OUT" in
  /*) : ;; # 绝对路径
  *) OUT="$PWD/$OUT" ;;
esac

# 需要 root（loop 挂载 + 保留属主/xattr）。
if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo -E "$0" "$IMG" "$OUT" "$BO"
fi

log() { printf '\033[1;34m[prepare]\033[0m %s\n' "$*" >&2; }

MNT="$(mktemp -d /tmp/q8b-steamos-ro.XXXXXX)"
cleanup() { mountpoint -q "$MNT" && umount "$MNT" || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT

log "loop 只读挂载 $IMG → $MNT"
mount -o ro,loop "$IMG" "$MNT"
# 确认确实是 btrfs（不是就提示，但不硬拦——万一是别的也让它跑）
fstype="$(findmnt -no FSTYPE "$MNT" || true)"
log "  文件系统类型: ${fstype:-未知}"

log "清空并重建 out-dir: $OUT"
rm -rf "$OUT"
mkdir -p "$OUT"

log "rsync rootfs → $OUT（保留 xattr/ACL/硬链/setuid，数字属主）"
# -H 保硬链、-A ACL、-X xattr（含 security.capability / setuid 相关）、--numeric-ids 不做名字映射。
# 排除挂载点内的伪文件系统（rsync 不跨 fs 也行，但显式排除更稳）。
# 注意：SteamOS 的 btrfs 在每个目录上带 `btrfs.compression` xattr，目标若是 ext4/其它 fs
# 会 lsetxattr 失败（Operation not supported），rsync 因此返回 23。这是**无害**的
# （该 xattr 只对 btrfs 有意义），故只对"非 btrfs.compression"的错误才判失败。
ERRLOG="$(mktemp)"
set +e
rsync -aHAX --numeric-ids --info=stats2 \
  --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
  --exclude='/run/*' --exclude='/tmp/*' \
  "$MNT"/ "$OUT"/ 2>"$ERRLOG"
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  if grep -v 'btrfs\.compression' "$ERRLOG" | grep -q 'rsync:'; then
    cat "$ERRLOG" >&2
    echo "ERROR: rsync 失败（存在非 btrfs.compression 的错误），退出码 $rc" >&2
    exit 1
  fi
  log "  忽略 btrfs.compression xattr 错误（目标 fs 非 btrfs，无害）"
fi
rm -f "$ERRLOG"

log "卸载"
umount "$MNT"; rmdir "$MNT" 2>/dev/null || true; trap - EXIT

# ── 应用去 Frame 化 / 压平 overlay ─────────────────────────────────────────
"$HERE/apply-sc8280xp-overlay.sh" "$OUT"

# ── 产出 ESP 引导器目录（systemd-boot）──────────────────────────────────────
if [[ -n "$BO" ]]; then
  case "$BO" in /*) : ;; *) BO="$PWD/$BO" ;; esac
  SRC="$OUT/usr/lib/systemd/boot/efi/systemd-bootaa64.efi"
  [[ -f "$SRC" ]] || { echo "ERROR: rootfs 里没有 $SRC，无法产出引导器" >&2; exit 1; }
  log "产出 ESP 引导器目录: $BO"
  rm -rf "$BO"
  mkdir -p "$BO/EFI/BOOT" "$BO/EFI/systemd"
  # UEFI 回退路径（可移除介质）：/EFI/BOOT/BOOTAA64.EFI
  install -m0644 "$SRC" "$BO/EFI/BOOT/BOOTAA64.EFI"
  # 常规路径（NVRAM 里 systemd 的默认项）：/EFI/systemd/systemd-bootaa64.efi
  install -m0644 "$SRC" "$BO/EFI/systemd/systemd-bootaa64.efi"
  log "  已放 EFI/BOOT/BOOTAA64.EFI + EFI/systemd/systemd-bootaa64.efi（$(stat -c%s "$SRC") 字节）"
fi

log "完成："
log "  rootfs 目录 : $OUT  ($(du -sh "$OUT" 2>/dev/null | cut -f1))"
[[ -n "$BO" ]] && log "  引导器目录 : $BO"
log "下一步（TF/512）："
log "  make steamos-image ROOTFS=$OUT BOOTLOADER=$BO TARGET=tf"
