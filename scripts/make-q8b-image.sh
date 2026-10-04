#!/usr/bin/env bash
#
# make-q8b-image.sh — 为 Radxa Dragon Q8B（Qualcomm SC8280XP / Adreno 690）打**可刷写整盘镜像**
#
# 布局与启动约定**逐条对齐 Radxa 官方镜像**（r7 的 guestfish 打包脚本）：
#   GPT：p1 config(vfat) / p2 efi(ESP, vfat) / p3 rootfs(ext4)
#   启动：SPI 里的 UEFI(EDK2) → ESP 上的 systemd-boot → BLS 条目 → 我们的 EFI zboot Image + DTB
#
# 本脚本改编自 radxa-build/radxa-dragon-midstream 的 .build-{4096,512}-image（guestfish 脚本）。
# 与 Radxa 原脚本的差别：原脚本 tar-in 的是它**自己打好内核**的 rootfs；
# 本脚本在 tar-in 之后，把**我们自己的**内核/DTB/模块/固件注入 rootfs 与 ESP，并写我们自己的 BLS 条目。
#
# ── 用法 ────────────────────────────────────────────────────────────────
#   ROOTFS=<rootfs.tar.xz | rootfs目录> TARGET=ufs|tf|nvme ./scripts/make-q8b-image.sh
#   （省略 TARGET 且在终端下运行 → 弹出菜单选择目标介质）
#
# 默认从本项目路径取内核产物：
#   Image     build/kernel/arch/arm64/boot/Image
#   DTB       build/kernel/arch/arm64/boot/dts/qcom/sc8280xp-radxa-dragon-q8b.dtb
#   模块      build/modules/lib/modules/
#   固件      firmware/lib/firmware/
#
# ── 目标介质（决定扇区大小，二者其一） ──────────────────────────────────
#   TARGET=ufs         → SECTOR=4096（板载 UFS）
#   TARGET=tf|nvme     → SECTOR=512 （microSD/TF 卡、NVMe）
#   不给 TARGET 也不给 SECTOR 时，在终端下运行会**弹出菜单**让你选。
#   SECTOR=4096|512    显式覆盖（自动化/特殊用途）。
#
# ── 其他环境变量 ────────────────────────────────────────────────────────
#   ROOTFS        必填。rootfs 的 .tar/.tar.xz/.tar.zst 或目录。
#   SIZE          镜像大小，默认 10G（与 Radxa 一致）。
#   OUT           输出镜像路径，默认 build/out/radxa-dragon-q8b_<SECTOR>.img
#   IMAGE/DTB/MODULES/FIRMWARE   覆盖默认内核产物路径。
#   OVERLAY       可选。目录，覆盖到 rootfs 根（SteamOS 阶段放我们的 sc8280xp-overlay）。
#   INITRD        可选。initrd 文件（steamos/initramfs/build-initramfs.sh 产出）。
#                   Radxa OS rootfs **可省**（ext4/UFS/NVMe 内建，直接挂根）；
#                   SteamOS rootfs **不能省**（需在 switch_root 前挂 /etc overlay）。
#   BOOTLOADER    可选。含 EFI/ 的目录，安装到 ESP（SteamOS rootfs 通常需显式给）。
#                   不给则要求输入 rootfs 自带 $ESP_MOUNT/EFI/BOOT/BOOTAA64.EFI。
#   ESP_MOUNT     ESP 在镜像内的挂载点，默认 /boot/efi。
#                   **SteamOS rootfs 用 /efi**：它的 /boot/efi 是指向 /efi 的软链，
#                   按 /boot/efi 挂会和 rootfs 里的软链打架。
#   WRITE_FSTAB   默认 1：打包时写一份 Radxa 风格 /etc/fstab（/config+/boot/efi+/）。
#                   0：不写，保留 rootfs/overlay 自带的 fstab（SteamOS 必须 0，
#                      否则会盖掉 apply-sc8280xp-overlay.sh 写的 partsets 替代版）。
#   CMDLINE_EXTRA 追加到内核 cmdline 的额外参数。
#   CONSOLE       内核 console= 参数，默认 console=ttyMSM0,115200n8 console=tty0。
#                 依据：板级 DTS &uart17 { compatible="qcom,geni-debug-uart" }
#                 （sc8280xp-radxa-dragon-q8b.dts:1619），驱动 qcom_geni_serial.c:1593
#                 .dev_name="ttyMSM" → 调试串口是 ttyMSM0；且板级 DTS 与 sc8280xp.dtsi
#                 都**没有** chosen/stdout-path，内核不会自动选默认 console，必须显式给。
#                 第二个 console=tty0 把内核日志也送到帧缓冲（HDMI）——本板用 HDMI 调试时
#                 必需，否则只给串口、屏幕上黑屏。
#                 不想要就设 CONSOLE=""。早期 console（earlycon）默认不开：
#                 earlycon=qcom_geni,0x884000 需 UEFI 已初始化该 UART 时钟，否则可能挂总线，
#                 仅在 console= 拿不到输出时才用 CMDLINE_EXTRA 加（见首启 runbook）。
#   KARGS         固定内核参数，默认 clk_ignore_unused。
#                 Radxa 官方 r7 changelog 明确 "fix: add clk_ignore_unused to kernel cmdline"。
#                 qcom 平台典型坑：clk 框架
#                 会关掉"看似未用"的时钟，导致存储/显示/USB 起不来甚至挂死。
#                 不想要就设 KARGS=""。
#   ENTRY_TITLE   BLS 条目标题。
#   WORK          暂存目录，默认 ./build/image-work
#   KEEP_WORK     1 则保留暂存目录
#
# ── 依赖 ────────────────────────────────────────────────────────────────
#   guestfish(libguestfs-tools)、tar、xz/zstd、sgdisk、blkid、sha256sum、sudo（guestfish 需读 /boot/vmlinuz）
#
set -euo pipefail

