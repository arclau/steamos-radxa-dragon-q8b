# Makefile — Radxa Dragon Q8B（SC8280XP / Adreno 690）固件构建顶层编排
#
# 把「内核适配 → 模块 → 运行时固件 → initramfs → 整盘镜像」串成一条命令。
# 需求与架构见 README.md。
#
#   make kernel          构建内核 Image（EFI zboot）+ dtbs
#   make kernel-config   生成/更新 build/kernel/.config（defconfig + SteamOS 片段）
#   make kernel-patches  把 config/patches/*.patch 幂等应用到 upstream 内核
#   make fetch-upstreams 按 upstream.lock 重建只读上游（radxa/kernel 等；绝不 push）
#   make fetch-rootfs    下载+重组 Valve SteamOS rootfs.img（校验 sha256）
#   make modules         strip 安装模块到 build/modules/（清悬空 build/source 链接）
#   make firmware        校验运行时固件齐全（对照板级 DT 的 firmware-name）
#   make initramfs       构建 busybox initramfs（steamos/initramfs/out/initrd.gz）
#   make check           校验内核配置 / 固件 / 模块（不产镜像）
#   make verify          check + BVT（布局/构建接线/产物自省/路径契约）
#   make verify-full     kernel + modules 后 verify（耗时；上机前用）
#   make all             kernel + modules + firmware + initramfs + check
#   make image          打整盘镜像（需 ROOTFS=...；TARGET 选介质）
#   make steamos-image  同上，但默认带上 initramfs（SteamOS rootfs 必需）
#   make steamos-rootfs 提取 SteamOS rootfs.img → 目录 + 去 Frame 化 overlay + 引导器
#   make steamos-tf     steamos-rootfs + 打 TF(512) 镜像（一条龙）
#   make clean           清掉本项目的中间产物（不碰内核构建目录）
#
# 未自动化的阶段（需人工/后续）：
#   - 板级 overlay 增量（a690 Mesa、音频 UCM、输入规则）

SHELL := /bin/bash
ARCH          ?= arm64
CROSS_COMPILE ?= aarch64-linux-gnu-
O             ?= build/kernel
KREL          ?= 7.0.11+
JOBS          ?= $(shell nproc)

IMAGE    ?= $(O)/arch/arm64/boot/Image
DTB      ?= $(O)/arch/arm64/boot/dts/qcom/sc8280xp-radxa-dragon-q8b.dtb
MODULES  ?= build/modules/lib/modules
FIRMWARE ?= firmware/lib/firmware
DTS      ?= upstream/radxa-kernel/arch/arm64/boot/dts/qcom/sc8280xp-radxa-dragon-q8b.dts
INITRAMFS_OUT ?= steamos/initramfs/out/initrd.gz

# 透传给打包脚本
TARGET     ?=
SECTOR     ?=
ROOTFS     ?=
INITRD     ?=
BOOTLOADER ?=
OUT        ?=
SIZE       ?=
ESP_MOUNT  ?=
WRITE_FSTAB ?=
IMG        ?= build/out/radxa-dragon-q8b_ufs.img

# SteamOS 一条龙（P4/P5）
STEAMOS_IMG            ?= build/dl/steamos-20260925.6175226/rootfs.img
STEAMOS_ROOTFS_DIR     ?= build/steamos-rootfs
STEAMOS_BOOTLOADER_DIR ?= build/steamos-bootloader

KMAKE = $(MAKE) -C upstream/radxa-kernel O=$(abspath $(O)) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) -j$(JOBS)

.PHONY: all kernel-patches kernel-config kernel modules firmware initramfs check verify verify-full image \
        steamos-image steamos-rootfs steamos-tf fetch-upstreams fetch-rootfs release-image clean help

all: kernel modules firmware initramfs check
	@echo
	@echo "产物就绪。打整盘镜像："
	@echo "  make image ROOTFS=<rootfs.tar.xz|目录> TARGET=ufs|tf|nvme"
	@echo "  （SteamOS rootfs 用 make steamos-image，会自动带 initramfs）"

# ── 内核补丁（config/patches/*.patch → upstream 工作树，幂等）──────────────
# 不自带改 upstream。补丁是我们的事实来源，构建前打上去。
kernel-patches:
	./config/apply-kernel-patches.sh

