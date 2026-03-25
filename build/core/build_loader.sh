#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MY_ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ROOT_DIR="${ROOT_DIR:-$MY_ROOT_DIR}"

if [ -z "${TARGET_PRODUCT}" ]; then
    echo -e "\033[1;31m[ERR ]\033[0m TARGET_PRODUCT is not set." >&2
    exit 1
fi

: "${UBOOT_DEFCONFIG:?UBOOT_DEFCONFIG is not set in mk file}"
: "${UBOOT_SRC:?UBOOT_SRC is not set in envsetup}"

LOG_OUT="${TARGET_OUT_DIR}/logs"
UBOOT_BUILD_LOG="${LOG_OUT}/uboot_build.log"

ensure_dir "${LOG_OUT}" "${UBOOT_OUT}" "${LOADER_OUT}"
cd "${UBOOT_SRC}"
rm -rf "${UBOOT_OUT:?}"/*

check_loader_build_tools
check_loader_build_packages

msg "Building U-Boot for ${TARGET_BOARD}"

run_task "LOADER" "make defconfig" "${UBOOT_BUILD_LOG}" \
    make O="${UBOOT_OUT}" CROSS_COMPILE="${CROSS_COMPILE}" "${UBOOT_DEFCONFIG}"

if [[ -n "${RK_TPL_BIN}" && -n "${RK_BL31_ELF}" ]]; then
    : "${RKBIN:=${RKBIN_SRC#${ROOT_DIR}/}}"
    : "${RKBIN:=vendor/rockchip/rkbin}"
    
    ABS_RKBIN_DIR="${ROOT_DIR}/${RKBIN}"
    TPL_PATH="${ROOT_DIR}/${RK_TPL_BIN}"
    BL31_PATH="${ROOT_DIR}/${RK_BL31_ELF}"

    if [ ! -d "${ABS_RKBIN_DIR}" ]; then
        msg "rkbin not found. Auto-cloning..."
        ensure_dir "$(dirname "${ABS_RKBIN_DIR}")"
        git clone --depth 1 https://github.com/rockchip-linux/rkbin.git "${ABS_RKBIN_DIR}" || die "Failed to clone rkbin."
    fi

    [ ! -f "${TPL_PATH}" ] && die "TPL firmware missing: ${TPL_PATH}"
    [ ! -f "${BL31_PATH}" ] && die "BL31 firmware missing: ${BL31_PATH}"

    msg "Detected Rockchip Platform. Injecting blobs:"
    msg "  TPL  -> ${RK_TPL_BIN}"
    msg "  BL31 -> ${RK_BL31_ELF}"

    run_task "LOADER" "build idbloader & itb" "${UBOOT_BUILD_LOG}" \
        make -j"${JOBS}" O="${UBOOT_OUT}" CROSS_COMPILE="${CROSS_COMPILE}" \
        BL31="${BL31_PATH}" \
        ROCKCHIP_TPL="${TPL_PATH}" \
        all

    cp -f "${UBOOT_OUT}/idbloader.img" "${LOADER_OUT}/"
    cp -f "${UBOOT_OUT}/u-boot.itb" "${LOADER_OUT}/"
    if [ -f "${UBOOT_OUT}/u-boot-rockchip.bin" ]; then
        cp -f "${UBOOT_OUT}/u-boot-rockchip.bin" "${LOADER_OUT}/"
    fi

else
    msg "Detected Generic Platform. Building standard U-Boot..."
    run_task "LOADER" "build all" "${UBOOT_BUILD_LOG}" \
        make -j"${JOBS}" O="${UBOOT_OUT}" CROSS_COMPILE="${CROSS_COMPILE}" all

    if [ -f "${UBOOT_OUT}/u-boot.img" ]; then
        cp -f "${UBOOT_OUT}/u-boot.img" "${LOADER_OUT}/"
    elif [ -f "${UBOOT_OUT}/u-boot.bin" ]; then
        cp -f "${UBOOT_OUT}/u-boot.bin" "${LOADER_OUT}/"
    fi
fi

msg "U-Boot build finished successfully!"
