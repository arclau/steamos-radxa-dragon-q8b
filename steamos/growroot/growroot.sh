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

# 盘尾还有空闲扇区？（sgdisk -F 打印第一个空闲扇区；无则空）
FREE="$(sgdisk -F "$DISK" 2>/dev/null || true)"
[[ -n "$FREE" ]] || { log "$DISK 无空闲空间，跳过"; exit 0; }

# 采集原分区属性
INFO="$(sgdisk -i "$PARTNUM" "$DISK" 2>/dev/null || true)"
START="$(printf '%s\n' "$INFO" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')"
TYPECODE="$(printf '%s\n' "$INFO" | sed -n 's/^Partition GUID code: \([0-9A-Fa-f-]*\).*/\1/p')"
GUID="$(printf '%s\n' "$INFO" | sed -n 's/^Partition unique GUID: \([0-9A-Fa-f-]*\).*/\1/p')"
NAME="$(printf '%s\n' "$INFO" | sed -n "s/^Partition name: '\(.*\)'.*/\1/p")"
[[ -n "$START" && -n "$TYPECODE" && -n "$GUID" ]] || { log "解析分区属性失败，跳过"; exit 0; }

log "扩容 $ROOT_SRC：disk=$DISK part=$PARTNUM start=$START 空闲起=$FREE"

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
