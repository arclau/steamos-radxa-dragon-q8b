# SteamOS for Radxa Dragon Q8B

把 **Valve 官方 SteamOS ARM**（Steam Frame / Deckard 构建的 aarch64 userspace）移植到
**Radxa Dragon Q8B**（Qualcomm **SC8280XP** / 骁龙 8cx Gen 3 / **Adreno 690**）单板计算机。

装上后是完整的 SteamOS：**Game Mode**（gamescope + Steam Gamepad UI）与 **KDE Plasma 桌面**，
x86 游戏经 FEX + ARM64 Proton 转译运行。

> 这是**跨 SoC** 移植：Steam Frame 底包面向高通手机平台，Q8B 是笔记本/计算平台（SC8280XP），
> 同为 ARM64 + Adreno 但芯片不同。本项目只复用他人**方法**，设备支持全部自写。

---

## 状态

| # | 成功定义 | 状态 |
|---|---|---|
| 1 | 从 UFS / NVMe 引导进入 SteamOS Game Mode | ✅ 已验证（板载 UFS） |
| 2 | `vulkaninfo` 报 Adreno 690，游戏 Vulkan 渲染出画 | ✅ 《星露谷物语》真机可玩 |
| 3 | 音频（3.5mm + HDMI/DP） | ⚠️ HDMI/DP ✅；**3.5mm ❌**（WCD938x EIO，卡 ADSP 固件） |
| 4 | 有线网络（2×2.5GbE）与 WiFi/BT | ✅ 均已验证 |
| 5 | Desktop Mode（KDE Plasma）切换并可切回 | ❓ 未验证（组件齐） |
| 6 | 外接手柄被识别为 Steam 输入设备 | ⚠️ USB ✅（有「开机前插→无输入」坑）；BT 未测 |
| 7 | 从整盘镜像可复现部署 | ✅ 已验证 |

**已知限制**：3.5mm 音频暂不可用；桌面模式切换未验证；蓝牙手柄未实测。
详细进度见仓库提交历史。

## 硬件要求

- **Radxa Dragon Q8B**（100×75mm SBC），Qualcomm SC8280XP + Adreno 690，4GB LPDDR4X
- 存储：板载 UFS 3.1 / microSD / M.2 NVMe 任一
- 显示：HDMI 或 USB-C DP-Alt
- 输入：USB 键鼠 / 手柄（当前**板上无输入设备**时 Game Mode 只能看不能操作）
- 无线：M.2 E-key Wi-Fi 6E/BT 模组（本项目用 Synaptics SYN43756B0 / AMPAK AP6276P）

---

## 三种用法

### A. 下载预编译镜像（最省事）

到 [Releases](../../releases) 下载对应介质的分卷 `.zst.part*` 与 `SHA256SUMS`，合并后解压：

```bash
cat radxa-dragon-q8b_ufs.img.zst.part* > img.zst
sha256sum -c SHA256SUMS          # 校验
zstd -d img.zst -o radxa-dragon-q8b_ufs.img
```

### B. 云端构建（fork → 跑 workflow）

1. **Fork** 本仓库到你自己的 GitHub。
2. 进 **Actions → build → Run workflow**，选目标介质（`ufs` / `tf` / `nvme`）。
3. 跑完在该次 run 的 **Artifacts** 里下载镜像分卷。

workflow 会**自动**按 `upstream.lock` 拉取上游（`radxa/kernel`）并从 Valve CDN 下载、重组
SteamOS rootfs，无需你手工准备任何东西。

### C. 本地构建

**依赖**（Debian/Ubuntu 为例）：

```bash
sudo apt install -y build-essential git curl rsync zstd xz-utils \
  gcc-aarch64-linux-gnu libguestfs-tools qemu-utils squashfs-tools \
  python3-requests
pip install zstandard
```

**构建**：

```bash
scripts/fetch-upstreams.sh          # 按 upstream.lock 拉 radxa/kernel（只读）
scripts/build-all.sh                # 一条龙：内核→模块→固件→initramfs→rootfs→镜像
# TARGET=ufs（默认，4096B 扇区）/ TARGET=tf / TARGET=nvme（512B）
```