# ── 内核配置（首次 defconfig + 应用 SteamOS 片段；之后幂等重应用）──────────
# 只在 .config 不存在时才 defconfig（避免每次构建清掉增量配置）；片段始终重应用。
kernel-config:
	@if [ ! -f $(O)/.config ]; then \
	  echo "== 生成 $(O)/.config（radxa_qcom_7_0_defconfig）=="; \
	  $(KMAKE) radxa_qcom_7_0_defconfig; \
	fi
	CFG=$(abspath $(O))/.config ./config/apply-steamos-fragment.sh
	$(KMAKE) olddefconfig

# ── 上游输入（按 upstream.lock 重建；只读，绝不 push 上游）─────────────────
fetch-upstreams:
	./scripts/fetch-upstreams.sh

# ── Valve SteamOS rootfs（下载 + 重组 + 校验；见 upstream.lock）────────────
fetch-rootfs:
	./scripts/fetch-valve-rootfs.sh

# ── 内核 ──────────────────────────────────────────────────────────────────
kernel: kernel-config kernel-patches
	$(KMAKE) Image dtbs

# ── 模块（先构建再 strip 安装到 build/modules/）──────────────────────────
modules: kernel-config kernel-patches
	$(KMAKE) modules
	$(KMAKE) INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH=$(CURDIR)/build/modules modules_install
	rm -f build/modules/lib/modules/$(KREL)/build build/modules/lib/modules/$(KREL)/source

# ── 运行时固件（对照 DT 的 firmware-name 清单）───────────────────────────
firmware:
	@echo "== 运行时固件（对照 $(DTS)）=="
	@miss=0; for f in $$(grep -oE 'firmware-name = "[^"]+"' $(DTS) | cut -d'"' -f2); do \
	  if [ -f "$(FIRMWARE)/$$f" ]; then echo "  OK   $$f"; else echo "  MISS $$f"; miss=1; fi; \
	done; \
	if [ $$miss -ne 0 ]; then echo "固件缺失"; exit 1; fi

# ── initramfs ─────────────────────────────────────────────────────────────
initramfs:
	./steamos/initramfs/build-initramfs.sh

# ── 校验（配置 / 关键内建项 / 模块）──────────────────────────────────────
check:
	@echo "== SteamOS 内核需求片段 vs $(O)/.config =="
	@bad=0; while IFS= read -r l; do \
	  case "$$l" in ''|\#*) continue;; esac; \
	  k="$${l%%=*}"; v="$${l#*=}"; \
	  cur=$$(grep -E "^(# )?$${k}[= ]" $(O)/.config | head -1); \
	  if [ "$$v" = n ]; then want="# $$k is not set"; else want="$$k=$$v"; fi; \
	  if [ "$$cur" = "$$want" ]; then echo "  OK   $$k=$$v"; \
	  else echo "  BAD  $$k 需=$$v 实=$$cur"; bad=1; fi; \
	done < config/steamos-sc8280xp.config; \
	if [ $$bad -ne 0 ]; then echo "内核配置有未落地项（改 config/steamos-sc8280xp.config 后跑 apply-steamos-fragment.sh）"; exit 1; fi
	@echo "== 关键内建项（不能是模块）=="
	@for k in CONFIG_OVERLAY_FS CONFIG_DRM_MSM CONFIG_EXT4_FS CONFIG_ANDROID_BINDERFS \
	          CONFIG_SCSI_UFS_QCOM CONFIG_PINCTRL_SC8280XP CONFIG_QCOM_RPMH; do \
	  grep -q "^$${k}=y" $(O)/.config && echo "  OK   $$k=y" \
	    || { echo "  BAD  $$k 不是 =y"; exit 1; }; \
	done
	@echo "== 模块 =="
	@if [ -d "$(MODULES)/$(KREL)" ]; then \
	  echo "  OK   $(MODULES)/$(KREL)（$$(find $(MODULES)/$(KREL) -name '*.ko*' | wc -l) 个）"; \
	else echo "  MISS 模块未安装（先 make modules）"; exit 1; fi
	@$(MAKE) --no-print-directory firmware

# ── BVT：构建与集成验证 ───────────────────────────────────────────────────
# verify      = check（配置/模块/固件）+ verify.sh（布局/接线/产物/契约）
# verify-full = 先重建 kernel+modules，再 verify（耗时，上机前用）
verify: check
	./scripts/verify.sh

verify-full: kernel modules
	$(MAKE) verify

