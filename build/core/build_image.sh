#!/usr/bin/env bash
set -e

if [ -z "${TARGET_PRODUCT}" ]; then
    echo -e "\033[1;31m[ERR ]\033[0m TARGET_PRODUCT is not set. Please run 'lunch' first." >&2
    exit 1
fi

: "${TARGET_OUT_DIR:?TARGET_OUT_DIR is not set}"
: "${IMAGE_OUT:?IMAGE_OUT is not set}"

: "${ROOTFS_CODENAME:=resolute}"

IDBLOADER="${LOADER_OUT}/idbloader.img"
UBOOT="${LOADER_OUT}/u-boot.itb"
ROOTFS_IMG="${IMAGE_OUT}/rootfs.img"

FINAL_IMAGE="${IMAGE_OUT}/${TARGET_PRODUCT}-ubuntu-${ROOTFS_CODENAME}.img"

echo "============================================"
echo " Assembling Final Unified Image"
echo " Target: $TARGET_PRODUCT"
echo " Output: $FINAL_IMAGE"
echo "============================================"

for f in "$IDBLOADER" "$UBOOT" "$ROOTFS_IMG"; do
    if [ ! -f "$f" ]; then
        echo -e "\033[1;31m[ERR ]\033[0m Missing component: $f" >&2
        echo "Please ensure you have successfully run 'm loader' and 'm rootfs'." >&2
        exit 1
    fi
done

echo "[1/3] Creating blank image file (9GB)..."
rm -f "$FINAL_IMAGE"
fallocate -l 8210M "$FINAL_IMAGE"

echo "[2/3] Writing GPT partition table..."

parted -s -a none "$FINAL_IMAGE" mklabel gpt
parted -s -a none "$FINAL_IMAGE" unit s mkpart idbloader 64 16383
parted -s -a none "$FINAL_IMAGE" unit s mkpart uboot 16384 32767
parted -s -a none "$FINAL_IMAGE" unit s mkpart rootfs 32768 100%

parted -s "$FINAL_IMAGE" set 3 boot on

echo "[3/3] Flashing components into image..."

echo " -> Writing idbloader.img (Seek: 64 sectors)..."
dd if="$IDBLOADER" of="$FINAL_IMAGE" seek=64 conv=notrunc status=none

echo " -> Writing u-boot.itb (Seek: 16384 sectors)..."
dd if="$UBOOT" of="$FINAL_IMAGE" seek=16384 conv=notrunc status=none

echo " -> Writing Unified rootfs.img (Seek: 32768 sectors)..."
dd if="$ROOTFS_IMG" of="$FINAL_IMAGE" seek=32768 conv=notrunc status=progress

echo "============================================"
echo -e "\033[1;32m[SUCCESS]\033[0m Firmware Image successfully generated at:"
echo "  $FINAL_IMAGE"
echo "============================================"