# ───────────────────────────── 参数 ─────────────────────────────
ROOTFS="${ROOTFS:-}"
TARGET="${TARGET:-}"
SECTOR="${SECTOR:-}"
SIZE="${SIZE:-10G}"
OUT="${OUT:-}"
IMAGE="${IMAGE:-build/kernel/arch/arm64/boot/Image}"
DTB="${DTB:-build/kernel/arch/arm64/boot/dts/qcom/sc8280xp-radxa-dragon-q8b.dtb}"
MODULES="${MODULES:-build/modules/lib/modules}"
FIRMWARE="${FIRMWARE:-firmware/lib/firmware}"
OVERLAY="${OVERLAY:-}"
INITRD="${INITRD:-}"
NO_INITRD="${NO_INITRD:-0}"
BOOTLOADER="${BOOTLOADER:-}"
ESP_MOUNT="${ESP_MOUNT:-/boot/efi}"
WRITE_FSTAB="${WRITE_FSTAB:-1}"
CMDLINE_EXTRA="${CMDLINE_EXTRA:-}"
CONSOLE="${CONSOLE:-console=ttyMSM0,115200n8 console=tty0}"
KARGS="${KARGS:-clk_ignore_unused}"
ENTRY_TITLE="${ENTRY_TITLE:-Radxa Dragon Q8B (SteamOS ARM)}"
WORK="${WORK:-$PWD/build/image-work}"
KEEP_WORK="${KEEP_WORK:-0}"
GUESTFISH="${GUESTFISH:-sudo guestfish}"
KREL="${KREL:-7.0.11+}"
DTB_NAME="sc8280xp-radxa-dragon-q8b.dtb"

PROG="$(basename "$0")"
log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$PROG" "$*" >&2; }
warn() { printf '\033[1;33m[%s] WARN:\033[0m %s\n' "$PROG" "$*" >&2; }
die()  { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "$PROG" "$*" >&2; exit 1; }

usage() { sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0; }
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

# ───────────────────── 目标介质 → 扇区大小 ─────────────────────
# 目标介质 → 扇区大小：UFS=4096；microSD(TF)/NVMe=512。错扇区镜像刷 UFS 引导不了。
sector_for_target() {
  case "$1" in
    ufs)                echo 4096 ;;
    tf|microsd|sd|nvme) echo 512  ;;
    *) return 1 ;;
  esac
}

pick_target_menu() {
  cat >&2 <<'MENU'

  选择目标介质（决定扇区大小）：
    1) UFS          —— 4096 字节扇区（板载；主机不能直接 dd）
    2) microSD / TF —— 512 字节扇区
    3) NVMe         —— 512 字节扇区
MENU
  local ans
  read -r -p "  输入 1-3 [默认 1=UFS]: " ans </dev/tty || ans=""
  case "${ans:-1}" in
    1) TARGET=ufs  ;;
    2) TARGET=tf   ;;
    3) TARGET=nvme ;;
    *) die "无效选择: '$ans'（应为 1-3）" ;;
  esac
}