> 打包阶段用 `guestfish`，**需要 sudo**（libguestfs 要读 `/boot/vmlinuz`）。
> 只出内核产物、不打镜像：`make kernel modules initramfs`；自检：`make verify`。

---

## 刷写（**扇区必须对**）

| 目标介质 | 镜像扇区 | 说明 |
|---|---|---|
| microSD / TF、NVMe | **512** | `TARGET=tf` 或 `TARGET=nvme` |
| 板载 UFS | **4096** | `TARGET=ufs`；**错扇区引导不了** |

```bash
# microSD / NVMe（从主机 dd）
sudo dd if=radxa-dragon-q8b_512.img of=/dev/sdX bs=4M status=progress conv=fsync

# 板载 UFS：主机无法直接 dd，需在板上写入，或走 EDL
```

没有 UFS 读卡器时，可先用 TF 卡进系统，再在板上 `dd` 到 UFS/NVMe。

## 首次启动

- 默认启用 SSH：`ssh steamos@<板子IP>`，**默认密码 `1234`** —— **首次登录后请立即 `passwd` 修改**。
- 根分区首启自动扩展到整盘（`steamos-growroot.service`）。
- 无输入设备时，Game Mode 画面可显示但无法操作；接 USB 键鼠或手柄即可。

---

## 致谢 (Credits)

本项目**站在许多人的肩膀上**。特别感谢两位移植先驱：

- **[hashtagbasit](https://github.com/hashtagbasit/SteamOS-ARM-Handhelds)** —— 提供了本项目的**移植基线**：
  rootfs 提取器（`extract_rootfs.py`，已 vendor 进 `steamos/tools/`）、分层 overlay 框架与 de-Frame 清单。
- **[MaSieS4Fun](https://github.com/MaSieS4Fun/SteamOS-ARM-SM8550)** —— 排错与验证清单参考。

还要感谢：

- **[radxa/kernel](https://github.com/radxa/kernel)**（GPL-2.0）—— 板级内核源码与 Q8B 设备树；
- **[Valve Corporation](https://developer.valvesoftware.com/wiki/Steam_Frame)** —— 官方 SteamOS ARM（Steam Frame）userspace；
- **[Radxa](https://github.com/radxa-build/radxa-dragon-midstream)** —— 打包脚本蓝本与 vendor 固件；
- **[linux-firmware](https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git)**、**[BusyBox](https://busybox.net/)**、**alsa-ucm-conf**、**AudioReach topology** —— 固件、initramfs、音频；
- **Sebastian Reichel (Collabora)** —— 补丁 `0004` 的原作者。

**完整的逐项来源、许可与用法见 [`CREDITS.md`](CREDITS.md)**；固件来源见 [`firmware/WHENCE`](firmware/WHENCE)。

> 本项目**不向上游提交 / 不提 PR**：上游只作只读输入，按 `upstream.lock` 钉死 commit。

## 跟进上游更新

上游（尤其 `radxa/kernel`）更新后，改 `upstream.lock` 里对应的 commit 再重建即可吃到新版：

```bash
# 1) 编辑 upstream.lock，把 RADXA_KERNEL_COMMIT 改成新 commit
# 2) 重建（fetch-upstreams 会按新 commit 重新克隆）
scripts/fetch-upstreams.sh && scripts/build-all.sh
```

**设计取舍**：我们钉 commit 而非跟分支 tip —— 保证**可复现**（任何时间构建结果一致），
代价是**更新要手动**。这样你可以选择「先验证再跟进」，而不是被动被上游改动破坏构建。

## 许可

- 本项目原创代码与脚本：**GPL-2.0**（见 [`LICENSE`](LICENSE)）。
- `firmware/` 下的固件二进制**不属于** GPL 授权范围，各自按其原始许可分发，来源见
  [`firmware/WHENCE`](firmware/WHENCE)。
- **Valve SteamOS rootfs 与 Steam 客户端**版权归 Valve，本项目**不再分发**，仅在构建时从 Valve CDN 下载。

## 声明

本项目仅供学习与研究移植技术，**请勿商用**；因刷写造成的设备损坏自负。相关商标归其各自所有者。
