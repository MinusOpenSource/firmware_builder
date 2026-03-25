#!/usr/bin/env bash
set -e

if [ -z "${TARGET_PRODUCT}" ]; then
    echo -e "\033[1;31m[ERR ]\033[0m TARGET_PRODUCT is not set. Please run 'lunch' first." >&2
    exit 1
fi

: "${TARGET_DEVICE:?TARGET_DEVICE is not set}"
: "${TARGET_SUITE:?TARGET_SUITE is not set}"
: "${TARGET_FLAVOR:?TARGET_FLAVOR is not set}"
: "${ROOTFS_RELEASE:?ROOTFS_RELEASE is not set}"
: "${ROOTFS_CODENAME:?ROOTFS_CODENAME is not set}"
: "${ROOTFS_TYPE:?ROOTFS_TYPE is not set}"
: "${ROOTFS_ARCH:?ROOTFS_ARCH is not set}"
: "${ROOTFS_BUILD_DIR:?ROOTFS_BUILD_DIR is not set}"
: "${ROOTFS_ARTIFACT_DIR:?ROOTFS_ARTIFACT_DIR is not set}"
: "${ROOTFS_BUILD_LOG:?ROOTFS_BUILD_LOG is not set}"
: "${ROOTFS_TARBALL:?ROOTFS_TARBALL is not set}"
: "${ROOTFS_LOCAL_DEB_DIR:=${ROOTFS_BUILD_DIR}/local-packages}"

ensure_dir "${ROOTFS_BUILD_DIR}" "${ROOTFS_ARTIFACT_DIR}" "${ROOTFS_LOCAL_DEB_DIR}" "$(dirname "${ROOTFS_BUILD_LOG}")"

msg "Building rootfs for ${TARGET_DEVICE}"
msg "Suite             : ${TARGET_SUITE} (${ROOTFS_RELEASE}/${ROOTFS_CODENAME})"
msg "Flavor            : ${TARGET_FLAVOR}"
msg "Type              : ${ROOTFS_TYPE}"
msg "Architecture      : ${ROOTFS_ARCH}"
msg "Build dir         : ${ROOTFS_BUILD_DIR}"
msg "Local package dir : ${ROOTFS_LOCAL_DEB_DIR}"
msg "Artifact          : ${ROOTFS_TARBALL}"
msg "Log file          : ${ROOTFS_BUILD_LOG}"

> "${ROOTFS_BUILD_LOG}"

if [ -n "${ROOTFS_LOCAL_PACKAGES:-}" ]; then
    msg "Building local rootfs packages: ${ROOTFS_LOCAL_PACKAGES}"
    run_task "ROOTFS" "local-packages" "${ROOTFS_BUILD_LOG}" \
        bash "${BUILD_DIR}/packages/build_local_packages.sh" "${ROOTFS_LOCAL_DEB_DIR}" ${ROOTFS_LOCAL_PACKAGES}
else
    msg "No local rootfs packages requested"
fi

run_task "ROOTFS" "livecd-rootfs" "${ROOTFS_BUILD_LOG}" \
    bash "${BUILD_DIR}/rootfs/livecd-rootfs.sh"

msg "Rootfs build stage finished."
