#!/usr/bin/env bash
set -e

if [ -z "${TARGET_PRODUCT}" ]; then
    echo -e "\033[1;31m[ERR ]\033[0m TARGET_PRODUCT is not set. Please run 'lunch' first." >&2
    exit 1
fi

: "${ROOTFS_CODENAME:=resolute}"
: "${ROOTFS_ARCH:=arm64}"

: "${TARGET_OUT_DIR:?TARGET_OUT_DIR is not set}"
: "${IMAGE_OUT:?IMAGE_OUT is not set}"
: "${ROOTFS_OUT:?ROOTFS_OUT is not set}"
: "${BOOT_OUT:?BOOT_OUT is not set}"

# 定义全局固定的 PARTUUID (与你的 build_image.sh 保持一致)
export ROOTFS_PARTUUID="${ROOTFS_PARTUUID:-B921B045-1D00-4000-8000-000000000003}"

LOG_OUT="${TARGET_OUT_DIR}/logs"
ROOTFS_LOG="${LOG_OUT}/rootfs_build.log"

# 【优化 1】：将 Ubuntu Base 基础包下载源替换为清华大学 TUNA 镜像站，极速下载！
UBUNTU_BASE_URL="https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/daily/current/${ROOTFS_CODENAME}-base-${ROOTFS_ARCH}.tar.gz"
UBUNTU_BASE_TAR="${TARGET_OUT_DIR}/ubuntu-base-${ROOTFS_CODENAME}-daily-${ROOTFS_ARCH}.tar.gz"

ensure_dir "${LOG_OUT}" "${IMAGE_OUT}"

msg "Rootfs building requires root privileges. Asking for sudo password upfront..."
sudo -v
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

if [ ! -f "${UBUNTU_BASE_TAR}" ]; then
    msg "Downloading Ubuntu Base Daily (${ROOTFS_CODENAME}) from Tsinghua Mirror..."
    run_task "ROOTFS" "download ubuntu-base" "${ROOTFS_LOG}" \
        wget -c "${UBUNTU_BASE_URL}" -O "${UBUNTU_BASE_TAR}"
fi

msg "Extracting Ubuntu Base (this takes a moment)..."
sudo rm -rf "${ROOTFS_OUT}"
mkdir -p "${ROOTFS_OUT}"
run_task "ROOTFS" "extract rootfs" "${ROOTFS_LOG}" \
    sudo tar -xpf "${UBUNTU_BASE_TAR}" -C "${ROOTFS_OUT}"