if [[ -n "$SECTOR" ]]; then
  : # 显式 SECTOR 优先；取值由下面的 case 校验
elif [[ -n "$TARGET" ]]; then
  SECTOR="$(sector_for_target "$TARGET")" || die "TARGET 只能是 ufs|tf|nvme，当前='$TARGET'"
elif [[ -t 0 && -r /dev/tty ]]; then
  pick_target_menu
  SECTOR="$(sector_for_target "$TARGET")"
else
  die "非交互运行：请显式指定 TARGET=ufs|tf|nvme（或 SECTOR=4096|512）"
fi

# ─────────────────────── 分区布局（照抄 Radxa r7） ───────────────────────
# 两个镜像的 p1/p2 起始扇区相同，只是扇区字节数不同；p2(ESP) 恒为 1GiB。
#   4096: p1 32768-65535(128MiB) p2 65536-327679(1GiB)   p3 327680-end
#    512: p1 32768-65535( 16MiB) p2 65536-2162687(1GiB)  p3 2162688-end
case "$SECTOR" in
  4096) P2_END=327679;  P3_START=327680  ;;
  512)  P2_END=2162687; P3_START=2162688 ;;
  *) die "SECTOR 只能是 4096(UFS) 或 512(NVMe/microSD)，当前=$SECTOR" ;;
esac
P1_START=32768; P1_END=65535; P2_START=65536
[[ -n "$OUT" ]] || OUT="build/out/radxa-dragon-q8b_${SECTOR}.img"

# ───────────────────────────── 校验输入 ─────────────────────────────
[[ -n "$ROOTFS" ]] || die "必须设置 ROOTFS=<rootfs.tar.xz|rootfs目录>"
[[ -e "$ROOTFS" ]] || die "ROOTFS 不存在: $ROOTFS"
[[ -f "$IMAGE" ]] || die "内核 Image 不存在: $IMAGE（先构建内核）"
[[ -f "$DTB"   ]] || die "DTB 不存在: $DTB"
[[ -d "$MODULES" ]] || die "模块目录不存在: $MODULES"
[[ -d "$FIRMWARE" ]] || die "固件目录不存在: $FIRMWARE"
[[ -d "$MODULES/$KREL" ]] || die "模块目录里没有 $KREL/（当前内核 release 应为 $KREL）"
command -v guestfish >/dev/null || die "缺 guestfish：sudo apt-get install -y libguestfs-tools"

# Image 必须是 EFI zboot（MZ 头），否则 UEFI/systemd-boot 引导不了
if [[ "$(head -c2 "$IMAGE" | xxd -p)" != "4d5a" ]]; then
  die "$IMAGE 不是 EFI zboot（应为 MZ 头 4d5a）。用 CONFIG_EFI_ZBOOT=y 重新构建。"
fi

mkdir -p "$(dirname "$OUT")"
# guestfish 以 root 运行，会在 $WORK 里留下 root 属主文件 → 清理需 sudo
sudo rm -rf "$WORK"; mkdir -p "$WORK"/{esp,rootfs,out}
log "布局: TARGET=${TARGET:-<显式SECTOR>}  SECTOR=$SECTOR  p1=$P1_START-$P1_END  p2=$P2_START-$P2_END  p3=$P3_START-末  SIZE=$SIZE"
log "输出: $OUT"

# ─────────────────── 1) 整理 ESP 载荷（/q8b/* + loader/entries） ───────────────────
log "整理 ESP 载荷 ..."
mkdir -p "$WORK/esp/q8b" "$WORK/esp/loader/entries"
cp -a "$IMAGE" "$WORK/esp/q8b/Image"
cp -a "$DTB"   "$WORK/esp/q8b/$DTB_NAME"

INITRD_LINE=""
if [[ -n "$INITRD" ]]; then
  [[ -f "$INITRD" ]] || die "INITRD 不存在: $INITRD"
  cp -a "$INITRD" "$WORK/esp/q8b/initrd.img"
  INITRD_LINE="initrd /q8b/initrd.img"
elif [[ "$NO_INITRD" != "1" ]]; then
  warn "未提供 INITRD：BLS 条目不写 initrd。"
  warn "  - Radxa OS rootfs：本内核 UFS/NVMe/MMC/ext4 均内建，可直接挂根，**可省**。"
  warn "  - SteamOS rootfs：**不能省**！SteamOS 的 /etc 是 overlayfs，必须在 switch_root 前挂好，"
  warn "    否则设备上启用的服务开机不自启。用 steamos/initramfs/build-initramfs.sh 产出后传 INITRD=。"
  warn "    详见 README.md。"
