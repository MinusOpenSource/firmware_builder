#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./tools/replace_uboot_in_image.sh [--backup] <image.img> <u-boot-rockchip.bin>

Description:
  Replace the Rockchip bootloader area inside an existing raw disk image
  with a binman-generated u-boot-rockchip.bin.

  This follows the same layout used by this repository for Rockchip images:
    dd if=u-boot-rockchip.bin of=image.img seek=1 bs=32k conv=notrunc

Options:
  --backup    Create <image.img>.bak before writing
  -h, --help  Show this help

Examples:
  sudo ./tools/replace_uboot_in_image.sh \
    out/target/product/radxa_4d/image/radxa-4d-resolute-preinstall.img \
    out/target/product/radxa_4d/loader/u-boot-rockchip.bin

  sudo ./tools/replace_uboot_in_image.sh --backup image.img u-boot-rockchip.bin
EOF
}

BACKUP=0

while [ $# -gt 0 ]; do
    case "$1" in
        --backup)
            BACKUP=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "[ERR] Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

if [ $# -ne 2 ]; then
    usage >&2
    exit 1
fi

IMG_PATH="$1"
UBOOT_BIN="$2"
SEEK_BLOCKS=1
BLOCK_SIZE=32k

for cmd in dd cmp stat sync; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "[ERR] Missing host command: ${cmd}" >&2
        exit 1
    fi
done

if [ ! -f "${IMG_PATH}" ]; then
    echo "[ERR] Image not found: ${IMG_PATH}" >&2
    exit 1
fi

if [ ! -f "${UBOOT_BIN}" ]; then
    echo "[ERR] U-Boot bin not found: ${UBOOT_BIN}" >&2
    exit 1
fi

IMG_PATH="$(readlink -f "${IMG_PATH}")"
UBOOT_BIN="$(readlink -f "${UBOOT_BIN}")"

if [ ! -w "${IMG_PATH}" ]; then
    echo "[ERR] Image is not writable: ${IMG_PATH}" >&2
    echo "      Try running with sudo or adjust file permissions." >&2
    exit 1
fi

UBOOT_SIZE="$(stat -c '%s' "${UBOOT_BIN}")"
IMG_SIZE="$(stat -c '%s' "${IMG_PATH}")"
WRITE_OFFSET=$((SEEK_BLOCKS * 32768))
END_OFFSET=$((WRITE_OFFSET + UBOOT_SIZE))

if [ "${END_OFFSET}" -gt "${IMG_SIZE}" ]; then
    echo "[ERR] Image is too small for this U-Boot bin." >&2
    echo "      Image size : ${IMG_SIZE} bytes" >&2
    echo "      Write end  : ${END_OFFSET} bytes" >&2
    exit 1
fi

if [ "${BACKUP}" -eq 1 ]; then
    BACKUP_PATH="${IMG_PATH}.bak"
    echo "============================================"
    echo " Creating Backup"
    echo " Source : ${IMG_PATH}"
    echo " Backup : ${BACKUP_PATH}"
    echo "============================================"
    cp -a "${IMG_PATH}" "${BACKUP_PATH}"
fi

echo "============================================"
echo " Replace U-Boot In Image"
echo " Image      : ${IMG_PATH}"
echo " U-Boot bin : ${UBOOT_BIN}"
echo " Offset     : ${WRITE_OFFSET} bytes"
echo " Write      : seek=${SEEK_BLOCKS} bs=${BLOCK_SIZE}"
echo " Size       : ${UBOOT_SIZE} bytes"
echo "============================================"

dd if="${UBOOT_BIN}" of="${IMG_PATH}" seek="${SEEK_BLOCKS}" bs="${BLOCK_SIZE}" conv=notrunc,fsync status=progress
sync

TMP_READBACK="$(mktemp /tmp/replace-uboot-readback.XXXXXX)"
trap 'rm -f "${TMP_READBACK}"' EXIT

dd if="${IMG_PATH}" of="${TMP_READBACK}" bs=1 skip="${WRITE_OFFSET}" count="${UBOOT_SIZE}" status=none

if cmp -s "${UBOOT_BIN}" "${TMP_READBACK}"; then
    echo "[OK ] Verification passed."
else
    echo "[ERR] Verification failed after writing." >&2
    exit 1
fi

echo "[OK ] U-Boot replaced successfully."
