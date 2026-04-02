#!/usr/bin/env bash
set -e

if [ -z "${TARGET_PRODUCT}" ]; then
    echo -e "\033[1;31m[ERR ]\033[0m TARGET_PRODUCT is not set." >&2
    exit 1
fi

if [ -z "${KERNEL_BASE_DEFCONFIG}" ]; then
    die "KERNEL_BASE_DEFCONFIG is not set."
fi

: "${TARGET_OUT_DIR:?TARGET_OUT_DIR is not set}"
: "${KERNEL_SRC:?KERNEL_SRC is not set}"
: "${KERNEL_OUT:?KERNEL_OUT is not set}"
: "${FAKEROOT_BIN:=fakeroot}"
: "${DPKG_ARCH:=dpkg-architecture}"
: "${KBUILD_OUTPUT:?KBUILD_OUTPUT is not set}"
: "${KCONFIG_CONFIG:?KCONFIG_CONFIG is not set}"
: "${KERNEL_PKG_OUT:?KERNEL_PKG_OUT is not set}"
: "${KERNEL_PACKAGE_MANIFEST:?KERNEL_PACKAGE_MANIFEST is not set}"
: "${KERNEL_BUILD_LOG:?KERNEL_BUILD_LOG is not set}"
: "${KERNEL_DEB_BUILD_TARGET:?KERNEL_DEB_BUILD_TARGET is not set}"
: "${KERNEL_DEB_PACKAGE_GLOBS:?KERNEL_DEB_PACKAGE_GLOBS is not set}"
: "${KERNEL_DPKG_FLAGS:=}"
: "${KERNEL_CLEAN_BUILD:=true}"
: "${DEB_BUILD_OPTIONS:=nocheck}"
: "${JOBS:=1}"

ensure_dir "${TARGET_OUT_DIR}/logs" "${KERNEL_OUT}" "${KERNEL_PKG_OUT}"

msg "Building kernel packages for ${TARGET_BOARD}"
msg "Kernel source      : ${KERNEL_SRC}"
msg "Kernel output      : ${KERNEL_OUT}"
msg "Kernel package out : ${KERNEL_PKG_OUT}"
msg "Base defconfig     : ${KERNEL_BASE_DEFCONFIG}"
msg "Build target       : ${KERNEL_DEB_BUILD_TARGET}"
msg "Clean build        : ${KERNEL_CLEAN_BUILD}"
msg "DPKG flags         : ${KERNEL_DPKG_FLAGS:-<none>}"
msg "Architecture       : ${ARCH}"
msg "Cross compiler     : ${CROSS_COMPILE}"
msg "Deb architecture   : ${DEB_ARCH}"
msg "Log file           : ${KERNEL_BUILD_LOG}"

if [ -z "${ARCH}" ]; then
    die "ARCH not set. Please run 'lunch' first."
fi
if [ -z "${CROSS_COMPILE}" ]; then
    die "CROSS_COMPILE not set. Please run 'lunch' first."
fi

if [ ! -d "${KERNEL_SRC}" ]; then
    die "Kernel source directory not found: ${KERNEL_SRC}"
fi

if [ ! -f "${KERNEL_SRC}/Makefile" ]; then
    die "Missing ${KERNEL_SRC}/Makefile. The current kernel source tree is incomplete."
fi

check_kernel_build_tools
check_kernel_build_packages

> "${KERNEL_BUILD_LOG}"
cd "${KERNEL_SRC}"

export ARCH CROSS_COMPILE CC DEB_ARCH

KDEB_PKGVERSION_DEFAULT="$(date +%Y%m%d)-${TARGET_BOARD}"
if [[ ! "${KDEB_PKGVERSION_DEFAULT}" =~ ^[0-9] ]]; then
    KDEB_PKGVERSION_DEFAULT="1${KDEB_PKGVERSION_DEFAULT}"
fi
export KDEB_PKGVERSION="${KDEB_PKGVERSION:-${KDEB_PKGVERSION_DEFAULT}}"

msg "Package version    : ${KDEB_PKGVERSION}"

