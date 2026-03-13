#!/usr/bin/env bash

export TOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Sources
export BUILD_DIR="${TOP_DIR}/build"
export DEVICE_DIR="${TOP_DIR}/device"
export KERNEL_SRC="${TOP_DIR}/kernel"
export UBOOT_SRC="${TOP_DIR}/u-boot"
export EXTERNAL_DIR="${TOP_DIR}/external"
export RKBIN_SRC="${EXTERNAL_DIR}/rkbin"
export OUT_DIR="${TOP_DIR}/out"

# Toolchains
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
export ARCH=arm64
export DEB_ARCH=arm64
export JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

# Tools
export MKIMAGE_BIN="${MKIMAGE_BIN:-mkimage}"
export DTC_BIN="${DTC_BIN:-dtc}"
export PARTED_BIN="${PARTED_BIN:-parted}"

# Helper Functions
msg()  { printf "\033[1;32m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*" >&2; }
err()  { printf "\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; }
die()  { err "$*"; exit 1; }

ensure_dir() { mkdir -p "$@"; }

check_toolchain() {
    if ! command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1; then
        warn "Cross compiler '${CROSS_COMPILE}gcc' not found in PATH."
    fi
}

export LUNCH_MENU_CHOICES=""

add_lunch_combo() {
    export LUNCH_MENU_CHOICES="${LUNCH_MENU_CHOICES} $1"
}

for f in $(find "${DEVICE_DIR}" -name "*.sh" 2>/dev/null); do
    source "$f"
done

lunch() {
    local target=$1

    local configs=()
    for f in $(find "${DEVICE_DIR}" -type f -name "*.mk" 2>/dev/null); do
        configs+=("$(basename "$f" .mk)")
    done

    if [ -z "$target" ]; then
        msg "Lunch menu... pick a board:"
        select target in "${configs[@]}"; do
            [ -n "$target" ] && break
        done
    fi

    local product_config=$(find "${DEVICE_DIR}" -name "${target}.mk" 2>/dev/null | head -n 1)
    if [ -z "$product_config" ]; then
        err "Product spec not found for: '$target'"
        return 1
    fi

    export TARGET_PRODUCT="$target"
    set -a
    source "$product_config"
    set +a

    export TARGET_OUT_DIR="${OUT_DIR}/target/product/${TARGET_PRODUCT}"
    export KERNEL_OUT="${TARGET_OUT_DIR}/obj/kernel"
    export UBOOT_OUT="${TARGET_OUT_DIR}/obj/uboot"
    export BOOT_OUT="${TARGET_OUT_DIR}/boot"
    export ROOTFS_OUT="${TARGET_OUT_DIR}/rootfs"
    export IMAGE_OUT="${TARGET_OUT_DIR}/image"

    ensure_dir "${KERNEL_OUT}" "${UBOOT_OUT}" "${BOOT_OUT}" "${ROOTFS_OUT}" "${IMAGE_OUT}"
    check_toolchain

    cat <<EOF
============================================
TARGET_PRODUCT=$TARGET_PRODUCT
TARGET_OUT_DIR=$TARGET_OUT_DIR
ARCH=$ARCH
CROSS_COMPILE=$CROSS_COMPILE
============================================
EOF
}

m() {
    local target=$1
    if [ -z "$TARGET_PRODUCT" ]; then
        err "Please run 'lunch' first."
        return 1
    fi

    if [ -z "$target" ]; then
        bash "${BUILD_DIR}/core/main.sh" all
    else
        bash "${BUILD_DIR}/core/main.sh" "$target"
    fi
}

msg "Environment setup script loaded. Run 'lunch' to begin."