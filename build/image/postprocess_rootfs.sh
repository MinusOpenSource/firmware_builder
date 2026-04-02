#!/usr/bin/env bash

postprocess_require_command() {
    local cmd="$1"
    local package_hint="${2:-}"

    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo -e "\033[1;31m[ERR ]\033[0m Missing host command: ${cmd}" >&2
        [ -n "${package_hint}" ] && echo "Install package: ${package_hint}" >&2
        return 1
    fi
}

postprocess_resolve_kernel_deb() {
    local package
    local -a packages=()

    if [ -f "${KERNEL_PACKAGE_MANIFEST:-}" ]; then
        while IFS= read -r package; do
            [ -f "${package}" ] || continue
            case "$(basename "${package}")" in
                linux-image-*.deb)
                    case "$(basename "${package}")" in
                        *-dbg_*.deb) ;;
                        *) packages+=("${package}") ;;
                    esac
                    ;;
            esac
        done < "${KERNEL_PACKAGE_MANIFEST}"
    fi

    if [ ${#packages[@]} -eq 0 ]; then
        while IFS= read -r package; do
            packages+=("${package}")
        done < <(find "${KERNEL_PKG_OUT}" -maxdepth 1 -type f -name 'linux-image-*.deb' ! -name '*-dbg_*.deb' | LC_ALL=C sort)
    fi

    if [ ${#packages[@]} -eq 0 ]; then
        echo -e "\033[1;31m[ERR ]\033[0m No runtime kernel package found under ${KERNEL_PKG_OUT}." >&2
        echo "Please ensure you have successfully run 'm kernel'." >&2
        return 1
    fi

    printf '%s\n' "${packages[@]}" | LC_ALL=C sort | tail -n 1
}

resolve_board_boot_artifacts() {
    : "${KERNEL_PKG_OUT:?KERNEL_PKG_OUT is not set}"
    : "${KERNEL_DTB:?KERNEL_DTB is not set}"

    KERNEL_IMAGE_DEB="$(postprocess_resolve_kernel_deb)" || return 1
    KERNEL_IMAGE_DEB_NAME="$(basename "${KERNEL_IMAGE_DEB}")"
    KERNEL_PACKAGE_NAME="$(dpkg-deb -f "${KERNEL_IMAGE_DEB}" Package)"
    CUSTOM_KERNEL_VERSION="${KERNEL_PACKAGE_NAME#linux-image-}"
    CUSTOM_KERNEL_DTB_SRC="/usr/lib/linux-image-${CUSTOM_KERNEL_VERSION}/${KERNEL_DTB}"
    CUSTOM_KERNEL_DTB_DST="/boot/dtb-${CUSTOM_KERNEL_VERSION}"

    export KERNEL_IMAGE_DEB
    export KERNEL_IMAGE_DEB_NAME
    export CUSTOM_KERNEL_VERSION
    export CUSTOM_KERNEL_DTB_SRC
    export CUSTOM_KERNEL_DTB_DST
}

postprocess_cleanup_existing_kernel_files() {
    local rootfs_dir="$1"

    rm -rf \
        "${rootfs_dir}/lib/modules"/* \
        "${rootfs_dir}/usr/lib"/linux-image-* \
        "${rootfs_dir}/boot"/System.map-* \
        "${rootfs_dir}/boot"/config-* \
        "${rootfs_dir}/boot"/dtb-* \
        "${rootfs_dir}/boot"/initrd.img-* \
        "${rootfs_dir}/boot"/vmlinuz-*

    rm -f "${rootfs_dir}/boot"/initrd.img "${rootfs_dir}/boot"/vmlinuz
}

postprocess_update_fstab() {
    local rootfs_dir="$1"
    local root_uuid="$2"
    local fstab="${rootfs_dir}/etc/fstab"
    local tmp

    mkdir -p "${rootfs_dir}/etc"
    tmp="$(mktemp "${rootfs_dir}/etc/fstab.tmp.XXXXXX")"

    printf 'UUID=%s / ext4 defaults,x-systemd.growfs 0 1\n' "${root_uuid}" > "${tmp}"
    if [ -f "${fstab}" ]; then
        awk '$2 != "/" { print }' "${fstab}" >> "${tmp}"
    fi

    mv -f "${tmp}" "${fstab}"
}

postprocess_strip_root_arg() {
    printf '%s\n' "${1:-}" \
        | sed -E 's/(^|[[:space:]])root=[^[:space:]]+//g; s/[[:space:]]+/ /g; s/^ //; s/ $//'
}

postprocess_mount_chroot_env() {
    local rootfs_dir="$1"

    mkdir -p "${rootfs_dir}/dev/pts" "${rootfs_dir}/proc" "${rootfs_dir}/sys"
    mount --bind /dev "${rootfs_dir}/dev"
    mount --bind /dev/pts "${rootfs_dir}/dev/pts"
    mount -t proc proc "${rootfs_dir}/proc"
    mount -t sysfs sysfs "${rootfs_dir}/sys"
}

postprocess_unmount_chroot_env() {
    local rootfs_dir="$1"

    awk -v p="${rootfs_dir}" '$2 ~ ("^" p "(/|$)") { print $2 }' /proc/self/mounts \
        | LC_ALL=C sort -r \
        | while IFS= read -r m; do
            umount "${m}" 2>/dev/null || true
        done
}

apply_board_rootfs_customizations() {
    local rootfs_dir="$1"
    local root_uuid="$2"
    local cmdline
    local qemu_host
    local qemu_target
    local rc=0

    : "${KERNEL_CMDLINE:?KERNEL_CMDLINE is not set}"

    resolve_board_boot_artifacts || return 1
    postprocess_require_command dpkg-deb dpkg || return 1
    postprocess_require_command qemu-aarch64-static qemu-user-static || return 1
    postprocess_require_command chroot coreutils || return 1
    postprocess_require_command mount util-linux || return 1

    echo " -> Using kernel package: ${KERNEL_IMAGE_DEB_NAME}"
    echo " -> Board DTB: ${KERNEL_DTB}"
    echo " -> Kernel version: ${CUSTOM_KERNEL_VERSION}"

    postprocess_cleanup_existing_kernel_files "${rootfs_dir}"
    postprocess_update_fstab "${rootfs_dir}" "${root_uuid}"

    qemu_host="$(command -v qemu-aarch64-static)"
    qemu_target="${rootfs_dir}/usr/bin/qemu-aarch64-static"
    cmdline="$(postprocess_strip_root_arg "${KERNEL_CMDLINE}")"

    mkdir -p "${rootfs_dir}/tmp" "${rootfs_dir}/usr/bin"
    install -m 0755 "${qemu_host}" "${qemu_target}"
    install -m 0644 "${KERNEL_IMAGE_DEB}" "${rootfs_dir}/tmp/${KERNEL_IMAGE_DEB_NAME}"

    postprocess_mount_chroot_env "${rootfs_dir}"

    if chroot "${rootfs_dir}" /usr/bin/qemu-aarch64-static /bin/sh -ec "
set -e
export DEBIAN_FRONTEND=noninteractive
dpkg -i /tmp/${KERNEL_IMAGE_DEB_NAME}
install -m 0644 '${CUSTOM_KERNEL_DTB_SRC}' '${CUSTOM_KERNEL_DTB_DST}'
cat > /etc/kernel/cmdline <<'EOF'
root=UUID=${root_uuid} ${cmdline}
EOF
mkdir -p /etc/u-boot-menu/conf.d
cat > /etc/u-boot-menu/conf.d/99-firmware-builder.conf <<'EOF'
U_BOOT_ROOT=\"root=UUID=${root_uuid}\"
U_BOOT_PARAMETERS=\"${cmdline}\"
U_BOOT_FDT=\"${CUSTOM_KERNEL_DTB_DST}\"
EOF
u-boot-update
"
    then
        :
    else
        rc=$?
    fi

    rm -f "${rootfs_dir}/tmp/${KERNEL_IMAGE_DEB_NAME}" "${qemu_target}"
    postprocess_unmount_chroot_env "${rootfs_dir}"

    if [ "${rc}" -ne 0 ]; then
        return "${rc}"
    fi
}
