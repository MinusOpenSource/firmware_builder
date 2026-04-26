#!/usr/bin/env bash
set -eE
trap 'echo -e "\033[1;31m[ERR ]\033[0m Error in $0 on line $LINENO" >&2' ERR

if [ "$(id -u)" -ne 0 ]; then
    echo -e "\033[1;31m[ERR ]\033[0m Please run as root." >&2
    exit 1
fi

if [ -z "${TARGET_PRODUCT}" ]; then
    echo -e "\033[1;31m[ERR ]\033[0m TARGET_PRODUCT is not set. Please run 'lunch' first." >&2
    exit 1
fi

# Initial base environment
: "${TARGET_SUITE:?TARGET_SUITE is not set}"
: "${ROOTFS_ARCH:=arm64}"
: "${ROOTFS_BUILD_DIR:?ROOTFS_BUILD_DIR is not set}"
: "${ROOTFS_TARBALL:?ROOTFS_TARBALL is not set}"
: "${ROOTFS_CLEAN_BUILD:=false}"
: "${ROOTFS_PORTS_MIRROR:=http://ports.ubuntu.com/ubuntu-ports}"
: "${ROOTFS_LOCAL_DEB_DIR:=${ROOTFS_BUILD_DIR}/local-packages}"
: "${ROOTFS_LOCAL_REPO_DIR:=${ROOTFS_BUILD_DIR}/local-repo}"
: "${KERNEL_PKG_OUT:?KERNEL_PKG_OUT is not set}"
: "${KERNEL_OUT:?KERNEL_OUT is not set}"
: "${KERNEL_DTB:?KERNEL_DTB is not set}"

HOST_DPKG_ARCH="$(dpkg --print-architecture)"
ROOTFS_CROSS_BUILD=false
if [ "${HOST_DPKG_ARCH}" != "${ROOTFS_ARCH}" ]; then
    ROOTFS_CROSS_BUILD=true
fi

LIVECD_LB_DIR="${ROOTFS_BUILD_DIR}/live-build"
if [ "${ROOTFS_CLEAN_BUILD}" = "true" ]; then
    rm -rf "${LIVECD_LB_DIR}"
else
    echo -e "\033[1;32m[INFO]\033[0m Reusing existing live-build workspace: ${LIVECD_LB_DIR}"
fi
mkdir -p "${LIVECD_LB_DIR}" && cd "${LIVECD_LB_DIR}"

echo -e "\033[1;32m[INFO]\033[0m Initializing live-build workspace..."

# Track our own livecd_rootfs
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVECD_ROOTFS_ROOT=""
LIVECD_ROOTFS_CANDIDATES=(
    "$(cd "${SCRIPT_DIR}/../../.." && pwd)/livecd_rootfs"
    "$(cd "${SCRIPT_DIR}/../.." && pwd)/livecd_rootfs"
)

for candidate in "${LIVECD_ROOTFS_CANDIDATES[@]}"; do
    if [ -d "${candidate}/live-build/auto" ]; then
        LIVECD_ROOTFS_ROOT="${candidate}"
        break
    fi
done

if [ -z "${LIVECD_ROOTFS_ROOT}" ]; then
    echo -e "\033[1;31m[ERR ]\033[0m Cannot find workspace livecd_rootfs from ${SCRIPT_DIR}" >&2
    exit 1
fi

rm -rf auto ubuntu-cpc
cp -a "${LIVECD_ROOTFS_ROOT}/live-build/auto" .
cp -a "${LIVECD_ROOTFS_ROOT}/live-build/ubuntu-cpc" .

# Reused live-build workspaces may contain exported artifacts from a previous
# run. Remove them up front so ubuntu-cpc's hard-link export step can succeed.
rm -f livecd.ubuntu-cpc.manifest \
      livecd.ubuntu-cpc.manifest-remove \
      livecd.ubuntu-cpc.kernel \
      livecd.ubuntu-cpc.initrd \
      livecd.ubuntu-cpc.kernel-* \
      livecd.ubuntu-cpc.initrd-*

if [ "${ROOTFS_CROSS_BUILD}" = "true" ]; then
    echo -e "\033[1;32m[INFO]\033[0m Cross-arch build detected (${HOST_DPKG_ARCH} -> ${ROOTFS_ARCH}); relaxing livecd-rootfs minimize-manual check."
    sed -i 's#${LIVECD_ROOTFS_ROOT}/minimize-manual chroot#${LIVECD_ROOTFS_ROOT}/minimize-manual chroot || echo "W: minimize-manual did not converge under cross-arch build; continuing"#' auto/build
fi

