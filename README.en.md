# SteamOS for Radxa Dragon Q8B

Port **Valve's official SteamOS ARM** (the aarch64 userspace from the Steam Frame /
Deckard build) to the **Radxa Dragon Q8B** single-board computer
(Qualcomm **SC8280XP** / Snapdragon 8cx Gen 3 / **Adreno 690**).

Once installed it boots into SteamOS **Game Mode** (gamescope + Steam Gamepad UI);
x86 games run through FEX + ARM64 Proton translation.

> This is a **cross-SoC** port: the Steam Frame base targets Qualcomm mobile
> platforms, while the Q8B is a laptop/compute platform (SC8280XP). Both are
> ARM64 + Adreno, but the chips differ. This project only reuses other people's
> **methods**; all device support is written from scratch.

---

## Status

| # | Success criterion | Status |
|---|---|---|
| 1 | Boot from UFS / NVMe into SteamOS Game Mode | ✅ Verified (onboard UFS) |
| 2 | `vulkaninfo` reports Adreno 690, games render via Vulkan | ✅ *Stardew Valley* playable on real hardware |
| 3 | Audio (3.5 mm + HDMI/DP) | ⚠️ HDMI/DP ✅; **3.5 mm ❌** (WCD938x EIO, stuck on ADSP firmware) |
| 4 | Wired networking (2× 2.5GbE) and Wi-Fi/BT | ✅ All verified |
| 5 | External gamepad recognized as a Steam input device | ✅ Both USB and BT verified (USB has a "plugged in before boot → no input" gotcha; replug fixes it) |
| 6 | Reproducible deployment from a full-disk image | ✅ Verified |

## What is implemented

### Kernel and device tree
- Cross-compiled an **EFI zboot kernel** + 3397 modules + the Q8B device tree from
  `radxa/kernel` (`7.0.11+`, `SMP PREEMPT`).
- Kernel config **aligned item-by-item with the Valve Steam Frame kernel** (a full
  config was extracted from the Frame kernel's embedded IKCONFIG and used as the
  authoritative diff), filling in `PREEMPT`, `OVERLAY_FS`, `SCHED_CLASS_EXT`,
  `DEBUG_INFO_BTF`, `HID_PID`, `USB_HIDDEV`, `PM_WAKELOCKS`, `NO_HZ_IDLE`,
  `CPU_FREQ_DEFAULT_GOV_PERFORMANCE`, and others.
- **4 kernel patches** (`config/patches/`, applied idempotently to the read-only
  upstream tree at build time):
  1. `tc956x` bridge `irq_domain` struct initialization — fixes an SP/PC alignment
     oops in the onboard 2.5GbE;
  2. `brcmfmac`: add **SYN43756 / AP6276P** Wi-Fi module support — not in mainline;
  3. Q8B Bluetooth `serdev` device-tree node;
  4. `brcmfmac` D3 substate handshake timeout tolerance.

### Runtime firmware
- Added **all runtime firmware** the kernel loads from `/lib/firmware` (paths are
  authoritative from the device tree `firmware-name` and the driver catalogs): the
  `a660` GMU/SQE reused by Adreno 690, the GPU zap shader, ADSP/CDSP/SLPI/VSS/QUPv3,
  the Iris VPU, Wi-Fi/BT firmware, and the ALSA audio topology. Sources and licenses:
  [`firmware/WHENCE`](firmware/WHENCE).

### Storage and boot
- **Boots from onboard UFS** (Samsung 128G UFS, requires a **4096-byte sector**
  image); microSD / NVMe (**512-byte sector**) are supported too.
- Full-disk image assembly (GPT: `config` + ESP + `rootfs`), with the kernel + DTB +
  systemd-boot BLS entries on the ESP.
- **First boot automatically grows the root partition to fill the disk**
  (`steamos-growroot.service`, best-effort, idempotent).

### Graphics
- **Adreno 690 is natively supported by stock Mesa**: both Turnip
  (`libvulkan_freedreno`) and zink enumerate `Adreno (TM) 690`, so **no custom Mesa
  build is needed**.
- Game Mode (gamescope + Steam Gamepad UI) renders; HDMI and both USB-C DP outputs
  work, with dual DP hot-plugging supported.

### Audio
- Hand-written **ALSA UCM** (Q8B profiles, 3 files) + **AudioReach topology**, fixing
  the total silence caused by stock UCM only recognizing the X13s.
