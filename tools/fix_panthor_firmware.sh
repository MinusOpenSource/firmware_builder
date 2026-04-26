#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  sudo ./tools/fix_panthor_firmware.sh <image.img> [rootfs_start_sector]

Description:
  Mount the rootfs partition inside a raw image, decompress
  /usr/lib/firmware/arm/mali/*/mali_csffw.bin.zst to mali_csffw.bin,
  and force-download arch10.8/mali_csffw.bin from an online firmware
  mirror into the image before syncing and unmounting.

Arguments:
  image.img            Raw disk image to patch
  rootfs_start_sector  Rootfs partition start sector, default: 32768

Example:
  sudo ./tools/fix_panthor_firmware.sh \
    out/target/product/armsom_w3/image/armsom_w3-ubuntu-resolute.img
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ $# -lt 1 ]; then
    usage >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root." >&2
    exit 1
fi

IMG_PATH="$1"
ROOTFS_START_SECTOR="${2:-32768}"
SECTOR_SIZE=512
ROOTFS_OFFSET=$((ROOTFS_START_SECTOR * SECTOR_SIZE))

if [ ! -f "${IMG_PATH}" ]; then
    echo "[ERR] Image not found: ${IMG_PATH}" >&2
    exit 1
fi

if ! command -v losetup >/dev/null 2>&1; then
    echo "[ERR] Missing host command: losetup" >&2
    exit 1
fi

if ! command -v mount >/dev/null 2>&1; then
    echo "[ERR] Missing host command: mount" >&2
    exit 1
fi

if ! command -v zstd >/dev/null 2>&1; then
    echo "[ERR] Missing host command: zstd" >&2
    exit 1
fi

if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
    echo "[ERR] Missing host command: wget or curl" >&2
    exit 1
fi

ARCH108_FW_URL='https://git.ti.com/cgit/processor-firmware/ti-linux-firmware/plain/arm/mali/arch10.8/mali_csffw.bin?h=ti-linux-firmware-next&id=edbfc3e540c9f426feb51db6a466a9015ada4dd0'

download_arch108_firmware() {
    local dst="$1"

    if command -v wget >/dev/null 2>&1; then
        wget -q -O "${dst}" "${ARCH108_FW_URL}"
    else
        curl -LfsS -o "${dst}" "${ARCH108_FW_URL}"
    fi

    if [ ! -s "${dst}" ]; then
        echo "[ERR] Downloaded arch10.8 firmware is empty: ${dst}" >&2
        return 1
    fi
}

cleanup() {
    set +e
    if [ -n "${MOUNT_POINT:-}" ] && mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
        umount "${MOUNT_POINT}" || true
    fi
    if [ -n "${LOOP_DEV:-}" ] && [ -b "${LOOP_DEV}" ]; then
        losetup -d "${LOOP_DEV}" || true
    fi
    if [ -n "${MOUNT_POINT:-}" ] && [ -d "${MOUNT_POINT}" ]; then
        rmdir "${MOUNT_POINT}" 2>/dev/null || true
    fi
    if [ -n "${TMP_ARCH108_FW:-}" ] && [ -f "${TMP_ARCH108_FW}" ]; then
        rm -f "${TMP_ARCH108_FW}" || true
    fi
}
trap cleanup EXIT

IMG_PATH="$(readlink -f "${IMG_PATH}")"
MOUNT_POINT="$(mktemp -d /tmp/panthor-fw.XXXXXX)"
LOOP_DEV="$(losetup -f)"
TMP_ARCH108_FW=""

if [ ! -b "${LOOP_DEV}" ]; then
    minor="${LOOP_DEV#/dev/loop}"
    mknod -m 0660 "${LOOP_DEV}" b 7 "${minor}" 2>/dev/null || true
fi

echo "============================================"
echo " Panthor Firmware Image Fix"
echo " Image     : ${IMG_PATH}"
echo " Rootfs ofs: ${ROOTFS_OFFSET} bytes"
echo " Mount     : ${MOUNT_POINT}"
echo "============================================"

losetup -o "${ROOTFS_OFFSET}" "${LOOP_DEV}" "${IMG_PATH}"
mount "${LOOP_DEV}" "${MOUNT_POINT}"

FW_ROOT="${MOUNT_POINT}/usr/lib/firmware/arm/mali"
if [ ! -d "${FW_ROOT}" ]; then
    echo "[ERR] Firmware directory not found in image: ${FW_ROOT}" >&2
    exit 1
fi

ARCH108_DIR="${FW_ROOT}/arch10.8"
ARCH108_BIN="${ARCH108_DIR}/mali_csffw.bin"
rm -f "${ARCH108_BIN}" "${ARCH108_DIR}/mali_csffw.bin.zst"
TMP_ARCH108_FW="$(mktemp /tmp/mali_csffw.arch10.8.XXXXXX.bin)"
echo " -> Downloading required arch10.8 firmware from: ${ARCH108_FW_URL}"
download_arch108_firmware "${TMP_ARCH108_FW}"
mkdir -p "${ARCH108_DIR}"
echo " -> Injecting arch10.8 firmware into image"
install -m 0644 "${TMP_ARCH108_FW}" "${ARCH108_BIN}"

count=0
while IFS= read -r -d '' fw_zst; do
    fw_bin="${fw_zst%.zst}"
    echo " -> Decompressing ${fw_zst#${MOUNT_POINT}/}"
    zstd -d -q -f -o "${fw_bin}" "${fw_zst}"
    count=$((count + 1))
done < <(find "${FW_ROOT}" -type f -name 'mali_csffw.bin.zst' -print0 | sort -z)

while IFS= read -r -d '' fw_bin; do
    if [ -s "${fw_bin}" ]; then
        count=$((count + 1))
    fi
done < <(find "${FW_ROOT}" -type f -name 'mali_csffw.bin' -print0 | sort -z)

if [ ! -s "${ARCH108_BIN}" ]; then
    echo "[ERR] arch10.8 firmware injection failed: ${ARCH108_BIN}" >&2
    exit 1
fi

if [ "${count}" -eq 0 ]; then
    echo "[WARN] No mali_csffw firmware found under ${FW_ROOT}" >&2
else
    echo " -> Prepared ${count} Panthor firmware file(s)"
fi

echo ""
echo "Result:"
find "${FW_ROOT}" -type f \( -name 'mali_csffw.bin' -o -name 'mali_csffw.bin.zst' \) | sort

sync "${MOUNT_POINT}" || true
sync || true

echo ""
echo "[OK] Image patched successfully."
