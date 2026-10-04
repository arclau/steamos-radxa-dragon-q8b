#!/usr/bin/env bash
#
# verify.sh — 构建与集成验证（BVT harness）
#
# 人设与职责：构建与集成验证工程师。本脚本是它的**第一交付物**：
# 把「布局契约 / 构建接线 / 产物自省 / 阶段间契约」固化成一条命令，失败即 fail-loud。
#
# 用法（建议走 `make verify`，它先跑 `make check`）：
#   ./scripts/verify.sh
# 环境变量（与 Makefile 同名，可覆盖）：
#   O / MODULES / KREL / FIRMWARE / DTS / IMAGE / DTB
#
# 检查项：
#   1. 布局契约       必需源码目录/文件在位
#   2. 构建接线       build/kernel/Makefile 指向当前 kernel 源树；source 软链可解析
#   3. 内核产物       Image 存在且是 EFI zboot（MZ 头）；DTB 存在
#   4. DTB 契约       根 compatible 含 radxa,dragon-q8b
#   5. 模块           build/modules/.../<KREL> 存在、.ko* 计数 > 0、无悬空 build/source 软链
#   6. SteamOS 胶水   去 Frame / rootfs 准备 / initramfs 脚本在位
#   6b. 内核补丁机制   config/patches/*.patch 存在且可应用
#   7. 路径契约       自有"活文件"里无残留旧路径（build-q8b / kernel-out / 旧脚本路径…）
#
# 退出码：全部通过 0；任一失败 1（累积报告，不 fail-fast）。
#
set -uo pipefail   # 注意：不用 -e，改为累积失败后统一退出

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/.." && pwd)"
cd "$PROJ"

O="${O:-build/kernel}"
MODULES="${MODULES:-build/modules/lib/modules}"
KREL="${KREL:-7.0.11+}"
FIRMWARE="${FIRMWARE:-firmware/lib/firmware}"
DTS="${DTS:-upstream/radxa-kernel/arch/arm64/boot/dts/qcom/sc8280xp-radxa-dragon-q8b.dts}"
IMAGE="${IMAGE:-$O/arch/arm64/boot/Image}"
DTB="${DTB:-$O/arch/arm64/boot/dts/qcom/sc8280xp-radxa-dragon-q8b.dtb}"

fail=0
ok()   { printf '  \033[1;32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[1;31mBAD\033[0m  %s\n' "$*"; fail=$((fail+1)); }
hdr()  { printf '\033[1;34m== %s ==\033[0m\n' "$*"; }

# ── 1. 布局契约 ───────────────────────────────────────────────────────────
hdr "布局契约"
for p in \
  "$DTS" \
  "steamos/apply-sc8280xp-overlay.sh" \
  "steamos/prepare-steamos-rootfs.sh" \
  "steamos/initramfs/init" \
  "steamos/initramfs/build-initramfs.sh" \
  "scripts/make-q8b-image.sh" \
  "config/steamos-sc8280xp.config" \
  "Makefile" \
  ; do
  if [ -e "$p" ]; then ok "$p"; else bad "缺 $p"; fi
done
if [ -d build ]; then ok "build/（产物根）"; else bad "缺 build/（先跑 make kernel）"; fi
# 3 个 firmware 上游仅 provenance（构建实际吃仓库内 firmware/），fork 里没有不算失败。
for p in upstream/radxa-firmware upstream/radxa-linux-firmware upstream/linux-firmware; do
  if [ -e "$p" ]; then ok "$p（provenance）"
  else printf '  \033[1;33mWARN\033[0m %s（provenance，未克隆；不影响构建）\n' "$p"; fi
done

# ── 2. 构建接线 ───────────────────────────────────────────────────────────
hdr "构建接线"
if [ -f "$O/Makefile" ]; then
  inc="$(grep -m1 '^include ' "$O/Makefile" | awk '{print $2}')"
  case "$inc" in
    */upstream/radxa-kernel/Makefile) ok "$O/Makefile → $inc" ;;
    *) bad "$O/Makefile 指向旧源树：$inc" ;;
  esac
else
  bad "缺 $O/Makefile（out-of-tree 接线）"
fi
if [ -L "$O/source" ] && [ -e "$O/source" ]; then
  ok "$O/source → $(readlink "$O/source")"
else
  bad "$O/source 软链缺失或悬空"
fi

# ── 3. 内核产物 ───────────────────────────────────────────────────────────
hdr "内核产物"
if [ -f "$IMAGE" ]; then
  magic="$(head -c2 "$IMAGE" | od -An -tx1 | tr -d ' \n')"
  if [ "$magic" = "4d5a" ]; then ok "$IMAGE（EFI zboot，MZ 头，$(stat -c%s "$IMAGE") B）"
  else bad "$IMAGE 不是 EFI zboot（头=$magic，期望 4d5a）"; fi