- HDMI/DP output works, and the **default sink follows the active display port**
  (each of the three DP devices is bound to its own `JackControl`).
- 3.5 mm headphone / mic are not working yet (WCD938x EIO, ADSP rejects `GRAPH_START`).

### Networking
- **Wired**: dual 2.5GbE (Toshiba TC956x PCIe bridge + QCA8081 PHY); after the patch
  both ports bind.
- **Wi-Fi**: **Synaptics SYN43756B0 (AMPAK AP6276P)** — no support in either mainline
  or the vendor BSP; with a hand-written kernel patch + the real firmware,
  `brcmfmac` binds, `wlan0` comes up, both bands enumerate, and it **auto-loads
  across reboots**. This support is **specific to this module** (kernel patch 0002 +
  matching firmware); a different M.2 module needs its own port.
- **Bluetooth**: UART patchram; when the shared module's BT core isn't ready at cold
  boot, bluetoothd fails on first open and never retries, so `q8b-bt-bringup.service`
  self-heals it — it comes up automatically in ~36 s on cold boot and can scan for
  devices.

### System and session
- **De-Frame overlay**: replaces SteamOS's A/B partsets `fstab` with a flat
  single-slot layout, sets `VARIANT_ID` to `steamdeck`, and masks 26 system-level +
  5 user-level Frame-specific units (FPGA / fan / LED / VR / typec / ADB, etc.).
- Custom **initramfs** (required by SteamOS: the `/etc` overlay must be mounted
  before `switch_root`).
- **DRM hot-plug watchdog**: booting Game Mode with no display and plugging one in
  later self-heals (restarts the Steam session once after 8 s of stability).
- Restores the system's native sleep (s2idle; the only reliable wake source on this
  board is the PMIC power button).

### Build and delivery
- One-shot build: kernel → modules → firmware → initramfs → SteamOS rootfs →
  flashable image.
- **Fork the repo and run GitHub Actions to get a cloud-built image**, no local
  environment required.
- Upstreams (`radxa/kernel`, the rootfs extractor, etc.) are pinned by commit /
  sha256 in `upstream.lock`, so **builds are reproducible**.
- Self-check with `make verify`: layout / build wiring / artifact introspection /
  path contracts.

## Known limitations

- **3.5 mm audio** is not available yet (WCD938x EIO, stuck on ADSP firmware).
- USB gamepads have a "plugged in before boot → no input" gotcha (replug or reset
  fixes it).
- With **no input device** on the board, Game Mode can only display, not be operated.
- Audio takes about 1 minute to become ready after a cold boot; the
  `default-sink-volume` setting does not take effect.

## Hardware requirements

- **Radxa Dragon Q8B** (100×75 mm SBC), Qualcomm SC8280XP + Adreno 690, 4GB LPDDR4X
- Storage: onboard UFS 3.1 / microSD / M.2 NVMe (any one)
- Display: HDMI or USB-C DP-Alt
- Input: USB keyboard/mouse / gamepad (with **no input device** on the board, Game
  Mode can only be viewed, not operated)
- Wireless: M.2 E-key slot; this project is verified on **Synaptics SYN43756B0
  (AMPAK AP6276P)** — other modules need their own driver/firmware support and are
  not guaranteed to work out of the box

---

## Three ways to use it

### A. Download a prebuilt image (easiest)

Go to [Releases](../../releases) and download the split `.zst.part*` files for your
target medium plus `SHA256SUMS`, then merge and decompress:

```bash
cat radxa-dragon-q8b_ufs.img.zst.part* > img.zst
sha256sum -c SHA256SUMS          # verify
zstd -d img.zst -o radxa-dragon-q8b_ufs.img
```

### B. Cloud build (fork → run the workflow)

1. **Fork** this repository to your own GitHub.
2. Go to **Actions → build → Run workflow** and pick the target medium
   (`ufs` / `tf` / `nvme`).
3. When it finishes, download the image parts from that run's **Artifacts**.

The workflow **automatically** fetches the upstreams (`radxa/kernel`) per
`upstream.lock` and downloads + reassembles the SteamOS rootfs from Valve's CDN —
you don't need to prepare anything by hand.

### C. Local build

**Dependencies** (Debian/Ubuntu example):

```bash
sudo apt install -y build-essential git curl rsync zstd xz-utils \
  gcc-aarch64-linux-gnu libguestfs-tools qemu-utils squashfs-tools \
  python3-requests
pip install zstandard
```

