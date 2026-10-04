# CREDITS — 致谢与第三方来源

本项目的设备支持全部自写，但**站在许多人的肩膀上**。以下按「怎么用」分类，逐项列出
来源与许可。若你是其中某个项目的作者且希望调整署名方式，欢迎开 issue。

> 本仓库**不向上游提交 / 不提 PR**：上游只作只读输入（见 `upstream.lock`）。

---

## 一、移植先驱（特别感谢）

没有他们先把 Valve 的 SteamOS ARM 抠出来、把方法趟平，本项目无从开始：

- **[hashtagbasit/SteamOS-ARM-Handhelds](https://github.com/hashtagbasit/SteamOS-ARM-Handhelds)**
  —— 本项目的**移植基线**。我们复用了：
  - `scripts/extract_rootfs.py`（rootfs 提取器）→ **vendor** 进 `steamos/tools/`（GPL-2.0，未修改）
  - `steamos-overlay/` + `smXXXX-overlay/` 的**分层 overlay 思路** → 我们据此自写 `sc8280xp` 版
  - de-Frame 化清单（屏蔽 Frame 专有 systemd 单元、`VARIANT_ID` 修正、去 VR Vulkan 层等）
  - `external-and-mods/kernel-common/initramfs/init` → 我们**改编**为 `steamos/initramfs/init`
- **[MaSieS4Fun/SteamOS-ARM-SM8550](https://github.com/MaSieS4Fun/SteamOS-ARM-SM8550)**
  —— 排错与验证参考：`docs/BUILD-AND-FIXES.md`、`RELEASE-CHECKLIST.md`、
  `install-mesa-sm8550.sh`。该仓库的原创脚本同为 GPL-2.0
  （见其 `LICENSE`：*"includes work from MaSi's SteamOS-ARM-SM8550"*）。

## 二、内核与补丁

- **[radxa/kernel](https://github.com/radxa/kernel)**（分支 `linux-7.0.11`，**GPL-2.0**）
  —— 板级内核源码与 Q8B 设备树（`sc8280xp-radxa-dragon-q8b.dts`）。
  按 `upstream.lock` 钉死 commit，只读输入；我们的改动以补丁形式存放于 `config/patches/`。
- **补丁 `0004-wifi-brcmfmac-improve-d3-substate-timeout.patch`** 原作者为
  **Sebastian Reichel (Collabora)**，来自内核邮件列表；我们原样携带并保留其
  `From:` / `Signed-off-by:` 署名。
- **[ianchb/sm8550-mainline](https://github.com/ianchb/sm8550-mainline)**、ROCKNIX —— 早期移植思路参考。

## 三、Valve SteamOS

- **SteamOS ARM（Steam Frame / Deckard 构建的 aarch64 userspace）** 版权归
  **Valve Corporation**。本项目**不再分发**该 rootfs：构建时由 `scripts/fetch-valve-rootfs.sh`
  从 Valve CDN 下载并按 manifest 校验后重组（见 `upstream.lock`）。
- *Steam、SteamOS、Steam Deck、Steam Frame* 是 Valve Corporation 的商标。

## 四、打包与构建

- **[radxa-build/radxa-dragon-midstream](https://github.com/radxa-build/radxa-dragon-midstream)**（r7）
  —— `scripts/make-q8b-image.sh` **改编自**其官方 guestfish 脚本
  `build-4096-image.fish` / `build-512-image.fish`（GPT 布局、分区/扇区约定照抄）。
- **[radxa/rsdk](https://github.com/radxa/rsdk)（RadxaOS-SDK）** —— Radxa 构建体系参考。
- **[flange-build/flange](https://github.com/flange-build/flange)** —— Q8B 端到端支持（EDL 刷写等）参考。

## 五、运行时固件（见 [`firmware/WHENCE`](firmware/WHENCE)）

- **[radxa-pkg/radxa-firmware](https://github.com/radxa-pkg/radxa-firmware)** —— SC8280XP vendor 固件（ADSP/CDSP/SLPI/VSS/QUPv3）。
- **[linux-firmware](https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git)** —— a660 GMU/SQE、VPU、GPU zap shader。
- **AMPAK AP6276P / Synaptics SYN43756B0** vendor 包 —— Wi-Fi + BT 固件。
- **AudioReach topology**（`audioreach-topology` 的 `SC8280XP-Radxa-Dragon-Q8B.m4`）
  —— 经 `m4` + `alsatplg` 生成 `SC8280XP-Radxa-Dragon-Q8B-tplg.bin`。
- **[alsa-ucm-conf](https://github.com/alsa-project/alsa-ucm-conf)**（Radxa 的 sc8280xp profile）
  —— `steamos/ucm/` 的基线；我们针对 Q8B 修了 DMI 匹配与 `False.Error` 早退。

## 六、工具

- **[BusyBox](https://busybox.net/)**（**GPL-2.0**）—— `steamos/initramfs/tools/busybox-aarch64`
  是静态 aarch64 busybox（取自 Rockchip RK3576 Linux SDK）。源码见 busybox 上游。

---

## 许可

- 本项目**原创**代码与脚本：**GPL-2.0**（见 [`LICENSE`](LICENSE)）。
- 上表中标注 GPL-2.0 的第三方代码，其版权归原作者，按 GPL-2.0 分发。
- 固件二进制**不在** GPL 授权范围内，各自按其原始许可分发。
