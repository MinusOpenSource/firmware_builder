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

: "${TARGET_SUITE:?TARGET_SUITE is not set}"
: "${ROOTFS_ARCH:=arm64}"
: "${ROOTFS_BUILD_DIR:?ROOTFS_BUILD_DIR is not set}"
: "${ROOTFS_TARBALL:?ROOTFS_TARBALL is not set}"
: "${ROOTFS_CLEAN_BUILD:=false}"
: "${ROOTFS_PORTS_MIRROR:=http://ports.ubuntu.com/ubuntu-ports}"
: "${ROOTFS_LOCAL_DEB_DIR:=${ROOTFS_BUILD_DIR}/local-packages}"
: "${ROOTFS_LOCAL_REPO_DIR:=${ROOTFS_BUILD_DIR}/local-repo}"
: "${ROOTFS_BASE_CACHE_DIR:=${ROOTFS_BUILD_DIR}/base-cache}"
: "${BUILD_DIR:?BUILD_DIR is not set}"
: "${ROOTFS_RELEASE:?ROOTFS_RELEASE is not set}"

HOST_DPKG_ARCH="$(dpkg --print-architecture)"
ROOTFS_CROSS_BUILD=false
if [ "${HOST_DPKG_ARCH}" != "${ROOTFS_ARCH}" ]; then
    ROOTFS_CROSS_BUILD=true
fi

for tool in dpkg-scanpackages wget tar; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo -e "\033[1;31m[ERR ]\033[0m Missing required tool for base rootfs: ${tool}" >&2
        exit 1
    fi
done

QEMU_STATIC=""
if [ "${ROOTFS_CROSS_BUILD}" = "true" ]; then
    QEMU_STATIC="qemu-${ROOTFS_ARCH}-static"
    if ! command -v "${QEMU_STATIC}" >/dev/null 2>&1; then
        echo -e "\033[1;31m[ERR ]\033[0m Missing required tool for cross rootfs build: ${QEMU_STATIC}" >&2
        exit 1
    fi
fi

ROOTFS_BASE_DIR="${ROOTFS_BUILD_DIR}/base-rootfs"
if [ "${ROOTFS_CLEAN_BUILD}" = "true" ]; then
    rm -rf "${ROOTFS_BASE_DIR}" "${ROOTFS_LOCAL_REPO_DIR}"
else
    echo -e "\033[1;32m[INFO]\033[0m Reusing existing base rootfs workspace: ${ROOTFS_BASE_DIR}"
fi

rm -rf "${ROOTFS_BASE_DIR}.new"
mkdir -p "${ROOTFS_BUILD_DIR}" "${ROOTFS_LOCAL_DEB_DIR}" "${ROOTFS_BASE_CACHE_DIR}"

if [ -z "${ROOTFS_LOCAL_PACKAGES:-}" ]; then
    ROOTFS_LOCAL_PACKAGES="platform-kubuntu platform-board-firmware"
elif ! printf ' %s ' "${ROOTFS_LOCAL_PACKAGES}" | grep -q ' platform-kubuntu '; then
    ROOTFS_LOCAL_PACKAGES="${ROOTFS_LOCAL_PACKAGES} platform-kubuntu"
fi

if ! printf ' %s ' "${ROOTFS_LOCAL_PACKAGES}" | grep -q ' platform-board-firmware '; then
    ROOTFS_LOCAL_PACKAGES="${ROOTFS_LOCAL_PACKAGES} platform-board-firmware"
fi

ROOTFS_BASE_PACKAGES="u-boot-menu"
if [ -n "${ROOTFS_PACKAGE_LIST:-}" ]; then
    ROOTFS_BASE_PACKAGES="${ROOTFS_BASE_PACKAGES} ${ROOTFS_PACKAGE_LIST}"
fi
ROOTFS_BASE_PACKAGES="${ROOTFS_BASE_PACKAGES} ${ROOTFS_LOCAL_PACKAGES}"

echo -e "\033[1;32m[INFO]\033[0m Building local packages: ${ROOTFS_LOCAL_PACKAGES}..."
bash "${BUILD_DIR}/packages/build_local_packages.sh" \
    "${ROOTFS_LOCAL_DEB_DIR}" ${ROOTFS_LOCAL_PACKAGES}

