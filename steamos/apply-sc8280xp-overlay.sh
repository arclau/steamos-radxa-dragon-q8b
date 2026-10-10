#!/usr/bin/env bash
#
# apply-sc8280xp-overlay.sh — 把 Valve SteamOS ARM(Deckard/Frame) rootfs "去 Frame 化"
#                             并压平成本板（Radxa Dragon Q8B / SC8280XP）可启动的形态。
#
# 这是 P5 overlay 的**最小可启动集**。它不安装任何板级驱动/UCM/输入规则（那是后续 P5
# 增量），只做「让 SteamOS 用户态在我们这台 SBC 上能起来」的必需改动。
#
# 背景（全部对着真实 rootfs 验证过）：
#   SteamOS 的 /etc/fstab 用的是 Deck/Frame 的 **A/B partsets** 模型：
#     PARTLABEL=syspersist / /dev/disk/by-partsets/self/efi / .../shared/esp / .../shared/home
#   这些分区在我们的 GPT 布局（p1 config / p2 efi(ESP) / p3 rootfs）里都不存在，
#   不重写 fstab 会导致一堆 90s 设备超时 + 服务崩。
#   SteamOS 的 /etc 是 overlayfs（lower=/etc, upper=/var/lib/overlays/etc/upper），
#   由 initramfs 在 switch_root 前挂好；原始 rootfs 里 **没有** /var/lib/overlays/ 目录，
#   必须在这里建出来（否则 overlay 挂不上）。
#   VARIANT_ID="vr" 会让 Frame 版 steamclient 进 Gamepad UI 后抛异常，改成 "steamdeck"。
#   一批 Frame 专有 unit（FPGA/风扇/LED/typec/ADB/USB gadget/A/B 槽位 bookkeeping）
#   在 SBC 上无对应硬件，会崩循环并拖住启动，全部 mask 掉。
#   此外还固化真机必需修复：
#     §4b NM Wi-Fi 后端固化为 iwd（Valve 未随镜像下发该 conf，运行时才生成）。
#     §9  SSH：启用 sshd + 预设 steamos 密码（公开镜像默认，默认 1234）。
#     §10 根分区自扩（growroot）：首启把根扩到整盘，避免根写满导致 Steam 崩、HDMI 无画。
#     §11 音频 UCM：Radxa 的 Q8B UCM 树（stock 只认 X13s，否则 PipeWire 只有 auto_null；
#            并补齐 3.5mm 的 WCD938x 耳机 codec 序列）。
#     §12 去 VR/麦克风 WirePlumber 组件（有声卡节点时会 SEGV）。
#     §13 默认 sink 音量 0.7。
#     §14 蓝牙 bring-up（冷启动重试直到 SYN43756 控制器就绪）。
#   （历史：曾有 §15「禁止系统休眠」（mask 睡眠单元）——2026-10-04 已移除，
#     恢复系统原生睡眠行为。理由见 §15 处注释。）
#     §16 DRM 热插拔看门狗（无显示器启动 → 后插屏 → 重启 steam.service 一次）。
#     §17 强制默认登录模式 = Game Mode（Desktop Mode 在本板必黑屏，防止误切砖）。
#
# 用法：
#   sudo steamos/apply-sc8280xp-overlay.sh <rootfs-dir>
#
#   <rootfs-dir>  已解开的 SteamOS rootfs 目录（rsync 自 rootfs.img）。
#                 脚本**就地**修改它；幂等，可重复运行。
#
# 环境变量：
#   ROOT_PARTLABEL  fstab 里根分区的标识，默认 rootfs（对应 make-q8b-image.sh 的 mkfs label:rootfs）。
#                   steamos/initramfs/init 与 BLS 的 root= 均支持 PARTLABEL=。
#
set -euo pipefail

# 本脚本所在目录：用于取同仓素材（growroot/ 等），不依赖调用者的 cwd。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

R="${1:-}"
[[ -n "$R" ]] || { echo "用法: sudo $0 <rootfs-dir>" >&2; exit 1; }
[[ -d "$R" ]] || { echo "ERROR: rootfs 目录不存在: $R" >&2; exit 1; }
[[ -d "$R/etc" && -d "$R/usr/lib/systemd" ]] || {
  echo "ERROR: $R 看起来不是 SteamOS rootfs（缺 /etc 或 /usr/lib/systemd）" >&2; exit 1; }

ROOT_PARTLABEL="${ROOT_PARTLABEL:-rootfs}"

log() { printf '\033[1;34m[overlay]\033[0m %s\n' "$*" >&2; }

# ── 1) /etc overlay 的 upper/work 目录（必须存在，initramfs 才能挂 /etc overlay）──
log "创建 /var/lib/overlays/etc/{upper,work}"
mkdir -p "$R/var/lib/overlays/etc/upper" "$R/var/lib/overlays/etc/work"

# ── 2) 重写 fstab：Deck/Frame A/B partsets → 我们的扁平单槽布局 ──────────────
# 说明：
#   - 根分区用 PARTLABEL 而非 UUID：打包时 UUID 才知道，PARTLABEL 在 mkfs 时就定死了，
#     免去镜像里回填 UUID 的步骤（steamos/initramfs/init 与 BLS 都认 PARTLABEL=）。
#   - 不写 /efi、/esp、/home、/persist：本布局没有这些分区；/efi、/esp 是空目录且我们
#     mask 了 efi.mount/esp.mount（见下），/home 直接落在根分区上。
#   - 不写 /boot：内核/DTB/BLS 在 ESP（p2）上，由 UEFI/systemd-boot 读，Linux 侧不需要。
log "重写 /etc/fstab（根 = PARTLABEL=${ROOT_PARTLABEL}）"
FSTAB_TMP="$(mktemp)"
cat > "$FSTAB_TMP" <<EOF
# SteamOS ARM on Radxa Dragon Q8B (SC8280XP) — flat single-slot layout
# 由 steamos/apply-sc8280xp-overlay.sh 生成；不要手改，改脚本。
# 原生 SteamOS 的 A/B partsets(syspersist / by-partsets/*) 在本板 GPT 布局下不存在。
PARTLABEL=${ROOT_PARTLABEL}  /  ext4  defaults,noatime  0 1
EOF
install -m0644 "$FSTAB_TMP" "$R/etc/fstab"
# 也写一份到 overlay upper：SteamOS 认为 /etc 由 initrd 挂 overlay，两处都放最稳。
install -m0644 "$FSTAB_TMP" "$R/var/lib/overlays/etc/upper/fstab"
rm -f "$FSTAB_TMP"