# ── 整盘镜像 ──────────────────────────────────────────────────────────────
image:
	@test -n "$(ROOTFS)" || { \
	  echo "用法: make image ROOTFS=<rootfs.tar.xz|目录> [TARGET=ufs|tf|nvme] [INITRD=...] [BOOTLOADER=...]"; \
	  exit 1; }
	ROOTFS="$(ROOTFS)" TARGET="$(TARGET)" SECTOR="$(SECTOR)" \
	  IMAGE="$(IMAGE)" DTB="$(DTB)" MODULES="$(MODULES)" FIRMWARE="$(FIRMWARE)" \
	  INITRD="$(INITRD)" BOOTLOADER="$(BOOTLOADER)" OUT="$(OUT)" \
	  SIZE="$(SIZE)" ESP_MOUNT="$(ESP_MOUNT)" WRITE_FSTAB="$(WRITE_FSTAB)" \
	  ./scripts/make-q8b-image.sh

# SteamOS：默认带上 initramfs（/etc overlay 必需），并要求 BOOTLOADER。
# 默认 ESP_MOUNT=/efi（SteamOS 的 /boot/efi 是软链）、WRITE_FSTAB=0（别盖 overlay 的 fstab）、
# SIZE=16G（SteamOS rootfs 解压后约 9.2G，默认 10G 装不下）。
steamos-image: initramfs
	@test -n "$(ROOTFS)" || { echo "用法: make steamos-image ROOTFS=<steamos-rootfs目录|tar> [TARGET=ufs|tf|nvme] [BOOTLOADER=<含EFI/的目录>]"; exit 1; }
	@test -n "$(BOOTLOADER)" || echo "提示: SteamOS rootfs 不含 UEFI 引导器，请给 BOOTLOADER=<含EFI/的目录>（make steamos-rootfs 会产出）"
	ROOTFS="$(ROOTFS)" TARGET="$(TARGET)" SECTOR="$(SECTOR)" \
	  IMAGE="$(IMAGE)" DTB="$(DTB)" MODULES="$(MODULES)" FIRMWARE="$(FIRMWARE)" \
	  INITRD="$(if $(INITRD),$(INITRD),$(INITRAMFS_OUT))" BOOTLOADER="$(BOOTLOADER)" OUT="$(OUT)" \
	  SIZE="$(if $(SIZE),$(SIZE),16G)" \
	  ESP_MOUNT="$(if $(ESP_MOUNT),$(ESP_MOUNT),/efi)" \
	  WRITE_FSTAB="$(if $(WRITE_FSTAB),$(WRITE_FSTAB),0)" \
	  ./scripts/make-q8b-image.sh

# ── SteamOS rootfs 提取 + 去 Frame 化 + 引导器（P4/P5）──────────────────────
steamos-rootfs:
	./steamos/prepare-steamos-rootfs.sh "$(STEAMOS_IMG)" "$(STEAMOS_ROOTFS_DIR)" "$(STEAMOS_BOOTLOADER_DIR)"

# 一条龙：提取 rootfs → 打 TF(512) 镜像
steamos-tf: steamos-rootfs
	$(MAKE) steamos-image ROOTFS="$(STEAMOS_ROOTFS_DIR)" BOOTLOADER="$(STEAMOS_BOOTLOADER_DIR)" TARGET=tf

# ── 发布：压缩 + 分卷（<2GiB/卷，适配 GitHub Release 单文件上限）──────────
# 用法：make release-image IMG=build/out/radxa-dragon-q8b_ufs.img
release-image:
	@test -f "$(IMG)" || { echo "用法: make release-image IMG=<image>（默认 $(IMG)）"; exit 1; }
	zstd -19 -T0 -f "$(IMG)" -o "$(IMG).zst"
	mkdir -p build/out/parts
	split -b 1900M -d -a 2 "$(IMG).zst" "build/out/parts/$(notdir $(IMG)).zst.part"
	cd build/out/parts && sha256sum * > SHA256SUMS
	@echo "分卷在 build/out/parts/（含 SHA256SUMS）"

# ── 清理（只清本项目中间产物，不动内核构建目录）─────────────────────────
clean:
	rm -rf steamos/initramfs/out build/image-work
	@echo "（不动 build/steamos-rootfs/ 与 build/steamos-bootloader/：重建代价高，要删手动 rm -rf）"

help:
	@sed -n '2,23p' Makefile | sed 's/^# \{0,1\}//'