if [ "${ROOTFS_TRIM_UBUNTU_CPC:-false}" = "true" ]; then
    echo -e "\033[1;32m[INFO]\033[0m Trimming ubuntu-cpc seed selection to skip cloud-image and server layers."
    sed -i '/add_task install minimal standard cloud-image/c\			add_task install minimal standard' auto/config
    sed -i '/add_task install server/d' auto/config
fi

if [ "${ROOTFS_SKIP_RECOMMENDS_FIXUP:-true}" = "true" ]; then
    echo -e "\033[1;32m[INFO]\033[0m Skipping livecd-rootfs recommends fixup pass for faster rootfs iteration."
    sed -i '/echo "Installing any missing recommends"/,+2c\		echo "Skipping missing recommends fixup"' auto/build
fi

# ubuntu-cpc's auto/build unconditionally writes /etc/cloud/build.info for
# non-minimized builds. After trimming cloud layers, that directory may no
# longer exist, so create it before writing the metadata file.
sed -i '/cat > chroot\/etc\/cloud\/build.info << EOF/i\			mkdir -p chroot/etc/cloud' auto/build

# Prepare for auto config
export LIVECD_ROOTFS_ROOT
export PROJECT="ubuntu-cpc"
export SUITE="${TARGET_SUITE}"
export ARCH="${ROOTFS_ARCH}"
export IMAGEFORMAT=none
export NOW="$(date +%Y%m%d)"

# Gen basic config
lb config \
    --architecture "${ROOTFS_ARCH}" \
    --bootstrap-qemu-arch "${ROOTFS_ARCH}" \
    --bootstrap-qemu-static /usr/bin/qemu-aarch64-static \
    --archive-areas "main restricted universe multiverse" \
    --parent-archive-areas "main restricted universe multiverse" \
    --mirror-bootstrap "${ROOTFS_PORTS_MIRROR}" \
    --parent-mirror-bootstrap "${ROOTFS_PORTS_MIRROR}" \
    --mirror-chroot-security "${ROOTFS_PORTS_MIRROR}" \
    --parent-mirror-chroot-security "${ROOTFS_PORTS_MIRROR}" \
    --mirror-binary "${ROOTFS_PORTS_MIRROR}" \
    --parent-mirror-binary "${ROOTFS_PORTS_MIRROR}" \
    --mirror-binary-security "${ROOTFS_PORTS_MIRROR}" \
    --parent-mirror-binary-security "${ROOTFS_PORTS_MIRROR}" \
    --keyring-packages ubuntu-keyring \
    --linux-packages linux-image \
    --binary-images none \
    --bootappend-live ""

