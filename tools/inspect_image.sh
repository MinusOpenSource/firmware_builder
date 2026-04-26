#!/usr/bin/env bash
# ============================================================
# inspect_image.sh — 挂载固件镜像的 rootfs 分区并查看内容
#
# 用法:
#   sudo ./tools/inspect_image.sh <image.img> [挂载点]
#
# 不带第二个参数时默认挂载到 /tmp/inspect-rootfs-XXXXXX
# 脚本结束后会自动卸载并清理。
# ============================================================

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 运行: sudo $0 $*"
    exit 1
fi

IMG="${1:?用法: $0 <image.img> [挂载点]}"
MOUNT_POINT="${2:-}"

if [ ! -f "${IMG}" ]; then
    echo "[ERR] 镜像文件不存在: ${IMG}"
    exit 1
fi

# 如果没有指定挂载点，则创建临时目录
if [ -z "${MOUNT_POINT}" ]; then
    MOUNT_POINT="$(mktemp -d /tmp/inspect-rootfs-XXXXXX)"
    CREATED_MOUNT_POINT=1
else
    mkdir -p "${MOUNT_POINT}"
    CREATED_MOUNT_POINT=0
fi

cleanup() {
    echo ""
    echo "[INFO] 正在卸载..."
    umount "${MOUNT_POINT}" 2>/dev/null || true
    if [ -n "${LOOP_DEV:-}" ]; then
        losetup -d "${LOOP_DEV}" 2>/dev/null || true
    fi
    if [ "${CREATED_MOUNT_POINT}" -eq 1 ]; then
        rmdir "${MOUNT_POINT}" 2>/dev/null || true
    fi
    echo "[INFO] 清理完成。"
}
trap cleanup EXIT

echo "============================================"
echo " 固件镜像检查工具"
echo " 镜像: ${IMG}"
echo "============================================"

# 1. 显示分区表
echo ""
echo ">>> 分区表:"
parted -s "${IMG}" unit s print || fdisk -l "${IMG}"

echo ""

# 2. 查找并挂载 rootfs 分区 (自动检测最大的分区)
# 使用 losetup -P 自动创建分区设备节点
LOOP_DEV="$(losetup -f)"

# 手动创建 loop 节点 (Docker 兼容)
if [ ! -b "${LOOP_DEV}" ]; then
    minor="${LOOP_DEV#/dev/loop}"
    mknod -m 0660 "${LOOP_DEV}" b 7 "${minor}" 2>/dev/null || true
fi

losetup -P "${LOOP_DEV}" "${IMG}"

# 等待分区设备节点出现
sleep 1

# 列出所有分区
echo ">>> Loop 设备分区:"
lsblk "${LOOP_DEV}" 2>/dev/null || ls -la "${LOOP_DEV}"*

# 寻找 rootfs 分区 (通常是最后一个/最大的分区)
ROOTFS_PART=""
for part in "${LOOP_DEV}"p*; do
    [ -b "${part}" ] || continue
    ROOTFS_PART="${part}"
done

if [ -z "${ROOTFS_PART}" ]; then
    # 如果 -P 没有生成分区节点 (Docker 环境)，用偏移量手动挂载
    echo "[INFO] 未检测到分区设备节点，使用偏移量模式 (sector 32768)..."
    losetup -d "${LOOP_DEV}"
    ROOTFS_OFFSET=$((32768 * 512))
    losetup -o ${ROOTFS_OFFSET} "${LOOP_DEV}" "${IMG}"
    ROOTFS_PART="${LOOP_DEV}"
fi

echo ""
echo ">>> 挂载分区: ${ROOTFS_PART}"
mount -o ro "${ROOTFS_PART}" "${MOUNT_POINT}"

echo ">>> 挂载成功: ${MOUNT_POINT}"
echo ""

# 3. 显示基本信息
echo "====== 磁盘用量 ======"
df -h "${MOUNT_POINT}"
echo ""

echo "====== 顶层目录 ======"
ls -la "${MOUNT_POINT}/"
echo ""

echo "====== 内核版本 ======"
ls "${MOUNT_POINT}/boot"/vmlinuz* 2>/dev/null || echo "(无内核文件)"
echo ""

echo "====== /boot 内容 ======"
ls -la "${MOUNT_POINT}/boot/" 2>/dev/null || echo "(无 /boot)"
echo ""

echo "====== extlinux 引导配置 ======"
cat "${MOUNT_POINT}/boot/extlinux/extlinux.conf" 2>/dev/null || echo "(无 extlinux.conf)"
echo ""

echo "====== /etc/fstab ======"
cat "${MOUNT_POINT}/etc/fstab" 2>/dev/null || echo "(无 fstab)"
echo ""

echo "====== OS 信息 ======"
cat "${MOUNT_POINT}/etc/os-release" 2>/dev/null || echo "(无 os-release)"
echo ""

echo "====== 已安装的内核包 ======"
if [ -f "${MOUNT_POINT}/var/lib/dpkg/status" ]; then
    grep -E "^Package: linux-(image|headers|modules)" "${MOUNT_POINT}/var/lib/dpkg/status" 2>/dev/null || echo "(无内核包)"
else
    echo "(无 dpkg 数据库)"
fi
echo ""

echo "====== 用户账户 ======"
grep -E ":\d{4}:" "${MOUNT_POINT}/etc/passwd" 2>/dev/null || echo "(无普通用户)"
echo ""

# 4. 交互模式：让用户自由探索
echo "============================================"
echo " 镜像已只读挂载到: ${MOUNT_POINT}"
echo " 你可以在另一个终端中自由浏览。"
echo " 按 Enter 卸载并退出..."
echo "============================================"
read -r
