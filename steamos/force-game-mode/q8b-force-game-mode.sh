#!/bin/bash
# q8b-force-game-mode — 把默认登录模式钉回 Game Mode（幂等，best-effort）。
#
# 为什么（根因，devlog/2026-10-09-01）：
#   本板 overlay 把 `steamvr.service` mask 了（Frame VR 无对应硬件）。SteamOS 的
#   **Desktop Mode** 会话链路是：
#       plasma.desktop → start-gamescope-session plasma-session.target
#         → gamescope-session（else 分支）内层 = steamvr-plasma.service
#         → Requires=steamvr.service（已 mask）→ 内层立刻退出
#         → gamescope 无客户端提交帧 → **黑屏**（Relogin=true 还会每几秒重试）。
#   一旦默认登录模式被切成 desktop（`steamosctl switch-to-desktop-mode` / Steam UI
#   的“切换到桌面模式”会写 /etc/sddm.conf.d/zz-steamos-autologin.conf），
#   **下次冷启动就黑屏**（这正是本次事故）。
#   既然 Desktop Mode 在本板 out-of-scope 且必然黑屏，就在每次启动时把它钉回 Game Mode。
#
# 设计：幂等（已是 game 则零动作）、best-effort（任何失败都 exit 0，绝不阻断启动）、
#   由 q8b-force-game-mode.service 在 display-manager 之前运行。
set -u

F=/etc/sddm.conf.d/zz-steamos-autologin.conf
WANT='Session=gamescope-wayland.desktop'

# 幂等：文件已指向 Game Mode 就直接返回（不打扰 steamos-manager）。
if [ -r "$F" ] && grep -qx "$WANT" "$F"; then
    exit 0
fi

# 首选官方途径：同时更新 steamos-manager 的持久状态（它才是 zz 文件的写入者）。
if command -v steamosctl >/dev/null 2>&1; then
    steamosctl set-default-login-mode game >/dev/null 2>&1 || true
fi

# 兜底：steamosctl 不可用/失败时，直接写 SDDM 的 autologin 会话文件。
if ! { [ -r "$F" ] && grep -qx "$WANT" "$F"; }; then
    mkdir -p /etc/sddm.conf.d 2>/dev/null || true
    printf '[Autologin]\n%s\n' "$WANT" > "$F" 2>/dev/null || true
    chmod 0644 "$F" 2>/dev/null || true
fi

exit 0