if [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    die "Please enable binfmt support for aarch64: sudo apt-get install qemu-user-binfmt binfmt-support"
fi
sudo cp /etc/resolv.conf "${ROOTFS_OUT}/etc/resolv.conf"

# ==============================================================================
# 【优化 2】：极简固件注入 (跳过 apt 安装庞大的 linux-firmware)
# ==============================================================================
msg "Downloading precision firmware (GPU & WiFi)..."
FIRMWARE_CACHE="${TARGET_OUT_DIR}/firmware_cache"
mkdir -p "${FIRMWARE_CACHE}/arm/mali/arch10.8"
mkdir -p "${FIRMWARE_CACHE}/rtw89"

if [ ! -f "${FIRMWARE_CACHE}/arm/mali/arch10.8/mali_csffw.bin" ]; then
    wget -qO "${FIRMWARE_CACHE}/arm/mali/arch10.8/mali_csffw.bin" "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/arm/mali/arch10.8/mali_csffw.bin"
fi
if [ ! -f "${FIRMWARE_CACHE}/rtw89/rtw8852b_fw.bin" ]; then
    wget -qO "${FIRMWARE_CACHE}/rtw89/rtw8852b_fw.bin" "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/rtw89/rtw8852b_fw.bin"
fi

sudo mkdir -p "${ROOTFS_OUT}/lib/firmware/arm/mali/arch10.8"
sudo mkdir -p "${ROOTFS_OUT}/lib/firmware/rtw89"
sudo cp -a "${FIRMWARE_CACHE}/arm/mali/arch10.8/mali_csffw.bin" "${ROOTFS_OUT}/lib/firmware/arm/mali/arch10.8/"
sudo cp -a "${FIRMWARE_CACHE}/rtw89/rtw8852b_fw.bin" "${ROOTFS_OUT}/lib/firmware/rtw89/"
sudo chmod 644 "${ROOTFS_OUT}/lib/firmware/arm/mali/arch10.8/mali_csffw.bin"
sudo chmod 644 "${ROOTFS_OUT}/lib/firmware/rtw89/rtw8852b_fw.bin"

# ==============================================================================
# 构建 chroot 内部执行脚本
# ==============================================================================
msg "Generating init_rootfs.sh..."
cat << EOF | sudo tee "${ROOTFS_OUT}/init_rootfs.sh" > /dev/null
#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export LANGUAGE=C

# 换源：将 Ubuntu Ports 官方源替换为清华 TUNA 镜像站
if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
    sed -i 's/ports.ubuntu.com/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list.d/ubuntu.sources
    sed -i 's/Components: main/Components: main restricted universe multiverse/g' /etc/apt/sources.list.d/ubuntu.sources
elif [ -f /etc/apt/sources.list ]; then
    sed -i 's/ports.ubuntu.com/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list
    sed -i 's/main$/main restricted universe multiverse/g' /etc/apt/sources.list
fi

apt-get update

# 【优化 3】：砍掉 oem-config 向导，只安装核心桌面和网络工具
apt-get install -y --no-install-recommends \
    ubuntu-desktop \
    language-pack-en-base language-pack-zh-hans tzdata \
    network-manager sudo ssh curl file

# 基础配置
echo "armsom-ubuntu" > /etc/hostname
echo "127.0.0.1 localhost" > /etc/hosts
echo "127.0.1.1 armsom-ubuntu" >> /etc/hosts

# 设置时区为上海
ln -fs /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
dpkg-reconfigure -f noninteractive tzdata

# 【优化 4】：直接创建用户，跳过配置向导
useradd -m -s /bin/bash armsom || true
echo "armsom:123456" | chpasswd || true
usermod -aG sudo,adm armsom || true

# 配置桌面自动登录 (开机直接进桌面，连密码都不用敲)
mkdir -p /etc/gdm3
cat <<GDM_EOF > /etc/gdm3/custom.conf
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=armsom
GDM_EOF

# 激活串口登录终端 (防砖神器)
ln -sf /lib/systemd/system/serial-getty@.service /etc/systemd/system/getty.target.wants/serial-getty@ttyS2.service

# 写入正确的 fstab
cat <<FSTAB_EOF > /etc/fstab
# <file system>                           <mount point>   <type>  <options>          <dump>  <pass>
PARTUUID=${ROOTFS_PARTUUID}               /               ext4    defaults,noatime   0       1
FSTAB_EOF

apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -f /init_rootfs.sh
EOF

sudo chmod +x "${ROOTFS_OUT}/init_rootfs.sh"

trap '
    sudo umount "${ROOTFS_OUT}/dev/pts" 2>/dev/null || true
    sudo umount "${ROOTFS_OUT}/dev" 2>/dev/null || true
    sudo umount "${ROOTFS_OUT}/sys" 2>/dev/null || true
    sudo umount "${ROOTFS_OUT}/proc" 2>/dev/null || true
' EXIT INT TERM

msg "Entering Chroot to install Ubuntu Desktop (Expect much faster time now)..."
sudo bash -c "mount -t proc /proc ${ROOTFS_OUT}/proc && \
              mount -t sysfs /sys ${ROOTFS_OUT}/sys && \
              mount -o bind /dev ${ROOTFS_OUT}/dev && \
              mount -o bind /dev/pts ${ROOTFS_OUT}/dev/pts"

sudo chroot "${ROOTFS_OUT}" /bin/bash /init_rootfs.sh

msg "Unmounting virtual filesystems before packing..."
sudo umount "${ROOTFS_OUT}/dev/pts" 2>/dev/null || true
sudo umount "${ROOTFS_OUT}/dev" 2>/dev/null || true
sudo umount "${ROOTFS_OUT}/sys" 2>/dev/null || true
sudo umount "${ROOTFS_OUT}/proc" 2>/dev/null || true

msg "Fusing Kernel assets into Rootfs..."

if [ -d "${BOOT_OUT}" ] && [ -f "${BOOT_OUT}/extlinux/extlinux.conf" ]; then
    sudo mkdir -p "${ROOTFS_OUT}/boot"
    sudo cp -a "${BOOT_OUT}/Image" "${ROOTFS_OUT}/boot/" 2>/dev/null || true
    sudo cp -a "${BOOT_OUT}/"*.dtb "${ROOTFS_OUT}/boot/" 2>/dev/null || true
    sudo cp -a "${BOOT_OUT}/extlinux" "${ROOTFS_OUT}/boot/" 2>/dev/null || true

    if [ -d "${BOOT_OUT}/lib" ]; then
        sudo cp -a "${BOOT_OUT}/lib/"* "${ROOTFS_OUT}/lib/" 2>/dev/null || true
    fi
    msg "Kernel fused successfully!"
else
    echo -e "\033[1;33m[WARN] Boot assets missing in ${BOOT_OUT}. Did you run 'm kernel'? System will NOT boot!\033[0m"
fi

msg "Packing rootfs.img..."
ROOTFS_IMG="${IMAGE_OUT}/rootfs.img"
sudo rm -f "${ROOTFS_IMG}"

run_task "ROOTFS" "make ext4 image" "${ROOTFS_LOG}" \
    sudo bash -c "
        fallocate -l 8G ${ROOTFS_IMG} &&
        mkfs.ext4 -O ^has_journal,^metadata_csum -E nodiscard -L rootfs -d ${ROOTFS_OUT} ${ROOTFS_IMG} &&
        chown $(id -un):$(id -gn) ${ROOTFS_IMG}
    "

msg "Rootfs image generated successfully at ${ROOTFS_IMG} !"