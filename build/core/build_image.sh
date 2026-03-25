#!/usr/bin/env bash
set -e

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

if [ -z "${TARGET_PRODUCT}" ]; then
    echo -e "\033[1;31m[ERR ]\033[0m TARGET_PRODUCT is not set. Please run 'lunch' first." >&2
    exit 1
fi

: "${TARGET_OUT_DIR:?TARGET_OUT_DIR is not set}"
: "${IMAGE_OUT:?IMAGE_OUT is not set}"
: "${ROOTFS_ARTIFACT_DIR:?ROOTFS_ARTIFACT_DIR is not set}"
: "${ROOTFS_TARBALL:?ROOTFS_TARBALL is not set}"
: "${ROOTFS_CODENAME:=resolute}"

ensure_dir "${IMAGE_OUT}"

IDBLOADER="${LOADER_OUT}/idbloader.img"
UBOOT="${LOADER_OUT}/u-boot.itb"
UBOOT_ROCKCHIP_BIN="${LOADER_OUT}/u-boot-rockchip.bin"

FINAL_IMAGE="${IMAGE_OUT}/${TARGET_PRODUCT}-ubuntu-${ROOTFS_CODENAME}.img"

require_host_command() {
    local cmd="$1"
    local package_hint="${2:-}"

    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo -e "\033[1;31m[ERR ]\033[0m Required host command not found: ${cmd}" >&2
        if [ -n "${package_hint}" ]; then
            echo "Install package: ${package_hint}" >&2
        fi
        exit 1
    fi
}

cleanup_loopdev() {
    local loop="$1"

    sync --file-system || true
    sync || true
    sleep 1

    if [ -b "${loop}" ]; then
        for part in "${loop}"p*; do
            if mnt=$(findmnt -n -o target -S "$part" 2>/dev/null); then
                umount "${mnt}" || true
            fi
        done
        losetup -d "${loop}" || true
    fi
}

wait_loopdev() {
    local loop="$1"
    local seconds="$2"

    until test $((seconds--)) -eq 0 -o -b "${loop}"; do
        sleep 1
    done

    ((++seconds))
    ls -l "${loop}" >/dev/null 2>&1
}

cleanup_image_workspace() {
    local mount_point="$1"
    local loop="${2:-}"

    if [ -n "${mount_point}" ]; then
        awk -v p="${mount_point}" '$2 ~ ("^" p "(/|$)") {print $2}' /proc/self/mounts | LC_ALL=C sort -r | while IFS= read -r m; do
            umount "${m}" || true
        done
        rm -rf "${mount_point}"
    fi

    if [ -n "${loop}" ]; then
        cleanup_loopdev "${loop}"
    fi
}

generate_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        tr '[:upper:]' '[:lower:]' < /proc/sys/kernel/random/uuid
        return 0
    fi
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
        return 0
    fi
    echo -e "\033[1;31m[ERR ]\033[0m Unable to generate UUID" >&2
    exit 1
}

echo "============================================"
echo " Assembling Final Unified Image"
echo " Target: $TARGET_PRODUCT"
echo " Output: $FINAL_IMAGE"
echo "============================================"

require_host_command truncate coreutils
require_host_command parted parted
require_host_command partprobe parted
require_host_command dd coreutils
require_host_command blkid util-linux
require_host_command losetup util-linux
require_host_command mount util-linux
require_host_command tar tar
require_host_command mkfs.ext4 e2fsprogs

if [ ! -f "${UBOOT_ROCKCHIP_BIN}" ]; then
    for f in "$IDBLOADER" "$UBOOT"; do
        if [ ! -f "$f" ]; then
            echo -e "\033[1;31m[ERR ]\033[0m Missing component: $f" >&2
            echo "Please ensure you have successfully run 'm loader'." >&2
            exit 1
        fi
    done
fi