prepare_kernel_config() {
    local fragment_raw="${KERNEL_CONFIG_FRAGMENT:-}"
    local fragment
    local -a fragments=()
    local merge_script="${KERNEL_SRC}/scripts/kconfig/merge_config.sh"

    if [ ! -x "${merge_script}" ]; then
        die "Missing merge_config.sh: ${merge_script}"
    fi

    msg "Preparing kernel config in ${KERNEL_OUT}"
    run_task "KERNEL" "base defconfig" "${KERNEL_BUILD_LOG}" \
        make -C "${KERNEL_SRC}" O="${KERNEL_OUT}" ARCH="${ARCH}" \
        CROSS_COMPILE="${CROSS_COMPILE}" "${KERNEL_BASE_DEFCONFIG}"

    if [ -n "${fragment_raw}" ]; then
        for fragment in ${fragment_raw//,/ }; do
            [ -n "${fragment}" ] || continue
            [ -f "${fragment}" ] || die "Kernel config fragment not found: ${fragment}"
            fragments+=("${fragment}")
        done
    fi

    if [ ${#fragments[@]} -gt 0 ]; then
        msg "Merging kernel config fragments"
        run_task "KERNEL" "merge fragments" "${KERNEL_BUILD_LOG}" \
            "${merge_script}" -m -O "${KERNEL_OUT}" "${KCONFIG_CONFIG}" "${fragments[@]}"
        run_task "KERNEL" "olddefconfig" "${KERNEL_BUILD_LOG}" \
            make -C "${KERNEL_SRC}" O="${KERNEL_OUT}" ARCH="${ARCH}" \
            CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig
    fi

    cp -f "${KCONFIG_CONFIG}" "${KERNEL_OUT}/kernel.config"
}

collect_kernel_packages() {
    local search_dir
    local package
    local package_name
    local dest_package
    local found=0

    : > "${KERNEL_PACKAGE_MANIFEST}"
    rm -f "${KERNEL_PKG_OUT}"/*.deb "${KERNEL_PKG_OUT}"/*.buildinfo "${KERNEL_PKG_OUT}"/*.changes

    for search_dir in \
        "${KERNEL_OUT}/.." \
        "${KERNEL_OUT}" \
        "${TARGET_OUT_DIR}" \
        "${KERNEL_SRC}/.." \
        "${KERNEL_SRC}"
    do
        [ -d "${search_dir}" ] || continue
        while IFS= read -r package; do
            package_name="$(basename "${package}")"
            dest_package="${KERNEL_PKG_OUT}/${package_name}"
            if [ "$(readlink -f "${package}")" != "$(readlink -f "${dest_package}")" ]; then
                mv -f "${package}" "${dest_package}"
            fi
            printf "%s\n" "${dest_package}" >> "${KERNEL_PACKAGE_MANIFEST}"
            found=1
        done < <(find "${search_dir}" -maxdepth 1 -type f \( -name "*.deb" -o -name "*.buildinfo" -o -name "*.changes" \) | sort)
    done

    if [ "${found}" -eq 0 ]; then
        die "No kernel .deb packages were found after the build."
    fi

    sort -u -o "${KERNEL_PACKAGE_MANIFEST}" "${KERNEL_PACKAGE_MANIFEST}"
}

case "${KERNEL_CLEAN_BUILD}" in
    1|true|TRUE|yes|YES|y|Y)
        run_task "KERNEL" "mrproper" "${KERNEL_BUILD_LOG}" \
            make -C "${KERNEL_SRC}" O="${KERNEL_OUT}" ARCH="${ARCH}" \
            CROSS_COMPILE="${CROSS_COMPILE}" mrproper
        ;;
    0|false|FALSE|no|NO|n|N)
        msg "Skipping kernel clean step"
        ;;
    *)
        die "Invalid KERNEL_CLEAN_BUILD value: ${KERNEL_CLEAN_BUILD}"
        ;;
esac

prepare_kernel_config

run_task "KERNEL" "build packages" "${KERNEL_BUILD_LOG}" \
    env ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" CC="${CC}" \
    KDEB_PKGVERSION="${KDEB_PKGVERSION}" \
    KBUILD_OUTPUT="${KBUILD_OUTPUT}" KCONFIG_CONFIG="${KCONFIG_CONFIG}" \
    DPKG_FLAGS="${KERNEL_DPKG_FLAGS}" \
    DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS}" \
    make -C "${KERNEL_SRC}" O="${KERNEL_OUT}" -j"${JOBS}" \
    ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" \
    "${KERNEL_DEB_BUILD_TARGET}"

collect_kernel_packages

msg "Generated packages in ${KERNEL_PKG_OUT}:"
ls -la "${KERNEL_PKG_OUT}"/*.deb 2>/dev/null || warn "No .deb packages found in ${KERNEL_PKG_OUT}"

MISSING_PACKAGES=()
for pkg in ${KERNEL_DEB_PACKAGE_GLOBS}; do
    if ! ls "${KERNEL_PKG_OUT}/${pkg}"*.deb >/dev/null 2>&1; then
        MISSING_PACKAGES+=("${pkg}")
    fi
done

if [ ${#MISSING_PACKAGES[@]} -ne 0 ]; then
    die "Missing expected kernel packages: ${MISSING_PACKAGES[*]}"
fi

msg "Kernel package build finished successfully."