else bad "缺 $IMAGE（先跑 make kernel）"; fi
[ -f "$DTB" ] && ok "$DTB（$(stat -c%s "$DTB") B）" || bad "缺 $DTB"

# ── 4. DTB 契约 ───────────────────────────────────────────────────────────
hdr "DTB 契约"
if [ -f "$DTB" ]; then
  if command -v dtc >/dev/null 2>&1; then
    rootc="$(dtc -I dtb -O dts "$DTB" 2>/dev/null | grep -m1 'compatible' | head -1)"
  else
    rootc="$(strings "$DTB" | grep -m1 'radxa,dragon-q8b')"
  fi
  case "$rootc" in
    *radxa,dragon-q8b*) ok "根 compatible 含 radxa,dragon-q8b" ;;
    *) bad "根 compatible 不含 radxa,dragon-q8b：$rootc" ;;
  esac
fi

# ── 5. 模块 ───────────────────────────────────────────────────────────────
hdr "模块"
if [ -d "$MODULES/$KREL" ]; then
  n="$(find "$MODULES/$KREL" -name '*.ko*' | wc -l)"
  [ "$n" -gt 0 ] && ok "$MODULES/$KREL（$n 个 .ko*）" || bad "$MODULES/$KREL 下无 .ko*"
  dangling=0
  for s in build source; do
    if [ -L "$MODULES/$KREL/$s" ]; then
      if [ -e "$MODULES/$KREL/$s" ]; then dangling=$((dangling+1)); else ok "已移除悬空 $s 软链"; fi
    fi
  done
  [ "$dangling" -eq 0 ] || bad "存在悬空 build/source 软链（应被 Makefile 移除）"
else
  bad "缺 $MODULES/$KREL（先跑 make modules）"
fi

# ── 6. SteamOS 胶水 ───────────────────────────────────────────────────────
hdr "SteamOS 胶水"
for f in steamos/apply-sc8280xp-overlay.sh steamos/prepare-steamos-rootfs.sh \
         steamos/initramfs/init steamos/initramfs/build-initramfs.sh; do
  [ -f "$f" ] && ok "$f" || bad "缺 $f"
done

# ── 6b. 内核补丁机制（改动以补丁入库，构建前幂等应用）──────────────
hdr "内核补丁机制"
if [ -x config/apply-kernel-patches.sh ]; then
  ok "config/apply-kernel-patches.sh（可执行）"
else
  bad "缺 config/apply-kernel-patches.sh（或不可执行）"
fi
if [ -d config/patches ]; then
  shopt -s nullglob
  kpatches=("$PROJ"/config/patches/*.patch)   # 绝对路径：git -C 会按内核目录解析相对路径
  if [ "${#kpatches[@]}" -eq 0 ]; then
    ok "config/patches/（暂无补丁）"
  else
    for p in "${kpatches[@]}"; do
      if git -C upstream/radxa-kernel apply --reverse --check "$p" >/dev/null 2>&1; then
        ok "$p（已应用）"
      elif git -C upstream/radxa-kernel apply --check "$p" >/dev/null 2>&1; then
        ok "$p（可干净应用，当前未打——make kernel/modules 会打上）"
      else
        bad "$p 无法应用（upstream 变了？）"
      fi
    done
  fi
else
  bad "缺 config/patches/"
fi

# ── 7. 路径契约：自有"活文件"无残留旧路径 ──────────────────────────────────
hdr "路径契约（无残留旧路径）"
# 只扫"活文件"：Makefile 与 scripts/config/steamos 下的 *.sh。
# 跳过：本脚本自身（含模式定义）。
stale_pat='build-q8b|kernel-out|build-steamos-rootfs|build-steamos-bootloader|build-image-work'
live_files=(Makefile)
while IFS= read -r f; do
  [ "$f" = "scripts/verify.sh" ] && continue
  live_files+=("$f")
done < <(find scripts config steamos -type f -name '*.sh' 2>/dev/null)
hits="$(grep -nE "$stale_pat" "${live_files[@]}" 2>/dev/null)"
if [ -z "$hits" ]; then
  ok "活文件无旧产物路径（${#live_files[@]} 个文件）"
else
  bad "活文件残留旧路径："; printf '%s\n' "$hits" | sed 's/^/       /'
fi

# ── 汇总 ──────────────────────────────────────────────────────────────────
echo
if [ "$fail" -eq 0 ]; then
  printf '\033[1;32mBVT PASS\033[0m — 全部检查通过\n'
  exit 0
else
  printf '\033[1;31mBVT FAIL\033[0m — %d 项失败\n' "$fail"
  exit 1
fi
