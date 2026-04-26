# ==============================================================================
# Device Configuration: Radxa Rock 4D (RK3576)
#
# Board Info:
# Platform:
# ........
# ==============================================================================

# Board Identity
BOARD_NAME="Radxa Rock 4D"
TARGET_BOARD="radxa-4d"
SOC_FAMILY="rockchip"
SOC="rk3576"
TARGET_ARCH="arm64"
DEFAULT_SUITE="resolute"
DEFAULT_FLAVOR="kde"

# U-Boot
BOOTLOADER="u-boot"
UBOOT_IMPL="mainline"
UBOOT_DEFCONFIG="rock-4d-rk3576_defconfig"
# Build a self-contained disk image with bootloader injection, matching the
# upstream Radxa/Armbian whole-image layout for removable media.
IMAGE_INJECT_BOOTLOADER="true"
RKBIN="vendor/rockchip/rkbin"
RK_TPL_BIN="${RKBIN}/bin/rk35/rk3576_ddr_lp4_2112MHz_lp5_2736MHz_v1.09.bin"
RK_BL31_ELF="${RKBIN}/bin/rk35/rk3576_bl31_v1.20.elf"

# Kernel
KERNEL_IMPL="mainline"
KERNEL_BASE_DEFCONFIG="rockchip_linux_defconfig"
KERNEL_CONFIG_FRAGMENT="${DEVICE_DIR}/radxa/4d/radxa_4d-kernel.config"
KERNEL_IMAGE_NAME="Image"
KERNEL_DTB="rockchip/rk3576-rock-4d.dtb"

# Kernel Command Line
SERIAL_CONSOLE="ttyS0,1500000n8"
EARLYCON="uart8250,mmio32,0x2ad40000"
KERNEL_CMDLINE_BASE="rootwait rw console=tty0 loglevel=7 systemd.show_status=1 systemd.log_level=info plymouth.enable=0"
KERNEL_CMDLINE_DEBUG="console=${SERIAL_CONSOLE} earlycon=${EARLYCON}"
KERNEL_CMDLINE="${KERNEL_CMDLINE_BASE} ${KERNEL_CMDLINE_DEBUG}"

# Partition & Image Layout
IMAGE_BASENAME="${TARGET_BOARD}-${SUITE}-preinstall"
IMAGE_NAME="${IMAGE_BASENAME}.img"
IMAGE_SIZE_GIB="8"

PARTITION_TABLE="gpt"
BOOT_FS_TYPE="vfat"
ROOTFS_FS_TYPE="ext4"
ROOTFS_START_SECTOR="32768"

IMAGE_START_MIB="32"
BOOT_SIZE_MIB="512"
BOOT_PART_START_MIB="32"
BOOT_PART_END_MIB="544"
ROOTFS_PART_START_MIB="544"

ROCKCHIP_IDBLOADER_SECTOR="64"
ROCKCHIP_UBOOT_ITB_SECTOR="16384"

# ROOTFS
ROOTFS_VERSION="26.04"
ROOTFS_ARCH="${TARGET_ARCH}"
