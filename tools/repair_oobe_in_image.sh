#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  sudo ./tools/repair_oobe_in_image.sh <image.img|rootfs_dir> [rootfs_start_sector]

Description:
  Apply the minimal OOBE fix to an existing image or unpacked rootfs by
  removing the Calamares self-uninstall rule from:
    /etc/calamares/modules/packages.conf

Arguments:
  image.img            Raw disk image to patch
  rootfs_dir           Mounted or unpacked rootfs directory to patch directly
  rootfs_start_sector  Rootfs partition start sector for raw images, default: 32768
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
    echo "[ERR] Please run as root." >&2
    exit 1
fi

TARGET="$1"
ROOTFS_START_SECTOR="${2:-32768}"
SECTOR_SIZE=512
ROOTFS_OFFSET=$((ROOTFS_START_SECTOR * SECTOR_SIZE))
PACKAGES_CONF_REL="etc/calamares/modules/packages.conf"

LOOP_DEV=""
MOUNT_POINT=""
ROOTFS_DIR=""

cleanup() {
    set +e
    if [ -n "${MOUNT_POINT}" ] && mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
        umount "${MOUNT_POINT}" || true
    fi
    if [ -n "${LOOP_DEV}" ] && [ -b "${LOOP_DEV}" ]; then
        losetup -d "${LOOP_DEV}" || true
    fi
    if [ -n "${MOUNT_POINT}" ] && [ -d "${MOUNT_POINT}" ]; then
        rmdir "${MOUNT_POINT}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [ -d "${TARGET}" ]; then
    ROOTFS_DIR="$(readlink -f "${TARGET}")"
elif [ -f "${TARGET}" ]; then
    IMG_PATH="$(readlink -f "${TARGET}")"
    MOUNT_POINT="$(mktemp -d /tmp/repair-oobe.XXXXXX)"
    LOOP_DEV="$(losetup -f)"

    if [ ! -b "${LOOP_DEV}" ]; then
        minor="${LOOP_DEV#/dev/loop}"
        mknod -m 0660 "${LOOP_DEV}" b 7 "${minor}" 2>/dev/null || true
    fi

    losetup -o "${ROOTFS_OFFSET}" "${LOOP_DEV}" "${IMG_PATH}"
    mount "${LOOP_DEV}" "${MOUNT_POINT}"
    ROOTFS_DIR="${MOUNT_POINT}"
else
    echo "[ERR] Target not found: ${TARGET}" >&2
    exit 1
fi

if [ ! -f "${ROOTFS_DIR}/etc/os-release" ]; then
    echo "[ERR] Target does not look like a Linux rootfs: ${ROOTFS_DIR}" >&2
    exit 1
fi

PACKAGES_CONF="${ROOTFS_DIR}/${PACKAGES_CONF_REL}"

if [ ! -f "${PACKAGES_CONF}" ]; then
    echo "[ERR] Missing ${PACKAGES_CONF_REL} in target rootfs." >&2
    exit 1
fi

echo "============================================"
echo " Repair OOBE"
echo " Target rootfs : ${ROOTFS_DIR}"
echo " Config        : ${PACKAGES_CONF_REL}"
echo "============================================"

before="$(grep -n -- '- calamares$' "${PACKAGES_CONF}" || true)"
sed -i '/- calamares$/d' "${PACKAGES_CONF}"
after="$(grep -n -- '- calamares$' "${PACKAGES_CONF}" || true)"

sync "${ROOTFS_DIR}" || true
sync || true

echo ""
if [ -n "${before}" ] && [ -z "${after}" ]; then
    echo "[OK] Removed Calamares self-uninstall rule."
elif [ -z "${before}" ]; then
    echo "[OK] No Calamares self-uninstall rule was present."
else
    echo "[WARN] packages.conf still appears to contain '- calamares'."
    exit 1
fi