# ── 3) VARIANT_ID="vr" → "steamdeck"（Frame 版 steamclient 否则 Gamepad UI 抛异常）──
log "修正 VARIANT_ID=steamdeck"
for _osr in "$R/etc/os-release" "$R/usr/lib/os-release" \
            "$R/var/lib/overlays/etc/upper/os-release"; do
  [[ -f "$_osr" ]] || continue
  # /etc/os-release 常是指向 /usr/lib/os-release 的软链，sed -i 会打断软链 → 只在真实文件上改。
  if [[ -L "$_osr" ]]; then
    _real="$(readlink -f "$_osr")"
    [[ -f "$_real" ]] || continue
    _osr="$_real"
  fi
  sed -i 's/^VARIANT_ID=.*/VARIANT_ID="steamdeck"/' "$_osr"
  grep -q '^VARIANT_ID=' "$_osr" || echo 'VARIANT_ID="steamdeck"' >> "$_osr"
done
unset _osr

# ── 4) mask 掉 Frame 专有 unit（SBC 上无对应硬件）────────────────────────────
# 证据与理由（逐条）见文件头注释 + SteamOS-ARM-Handhelds 的 apply-overlays.sh。
# 系统级：
SYS_UNITS="
steamvr-program-ble.service steamvr-v4l2loopback.service
steamvr-set-kernel-thread-priorities.service
deckard-audio-setup.service deckard-fan-control.service deckard-fpga.service
deckard-led-control.service deckard-typec-logger.service
deckard-charger.service deckard-power-monitor.service
deckard-fpga-resume.service deckard-boot-images.service
set-wifi-mac-address.service
adbd.service adbd-post.service usb-gadget.service usb-gadget.target
usb-ncm-gadget@.service usb-ncm-dnsmasq@.service
steamos-boot.service efi.mount efi.automount esp.mount esp.automount systemd-repart.service
home.mount rauc.service
"
# 注（2026-10-03）：rauc 是 Frame A/B partsets 升级服务，启动即查
#   /dev/disk/by-partsets/{A,B}/rootfs；本板压平 PARTLABEL 后必然 exit 1。
#   与其它 Frame unit 同类，mask 掉（静态 unit，无 [Install]，mask 防拉起）。
# 注（2026-10-04）：**不要 mask `iwd.service`**。SteamOS 的 NM 用
#   `wifi.backend=iwd`（/etc/NetworkManager/conf.d/99-valve-wifi-backend.conf），
#   且 iwd 由 D-Bus 激活（/usr/share/dbus-1/system-services/net.connman.iwd.service
#   `SystemdService=iwd.service`）。mask 掉 iwd 后 wlan0 永远 `unavailable`，
#   Steam 网络 UI 里看不到任何 Wi-Fi（曾误把 iwd 和 set-wifi-mac-address 一起 mask）。
# 用户级（Frame SteamVR 残留；Wants= 是叠加的，必须 mask 才不启动）：
USR_UNITS="
steamvr.service steamvr-logs.service steamvr-proxmicmute.service
steamvr-v4l2cam.service steamvr-nested-desktop.service
"
log "mask Frame 专有 unit（系统级 + 用户级）"
mkdir -p "$R/etc/systemd/system" "$R/etc/systemd/user"
n_sys=0; for u in $SYS_UNITS; do ln -sfn /dev/null "$R/etc/systemd/system/$u"; n_sys=$((n_sys+1)); done
n_usr=0; for u in $USR_UNITS; do ln -sfn /dev/null "$R/etc/systemd/user/$u";   n_usr=$((n_usr+1)); done
log "  系统级 $n_sys 个，用户级 $n_usr 个"

# ── 4b) 固化 NetworkManager Wi-Fi 后端 = iwd（本板已验证路径）─────────────────
# 为什么（真机 2026-10-04）：
#   Valve rootfs **不随镜像下发** /etc/NetworkManager/conf.d/99-valve-wifi-backend.conf
#   —— 它在 /usr/lib/NetworkManager/conf.d/10-steamos-defaults.conf 里是**注释掉**的
#   （`#wifi.backend=iwd`，注：deckard 切 iwd 前不启用）；运行时才由 steamos-manager
#   （SetWifiBackend，见其二进制串）生成，且**无持久化配置**（/etc/steamos-manager/ 只有
#   remotes.d/），触发者不明（多半是 Steam 客户端的 Wi-Fi 设置）。
#   但本板 Wi-Fi 验证是在 **iwd 后端**下完成的（板上 iwd=active、
#   wpa_supplicant=inactive）。若不落盘，fresh 板在 Steam 设置 Wi-Fi 前会退回 NM 默认
#   （wpa_supplicant，未随本板的 SYN43756 验证）→ 故在 overlay 里**确定性地**写入，
#   保证首启即走 iwd。
# 内容与板上实测一致（steamos-manager 的生成值）：
#   [connection] wifi.powersave=2 ; [device] wifi.backend=iwd
# 幂等；若用户日后在 Steam 里切换后端，steamos-manager 会覆写此文件（同路径，无冲突）。
log "固化 NM Wi-Fi 后端 = iwd（99-valve-wifi-backend.conf）"
mkdir -p "$R/etc/NetworkManager/conf.d"
cat > "$R/etc/NetworkManager/conf.d/99-valve-wifi-backend.conf" <<'EOF'
[connection]
wifi.powersave=2
[device]
wifi.backend=iwd
EOF