**Build**:

```bash
scripts/fetch-upstreams.sh          # fetch radxa/kernel per upstream.lock (read-only)
scripts/build-all.sh                # one shot: kernel→modules→firmware→initramfs→rootfs→image
# TARGET=ufs (default, 4096B sectors) / TARGET=tf / TARGET=nvme (512B)
```

> Image assembly uses `guestfish` and **needs sudo** (libguestfs must read
> `/boot/vmlinuz`).
> Kernel artifacts only, no image: `make kernel modules initramfs`; self-check:
> `make verify`.

---

## Flashing (**sector size must match**)

| Target medium | Image sector | Notes |
|---|---|---|
| microSD / TF, NVMe | **512** | `TARGET=tf` or `TARGET=nvme` |
| Onboard UFS | **4096** | `TARGET=ufs`; **a wrong sector size won't boot** |

```bash
# microSD / NVMe (dd from a host)
sudo dd if=radxa-dragon-q8b_512.img of=/dev/sdX bs=4M status=progress conv=fsync

# Onboard UFS: a host cannot dd it directly — write on the board, or use EDL
```

If you have no UFS reader, boot from a TF card first, then `dd` to UFS/NVMe from the
board.

## First boot

- SSH is enabled by default: `ssh steamos@<board-ip>`, **default password `1234`** —
  **change it with `passwd` immediately after first login**.
- The root partition grows to fill the disk on first boot
  (`steamos-growroot.service`).
- With no input device, Game Mode displays but can't be operated; plug in a USB
  keyboard/mouse or gamepad.

---

## Credits

This project **stands on many shoulders**. Special thanks to two porting pioneers:

- **[hashtagbasit](https://github.com/hashtagbasit/SteamOS-ARM-Handhelds)** — provided
  this project's **porting baseline**: the rootfs extractor (`extract_rootfs.py`,
  vendored into `steamos/tools/`), the layered overlay framework, and the de-Frame
  checklist.
- **[MaSieS4Fun](https://github.com/MaSieS4Fun/SteamOS-ARM-SM8550)** — troubleshooting
  and verification checklist reference.

Also thanks to:

- **[radxa/kernel](https://github.com/radxa/kernel)** (GPL-2.0) — board kernel source
  and the Q8B device tree;
- **[Valve Corporation](https://developer.valvesoftware.com/wiki/Steam_Frame)** — the
  official SteamOS ARM (Steam Frame) userspace;
- **[Radxa](https://github.com/radxa-build/radxa-dragon-midstream)** — the packaging
  script blueprint and vendor firmware;
- **[linux-firmware](https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git)**,
  **[BusyBox](https://busybox.net/)**, **alsa-ucm-conf**, **AudioReach topology** —
  firmware, initramfs, audio;
- **Sebastian Reichel (Collabora)** — original author of patch `0004`.

**The full item-by-item sources, licenses and usage are in [`CREDITS.md`](CREDITS.md)**
(in Chinese); firmware sources are in [`firmware/WHENCE`](firmware/WHENCE).

> This project **does not submit to or open PRs against upstreams**: upstreams are
> read-only inputs pinned by commit in `upstream.lock`.

## Following upstream updates

After an upstream (especially `radxa/kernel`) update, change the corresponding commit
in `upstream.lock` and rebuild to pick it up:

```bash
# 1) edit upstream.lock and change RADXA_KERNEL_COMMIT to the new commit
# 2) rebuild (fetch-upstreams re-clones at the new commit)
scripts/fetch-upstreams.sh && scripts/build-all.sh
```

**Design trade-off**: we pin commits rather than tracking branch tips — this
guarantees **reproducibility** (the build result is identical at any time), at the
cost of **manual updates**. This lets you choose "verify first, then follow" instead
of being broken by upstream changes passively.

## License

- This project's original code and scripts: **GPL-2.0** (see [`LICENSE`](LICENSE)).
- The firmware binaries under `firmware/` are **not** covered by the GPL; each is
  distributed under its own original license, with sources in
  [`firmware/WHENCE`](firmware/WHENCE).
- **Valve's SteamOS rootfs and Steam client** are copyright Valve; this project does
  **not** redistribute them and only downloads them from Valve's CDN at build time.

## Disclaimer

This project is for learning and studying porting techniques only — **do not use it
commercially**; you are responsible for any device damage caused by flashing.
Related trademarks belong to their respective owners.