fi

cat > "$WORK/esp/loader/entries/q8b.conf" <<EOF
title   $ENTRY_TITLE
linux   /q8b/Image
devicetree /q8b/$DTB_NAME
$INITRD_LINE
options $CONSOLE $KARGS root=UUID=__ROOT_UUID__ rw rootwait rootfstype=ext4 $CMDLINE_EXTRA
EOF
cat > "$WORK/esp/loader/loader.conf" <<EOF
default q8b.conf
timeout 3
editor  no
EOF

# ─────────────────── 2) 整理 rootfs 载荷（模块 + 固件） ───────────────────
# 打成 tar 用 tar-in 合并进 rootfs（copy-in 目录会变成 /usr/usr，不能这么用）。
log "整理 rootfs 载荷（模块 $KREL + 固件）..."
RP="$WORK/rootfs-payload"
mkdir -p "$RP/usr/lib/modules" "$RP/usr/lib/firmware"
cp -a "$MODULES/$KREL" "$RP/usr/lib/modules/"
cp -a "$FIRMWARE/."    "$RP/usr/lib/firmware/"
# 去掉 modules_install 留下的悬空软链（指向构建机路径）
rm -f "$RP/usr/lib/modules/$KREL/build" "$RP/usr/lib/modules/$KREL/source"
# 载荷强制 root 属主（本是我们自己的文件；ext4 支持属主，但 root 才正确）
tar --owner=0 --group=0 --numeric-owner -cf "$WORK/payload.tar" -C "$RP" .

# ─────────────────── 3) 准备 rootfs.tar（guestfish tar-in 用） ───────────────────
if [[ -d "$ROOTFS" ]]; then
  # FAT(ESP) 不支持任意属主：tar-in 到 ESP 时若源文件非 root 属主会 "Cannot change ownership"。
  # Radxa 官方 rootfs.tar 是 root 属主，正常；只有"自己准备的目录"容易踩。
  if find "$ROOTFS$ESP_MOUNT" -not -user root -print -quit 2>/dev/null | grep -q .; then
    die "rootfs 的 $ESP_MOUNT 里有非 root 属主文件，tar-in 到 FAT 会失败。先：sudo chown -R root:root <rootfs>，或直接给 rootfs.tar。"
  fi
  log "打包 rootfs 目录 -> $WORK/rootfs.tar（需 sudo 以保留权限/设备节点）"
  sudo tar -C "$ROOTFS" --xattrs --acls --numeric-owner -cf "$WORK/rootfs.tar" .
elif [[ -f "$ROOTFS" ]]; then
  case "$ROOTFS" in
    *.tar)        cp -a "$ROOTFS" "$WORK/rootfs.tar" ;;
    *.tar.xz)     log "解压 rootfs.tar.xz ..."; xz -dc "$ROOTFS" > "$WORK/rootfs.tar" ;;
    *.tar.zst)    log "解压 rootfs.tar.zst ..."; zstd -dc "$ROOTFS" > "$WORK/rootfs.tar" ;;
    *.tar.gz|*.tgz) log "解压 rootfs.tar.gz ..."; gzip -dc "$ROOTFS" > "$WORK/rootfs.tar" ;;
    *) die "不认识的 rootfs 格式: $ROOTFS" ;;
  esac
else
  die "ROOTFS 既不是目录也不是文件: $ROOTFS"
fi
[[ -s "$WORK/rootfs.tar" ]] || die "rootfs.tar 为空"

# ─────────────────── 3.5) 确保 ESP 上有 UEFI 引导器（systemd-boot） ───────────────────
# UEFI 固件在 ESP 上找 /EFI/BOOT/BOOTAA64.EFI（回退）或 /EFI/systemd/systemd-bootaa64.efi。
# Radxa OS rootfs 的 /boot/efi 里自带；**SteamOS rootfs 按 ABL/bootimg 设计，通常没有**，
# 不补的话镜像引导不起来（UEFI 找不到可执行的引导器）。
#   BOOTLOADER=<目录>  该目录下需有 EFI/（含 BOOT/BOOTAA64.EFI 或 systemd/systemd-bootaa64.efi）。
# 取法（最省事：从 Radxa OS rootfs 的 /boot/efi 拷）。
BL_LINES=""
if [[ -n "$BOOTLOADER" ]]; then
  [[ -d "$BOOTLOADER/EFI" ]] || die "BOOTLOADER 目录里没有 EFI/：$BOOTLOADER"
  log "安装 ESP 引导器：$BOOTLOADER/EFI -> $ESP_MOUNT/EFI"
  BL_LINES="copy-in $BOOTLOADER/EFI $ESP_MOUNT"