rm -f config/hooks/*.binary*

# Configure for packages
mkdir -p config/package-lists
cat > config/package-lists/my.list.chroot <<EOF
iptables
nftables
ufw
u-boot-menu
EOF

if [ -n "${ROOTFS_PACKAGE_LIST:-}" ]; then
    for pkg in ${ROOTFS_PACKAGE_LIST}; do
        echo "${pkg}" >> config/package-lists/my.list.chroot
    done
fi

if [ -z "${ROOTFS_LOCAL_PACKAGES:-}" ]; then
    ROOTFS_LOCAL_PACKAGES="platform-kubuntu platform-board-firmware"
elif ! printf ' %s ' "${ROOTFS_LOCAL_PACKAGES}" | grep -q ' platform-kubuntu '; then
    ROOTFS_LOCAL_PACKAGES="${ROOTFS_LOCAL_PACKAGES} platform-kubuntu"
fi

if ! printf ' %s ' "${ROOTFS_LOCAL_PACKAGES}" | grep -q ' platform-board-firmware '; then
    ROOTFS_LOCAL_PACKAGES="${ROOTFS_LOCAL_PACKAGES} platform-board-firmware"
fi

# Build and inject local custom DEB packages
if [ -n "${ROOTFS_LOCAL_PACKAGES:-}" ]; then
    echo -e "\033[1;32m[INFO]\033[0m Building local packages: ${ROOTFS_LOCAL_PACKAGES}..."
    bash "${BUILD_DIR}/packages/build_local_packages.sh" \
        "${ROOTFS_LOCAL_DEB_DIR}" ${ROOTFS_LOCAL_PACKAGES}
fi

rm -f config/archives/firmware-builder-local.list.chroot

echo -e "\033[1;32m[INFO]\033[0m Injecting local deb packages..."
mkdir -p config/includes.chroot/opt/firmware-builder/packages
rm -rf config/includes.chroot/opt/firmware-builder/packages/*
if compgen -G "${ROOTFS_LOCAL_DEB_DIR}/*.deb" > /dev/null; then
    cp -f "${ROOTFS_LOCAL_DEB_DIR}"/*.deb config/includes.chroot/opt/firmware-builder/packages/
fi

# Reused live-build workspaces keep stage stamps under .build/. Since our local
# packages and package lists may change, drop the related stamps so install
# stages are re-executed on incremental builds.
rm -f .build/chroot_package-lists.install \
      .build/chroot_install-packages.install \
      .build/chroot_package-lists.live \
      .build/chroot_install-packages.live \
      .build/chroot_includes \
      .build/chroot_hooks \
      .build/chroot_hacks

# Configure Hook
mkdir -p config/hooks
if [ "${ROOTFS_CROSS_BUILD}" = "true" ]; then
    cat > config/hooks/005-disable-py3compile.chroot_early <<'EOF'
#!/bin/sh
set -e

# Docker cross-builds execute foreign-arch binaries through the host kernel's
# binfmt_misc handler, which can crash python3.14 during py3compile. Temporarily
# stub the helpers so package configuration can complete under emulation.
for tool in py3compile pypy3compile; do
    if [ -x "/usr/bin/${tool}" ]; then
        dpkg-divert --quiet --local --rename --add "/usr/bin/${tool}"
        cat > "/usr/bin/${tool}" <<'EOS'
#!/bin/sh
exit 0
EOS
        chmod +x "/usr/bin/${tool}"
    fi
done
EOF
    chmod +x config/hooks/005-disable-py3compile.chroot_early

    cat > config/hooks/999-restore-py3compile.chroot <<'EOF'
#!/bin/sh
set -e

for tool in py3compile pypy3compile; do
    if [ -e "/usr/bin/${tool}.distrib" ]; then
        rm -f "/usr/bin/${tool}"
        dpkg-divert --quiet --rename --remove "/usr/bin/${tool}"
    fi
done
EOF
    chmod +x config/hooks/999-restore-py3compile.chroot
fi

cat > config/hooks/010-install-local.chroot <<'EOF'
#!/bin/sh
set -e
export DEBIAN_FRONTEND=noninteractive
export G_SLICE=always-malloc
export QEMU_CPU=max
export NEEDRESTART_MODE=a

echo "exit 101" > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

mkdir -p /etc/needrestart/conf.d
echo '$nrconf{restart} = "a";' > /etc/needrestart/conf.d/99-firmware-builder.conf

if ls /opt/firmware-builder/packages/*.deb >/dev/null 2>&1; then
    apt-get install -y /opt/firmware-builder/packages/*.deb
fi

rm -f /usr/sbin/policy-rc.d
EOF
chmod +x config/hooks/010-install-local.chroot

# Build
echo -e "\033[1;32m[INFO]\033[0m Starting rootfs build via live-build..."
trap - ERR
set +e
lb build
LB_BUILD_STATUS=$?
set -eE
trap 'echo -e "\033[1;31m[ERR ]\033[0m Error in $0 on line $LINENO" >&2' ERR
if [ "${LB_BUILD_STATUS}" -ne 0 ]; then
    echo -e "\033[1;31m[ERR ]\033[0m live-build failed with exit code ${LB_BUILD_STATUS}. See ${LIVECD_LB_DIR}/binary.log for details." >&2
    exit "${LB_BUILD_STATUS}"
fi

# Cleanups
chroot chroot /usr/bin/env -i \
    HOME=/root TERM="${TERM:-linux}" \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    DEBIAN_FRONTEND=noninteractive \
    /bin/bash -ec '
echo "exit 101" > /usr/sbin/policy-rc.d; chmod +x /usr/sbin/policy-rc.d
apt-get purge -y "^linux-image-.*" "^linux-modules-.*" || true
apt-get purge -y "^grub-.*" || true
apt-get purge -y cloud-init cloud-guest-utils || true
apt-get autoremove -y --purge || true
rm -rf /etc/cloud /var/lib/cloud
rm -rf /boot/grub
apt-get clean
rm -f /usr/sbin/policy-rc.d
'

ROOTFS_STAGING_DIR="chroot"

# Packing rootfs tarball
echo -e "\033[1;32m[INFO]\033[0m Packing rootfs tarball..."
if mount | grep -q " $(realpath "${ROOTFS_STAGING_DIR}")/"; then
    echo -e "\033[1;31m[ERR ]\033[0m Unsafe mounts detected in ${ROOTFS_STAGING_DIR}! Aborting pack." >&2
    exit 1
fi

mkdir -p "$(dirname "${ROOTFS_TARBALL}")"
(cd "${ROOTFS_STAGING_DIR}/" && tar -p -c --one-file-system --sort=name --xattrs .) | xz -3 -T0 > "${ROOTFS_TARBALL}"

echo -e "\033[1;32m[INFO]\033[0m Build complete! Tarball generated: ${ROOTFS_TARBALL}"
