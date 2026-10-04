# steamos/initramfs/tools — vendored binaries

## busybox-aarch64

Static aarch64 busybox used to assemble the initramfs
(`steamos/initramfs/build-initramfs.sh`). The initramfs has no dynamic loader,
so busybox must be **statically linked**.

- **Type**: `ELF 64-bit LSB executable, ARM aarch64, statically linked, stripped`
- **Source**: Rockchip RK3576 Linux SDK
  (`device/rockchip/common/tools/aarch64/busybox`), a stock buildroot busybox.
- **License**: GPL-2.0 (busybox). Source: https://busybox.net/
- **SHA256**:
  `d5b3d2d690138211cb43ba56005515203fede743757563316c114eedb6db0a9d`

To rebuild/refresh (any static aarch64 busybox works):

```sh
# Debian/Ubuntu aarch64 host, or an aarch64 chroot:
apt-get install busybox-static        # provides /bin/busybox (static)
cp /bin/busybox steamos/initramfs/tools/busybox-aarch64
```

`build-initramfs.sh` validates the binary is aarch64 + statically linked before
use, and accepts `BUSYBOX=<path>` to override.