# ── 5b) 默认时区 Asia/Shanghai（用户在中国；timedatectl 需运行中 systemd，
# 构建期直接落 localtime 软链；用户可在系统设置里再改）─────────────────────────
log "默认时区 → Asia/Shanghai"
ln -sfn ../usr/share/zoneinfo/Asia/Shanghai "$R/etc/localtime"

# ── 5) machine-id 清空（每台设备首次启动重新生成 D-Bus/网络身份）─────────────
log "清空 machine-id"
: > "$R/etc/machine-id"
[[ -f "$R/var/lib/overlays/etc/upper/machine-id" ]] && : > "$R/var/lib/overlays/etc/upper/machine-id"

# ── 6) 清掉悬空的 Frame VR 音频插件软链（会让 Chromium/Steam 串流报错）─────────
for _so in "$R/usr/lib/ladspa/vraudiocompositor.so" \
           "$R/usr/lib/ladspa/audiofilter.so" \
           "$R/usr/lib/ladspa/libphonon.so"; do
  if [[ -L "$_so" && ! -e "$_so" ]]; then rm -f "$_so"; log "  删悬空软链 ${_so#$R}"; fi
done
unset _so

# ── 7) 板载 TC956x 2.5GbE：驱动已修，撤销历史 blacklist ─────────────────────
# 背景（真机首启串口 oops）：
#   irq: Invalid fwnode type for irqdomain
#   Internal error: SP/PC alignment exception  [#1] SMP
#   Call trace: tc956x_msigen_irq_domain_instantiate → __irq_domain_instantiate
#               tc956x_dwmac_probe [dwmac_tc956x]
# 根因 = drivers/net/ethernet/stmicro/stmmac/dwmac-tc956x.c 里两个 irq_domain
# 结构体（dgc_info / info）声明后**未初始化**，垃圾 fwnode/dev/direct_max/virq_base
# 送进 irqdomain 核心。修复补丁：config/patches/0001-*，由
# config/apply-kernel-patches.sh 在构建前打入内核（不自带改 upstream）。
# 故此处**移除**历史 blacklist，让 tc956x_pci + dwmac_tc956x + gpio_tc956x 正常加载，
# 启用板载双 2.5GbE（QCA8081 PHY，NetworkManager 会自动 DHCP）。
log "撤销历史 TC956x blacklist（驱动已修，启用板载 2.5GbE）"
rm -f "$R/etc/modprobe.d/q8b-blacklist.conf"

# ── 8) 去 Frame：gamescope 会话从 VR(openvr) 改为 DRM（HDMI SBC）────────────
# 证据（真机 2026-10-03）：Frame 的 /usr/lib/steamos/gamescope-session 里
#   硬编码 `--backend openvr` + `--vr-*`；本板无 VR 运行时，gamescope 的
#   `--allow-deferred-backend` 会退回 headless 后端（离屏）→ HDMI 无画面。
#   日志：`openvr: Unable to init VR runtime` → `Creating headless backend`。
#   改 `--backend drm` 后仍残留 `--vr-session-manager` / `--virtual-connector-strategy`
#   等 Frame flag，实测需一并去掉（否则 gamescope 走 VR overlay 语义，不向 HDMI 提交）。
#   最终生效组合：`--backend drm` + 无 VR flag → 真机 `DRM_IOCTL_MODE_ATOMIC` ~60Hz
#   持续提交，Steam Big Picture Mode 扫到 HDMI。
_gsc="$R/usr/lib/steamos/gamescope-session"
if [[ -f "$_gsc" ]]; then
  if grep -q -- '--backend openvr' "$_gsc"; then
    sed -i 's/--backend openvr/--backend drm/' "$_gsc"
    log "gamescope-session: --backend openvr → drm（去 VR，走 HDMI DRM）"
  else
    log "gamescope-session: 已非 openvr 后端，跳过"
  fi
  # 去掉 Frame 专有 VR flag（--vr-* / --virtual-connector-strategy）。幂等：已去则无匹配。
  if grep -qE -- '--vr-|--virtual-connector-strategy' "$_gsc"; then
    sed -i -E '/--vr-|--virtual-connector-strategy/d' "$_gsc"
    log "gamescope-session: 去掉 Frame VR flag（--vr-* / --virtual-connector-strategy）"
  fi
else
  log "警告：找不到 $_gsc（跳过 gamescope 去 VR）"
fi
unset _gsc

# ── 9) SSH：启用 sshd + 预设 steamos 密码（公开镜像默认，便于首启登录）─────────
# 为什么不用公钥：本镜像要 push 到 GitHub 给公众使用，塞个人公钥不合适。
# 改为**预设密码**（默认 1234，可用 SSH_PASSWORD 覆盖）；这是开发便利默认值，
# 用户首登后应自行 `passwd` 修改。
# 要点：
#   - rootfs 自带 /usr/lib/systemd/system/sshd.service（WantedBy=multi-user.target），
#     这里建 multi-user.target.wants 软链即启用（幂等）。
#   - sshd_config 默认 PasswordAuthentication yes、PermitEmptyPasswords no，
#     所以 shadow 里必须是**真实哈希**（空字段会被 sshd 拒绝）。
#   - login.defs 的 ENCRYPT_METHOD=YESCRYPT 只影响「本机生成」；校验认的是 shadow
#     里哈希自带的算法前缀。这里用 sha512crypt（$6$），板端 libcrypt/PAM 可校验
#     （真机实测 `sshpass -p 1234` 可登录）。
#   - 只改**已存在**的 shadow：绝不新建 upper/shadow（那会整体遮蔽 lower 的其余账号）。
SSH_PASSWORD="${SSH_PASSWORD:-1234}"
# 盐默认固定，保证**可复现构建**（同一输入的镜像逐字节一致）；可用 SSH_PASSWORD_SALT 覆盖。
# 密码是公开的开发默认值，固定盐不构成额外风险；用户首登后应自行 `passwd` 改。
SSH_PASSWORD_SALT="${SSH_PASSWORD_SALT:-q8bSteamOSsalt}"
log "启用 sshd.service 并预设 steamos 密码（默认 1234，SSH_PASSWORD 可覆盖）"
install -d -m0755 "$R/etc/systemd/system/multi-user.target.wants"
ln -sfn /usr/lib/systemd/system/sshd.service \
        "$R/etc/systemd/system/multi-user.target.wants/sshd.service"