else
  # 探测输入 rootfs 是否自带引导器（目录直接看，tar 看清单）
  have_bl=0
  esp_rel="${ESP_MOUNT#/}"
  if [[ -d "$ROOTFS" ]]; then
    [[ -f "$ROOTFS/$esp_rel/EFI/BOOT/BOOTAA64.EFI" ]] && have_bl=1
  else
    tar -tf "$WORK/rootfs.tar" 2>/dev/null \
      | grep -qxE "\./$esp_rel/EFI/BOOT/BOOTAA64\.EFI" && have_bl=1
  fi
  if [[ "$have_bl" == 1 ]]; then
    log "输入 rootfs 自带 ESP 引导器（$ESP_MOUNT/EFI/BOOT/BOOTAA64.EFI），沿用。"
  else
    die "输入 rootfs 的 ESP 上没有引导器（$ESP_MOUNT/EFI/BOOT/BOOTAA64.EFI 不存在），且未给 BOOTLOADER=<目录>。
  Radxa OS rootfs 自带；SteamOS rootfs 通常没有。请从 Radxa OS rootfs 的 /boot/efi 取一份，
  或用 BOOTLOADER=<含 EFI/ 的目录> 指定。详见 README.md。"
  fi
fi

# ─────────────────── 4) 生成 guestfish 脚本（核心，照 Radxa 改） ───────────────────
# fstab 写入块：WRITE_FSTAB=0 时不生成（SteamOS 用 overlay 自带 fstab，别盖掉）。
FSTAB_BLOCK=""
if [[ "$WRITE_FSTAB" == "1" ]]; then
  FSTAB_BLOCK=$(cat <<FSEOF
echo "Writing /etc/fstab with real UUIDs..."
blkid /dev/sda1 | grep "^UUID:" | cut -d " " -f 2 | xargs printf "UUID=%s /config vfat defaults,x-systemd.automount,fmask=0077,dmask=0077 0 2\n" > "$WORK/fstab"
blkid /dev/sda2 | grep "^UUID:" | cut -d " " -f 2 | xargs printf "UUID=%s $ESP_MOUNT vfat defaults,x-systemd.automount,fmask=0077,dmask=0077 0 2\n" >> "$WORK/fstab"
blkid /dev/sda3 | grep "^UUID:" | cut -d " " -f 2 | xargs printf "UUID=%s / ext4 defaults 0 1\n" >> "$WORK/fstab"
copy-in $WORK/fstab /etc/
FSEOF
)
else
  log "WRITE_FSTAB=0：保留 rootfs/overlay 自带的 /etc/fstab"
fi

GF="$WORK/build-image.fish"
log "生成 guestfish 脚本: $GF"
cat > "$GF" <<EOF
#!/usr/bin/env -S guestfish -f

!echo "Q8B image build started at \$(date)."
echo "Allocating image file..."
!rm -f "$OUT"
disk-create "$OUT" raw $SIZE
add-drive "$OUT" format:raw discard:besteffort blocksize:$SECTOR
run

echo "Creating partition table (GPT)..."
part-init /dev/sda gpt
part-add /dev/sda primary $P1_START $P1_END
part-add /dev/sda primary $P2_START $P2_END
part-set-bootable /dev/sda 2 true
part-add /dev/sda primary $P3_START -34
part-set-bootable /dev/sda 3 true
part-set-gpt-type /dev/sda 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B
part-set-gpt-type /dev/sda 3 0FC63DAF-8483-4772-8E79-3D69D8477DE4
part-set-gpt-attributes /dev/sda 2 4
part-set-gpt-attributes /dev/sda 3 4
echo "Naming GPT partitions (config/efi/rootfs)..."
part-set-name /dev/sda 1 config
part-set-name /dev/sda 2 efi
part-set-name /dev/sda 3 rootfs

echo "Formatting partitions..."
mkfs vfat /dev/sda1 label:config
mkfs vfat /dev/sda2 label:efi
mkfs ext4 /dev/sda3 label:rootfs

echo "Mounting partitions..."
mount /dev/sda3 /
mkdir-p /config
mount /dev/sda1 /config
mkdir-p $ESP_MOUNT
mount /dev/sda2 $ESP_MOUNT

