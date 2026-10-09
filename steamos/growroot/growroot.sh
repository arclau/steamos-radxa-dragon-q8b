#!/usr/bin/env bash
#
# growroot.sh — 把根分区扩到整盘（幂等；每次启动跑一次，无空闲空间则空转）。
#
# 为什么需要（真机根因）：
#   镜像按固定 SIZE（make-q8b-image.sh 默认 16G）打包；刷到更大的 TF/NVMe 后，
#   剩余空间是**未分区**的，根分区只有 16G。SteamOS + Steam 客户端 + shader cache
#   要 GB 级空间，根分区写满会让 Steam 装不完/崩溃 → gamescope 的 --steam 会话
#   拿不到客户端、从不提交 KMS → HDMI 只剩 fbcon 光标。
#
# 安全性（务必保持）：
#   - 只在「根分区是该磁盘最后一个分区」时动手（否则扩它会踩到后面的分区）；
#   - 原地重建该分区，**保留 start / type / name / unique-GUID**：不动数据，
#     不改文件系统 UUID → root=UUID / PARTLABEL 全部不受影响；
#   - partx -u 让内核看到新尺寸，resize2fs 在线扩容；
#   - 任何一步异常都只记录并 exit 0（best-effort，绝不阻断启动）。
#
# 依赖（SteamOS rootfs 自带）：sgdisk、partx、resize2fs。
#
set -u

log() { echo "steamos-growroot: $*"; }

ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || true)"
[[ "$ROOT_SRC" == /dev/* ]] || { log "根不是块设备（$ROOT_SRC），跳过"; exit 0; }
ROOT_SRC="$(readlink -f "$ROOT_SRC")"
PARTNAME="$(basename "$ROOT_SRC")"

PARTNUM="$(cat "/sys/class/block/$PARTNAME/partition" 2>/dev/null || true)"
[[ -n "$PARTNUM" ]] || { log "$ROOT_SRC 不是分区，跳过"; exit 0; }

PK="$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1)"
[[ -n "$PK" ]] || { log "取不到 $ROOT_SRC 的父磁盘，跳过"; exit 0; }
DISK="/dev/$PK"

# 根分区必须是该磁盘最后一个分区
LASTPART="$(lsblk -rno NAME,TYPE "$DISK" 2>/dev/null | awk '$2=="part"{p=$1} END{print p}')"
[[ "$PARTNAME" == "$LASTPART" ]] || { log "$PARTNAME 不是 $DISK 最后一个分区（$LASTPART），跳过"; exit 0; }

for t in sgdisk partx resize2fs; do
  command -v "$t" >/dev/null 2>&1 || { log "缺 $t，跳过"; exit 0; }
done

# 采集原分区属性
INFO="$(sgdisk -i "$PARTNUM" "$DISK" 2>/dev/null || true)"
START="$(printf '%s\n' "$INFO" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')"
PART_LAST="$(printf '%s\n' "$INFO" | sed -n 's/^Last sector: \([0-9]*\).*/\1/p')"
TYPECODE="$(printf '%s\n' "$INFO" | sed -n 's/^Partition GUID code: \([0-9A-Fa-f-]*\).*/\1/p')"
GUID="$(printf '%s\n' "$INFO" | sed -n 's/^Partition unique GUID: \([0-9A-Fa-f-]*\).*/\1/p')"
NAME="$(printf '%s\n' "$INFO" | sed -n "s/^Partition name: '\(.*\)'.*/\1/p")"
[[ -n "$START" && -n "$TYPECODE" && -n "$GUID" ]] || { log "解析分区属性失败，跳过"; exit 0; }

# 幂等判据：根分区**末尾是否已到物理磁盘末尾**。
# ⚠️ 两次血案（devlog/2026-10-09-01 → 2026-10-09-02）：
#   1) 旧代码用 `sgdisk -F`（第一个空闲扇区）判空 —— GPT 与 p1 之间的空隙恒空闲 →
#      恒返回 256 → 每次开机都误判「还有空间」→ **每次重写分区表**（sgdisk -e/-d/-n）
#      + partx + resize2fs，白花 ~3s 且有改坏分区表的风险。
#   2) 改用 `sgdisk -p` 的 "last usable sector" 后，**在「小镜像 dd 到大盘」的首启场景失效**：
#      GPT 记录的是镜像自身尺寸（如 16G），`sgdisk -p` 与 `sgdisk -i` 都从这份**陈旧 GPT**
#      取值 → 两者相等 → 误判「已在盘尾」→ **永不扩容**（根写满 → Steam 崩 → 黑屏）。
#      真机实测（2026-10-09）：477G TF 卡刷 16G 镜像后 `sgdisk -p` 报 last usable=33554398
#      （=16G），而物理盘是 1000243200 个 512B 扇区；`sgdisk -E` 同样不可信（返回 32767）。
#   3) 正解：用**物理尺寸**判据（sysfs `/sys/block/$PK/size` 恒以 512B 为单位）。
#      分区末尾用 `sgdisk -i` 的 Last sector（逻辑扇区）× (logical_block_size/512) 归一到
#      512B 单位；留 8MiB slack 覆盖 GPT 备份 + 2048 扇区对齐。
LOGICAL="$(cat "/sys/block/$PK/queue/logical_block_size" 2>/dev/null || echo 512)"
DISK_512="$(cat "/sys/block/$PK/size" 2>/dev/null || true)"
FACTOR=$(( LOGICAL / 512 )); [ "$FACTOR" -ge 1 ] || FACTOR=1
if [ -z "$PART_LAST" ] || [ -z "$DISK_512" ]; then
  log "取不到分区末尾或物理磁盘尺寸（part_last='$PART_LAST' disk='$DISK_512'），跳过"
  exit 0
fi
PART_LAST_512=$(( PART_LAST * FACTOR ))
if [ "$PART_LAST_512" -ge "$(( DISK_512 - 16384 ))" ]; then
  log "根分区已在盘尾（part_last=${PART_LAST_512} disk=${DISK_512} [512B扇区]），跳过"
  exit 0
fi

log "扩容 $ROOT_SRC：disk=$DISK part=$PARTNUM start=$START last=${PART_LAST_512} disk=${DISK_512} [512B扇区]"

ARGS=(-d "$PARTNUM" -n "$PARTNUM:$START:0" -t "$PARTNUM:$TYPECODE" -u "$PARTNUM:$GUID")
[[ -n "$NAME" ]] && ARGS+=(-c "$PARTNUM:$NAME")

sgdisk -e "$DISK" >/dev/null 2>&1 || true            # 备份 GPT 移到盘尾
if ! sgdisk "${ARGS[@]}" "$DISK" >/dev/null 2>&1; then
  log "sgdisk 重建分区失败，放弃（未做任何破坏性改动）"
  exit 0
fi
partx -u "$DISK" >/dev/null 2>&1 || true
sleep 1
resize2fs "$ROOT_SRC" 2>&1 | sed 's/^/steamos-growroot: /' || true
log "完成：$(df -h / | tail -1)"
exit 0