# 生成 sha512crypt（$6$）哈希。盐固定 ⇒ 可复现；并立刻用 verify_hash 自校验，
# 因为「一个校验不过的哈希」正是曾锁死板上 sudo 的事故根因。
_ssh_hash=""
if command -v openssl >/dev/null 2>&1; then
  _ssh_hash="$(printf '%s' "$SSH_PASSWORD" | openssl passwd -6 -salt "$SSH_PASSWORD_SALT" -stdin 2>/dev/null || true)"
fi
if [[ -z "$_ssh_hash" ]] && command -v python3 >/dev/null 2>&1; then
  _ssh_hash="$(python3 - "$SSH_PASSWORD" "$SSH_PASSWORD_SALT" <<'PY' 2>/dev/null || true
import crypt, sys
print(crypt.crypt(sys.argv[1], "$6$" + sys.argv[2]))
PY
)"
fi

# verify_hash <password> <hash>：用哈希自带的盐重算，必须相等。
# 这是「shell 展开写坏 shadow → 锁死 sudo」事故的防线：
# 宁可构建 fail-loud，也绝不把「校验不过的哈希」写进镜像。
verify_hash() {
  local pw="$1" h="$2" salt re
  [[ "$h" == \$6\$*\$* ]] || return 1
  salt="${h#\$6\$}"; salt="${salt%%\$*}"
  if command -v openssl >/dev/null 2>&1; then
    re="$(printf '%s' "$pw" | openssl passwd -6 -salt "$salt" -stdin 2>/dev/null || true)"
    if [[ "$re" == "$h" ]]; then return 0; fi
  fi
  if command -v python3 >/dev/null 2>&1; then
    re="$(python3 - "$pw" "$h" <<'PY' 2>/dev/null || true
import crypt, sys
print(crypt.crypt(sys.argv[1], sys.argv[2]))
PY
)"
    if [[ "$re" == "$h" ]]; then return 0; fi
  fi
  return 1
}

if [[ -z "$_ssh_hash" ]]; then
  log "  警告：无法生成密码哈希（缺 openssl/python3），跳过设密码（SSH 仍启用）"
elif ! verify_hash "$SSH_PASSWORD" "$_ssh_hash"; then
  echo "ERROR: 生成的密码哈希自校验失败（拒绝写入 shadow，避免锁死账号）" >&2
  exit 1
else
  for _sf in "$R/etc/shadow" "$R/var/lib/overlays/etc/upper/shadow"; do
    [[ -f "$_sf" ]] || continue
    _tmp="$(mktemp)"
    awk -F: -v OFS=: -v h="$_ssh_hash" '$1=="steamos"{$2=h} {print}' "$_sf" > "$_tmp"
    chmod --reference="$_sf" "$_tmp" 2>/dev/null || chmod 0600 "$_tmp"
    chown --reference="$_sf" "$_tmp" 2>/dev/null || true
    mv -f "$_tmp" "$_sf"
    log "  已设 steamos 密码哈希：${_sf#$R}"
  done
fi
unset _sf _tmp _ssh_hash

# ── 10) 根分区自扩：首启把根扩到整盘（固化真机修复）────
# 脚本 best-effort、幂等；装到 /usr/libexec 并由 steamos-growroot.service 早期启用。
# 素材来自同仓 steamos/growroot/（改动入库，不进 upstream）。
log "安装根分区自扩（growroot）"
install -d -m0755 "$R/usr/libexec"
install -m0755 "$SCRIPT_DIR/growroot/growroot.sh" "$R/usr/libexec/steamos-growroot"
install -m0644 "$SCRIPT_DIR/growroot/steamos-growroot.service" \
               "$R/etc/systemd/system/steamos-growroot.service"
install -d -m0755 "$R/etc/systemd/system/sysinit.target.wants"
ln -sfn /etc/systemd/system/steamos-growroot.service \
        "$R/etc/systemd/system/sysinit.target.wants/steamos-growroot.service"

# ── 11) 音频：Q8B 的 ALSA UCM（否则 PipeWire 只有 auto_null，游戏有播无声）──────
# 根因（真机实测）：
#   stock /usr/share/alsa/ucm2/Qualcomm/sc8280xp/sc8280xp.conf 只认 X13s DMI，
#   其它机型走 `False.Error` → UCM import 直接 abort → WirePlumber 建不出 sink，
#   只剩 auto_null；游戏把流连到 null，有播无声（而 speaker-test 直捅硬件却有声音）。
#
# 素材（steamos/ucm/，镜像 ALSA ucm2 目录结构，改动入库）：
#   Qualcomm/sc8280xp/sc8280xp.conf         我们的 DMI 分发器（已验证；加 Q8B 分支，去 X13s 的 False.Error）
#   Qualcomm/sc8280xp/Radxa-Dragon-Q8B.conf Radxa 官方版（BootSequence + include wcd/rxm init）
#   Qualcomm/sc8280xp/Dragon-Q8B-HiFi.conf  Radxa 官方版 + 我们标注的 DSP 每流增益 delta
#   codecs/wcd938x/*                        WCD938x codec 序列（含 Radxa 新增 HeadphoneABEnableSeq，wcd9385 必需）
#   codecs/qcom-lpass/{rx,tx}-macro/*       LPASS macro 序列
# 来源：Radxa 的 alsa-ucm-conf fork（radxa-pkg/alsa-ucm-conf 1.2.16.1-radxa-1）。
#   **关键**：Radxa 的 Dragon-Q8B-HiFi.conf 里 Headphones 是**完整 WCD938x 通路**
#   （codec class CLS_AB_HIFI + rx-macro 序列），我们旧的手写 UCM 只是空壳
#   （没有 EnableSequence/codec）→ 裸 `aplay -D hw:0,0` 必然 EIO。见 devlog/2026-10-10-01。
log "安装 Q8B ALSA UCM（Radxa 的 Q8B UCM 树 + 我们的 DMI 分发器）"
UCM_DIR="$R/usr/share/alsa/ucm2"
UCM_SRC="$SCRIPT_DIR/ucm"
install -d -m0755 "$UCM_DIR/Qualcomm/sc8280xp" \
                 "$UCM_DIR/codecs/wcd938x" \
                 "$UCM_DIR/codecs/qcom-lpass/rx-macro" \
                 "$UCM_DIR/codecs/qcom-lpass/tx-macro"
