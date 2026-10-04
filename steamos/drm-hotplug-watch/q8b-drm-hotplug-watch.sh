#!/bin/bash
# q8b-drm-hotplug-watch — 一次性恢复「无显示器启动 Game Mode → 后插屏 → 黑屏」。
#
# 根因（真机定位）：
#   会话**无显示器启动**时 gamescope 进 deferred 后端；之后热插拔显示器，
#   gamescope 自己会恢复（DRM 原子提交恢复、DPMS On），**但 Steam 客户端不再
#   提交帧**（`steamui_steamos.txt` / `systemdisplaymanager.txt` 停在热插拔那一刻），
#   屏上一直纯黑（`kmsgrab` 抓到逐像素全 0）。
#   `systemctl --user restart steam.service` 是**已验证**的恢复手段（重启后抓到
#   真实 Steam Game Mode 库界面）。
#
# 本看门狗（Plan A）：
#   ① 仅在「会话启动时无任何 DRM 连接器 connected」时**武装**（带屏启动则直接退出）；
#   ② 武装后轮询 /sys/class/drm/card*-*/status，一旦有连接器 connected 且**稳定**
#      若干秒 → `systemctl --user restart steam.service` **一次**，然后退出。
#   一次性、best-effort、绝不阻断启动；任何异常都 exit 0。
#
# 为什么是**用户**服务：
#   restart steam.service 是**用户级** unit；`/sys/class/drm/*/status` 世界可读，
#   放在用户会话里可直接 `systemctl --user`，无需跨用户边界（machinectl/runuser）。
#
# 环境变量（便于离线测试 / 调参）：
#   Q8B_HOTPLUG_LOG          日志路径（默认 $XDG_RUNTIME_DIR 下）
#   Q8B_HOTPLUG_DRM_GLOB     DRM 连接器 status glob（默认 /sys/class/drm/card*-*/status）
#   Q8B_HOTPLUG_SYSTEMCTL    systemctl 命令（默认 `systemctl --user`，测试可换成 mock）
#   Q8B_HOTPLUG_BOOT_SETTLE  启动后等 DRM 稳定的秒数（默认 12）
#   Q8B_HOTPLUG_SETTLE       连接器需连续 connected 的秒数（默认 8）
#   Q8B_HOTPLUG_POLL         轮询间隔秒（默认 2）
set -u

LOG="${Q8B_HOTPLUG_LOG:-${XDG_RUNTIME_DIR:-/tmp}/q8b-drm-hotplug-watch.log}"
DRM_GLOB="${Q8B_HOTPLUG_DRM_GLOB:-/sys/class/drm/card*-*/status}"
SYSTEMCTL="${Q8B_HOTPLUG_SYSTEMCTL:-systemctl --user}"
BOOT_SETTLE="${Q8B_HOTPLUG_BOOT_SETTLE:-12}"
SETTLE="${Q8B_HOTPLUG_SETTLE:-8}"
POLL="${Q8B_HOTPLUG_POLL:-2}"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG" 2>/dev/null || true; }

# 任一 DRM 连接器 connected？（忽略不可读 / 无 status 的条目）
any_connected() {
    local f
    for f in $DRM_GLOB; do
        [ -r "$f" ] || continue
        [ "$(cat "$f" 2>/dev/null)" = "connected" ] && return 0
    done
    return 1
}

log "start (pid $$)"
# 等 DRM 与连接器状态稳定，避免把「带屏启动但状态尚未 settle」误判为 headless。
sleep "$BOOT_SETTLE"
if any_connected; then
    log "启动时已有显示器连接；无需干预，退出"
    exit 0
fi
log "启动时无显示器（headless）；武装看门狗，等待热插拔（boot_settle=${BOOT_SETTLE}s settle=${SETTLE}s poll=${POLL}s）"

# 等「有连接器 connected 且稳定 SETTLE 秒」→ 重启 steam.service 一次。
while true; do
    if any_connected; then
        sleep "$SETTLE"
        if any_connected; then
            log "检测到显示器已连接且稳定 ${SETTLE}s；重启 steam.service（一次性恢复）"
            # shellcheck disable=SC2086  # 故意让 $SYSTEMCTL 词分裂（默认含 `--user`）
            $SYSTEMCTL restart steam.service
            rc=$?
            log "steam.service 重启 rc=$rc；看门狗退出"
            exit 0
        fi
        log "连接出现但未稳定（${SETTLE}s 内又断开）；继续等待"
    fi
    sleep "$POLL"
done
