#!/usr/bin/env bash
set -e

if [ -z "${TARGET_PRODUCT}" ]; then
    echo -e "\033[1;31m[ERR ]\033[0m TARGET_PRODUCT is not set." >&2
    exit 1
fi

: "${KERNEL_BASE_DEFCONFIG:?}"
: "${KERNEL_IMAGE_NAME:?}"

LOG_OUT="${TARGET_OUT_DIR}/logs"
KERNEL_BUILD_LOG="${LOG_OUT}/kernel_build.log"
ensure_dir "${LOG_OUT}" "${KERNEL_OUT}" "${BOOT_OUT}/extlinux" "${ROOTFS_OUT}"

MERGE_SCRIPT="${KERNEL_SRC}/scripts/kconfig/merge_config.sh"
IMAGE_PATH="${KERNEL_OUT}/arch/${ARCH}/boot/${KERNEL_IMAGE_NAME}"
DTB_ROOT="${KERNEL_OUT}/arch/${ARCH}/boot/dts"

msg "Building kernel for ${TARGET_BOARD}"
msg "Kernel source      : ${KERNEL_SRC}"
msg "Kernel output      : ${KERNEL_OUT}"
msg "Base defconfig     : ${KERNEL_BASE_DEFCONFIG}"
msg "Log file           : ${KERNEL_BUILD_LOG}"

> "${KERNEL_BUILD_LOG}"
cd "${KERNEL_SRC}"
rm -rf "${KERNEL_OUT:?}"/*

run_task "KERNEL" "make defconfig" "${KERNEL_BUILD_LOG}" \
    make O="${KERNEL_OUT}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" "${KERNEL_BASE_DEFCONFIG}"

if [[ -n "${KERNEL_CONFIG_FRAGMENT:-}" ]]; then
    if [ ! -f "${KERNEL_CONFIG_FRAGMENT}" ]; then
        die "Kernel fragment not found: ${KERNEL_CONFIG_FRAGMENT}"
    fi
    run_task "KERNEL" "merge config" "${KERNEL_BUILD_LOG}" \
        "${MERGE_SCRIPT}" -m -O "${KERNEL_OUT}" "${KERNEL_OUT}/.config" "${KERNEL_CONFIG_FRAGMENT}"
fi

run_task "KERNEL" "olddefconfig" "${KERNEL_BUILD_LOG}" \
    make O="${KERNEL_OUT}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig

run_task "KERNEL" "build image & dtbs" "${KERNEL_BUILD_LOG}" \
    make -j"${JOBS}" O="${KERNEL_OUT}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" "${KERNEL_IMAGE_NAME}" modules dtbs

run_task "KERNEL" "install modules" "${KERNEL_BUILD_LOG}" \
    make O="${KERNEL_OUT}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" INSTALL_MOD_PATH="${ROOTFS_OUT}" INSTALL_MOD_STRIP=1 modules_install

if [ ! -f "${IMAGE_PATH}" ]; then
    die "Kernel image not found: ${IMAGE_PATH}"
fi
cp -f "${IMAGE_PATH}" "${BOOT_OUT}/${KERNEL_IMAGE_NAME}"

if [[ -n "${KERNEL_DTB:-}" ]]; then
    TARGET_DTB="${DTB_ROOT}/${KERNEL_DTB}"
    if [ ! -f "${TARGET_DTB}" ]; then
        die "Target DTB not found: ${TARGET_DTB}"
    fi
    cp -f "${TARGET_DTB}" "${BOOT_OUT}/$(basename "${KERNEL_DTB}")"
else
    if [[ -d "${DTB_ROOT}/rockchip" ]]; then
        find "${DTB_ROOT}/rockchip" -maxdepth 1 -type f -name '*.dtb' -exec cp -f {} "${BOOT_OUT}/" \;
    fi
fi

DTB_BASENAME=$(basename "${KERNEL_DTB}")
cat <<EOF > "${BOOT_OUT}/extlinux/extlinux.conf"
label ${SUITE} (${KERNEL_IMPL} kernel)
    kernel /${KERNEL_IMAGE_NAME}
    fdt /${DTB_BASENAME}
    append ${KERNEL_CMDLINE}
EOF

msg "Kernel build finished successfully!"