# 显式清单（可审阅；install 保证 root:root 0644，不把构建机的属主/mtime 带进镜像）。
while read -r _rel; do
  [[ -n "$_rel" ]] || continue
  install -m0644 -o root -g root "$UCM_SRC/$_rel" "$UCM_DIR/$_rel"
done <<'UCM_FILES'
Qualcomm/sc8280xp/sc8280xp.conf
Qualcomm/sc8280xp/Radxa-Dragon-Q8B.conf
Qualcomm/sc8280xp/Dragon-Q8B-HiFi.conf
codecs/wcd938x/HeadphoneABEnableSeq.conf
codecs/wcd938x/HeadphoneDisableSeq.conf
codecs/wcd938x/HeadphoneMicEnableSeq.conf
codecs/wcd938x/HeadphoneMicDisableSeq.conf
codecs/qcom-lpass/rx-macro/HeadphoneEnableSeq.conf
codecs/qcom-lpass/rx-macro/HeadphoneDisableSeq.conf
codecs/qcom-lpass/rx-macro/init.conf
codecs/qcom-lpass/tx-macro/HeadphoneMicEnableSeq.conf
codecs/qcom-lpass/tx-macro/HeadphoneMicDisableSeq.conf
UCM_FILES
unset _rel
# 清掉历史文件名（旧版 overlay 落过 HiFi-Dragon-Q8B.conf），避免残留误导。
rm -f "$UCM_DIR/Qualcomm/sc8280xp/HiFi-Dragon-Q8B.conf"

# ── 12) 去 SteamOS 的 VR/麦克风 WirePlumber 组件（本板无 VR、无可用麦克风，且会 SEGV）──
# 真机 2026-10-03 实测：一旦 UCM 生效、声卡产生真实节点，WirePlumber 立刻 SEGV 重启循环：
#   microphone-tracker.lua:64  Json.Raw(defaults:find(0,"default.audio.source")):parse()
#   → 本板无采集源 → metadata 缺 default.audio.source → find 返回 nil → strlen(NULL) 崩。
#     （栈：wp_spa_json_new_from_string ← libwireplumber-module-lua-scripting）
#   spatial-node-config.lua 又引用已被 §6 删掉的 /usr/lib/ladspa/vraudiocompositor.so。
# 两者对本 SBC 都无意义（无 VR；WCD 麦克风 EIO 不可用），直接摘掉组件 conf。
log "禁用 SteamOS VR/麦克风 WirePlumber 组件（无 VR/无麦克风，且会导致 SEGV）"
WPCD="$R/etc/wireplumber/wireplumber.conf.d"
for _c in 40-mic-processing.conf 70-spatial-node-config.conf; do
  if [[ -f "$WPCD/$_c" ]]; then
    mv -f "$WPCD/$_c" "$R/etc/wireplumber/$_c.disabled"
    log "  disable $_c"
  fi
done
unset _c

# ── 13) 默认 sink 音量 0.6 → 0.7（用户真机实测 70% 合适；仅影响首次创建路由时的默认值）──
_sac="$R/etc/wireplumber/wireplumber.conf.d/50-alsa-config.conf"
if [[ -f "$_sac" ]] && grep -q 'device.routes.default-sink-volume = 0.6' "$_sac"; then
  sed -i 's/device\.routes\.default-sink-volume = 0\.6/device.routes.default-sink-volume = 0.7/' "$_sac"
  log "默认 sink 音量 → 0.7"
fi
unset _sac

# ── 14) 蓝牙 bring-up：冷启动重试直到 SYN43756 控制器就绪 ─────────────────────
# 根因（真机实测）：Wi-Fi 与 BT 在同一颗 M.2 E-key 模块（AP6276P /
#   SYN43756B0）上——Wi-Fi 走 PCIe，BT 走 UART（988000.serial）。冷启动时 BT 核
#   尚未就绪，bluetoothd 首次打开 hci0 即失败
#     "Bluetooth: hci0: command 0x0c03 tx timeout"
#     "Bluetooth: hci0: BCM: Reset failed (-110)"
#   且此后不再重试，控制器始终上不来（`bluetoothctl list` 为空）。稍后芯片就绪，
#   重载 hci_uart 让控制器重新注册到 MGMT、再显式 power on 即可稳定拉起（真机验证）。
# 脚本 best-effort、有界、幂等；装到 /usr/libexec，由 unit 在 bluetooth.service 后启用。
log "安装蓝牙 bring-up 重试（q8b-bt-bringup）"
install -d -m0755 "$R/usr/libexec"
install -m0755 "$SCRIPT_DIR/bt-bringup/q8b-bt-bringup.sh" "$R/usr/libexec/q8b-bt-bringup"
install -m0644 "$SCRIPT_DIR/bt-bringup/q8b-bt-bringup.service" \
               "$R/etc/systemd/system/q8b-bt-bringup.service"
install -d -m0755 "$R/etc/systemd/system/multi-user.target.wants"
ln -sfn /etc/systemd/system/q8b-bt-bringup.service \
        "$R/etc/systemd/system/multi-user.target.wants/q8b-bt-bringup.service"

