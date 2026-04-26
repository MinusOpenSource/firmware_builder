#!/usr/bin/env bash

export TOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Sources
export BUILD_DIR="${TOP_DIR}/build"
export DEVICE_DIR="${TOP_DIR}/device"
export SUITE_DIR="${TOP_DIR}/product/suite"
export FLAVOR_DIR="${TOP_DIR}/product/flavor"
export KERNEL_SRC="${TOP_DIR}/kernel"
export UBOOT_SRC="${TOP_DIR}/u-boot"
export VENDOR_DIR="${TOP_DIR}/vendor"
export RKBIN_SRC="${RKBIN_SRC:-${VENDOR_DIR}/rockchip/rkbin}"
export OUT_DIR="${TOP_DIR}/out"

# Toolchains
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
export CC="${CROSS_COMPILE}gcc"
export ARCH=arm64
export DEB_ARCH=arm64
export DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS:-nocheck}"
export JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

# Product / rootfs defaults
export SUITE=""
export FLAVOR=""
export ROOTFS_RELEASE=""
export ROOTFS_CODENAME=""
export ROOTFS_TYPE=""
export DESKTOP_ENV=""
export ROOTFS_ARCH="${ARCH}"
export ROOTFS_MIRROR=""
export ROOTFS_PORTS_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports"
export ROOTFS_HOSTNAME=""
export ROOTFS_USERNAME=""
export ROOTFS_PASSWORD=""
export ROOTFS_LOCALES=""
export ROOTFS_TIMEZONE=""
export ROOTFS_PACKAGE_LIST=""
export ROOTFS_LOCAL_PACKAGES=""
export ROOTFS_SEEDED_SNAPS=""
export ROOTFS_BACKEND="${ROOTFS_BACKEND:-live-build}"
export DEFAULT_SUITE=""
export DEFAULT_FLAVOR=""
export LIVECD_ROOTFS_SRC="${TOP_DIR}/livecd_rootfs"

# Kernel build specific (will be overridden by device config)
export KERNEL_BASE_DEFCONFIG=""
export KERNEL_CONFIG_FRAGMENT=""
export KERNEL_IMPL="rockchip"
export KERNEL_DEB_BUILD_TARGET="${KERNEL_DEB_BUILD_TARGET:-bindeb-pkg}"
export KERNEL_DEB_PACKAGE_GLOBS="${KERNEL_DEB_PACKAGE_GLOBS:-linux-image linux-headers}"
export KERNEL_DPKG_FLAGS="${KERNEL_DPKG_FLAGS:--d}"
export KERNEL_CLEAN_BUILD="${KERNEL_CLEAN_BUILD:-true}"

# Tools
export FAKEROOT_BIN="${FAKEROOT_BIN:-fakeroot}"
export DPKG_ARCH="${DPKG_ARCH:-dpkg-architecture}"

# Helper Functions
msg()  { printf "\033[1;32m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*" >&2; }
err()  { printf "\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; }
die()  { err "$*"; exit 1; }

ensure_dir() { mkdir -p "$@"; }

show_log_tail() {
    local log_file="$1"
    local tail_lines="${2:-80}"

    [ -s "${log_file}" ] || return 0

    err "Showing the last ${tail_lines} lines from ${log_file}:"
    tail -n "${tail_lines}" "${log_file}" >&2 || true
}

run_task() {
    local project="$1"
    local task_name="$2"
    local log_file="$3"
    shift 3

    local start_seconds=$SECONDS
    local elapsed
    local minutes
    local seconds
    local rc
    local tail_lines="${BUILD_LOG_TAIL_LINES:-80}"
    local had_errexit=0
    local had_pipefail=0

    case $- in
        *e*) had_errexit=1 ;;
    esac
    if set -o | grep -q '^pipefail[[:space:]]\+on$'; then
        had_pipefail=1
    fi

    echo ""
    msg "[${project}] ${task_name}"
    ensure_dir "$(dirname "${log_file}")"
    : >> "${log_file}"

    set +e
    set -o pipefail
    "$@" 2>&1 | tee -a "${log_file}"
    rc=${PIPESTATUS[0]}
    if [ "${had_errexit}" -eq 1 ]; then
        set -e
    fi
    if [ "${had_pipefail}" -eq 0 ]; then
        set +o pipefail
    fi

    elapsed=$((SECONDS - start_seconds))
    minutes=$((elapsed / 60))
    seconds=$((elapsed % 60))

    if [ "${rc}" -ne 0 ]; then
        err "[${project}] ${task_name} failed after ${minutes}m${seconds}s (exit ${rc}). Full log: ${log_file}"
        show_log_tail "${log_file}" "${tail_lines}"
        return "${rc}"
    fi

    msg "[${project}] ${task_name} completed in ${minutes}m${seconds}s"
}

export -f msg warn err die ensure_dir show_log_tail run_task

