# ==============================================================================
# Device Configuration: ArmSoM W3 (RK3588)
#
# Board Info:
# Platform:
# ........
# ==============================================================================

# Board Identity
BOARD_NAME="ArmSoM W3"
TARGET_BOARD="armsom-w3"
SOC_FAMILY="rockchip"
SOC="rk3588"
TARGET_ARCH="arm64"
DEFAULT_SUITE="resolute"
DEFAULT_FLAVOR="kde"

# U-Boot
BOOTLOADER="u-boot"
UBOOT_IMPL="mainline"
UBOOT_DEFCONFIG="w3-rk3588_defconfig"
RKBIN="vendor/rockchip/rkbin"
RK_TPL_BIN="${RKBIN}/bin/rk35/rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v1.19.bin"
RK_BL31_ELF="${RKBIN}/bin/rk35/rk3588_bl31_v1.51.elf"

# Kernel
KERNEL_IMPL="mainline"
KERNEL_BASE_DEFCONFIG="defconfig"
KERNEL_CONFIG_FRAGMENT="${DEVICE_DIR}/armsom/w3/armsom_w3-kernel.config"
KERNEL_IMAGE_NAME="Image"
KERNEL_DTB="rockchip/rk3588-armsom-w3.dtb"

# Kernel Command Line
SERIAL_CONSOLE="ttyS2,1500000n8"
EARLYCON="uart8250,mmio32,0xfeb50000"
KERNEL_CMDLINE_BASE="rootwait rw splash quiet loglevel=4"
KERNEL_CMDLINE_DEBUG="console=${SERIAL_CONSOLE} earlycon=${EARLYCON}"
KERNEL_CMDLINE="${KERNEL_CMDLINE_BASE} ${KERNEL_CMDLINE_DEBUG}"

# Partition & Image Layout
IMAGE_BASENAME="${TARGET_BOARD}-${SUITE}-preinstall"
IMAGE_NAME="${IMAGE_BASENAME}.img"
IMAGE_SIZE_GIB="8"

PARTITION_TABLE="gpt"
BOOT_FS_TYPE="vfat"
ROOTFS_FS_TYPE="ext4"

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