# ── 15) 恢复系统原生睡眠（撤销旧版 §15 的睡眠 mask）──────────────────────────
# 2026-10-04 移除旧做法，恢复系统原生睡眠行为（用户决策 B）。
# 原做法：ln -sfn /dev/null 掉 sleep.target / suspend.target / hibernate.target /
#   hybrid-sleep.target / suspend-then-hibernate.target 及对应 systemd-*.service。
# 为何移除：
#   ① 该 mask 只阻断**系统 suspend**（s2idle），**挡不住 Steam 客户端自身的
#      空闲熄屏计时器**（system_idle_screensaver_ac_sec 等）——两者是不同层。
#      用户看到的「过一段时间黑屏」是后者，故 mask 被判为「无效」。
#   ② 用户要求**保持系统原生**：不 hack Steam 计时器，让系统按原生策略 idle→suspend。
# 代价/风险（用户已知并接受）：本板唯一可靠唤醒源是 PMIC 电源键（USB/RTC/WoWLAN/
#   CEC 均不可用）→ 睡下去后需按电源键唤醒。
# 迁移：在**已 overlaid** 的目录上重跑时，旧版遗留的 mask 需主动撤销（幂等：只删
#   指向 /dev/null 的软链；Valve rootfs 本身不 mask 这些单元，正常 `make steamos-rootfs`
#   会清空重建，本循环是给增量/重复运行兜底）。
for u in sleep.target suspend.target hibernate.target hybrid-sleep.target \
         suspend-then-hibernate.target systemd-suspend.service systemd-hibernate.service \
         systemd-hybrid-sleep.service systemd-suspend-then-hibernate.service; do
  if [[ "$(readlink "$R/etc/systemd/system/$u" 2>/dev/null)" == "/dev/null" ]]; then
    rm -f "$R/etc/systemd/system/$u"
    log "  撤销旧版睡眠 mask: $u（恢复原生睡眠）"
  fi
done

# ── 16) DRM 热插拔看门狗：恢复「无显示器启动 → 后插屏 → 黑屏」────────────────────
# 根因（真机定位）：会话**无显示器启动**时 gamescope 进 deferred 后端；
#   之后热插拔显示器，gamescope 自己恢复（DRM 原子提交、DPMS On），**但 Steam 客户端
#   不再提交帧**（日志停在热插拔那一刻）→ 屏上一直纯黑。`systemctl --user restart
#   steam.service` 是已验证的恢复手段。
# 方案 A：用户级看门狗，仅当**会话启动时无连接器**才武装，
#   之后一旦有显示器 connected 且稳定若干秒 → 重启 steam.service **一次**。
#   一次性、best-effort、绝不阻断启动。素材来自同仓 steamos/drm-hotplug-watch/。
log "安装 DRM 热插拔看门狗（q8b-drm-hotplug-watch）"
install -d -m0755 "$R/usr/libexec"
install -m0755 "$SCRIPT_DIR/drm-hotplug-watch/q8b-drm-hotplug-watch.sh" \
               "$R/usr/libexec/q8b-drm-hotplug-watch"
install -m0644 "$SCRIPT_DIR/drm-hotplug-watch/q8b-drm-hotplug-watch.service" \
               "$R/etc/systemd/user/q8b-drm-hotplug-watch.service"
install -d -m0755 "$R/etc/systemd/user/default.target.wants"
ln -sfn /etc/systemd/user/q8b-drm-hotplug-watch.service \
        "$R/etc/systemd/user/default.target.wants/q8b-drm-hotplug-watch.service"

# ── 17) 强制默认登录模式 = Game Mode（防止误切 Desktop Mode 黑屏）────────────
# 根因（真机，devlog/2026-10-09-01）：本板 mask 了 steamvr.service（Frame VR 无硬件），
#   而 Desktop Mode 会话链路 plasma.desktop → plasma-session.target →
#   steamvr-plasma.service → Requires=steamvr.service（mask）→ 内层立刻退出 →
#   gamescope 无客户端 → 黑屏。一旦默认登录模式被切成 desktop
#   （steamosctl switch-to-desktop-mode / Steam UI「切换到桌面模式」会写
#   /etc/sddm.conf.d/zz-steamos-autologin.conf），下次冷启动即黑屏。
# 处置：装一个 oneshot 单元，在 display-manager 之前把登录模式钉回 game（幂等）。
#   素材来自同仓 steamos/force-game-mode/。
log "安装强制 Game Mode 登录（q8b-force-game-mode）"
install -d -m0755 "$R/usr/libexec"
install -m0755 "$SCRIPT_DIR/force-game-mode/q8b-force-game-mode.sh" \
               "$R/usr/libexec/q8b-force-game-mode"
install -m0644 "$SCRIPT_DIR/force-game-mode/q8b-force-game-mode.service" \
               "$R/etc/systemd/system/q8b-force-game-mode.service"
install -d -m0755 "$R/etc/systemd/system/multi-user.target.wants"
ln -sfn /etc/systemd/system/q8b-force-game-mode.service \
        "$R/etc/systemd/system/multi-user.target.wants/q8b-force-game-mode.service"
# 同时把 zz 文件在镜像里预置为 Game Mode（首启即便单元因故未跑也正确）。
install -d -m0755 "$R/etc/sddm.conf.d"
printf '[Autologin]\nSession=gamescope-wayland.desktop\n' \
  > "$R/etc/sddm.conf.d/zz-steamos-autologin.conf"

# ── 18) 自检 ────────────────────────────────────────────────────────────────
log "自检："
ok=1
[[ -f "$R/etc/fstab" ]] && grep -q "PARTLABEL=${ROOT_PARTLABEL}.* / " "$R/etc/fstab" \
  && echo "  OK   /etc/fstab 根 = PARTLABEL=${ROOT_PARTLABEL}" || { echo "  BAD  fstab"; ok=0; }