check_toolchain() {
    if ! command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1; then
        warn "Cross compiler '${CROSS_COMPILE}gcc' not found in PATH."
    fi
}

check_build_tools() {
    local missing_tools=()
    
    for tool in "${FAKEROOT_BIN}" "${DPKG_ARCH}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$(basename "$tool")")
        fi
    done
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        warn "Missing build tools: ${missing_tools[*]}"
        warn "Please install: sudo apt-get install build-essential fakeroot dpkg-dev"
    fi
}

check_kernel_build_tools() {
    local missing_tools=()
    local tool

    for tool in bc rsync kmod; do
        if ! command -v "${tool}" >/dev/null 2>&1; then
            missing_tools+=("${tool}")
        fi
    done

    if [ ${#missing_tools[@]} -ne 0 ]; then
        die "Missing kernel build tools: ${missing_tools[*]}. Please install them before running 'm kernel'."
    fi
}

check_kernel_build_packages() {
    local missing_packages=()
    local package

    for package in libssl-dev; do
        if ! dpkg-query -W -f='${Status}\n' "${package}" 2>/dev/null | grep -q "install ok installed"; then
            missing_packages+=("${package}")
        fi
    done

    if [ ${#missing_packages[@]} -ne 0 ]; then
        die "Missing kernel build packages: ${missing_packages[*]}. Please install them before running 'm kernel'."
    fi
}

export -f check_kernel_build_tools check_kernel_build_packages

check_loader_build_tools() {
    local missing_tools=()
    local tool

    for tool in swig python3 openssl; do
        if ! command -v "${tool}" >/dev/null 2>&1; then
            missing_tools+=("${tool}")
        fi
    done

    if [ ${#missing_tools[@]} -ne 0 ]; then
        die "Missing loader build tools: ${missing_tools[*]}. Please install them before running 'm loader' (Ubuntu/Debian: sudo apt install swig python3 openssl)."
    fi
}

check_loader_build_packages() {
    local missing_packages=()
    local package

    for package in python3-dev python3-pyelftools; do
        if ! dpkg-query -W -f='${Status}\n' "${package}" 2>/dev/null | grep -q "install ok installed"; then
            missing_packages+=("${package}")
        fi
    done

    if [ ${#missing_packages[@]} -ne 0 ]; then
        die "Missing loader build packages: ${missing_packages[*]}. Please install them before running 'm loader'."
    fi
}

export -f check_loader_build_tools check_loader_build_packages

check_rootfs_build_tools() {
    local missing_tools=()
    local tool

    for tool in qemu-aarch64-static wget python3 grep-aptavail dpkg-scanpackages; do
        if ! command -v "${tool}" >/dev/null 2>&1; then
            missing_tools+=("${tool}")
        fi
    done

    if [ "${ROOTFS_BACKEND:-live-build}" = "live-build" ]; then
        for tool in lb germinate; do
            if ! command -v "${tool}" >/dev/null 2>&1; then
                missing_tools+=("${tool}")
            fi
        done
    else
        if ! command -v debootstrap >/dev/null 2>&1; then
            missing_tools+=("debootstrap")
        fi
    fi

    if [ ${#missing_tools[@]} -ne 0 ]; then
        die "Missing rootfs build tools: ${missing_tools[*]}. Please install the required packages before running 'm rootfs' (Ubuntu/Debian: sudo apt install live-build germinate qemu-user-static wget python3 dctrl-tools python3-yaml debootstrap dpkg-dev)."
    fi

    if ! python3 -c 'import yaml' >/dev/null 2>&1; then
        die "Missing Python module 'yaml' for rootfs build. Please install python3-yaml before running 'm rootfs'."
    fi
}

export -f check_rootfs_build_tools

setup_dpkg_architecture() {
    if command -v "${DPKG_ARCH}" >/dev/null 2>&1; then
        eval "$("${DPKG_ARCH}")" 2>/dev/null || true
    fi
}

setup_kernel_paths() {
    export KBUILD_OUTPUT="${KERNEL_OUT}"
    export KCONFIG_CONFIG="${KERNEL_OUT}/.config"
    export KERNEL_PKG_OUT="${TARGET_OUT_DIR}/packages/kernel"
    export KERNEL_PACKAGE_MANIFEST="${KERNEL_PKG_OUT}/packages.txt"
    export KERNEL_BUILD_LOG="${TARGET_OUT_DIR}/logs/kernel_build.log"
}

setup_rootfs_paths() {
    export ROOTFS_BUILD_DIR="${TARGET_OUT_DIR}/obj/rootfs"
    export ROOTFS_ARTIFACT_DIR="${TARGET_OUT_DIR}/packages/rootfs"
    export ROOTFS_BUILD_LOG="${TARGET_OUT_DIR}/logs/rootfs_build.log"
    export ROOTFS_TARBALL="${ROOTFS_ARTIFACT_DIR}/ubuntu-${ROOTFS_RELEASE}-preinstalled-${TARGET_FLAVOR}-${ROOTFS_ARCH}.rootfs.tar.xz"
}

for f in $(find "${DEVICE_DIR}" -name "*.env.sh" 2>/dev/null); do
    source "$f"
done

lunch() {
    local device_target=$1
    local suite_target=$2
    local flavor_target=$3

    local configs=()
    for f in $(find "${DEVICE_DIR}" -type f -name "*.mk" 2>/dev/null); do
        configs+=("$(basename "$f" .mk)")
    done

    if [ -z "$device_target" ]; then
        msg "Lunch menu... pick a board:"
        select device_target in "${configs[@]}"; do
            [ -n "$device_target" ] && break
        done
    fi

    local device_config
    local suite_config
    local flavor_config

    device_config=$(find "${DEVICE_DIR}" -name "${device_target}.mk" 2>/dev/null | head -n 1)
    if [ -z "$device_config" ]; then
        err "Device spec not found for: '$device_target'"
        return 1
    fi

    if [ -z "${suite_target}" ] || [ -z "${flavor_target}" ]; then
        local detected_defaults
        detected_defaults="$(
            set -a
            source "${device_config}"
            printf '%s;%s' "${DEFAULT_SUITE:-}" "${DEFAULT_FLAVOR:-}"
        )"
        if [ -z "${suite_target}" ]; then
            suite_target="${detected_defaults%%;*}"
        fi
        if [ -z "${flavor_target}" ]; then
            flavor_target="${detected_defaults#*;}"
        fi
    fi

    if [ -z "${suite_target}" ] || [ -z "${flavor_target}" ]; then
        err "No suite/flavor selected. Use 'lunch <device> <suite> <flavor>' or define DEFAULT_SUITE and DEFAULT_FLAVOR in the device config."
        return 1
    fi

    suite_config=$(find "${SUITE_DIR}" -name "${suite_target}.mk" 2>/dev/null | head -n 1)
    if [ -z "${suite_config}" ]; then
        err "Suite profile not found for: '$suite_target'"
        return 1
    fi

    flavor_config=$(find "${FLAVOR_DIR}" -name "${flavor_target}.mk" 2>/dev/null | head -n 1)
    if [ -z "${flavor_config}" ]; then
        err "Flavor profile not found for: '$flavor_target'"
        return 1
    fi

    export TARGET_DEVICE="${device_target}"
    export TARGET_PRODUCT="${device_target}"
    export TARGET_SUITE="${suite_target}"
    export TARGET_FLAVOR="${flavor_target}"
    set -a
    source "$suite_config"
    source "$flavor_config"
    source "$device_config"
    set +a

    export DEVICE_CONFIG_DIR="$(dirname "$device_config")"

    export TARGET_OUT_DIR="${OUT_DIR}/target/product/${TARGET_PRODUCT}"
    export KERNEL_OUT="${TARGET_OUT_DIR}/obj/kernel"
    export UBOOT_OUT="${TARGET_OUT_DIR}/obj/uboot"
    export IMAGE_OUT="${TARGET_OUT_DIR}/image"
    export LOADER_OUT="${TARGET_OUT_DIR}/loader"

    setup_kernel_paths
    setup_rootfs_paths
    ensure_dir "${KERNEL_OUT}" "${UBOOT_OUT}" "${IMAGE_OUT}" "${LOADER_OUT}"
    ensure_dir "${KERNEL_PKG_OUT}" "${ROOTFS_BUILD_DIR}" "${ROOTFS_ARTIFACT_DIR}" "${TARGET_OUT_DIR}/logs"
    check_toolchain
    check_build_tools
    setup_dpkg_architecture

    cat <<EOF
============================================
TARGET_PRODUCT=$TARGET_PRODUCT
TARGET_DEVICE=$TARGET_DEVICE
TARGET_SUITE=$TARGET_SUITE
TARGET_FLAVOR=$TARGET_FLAVOR
TARGET_OUT_DIR=$TARGET_OUT_DIR
ARCH=$ARCH
CROSS_COMPILE=$CROSS_COMPILE
CC=$CC
DEB_ARCH=$DEB_ARCH
ROOTFS_RELEASE=$ROOTFS_RELEASE
ROOTFS_CODENAME=$ROOTFS_CODENAME
ROOTFS_TYPE=$ROOTFS_TYPE
DESKTOP_ENV=$DESKTOP_ENV
ROOTFS_BUILD_DIR=$ROOTFS_BUILD_DIR
ROOTFS_ARTIFACT_DIR=$ROOTFS_ARTIFACT_DIR
ROOTFS_TARBALL=$ROOTFS_TARBALL
KBUILD_OUTPUT=$KBUILD_OUTPUT
KCONFIG_CONFIG=$KCONFIG_CONFIG
KERNEL_PKG_OUT=$KERNEL_PKG_OUT
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
        bash "${BUILD_DIR}/core/main.sh" "$@"
    fi
}

msg "Environment setup script loaded. Run 'lunch' to begin."
