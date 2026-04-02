#!/usr/bin/env bash

set -e

if [ -z "${TARGET_PRODUCT}" ]; then
    echo "build/core/main.sh: error: TARGET_PRODUCT is not set." >&2
    echo "You must run 'source build/envsetup.sh' and 'lunch' before running this command." >&2
    exit 1
fi

MAKECMDGOALS=$1
BUILD_VARIANT=$2
if [ -z "${MAKECMDGOALS}" ]; then
    MAKECMDGOALS="all"
fi

cat <<EOF
============================================
TARGET_PRODUCT=${TARGET_PRODUCT}
TARGET_ARCH=${TARGET_ARCH}
HOST_ARCH=$(uname -m)
HOST_OS=$(uname -s)
OUT_DIR=${TARGET_OUT_DIR}
============================================
EOF

START_TIME=$(date +%s)

clean_kernel_artifacts() {
    echo "Cleaning kernel artifacts under ${KERNEL_OUT} and ${KERNEL_PKG_OUT}"
    rm -rf "${KERNEL_OUT}" "${KERNEL_PKG_OUT}"
    rm -f "${KERNEL_BUILD_LOG}" "${KERNEL_PACKAGE_MANIFEST}"
}

clean_rootfs_artifacts() {
    echo "Cleaning rootfs artifacts under ${ROOTFS_BUILD_DIR} and ${ROOTFS_ARTIFACT_DIR}"
    rm -rf "${ROOTFS_BUILD_DIR}" "${ROOTFS_ARTIFACT_DIR}" "${ROOTFS_BUILD_LOG}" "${ROOTFS_TARBALL}"
}

clean_loader_artifacts() {
    echo "Cleaning loader artifacts under ${UBOOT_OUT} and ${LOADER_OUT}"
    rm -rf "${UBOOT_OUT}" "${LOADER_OUT}"
    rm -f "${TARGET_OUT_DIR}/logs/uboot_build.log"
}

clean_image_artifacts() {
    echo "Cleaning image artifacts under ${IMAGE_OUT}"
    rm -rf "${IMAGE_OUT}"
}

case "${MAKECMDGOALS}" in
    loader)
        echo "[100%] Building loader (U-Boot & rkbin)..."
        case "${BUILD_VARIANT}" in
            "")
                bash "${BUILD_DIR}/core/build_loader.sh"
                ;;
            clean)
                clean_loader_artifacts
                exit 0
                ;;
            rebuild)
                clean_loader_artifacts
                bash "${BUILD_DIR}/core/build_loader.sh"
                ;;
            noclean)
                UBOOT_CLEAN_BUILD=false bash "${BUILD_DIR}/core/build_loader.sh"
                ;;
            *)
                echo "Unknown loader build variant: '${BUILD_VARIANT}'" >&2
                echo "Supported variants: clean, rebuild, noclean" >&2
                exit 1
                ;;
        esac
        ;;
    kernel)
        echo "[100%] Building kernel and dtbs..."
        case "${BUILD_VARIANT}" in
            "")
                bash "${BUILD_DIR}/core/build_kernel.sh"
                ;;
            clean)
                clean_kernel_artifacts
                exit 0
                ;;
            rebuild)
                bash "${BUILD_DIR}/core/build_kernel.sh"
                ;;
            noclean)
                KERNEL_CLEAN_BUILD=false bash "${BUILD_DIR}/core/build_kernel.sh"
                ;;
            *)
                echo "Unknown kernel build variant: '${BUILD_VARIANT}'" >&2
                echo "Supported variants: clean, rebuild, noclean" >&2
                exit 1
                ;;
        esac
        ;;
    rootfs)
        echo "[100%] Building rootfs..."
        case "${BUILD_VARIANT}" in
            "")
                bash "${BUILD_DIR}/core/build_rootfs.sh"
                ;;
            clean)
                clean_rootfs_artifacts
                exit 0
                ;;
            rebuild)
                clean_rootfs_artifacts
                bash "${BUILD_DIR}/core/build_rootfs.sh"
                ;;
            noclean)
                ROOTFS_CLEAN_BUILD=false bash "${BUILD_DIR}/core/build_rootfs.sh"
                ;;
            *)
                echo "Unknown rootfs build variant: '${BUILD_VARIANT}'" >&2
                echo "Supported variants: clean, rebuild, noclean" >&2
                exit 1
                ;;
        esac
        ;;
    image)
        echo "[100%] Building final raw image..."
        case "${BUILD_VARIANT}" in
            "")
                bash "${BUILD_DIR}/core/build_image.sh"
                ;;
            clean)
                clean_image_artifacts
                exit 0
                ;;
            rebuild)
                clean_image_artifacts
                bash "${BUILD_DIR}/core/build_image.sh"
                ;;
            *)
                echo "Unknown image build variant: '${BUILD_VARIANT}'" >&2
                echo "Supported variants: clean, rebuild" >&2
                exit 1
                ;;
        esac
        ;;
    all)
        $0 loader
        $0 kernel
        $0 rootfs
        $0 image
        ;;
    clean)
        echo "Cleaning up target out dir: ${TARGET_OUT_DIR}"
        rm -rf "${TARGET_OUT_DIR}"
        bash "${BUILD_DIR}/packages/clean_local_packages.sh"
        ;;
    clobber)
        echo "Entire build directory removed: ${OUT_DIR}"
        rm -rf "${OUT_DIR}"
        ;;
    *)
        echo "make: *** No rule to make target '${MAKECMDGOALS}'.  Stop." >&2
        exit 1
        ;;
esac

END_TIME=$(date +%s)
TOTAL_SECONDS=$((END_TIME - START_TIME))
MINUTES=$((TOTAL_SECONDS / 60))
SECONDS=$((TOTAL_SECONDS % 60))

printf "#### build completed successfully (%02d:%02d) ####\n" "$MINUTES" "$SECONDS"