[[ -d "$R/var/lib/overlays/etc/upper" ]] && echo "  OK   /var/lib/overlays/etc/upper" \
  || { echo "  BAD  缺 overlay upper"; ok=0; }
grep -q '^VARIANT_ID="steamdeck"' "$(readlink -f "$R/usr/lib/os-release")" \
  && echo '  OK   VARIANT_ID="steamdeck"' || { echo "  BAD  VARIANT_ID"; ok=0; }
for u in deckard-fan-control.service adbd.service efi.mount efi.automount systemd-repart.service home.mount rauc.service; do
  [[ "$(readlink "$R/etc/systemd/system/$u")" == "/dev/null" ]] \
    && echo "  OK   mask $u" || { echo "  BAD  $u 未 mask"; ok=0; }
done
# iwd 必须**不**被 mask（否则 NM 的 wifi.backend=iwd 拿不到设备，Steam UI 无 Wi-Fi）
[[ ! -e "$R/etc/systemd/system/iwd.service" ]] \
  && echo "  OK   iwd.service 未被 mask（Wi-Fi 可用）" \
  || { echo "  BAD  iwd.service 被 mask，Steam 网络 UI 会没有 Wi-Fi"; ok=0; }
grep -q 'wifi.backend=iwd' "$R/etc/NetworkManager/conf.d/99-valve-wifi-backend.conf" 2>/dev/null \
  && echo "  OK   NM wifi.backend=iwd（与 iwd 一致）" \
  || { echo "  BAD  NM 未用 iwd 后端或配置文件缺失"; ok=0; }
if grep -q -- '--backend drm' "$R/usr/lib/steamos/gamescope-session" 2>/dev/null \
   && ! grep -qE -- '--vr-|--virtual-connector-strategy' "$R/usr/lib/steamos/gamescope-session" 2>/dev/null; then
  echo "  OK   gamescope 后端 = drm 且无 VR flag"
else
  echo "  BAD  gamescope 仍是 openvr 或残留 VR flag（HDMI 会退回 headless）"; ok=0
fi
[[ "$(readlink "$R/etc/systemd/user/steamvr.service")" == "/dev/null" ]] \
  && echo "  OK   mask steamvr.service(user)" || { echo "  BAD  user steamvr 未 mask"; ok=0; }
[[ ! -e "$R/etc/modprobe.d/q8b-blacklist.conf" ]] \
  && echo "  OK   无 TC956x blacklist（板载 2.5GbE 启用）" \
  || { echo "  BAD  仍有 q8b-blacklist.conf，板载网卡会被禁用"; ok=0; }
[[ "$(readlink "$R/etc/systemd/system/multi-user.target.wants/sshd.service")" == "/usr/lib/systemd/system/sshd.service" ]] \
  && echo "  OK   sshd.service 已启用" || { echo "  BAD  sshd 未启用"; ok=0; }
_sh="$(sed -n 's/^steamos:\([^:]*\):.*/\1/p' "$R/etc/shadow" 2>/dev/null)"
if [[ -n "$_sh" ]] && verify_hash "$SSH_PASSWORD" "$_sh"; then
  echo "  OK   steamos 密码哈希匹配预设密码（可用它 SSH/sudo）"
else
  echo "  BAD  steamos 密码哈希缺失或不匹配预设密码"; ok=0
fi
unset _sh
[[ -x "$R/usr/libexec/steamos-growroot" ]] \
  && echo "  OK   growroot 脚本已安装" || { echo "  BAD  缺 /usr/libexec/steamos-growroot"; ok=0; }
[[ "$(readlink "$R/etc/systemd/system/sysinit.target.wants/steamos-growroot.service")" == "/etc/systemd/system/steamos-growroot.service" ]] \
  && echo "  OK   steamos-growroot.service 已启用" \
  || { echo "  BAD  growroot 服务未启用（首启不会扩根）"; ok=0; }
# 音频 UCM：Radxa 的 Q8B UCM 树落齐（Qualcomm/sc8280xp + codecs）
for _f in Qualcomm/sc8280xp/sc8280xp.conf \
          Qualcomm/sc8280xp/Radxa-Dragon-Q8B.conf \
          Qualcomm/sc8280xp/Dragon-Q8B-HiFi.conf \
          codecs/wcd938x/HeadphoneABEnableSeq.conf \
          codecs/qcom-lpass/rx-macro/HeadphoneEnableSeq.conf \
          codecs/qcom-lpass/tx-macro/HeadphoneMicEnableSeq.conf; do
  [[ -f "$UCM_DIR/$_f" ]] && echo "  OK   UCM $_f" || { echo "  BAD  缺 UCM $_f"; ok=0; }
done
unset _f
if grep -q 'If.RadxaQ8B' "$UCM_DIR/Qualcomm/sc8280xp/sc8280xp.conf" \
   && ! grep -qE '^[[:space:]]*False\.Error' "$UCM_DIR/Qualcomm/sc8280xp/sc8280xp.conf"; then
  echo "  OK   UCM sc8280xp.conf 有 RadxaQ8B 分支且无 False.Error"
else
  echo "  BAD  UCM sc8280xp.conf 分支/False.Error 不对（未知机型会 abort）"; ok=0
fi
# 3.5mm：WCD938x 耳机通路必须完整（codec class + 被 HiFi 引用），否则耳机 EIO
grep -q 'CLS_AB_HIFI' "$UCM_DIR/codecs/wcd938x/HeadphoneABEnableSeq.conf" \
  && echo "  OK   WCD938x HeadphoneABEnableSeq 用 CLS_AB_HIFI（wcd9385 必需）" \
  || { echo "  BAD  HeadphoneABEnableSeq 缺 CLS_AB_HIFI（耳机不响/失真）"; ok=0; }