echo -e "\033[1;32m[INFO]\033[0m Preparing local apt repository..."
rm -rf "${ROOTFS_LOCAL_REPO_DIR}"
mkdir -p "${ROOTFS_LOCAL_REPO_DIR}"
cp -f "${ROOTFS_LOCAL_DEB_DIR}"/*.deb "${ROOTFS_LOCAL_REPO_DIR}/"
(
    cd "${ROOTFS_LOCAL_REPO_DIR}"
    dpkg-scanpackages . /dev/null > Packages
    gzip -9c Packages > Packages.gz
)

ROOTFS_BASE_TARBALL="ubuntu-base-${ROOTFS_RELEASE}-base-${ROOTFS_ARCH}.tar.gz"
ROOTFS_BASE_TARBALL_PATH="${ROOTFS_BASE_CACHE_DIR}/${ROOTFS_BASE_TARBALL}"

ubuntu_base_candidates() {
    cat <<EOF
https://cdimage.ubuntu.com/ubuntu-base/releases/${TARGET_SUITE}/release/${ROOTFS_BASE_TARBALL}
https://cdimage.ubuntu.com/ubuntu-base/releases/${TARGET_SUITE}/snapshot1/${ROOTFS_BASE_TARBALL}
https://cdimage.ubuntu.com/ubuntu-base/${TARGET_SUITE}/daily/current/${ROOTFS_BASE_TARBALL}
EOF
}

download_ubuntu_base() {
    local url

    if [ -s "${ROOTFS_BASE_TARBALL_PATH}" ]; then
        echo -e "\033[1;32m[INFO]\033[0m Using cached ubuntu-base tarball: ${ROOTFS_BASE_TARBALL_PATH}"
        return 0
    fi

    while IFS= read -r url; do
        [ -n "${url}" ] || continue
        echo -e "\033[1;32m[INFO]\033[0m Trying ubuntu-base tarball: ${url}"
        if wget -q --spider "${url}"; then
            wget -O "${ROOTFS_BASE_TARBALL_PATH}" "${url}"
            return 0
        fi
    done < <(ubuntu_base_candidates)

    echo -e "\033[1;31m[ERR ]\033[0m Unable to locate an official ubuntu-base tarball for ${TARGET_SUITE}/${ROOTFS_ARCH}." >&2
    exit 1
}

download_ubuntu_base

echo -e "\033[1;32m[INFO]\033[0m Extracting official ubuntu-base tarball..."
mkdir -p "${ROOTFS_BASE_DIR}.new"
tar -xzf "${ROOTFS_BASE_TARBALL_PATH}" -C "${ROOTFS_BASE_DIR}.new"

cat > "${ROOTFS_BASE_DIR}.new/etc/apt/sources.list" <<EOF
deb ${ROOTFS_PORTS_MIRROR} ${TARGET_SUITE} main restricted universe multiverse
deb ${ROOTFS_PORTS_MIRROR} ${TARGET_SUITE}-updates main restricted universe multiverse
deb ${ROOTFS_PORTS_MIRROR} ${TARGET_SUITE}-security main restricted universe multiverse
EOF

mkdir -p "${ROOTFS_BASE_DIR}.new/etc/apt/sources.list.d"
mkdir -p "${ROOTFS_BASE_DIR}.new/opt/firmware-builder/local-repo"
cat > "${ROOTFS_BASE_DIR}.new/etc/apt/sources.list.d/firmware-builder-local.list" <<EOF
deb [trusted=yes] file:/opt/firmware-builder/local-repo ./
EOF
cat > "${ROOTFS_BASE_DIR}.new/etc/apt/apt.conf.d/99firmware-builder-local-repo" <<'EOF'
Acquire::Languages "none";
EOF

if [ -f /etc/resolv.conf ]; then
    cp -Lf /etc/resolv.conf "${ROOTFS_BASE_DIR}.new/etc/resolv.conf"
fi

echo "${TARGET_PRODUCT}" > "${ROOTFS_BASE_DIR}.new/etc/hostname"
cat > "${ROOTFS_BASE_DIR}.new/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 ${TARGET_PRODUCT}
EOF

cat > "${ROOTFS_BASE_DIR}.new/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x "${ROOTFS_BASE_DIR}.new/usr/sbin/policy-rc.d"

CHROOT_RUNNER=()
if [ "${ROOTFS_CROSS_BUILD}" = "true" ]; then
    install -m 0755 "$(command -v "${QEMU_STATIC}")" "${ROOTFS_BASE_DIR}.new/usr/bin/${QEMU_STATIC}"
    CHROOT_RUNNER=("/usr/bin/${QEMU_STATIC}")
fi

mkdir -p "${ROOTFS_BASE_DIR}.new/dev/pts" "${ROOTFS_BASE_DIR}.new/proc" "${ROOTFS_BASE_DIR}.new/sys"
mount --bind /dev "${ROOTFS_BASE_DIR}.new/dev"
mount --bind /dev/pts "${ROOTFS_BASE_DIR}.new/dev/pts"
mount -t proc proc "${ROOTFS_BASE_DIR}.new/proc"
mount -t sysfs sysfs "${ROOTFS_BASE_DIR}.new/sys"
mount --bind "${ROOTFS_LOCAL_REPO_DIR}" "${ROOTFS_BASE_DIR}.new/opt/firmware-builder/local-repo"
if [ -f /etc/resolv.conf ]; then
    mount --bind /etc/resolv.conf "${ROOTFS_BASE_DIR}.new/etc/resolv.conf"
fi

cleanup_mounts() {
    awk -v p="${ROOTFS_BASE_DIR}.new" '$2 ~ ("^" p "(/|$)") { print $2 }' /proc/self/mounts \
        | LC_ALL=C sort -r \
        | while IFS= read -r m; do
            umount "${m}" 2>/dev/null || true
        done
}
trap cleanup_mounts EXIT

echo -e "\033[1;32m[INFO]\033[0m Installing requested packages into base rootfs..."
chroot "${ROOTFS_BASE_DIR}.new" "${CHROOT_RUNNER[@]}" /bin/bash -ec "
set -e
export DEBIAN_FRONTEND=noninteractive
export G_SLICE=always-malloc
export QEMU_CPU=max

restore_py3compile() {
    for tool in py3compile pypy3compile; do
        if [ -e \"/usr/bin/\${tool}.distrib\" ]; then
            rm -f \"/usr/bin/\${tool}\"
            dpkg-divert --quiet --rename --remove \"/usr/bin/\${tool}\"
        fi
    done
}

if [ \"${ROOTFS_CROSS_BUILD}\" = \"true\" ]; then
    # Under qemu-user emulation in Docker, py3compile can crash while
    # configuring large Python dependency chains. Temporarily stub it out so
    # dpkg can finish package configuration, then restore the real helpers.
    for tool in py3compile pypy3compile; do
        if [ -x \"/usr/bin/\${tool}\" ]; then
            dpkg-divert --quiet --local --rename --add \"/usr/bin/\${tool}\"
            cat > \"/usr/bin/\${tool}\" <<'EOF'
#!/bin/sh
exit 0
EOF
            chmod +x \"/usr/bin/\${tool}\"
        fi
    done
    trap restore_py3compile EXIT
fi

apt-get update
apt-get install -y ${ROOTFS_BASE_PACKAGES}
apt-get purge -y cloud-init cloud-guest-utils '^grub-.*' || true
apt-get clean
rm -rf /var/lib/apt/lists/*
restore_py3compile
"

rm -f "${ROOTFS_BASE_DIR}.new/usr/sbin/policy-rc.d"
if [ -n "${QEMU_STATIC}" ]; then
    rm -f "${ROOTFS_BASE_DIR}.new/usr/bin/${QEMU_STATIC}"
fi

cleanup_mounts
trap - EXIT

rm -rf "${ROOTFS_BASE_DIR}"
mv "${ROOTFS_BASE_DIR}.new" "${ROOTFS_BASE_DIR}"

ROOTFS_STAGING_DIR="${ROOTFS_BASE_DIR}"

echo -e "\033[1;32m[INFO]\033[0m Packing rootfs tarball..."
mkdir -p "$(dirname "${ROOTFS_TARBALL}")"
(cd "${ROOTFS_STAGING_DIR}/" && tar -p -c --one-file-system --sort=name --xattrs .) | xz -3 -T0 > "${ROOTFS_TARBALL}"

echo -e "\033[1;32m[INFO]\033[0m Base rootfs build complete! Tarball generated: ${ROOTFS_TARBALL}"