if [ ! -f "${ROOTFS_TARBALL}" ]; then
    echo -e "\033[1;31m[ERR ]\033[0m Missing component: ${ROOTFS_TARBALL}" >&2
    echo "Please ensure you have successfully run 'm rootfs'." >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo -e "\033[1;31m[ERR ]\033[0m Building the final image requires root privileges." >&2
    exit 1
fi

echo "[1/3] Creating sparse image file (9GB)..."
rm -f "$FINAL_IMAGE"
truncate -s 8210M "$FINAL_IMAGE"

echo "[2/3] Writing GPT partition table..."
parted -s -a none "$FINAL_IMAGE" mklabel gpt
parted -s -a none "$FINAL_IMAGE" unit s mkpart idbloader 64 16383
parted -s -a none "$FINAL_IMAGE" unit s mkpart uboot 16384 32767
parted -s -a none "$FINAL_IMAGE" unit s mkpart rootfs 32768 100%
parted -s "$FINAL_IMAGE" set 3 boot on

echo "[3/3] Populating image (This may take a while)..."

rootfs_uuid="$(generate_uuid)"

ROOTFS_OFFSET=$((32768 * 512))

loop_rootfs="$(losetup -f)"

if [ ! -b "${loop_rootfs}" ]; then
    minor="${loop_rootfs#/dev/loop}"
    mknod -m 0660 "${loop_rootfs}" b 7 "${minor}"
fi

losetup -o ${ROOTFS_OFFSET} "${loop_rootfs}" "${FINAL_IMAGE}"
trap 'cleanup_image_workspace "${mount_point:-}" "${loop_rootfs:-}"' EXIT

dd if=/dev/zero of="${loop_rootfs}" bs=1K count=10 >/dev/null 2>&1 || true
mkfs.ext4 -F -q -U "${rootfs_uuid}" -L rootfs "${loop_rootfs}" >/dev/null

mount_point="$(mktemp -d "${TARGET_OUT_DIR}/tmp.image-mnt.XXXXXX")"
mount "${loop_rootfs}" "${mount_point}"

echo " -> Extracting rootfs tarball..."
tar --xattrs --xattrs-include='*' -xJpf "${ROOTFS_TARBALL}" -C "${mount_point}"

echo " -> Configuring boot environment..."
cat > "${mount_point}/etc/fstab" <<EOF
UUID=${rootfs_uuid} / ext4 defaults,x-systemd.growfs 0 1
EOF

if [ -f "${mount_point}/etc/default/u-boot" ]; then
    sed -i -E "s#^U_BOOT_ROOT=.*#U_BOOT_ROOT=\"root=UUID=${rootfs_uuid}\"#" "${mount_point}/etc/default/u-boot"
fi

if [ -f "${mount_point}/boot/extlinux/extlinux.conf" ]; then
    sed -i -E "s/root=[^ ]+/root=UUID=${rootfs_uuid}/g" "${mount_point}/boot/extlinux/extlinux.conf"
else
    echo -e "\033[1;33m[WARN ]\033[0m /boot/extlinux/extlinux.conf not found. The system may not boot!" >&2
fi

sync --file-system || true

cleanup_image_workspace "${mount_point}" "${loop_rootfs}"
trap - EXIT

if [ -f "${UBOOT_ROCKCHIP_BIN}" ]; then
    echo " -> Writing u-boot-rockchip.bin (Seek: 1, BS: 32K)..."
    dd if="${UBOOT_ROCKCHIP_BIN}" of="${FINAL_IMAGE}" seek=1 bs=32k conv=notrunc status=none
else
    echo " -> Writing idbloader.img (Seek: 64 sectors)..."
    dd if="${IDBLOADER}" of="${FINAL_IMAGE}" seek=64 conv=notrunc status=none

    echo " -> Writing u-boot.itb (Seek: 16384 sectors)..."
    dd if="${UBOOT}" of="${FINAL_IMAGE}" seek=16384 conv=notrunc status=none
fi

sync || true

echo "============================================"
echo -e "\033[1;32m[SUCCESS]\033[0m Firmware Image successfully generated at:"
echo "  $FINAL_IMAGE"
echo "============================================"