if grep -q 'SectionDevice."Headphones"' "$UCM_DIR/Qualcomm/sc8280xp/Dragon-Q8B-HiFi.conf" \
   && grep -q 'HeadphoneABEnableSeq.conf' "$UCM_DIR/Qualcomm/sc8280xp/Dragon-Q8B-HiFi.conf" \
   && grep -q 'rx-macro/HeadphoneEnableSeq.conf' "$UCM_DIR/Qualcomm/sc8280xp/Dragon-Q8B-HiFi.conf"; then
  echo "  OK   Headphones 设备接 WCD938x codec + rx-macro 序列"
else
  echo "  BAD  Headphones 设备缺 codec/macro 序列（3.5mm 不会响）"; ok=0
fi
# 本地 delta：DSP 每流增益（Radxa 原文件没有，devlog/2026-10-03-27）
grep -q 'stream2.vol_ctrl2 MultiMedia3 Playback Volu' "$UCM_DIR/Qualcomm/sc8280xp/Dragon-Q8B-HiFi.conf" \
  && echo "  OK   UCM 含 DSP 每流增益 cset（否则游戏音量很小）" \
  || { echo "  BAD  UCM 缺 streamN.vol_ctrlN cset"; ok=0; }
# 每个 DP 设备都要有 JackControl，否则端口 availability=unknown，
# 默认 sink 被钉在 PlaybackPriority 最高那口 —— 显示器插在别的口就没声。
for _j in DP0 DP1 DP2; do
  grep -q "JackControl \"${_j} Jack\"" "$UCM_DIR/Qualcomm/sc8280xp/Dragon-Q8B-HiFi.conf" \
    && echo "  OK   UCM ${_j} 已接 JackControl（端口随插拔自动切换）" \
    || { echo "  BAD  UCM ${_j} 缺 JackControl（换口后无声）"; ok=0; }
done
unset _j
# WirePlumber：VR/麦克风组件已摘（否则有声卡节点时 SEGV）
for _c in 40-mic-processing.conf 70-spatial-node-config.conf; do
  if [[ ! -f "$R/etc/wireplumber/wireplumber.conf.d/$_c" && -f "$R/etc/wireplumber/$_c.disabled" ]]; then
    echo "  OK   WirePlumber $_c 已禁用"
  else
    echo "  BAD  WirePlumber $_c 未禁用（会 SEGV）"; ok=0
  fi
done
unset _c
grep -q 'device.routes.default-sink-volume = 0.7' "$R/etc/wireplumber/wireplumber.conf.d/50-alsa-config.conf" \
  && echo "  OK   默认 sink 音量 0.7" || { echo "  BAD  默认 sink 音量未改"; ok=0; }
[[ -x "$R/usr/libexec/q8b-bt-bringup" ]] \
  && echo "  OK   BT bring-up 脚本已安装" \
  || { echo "  BAD  缺 /usr/libexec/q8b-bt-bringup"; ok=0; }
[[ "$(readlink "$R/etc/systemd/system/multi-user.target.wants/q8b-bt-bringup.service")" == "/etc/systemd/system/q8b-bt-bringup.service" ]] \
  && echo "  OK   q8b-bt-bringup.service 已启用" \
  || { echo "  BAD   BT bring-up 服务未启用（冷启动蓝牙不会自拉起）"; ok=0; }
# 睡眠单元必须**未**被 mask（已恢复原生睡眠，见 §15）
for u in sleep.target suspend.target hibernate.target hybrid-sleep.target \
         suspend-then-hibernate.target systemd-suspend.service systemd-hibernate.service \
         systemd-hybrid-sleep.service systemd-suspend-then-hibernate.service; do
  [[ ! -e "$R/etc/systemd/system/$u" ]] \
    && echo "  OK   未 mask $u（原生睡眠）" \
    || { echo "  BAD  $u 仍被 mask（系统不会原生睡眠）"; ok=0; }
done
# DRM 热插拔看门狗（§16）：脚本可执行 + 用户 unit + default.target 启用软链
[[ -x "$R/usr/libexec/q8b-drm-hotplug-watch" ]] \
  && echo "  OK   DRM 热插拔看门狗脚本已安装" \
  || { echo "  BAD  缺 /usr/libexec/q8b-drm-hotplug-watch"; ok=0; }
[[ -f "$R/etc/systemd/user/q8b-drm-hotplug-watch.service" ]] \
  && echo "  OK   q8b-drm-hotplug-watch.service 已安装" \
  || { echo "  BAD  缺 q8b-drm-hotplug-watch.service"; ok=0; }
[[ "$(readlink "$R/etc/systemd/user/default.target.wants/q8b-drm-hotplug-watch.service")" == "/etc/systemd/user/q8b-drm-hotplug-watch.service" ]] \
  && echo "  OK   DRM 热插拔看门狗已启用（default.target）" \
  || { echo "  BAD  看门狗未启用（无显示器启动后插屏不会自愈）"; ok=0; }
# 强制 Game Mode（§17）：脚本 + unit + 启用软链 + 预置的 sddm autologin 文件
[[ -x "$R/usr/libexec/q8b-force-game-mode" ]] \
  && echo "  OK   force-game-mode 脚本已安装" \
  || { echo "  BAD  缺 /usr/libexec/q8b-force-game-mode"; ok=0; }
[[ "$(readlink "$R/etc/systemd/system/multi-user.target.wants/q8b-force-game-mode.service")" == "/etc/systemd/system/q8b-force-game-mode.service" ]] \
  && echo "  OK   q8b-force-game-mode.service 已启用" \
  || { echo "  BAD   force-game-mode 未启用（切到 Desktop Mode 后会黑屏）"; ok=0; }
grep -qx 'Session=gamescope-wayland.desktop' "$R/etc/sddm.conf.d/zz-steamos-autologin.conf" 2>/dev/null \
  && echo "  OK   预置 sddm autologin = gamescope-wayland.desktop（Game Mode）" \
  || { echo "  BAD  sddm autologin 未预置为 Game Mode"; ok=0; }
[[ $ok -eq 1 ]] || { echo "ERROR: overlay 自检失败" >&2; exit 1; }
log "完成。rootfs: $R"