echo "Deploying rootfs (this also populates the ESP if the tar carries $ESP_MOUNT/*)..."
tar-in $WORK/rootfs.tar / xattrs:true

echo "Removing stock BLS entries; installing ours..."
rm-rf $ESP_MOUNT/loader/entries
mkdir-p $ESP_MOUNT/loader/entries

echo "Injecting our kernel/DTB/entry onto the ESP..."
copy-in $WORK/esp/q8b $ESP_MOUNT
copy-in $WORK/esp/loader $ESP_MOUNT
$BL_LINES

echo "Injecting our modules + firmware into the rootfs..."
tar-in $WORK/payload.tar / xattrs:true

$FSTAB_BLOCK

echo "Patching root=UUID into our BLS entry..."
copy-out $ESP_MOUNT/loader/entries "$WORK"
blkid /dev/sda3 | grep "^UUID:" | cut -d " " -f 2 | xargs -I{} sed -i -e "s|__ROOT_UUID__|{}|g" "$WORK/entries/q8b.conf"
copy-in $WORK/entries $ESP_MOUNT/loader/

echo "Enlarging rootfs to the partition..."
shutdown
add-drive "$OUT" format:raw discard:besteffort blocksize:$SECTOR
run
resize2fs /dev/sda3
shutdown

echo "Cleaning up..."
!sync
echo "Deploy succeed!"
!echo "Image generation finished at \$(date)."
EOF

# ─────────────────── 5) 运行 guestfish ───────────────────
# DRY_RUN=1：只生成并打印 guestfish 脚本，不真打镜像（本地验证布局/ESP_MOUNT/fstab 用）。
if [[ "${DRY_RUN:-0}" == "1" ]]; then
  log "DRY_RUN=1：不执行 guestfish。脚本已生成：$GF"
  cat "$GF"
  exit 0
fi
log "运行 guestfish（sudo，需读 /boot/vmlinuz 构建 appliance）..."
$GUESTFISH -f "$GF" || die "guestfish 打包失败"

# ─────────────────── 6) 自检 ───────────────────
# 注意：镜像的逻辑块大小 = SECTOR。sgdisk/parted 读文件时默认按 512B 扇区，
# 会**误读 4096 镜像**，所以自检统一走 guestfish 并显式 blocksize。
log "自检（guestfish, blocksize=$SECTOR）..."
[[ -s "$OUT" ]] || die "输出镜像不存在或为空"
$GUESTFISH --ro <<GEOF | sed 's/^/    /' || warn "guestfish 只读自检失败（镜像可能仍可用，请手动核对）"
add-drive "$OUT" format:raw blocksize:$SECTOR
run
echo "== partitions =="
part-list /dev/sda
mount /dev/sda3 /
mkdir-p $ESP_MOUNT
mount /dev/sda2 $ESP_MOUNT
echo "== ESP /q8b =="
ls $ESP_MOUNT/q8b
echo "== ESP BLS entries =="
ls $ESP_MOUNT/loader/entries
echo "== our entry =="
cat $ESP_MOUNT/loader/entries/q8b.conf
echo "== ESP bootloader =="
ls $ESP_MOUNT/EFI/BOOT
echo "== rootfs /usr/lib/modules =="
ls /usr/lib/modules
echo "== /etc/fstab =="
cat /etc/fstab
GEOF

log "计算 sha256 ..."
( cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" | tee "$(basename "$OUT").sha256" )

[[ "$KEEP_WORK" == "1" ]] || sudo rm -rf "$WORK"
log "完成: $OUT  ($(du -h "$OUT" | cut -f1))  SECTOR=$SECTOR"
case "${TARGET:-}" in
  ufs)
    warn "目标=UFS(4096)：UFS 是**板载**的，主机上不能直接 dd 这块盘。"
    warn "  刷写请走 EDL/qdl，或从 TF 启动后在板上写（具体路径未验证）。镜像已就绪: $OUT"
    ;;
  tf)
    log "刷 TF 卡: sudo dd if=$OUT of=/dev/sdX bs=4M status=progress conv=fsync   # 换成你的读卡器设备，务必核对"
    ;;
  nvme)
    log "刷 NVMe : sudo dd if=$OUT of=/dev/nvmeXn1 bs=4M status=progress conv=fsync   # 换成你的 NVMe 设备，务必核对"
    ;;
  *)
    log "刷写:    sudo dd if=$OUT of=/dev/<dev> bs=4M status=progress conv=fsync   # 4096→UFS，512→TF/NVMe，务必核对介质"
    ;;
esac
