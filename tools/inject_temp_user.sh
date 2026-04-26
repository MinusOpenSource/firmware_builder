#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  sudo ./tools/inject_temp_user.sh [options] <image.img> <username> <password> [rootfs_start_sector]

Description:
  Mount the rootfs partition inside a raw image and create or update
  a temporary debug user. The user is unlocked, added to sudo, and can
  optionally be configured for tty1 autologin.

Options:
  --autologin            Enable tty1 autologin for the injected user
  --serial-autologin TTY Enable serial-getty autologin on the given TTY
                         (example: --serial-autologin ttyS2)
  -h, --help             Show this help

Arguments:
  image.img              Raw disk image to patch
  username               Username to create or update
  password               Plain-text password to set
  rootfs_start_sector    Rootfs partition start sector, default: 32768

Examples:
  sudo ./tools/inject_temp_user.sh out/board.img debug debug123
  sudo ./tools/inject_temp_user.sh --autologin out/board.img debug debug123
  sudo ./tools/inject_temp_user.sh --serial-autologin ttyS2 out/board.img debug debug123
EOF
}

AUTLOGIN_TTY1=0
SERIAL_AUTOLOGIN_TTY=""

while [ $# -gt 0 ]; do
    case "$1" in
        --autologin)
            AUTLOGIN_TTY1=1
            shift
            ;;
        --serial-autologin)
            [ $# -ge 2 ] || {
                echo "[ERR] --serial-autologin requires a TTY argument" >&2
                exit 1
            }
            SERIAL_AUTOLOGIN_TTY="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "[ERR] Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

if [ $# -lt 3 ]; then
    usage >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root." >&2
    exit 1
fi

IMG_PATH="$1"
USERNAME="$2"
PASSWORD="$3"
ROOTFS_START_SECTOR="${4:-32768}"
SECTOR_SIZE=512
ROOTFS_OFFSET=$((ROOTFS_START_SECTOR * SECTOR_SIZE))

if [ ! -f "${IMG_PATH}" ]; then
    echo "[ERR] Image not found: ${IMG_PATH}" >&2
    exit 1
fi

case "${USERNAME}" in
    *[!a-zA-Z0-9._-]*|'')
        echo "[ERR] Unsupported username: ${USERNAME}" >&2
        echo "      Allowed characters: a-z A-Z 0-9 . _ -" >&2
        exit 1
        ;;
esac

for cmd in losetup mount umount chroot install awk sed grep; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "[ERR] Missing host command: ${cmd}" >&2
        exit 1
    fi
done

if ! command -v qemu-aarch64-static >/dev/null 2>&1; then
    echo "[ERR] Missing host command: qemu-aarch64-static" >&2
    echo "      Install package: qemu-user-static" >&2
    exit 1
fi

cleanup() {
    set +e

    if [ -n "${MOUNT_POINT:-}" ] && [ -f "${MOUNT_POINT}/tmp/inject_temp_user.sh" ]; then
        rm -f "${MOUNT_POINT}/tmp/inject_temp_user.sh"
    fi
    if [ -n "${MOUNT_POINT:-}" ] && [ -f "${MOUNT_POINT}/usr/bin/qemu-aarch64-static" ]; then
        rm -f "${MOUNT_POINT}/usr/bin/qemu-aarch64-static"
    fi
    if [ -n "${MOUNT_POINT:-}" ] && mountpoint -q "${MOUNT_POINT}/dev/pts" 2>/dev/null; then
        umount "${MOUNT_POINT}/dev/pts" || true
    fi
    if [ -n "${MOUNT_POINT:-}" ] && mountpoint -q "${MOUNT_POINT}/dev" 2>/dev/null; then
        umount "${MOUNT_POINT}/dev" || true
    fi
    if [ -n "${MOUNT_POINT:-}" ] && mountpoint -q "${MOUNT_POINT}/proc" 2>/dev/null; then
        umount "${MOUNT_POINT}/proc" || true
    fi
    if [ -n "${MOUNT_POINT:-}" ] && mountpoint -q "${MOUNT_POINT}/sys" 2>/dev/null; then
        umount "${MOUNT_POINT}/sys" || true
    fi
    if [ -n "${MOUNT_POINT:-}" ] && mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
        umount "${MOUNT_POINT}" || true
    fi
    if [ -n "${LOOP_DEV:-}" ] && [ -b "${LOOP_DEV}" ]; then
        losetup -d "${LOOP_DEV}" || true
    fi
    if [ -n "${MOUNT_POINT:-}" ] && [ -d "${MOUNT_POINT}" ]; then
        rmdir "${MOUNT_POINT}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

IMG_PATH="$(readlink -f "${IMG_PATH}")"
MOUNT_POINT="$(mktemp -d /tmp/inject-user.XXXXXX)"
LOOP_DEV="$(losetup -f)"

if [ ! -b "${LOOP_DEV}" ]; then
    minor="${LOOP_DEV#/dev/loop}"
    mknod -m 0660 "${LOOP_DEV}" b 7 "${minor}" 2>/dev/null || true
fi

echo "============================================"
echo " Inject Temporary User"
echo " Image         : ${IMG_PATH}"
echo " Rootfs offset : ${ROOTFS_OFFSET} bytes"
echo " Username      : ${USERNAME}"
echo " TTY autologin : ${AUTLOGIN_TTY1}"
echo " Serial login  : ${SERIAL_AUTOLOGIN_TTY:-disabled}"
echo " Mount         : ${MOUNT_POINT}"
echo "============================================"

losetup -o "${ROOTFS_OFFSET}" "${LOOP_DEV}" "${IMG_PATH}"
mount "${LOOP_DEV}" "${MOUNT_POINT}"

if [ ! -f "${MOUNT_POINT}/etc/passwd" ]; then
    echo "[ERR] Mounted rootfs does not look like a Linux rootfs: ${MOUNT_POINT}" >&2
    exit 1
fi

mkdir -p "${MOUNT_POINT}/dev/pts" "${MOUNT_POINT}/proc" "${MOUNT_POINT}/sys" "${MOUNT_POINT}/tmp" "${MOUNT_POINT}/usr/bin"
mount --bind /dev "${MOUNT_POINT}/dev"
mount --bind /dev/pts "${MOUNT_POINT}/dev/pts"
mount -t proc proc "${MOUNT_POINT}/proc"
mount -t sysfs sysfs "${MOUNT_POINT}/sys"
install -m 0755 "$(command -v qemu-aarch64-static)" "${MOUNT_POINT}/usr/bin/qemu-aarch64-static"

cat > "${MOUNT_POINT}/tmp/inject_temp_user.sh" <<EOF
#!/bin/sh
set -eu

USERNAME='${USERNAME}'
PASSWORD='${PASSWORD}'
AUTLOGIN_TTY1='${AUTLOGIN_TTY1}'
SERIAL_AUTOLOGIN_TTY='${SERIAL_AUTOLOGIN_TTY}'

pick_groups() {
    local groups=""
    local g

    for g in sudo adm audio video render input plugdev netdev dialout users; do
        if getent group "\${g}" >/dev/null 2>&1; then
            if [ -n "\${groups}" ]; then
                groups="\${groups},\${g}"
            else
                groups="\${g}"
            fi
        fi
    done

    printf '%s\n' "\${groups}"
}

ensure_user() {
    local groups
    groups="\$(pick_groups)"

    if id -u "\${USERNAME}" >/dev/null 2>&1; then
        if [ -n "\${groups}" ]; then
            usermod -a -G "\${groups}" "\${USERNAME}"
        fi
    else
        if [ -n "\${groups}" ]; then
            useradd -m -s /bin/bash -G "\${groups}" "\${USERNAME}"
        else
            useradd -m -s /bin/bash "\${USERNAME}"
        fi
    fi

    echo "\${USERNAME}:\${PASSWORD}" | chpasswd
    passwd -u "\${USERNAME}" >/dev/null 2>&1 || true
}

install_sudoers() {
    if [ -d /etc/sudoers.d ]; then
        cat > "/etc/sudoers.d/90-temp-\${USERNAME}" <<EOSUDO
\${USERNAME} ALL=(ALL) NOPASSWD:ALL
EOSUDO
        chmod 0440 "/etc/sudoers.d/90-temp-\${USERNAME}"
    fi
}

install_marker() {
    cat > /etc/firmware-builder-temp-user <<EOMARK
Temporary debug user injected by firmware_builder/tools/inject_temp_user.sh
username=\${USERNAME}
tty1_autologin=\${AUTLOGIN_TTY1}
serial_autologin=\${SERIAL_AUTOLOGIN_TTY}
EOMARK
    chmod 0644 /etc/firmware-builder-temp-user
}

enable_tty1_autologin() {
    mkdir -p /etc/systemd/system/getty@tty1.service.d
    cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOAUTO
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin \${USERNAME} --noclear %I \$TERM
EOAUTO
}

enable_serial_autologin() {
    [ -n "\${SERIAL_AUTOLOGIN_TTY}" ] || return 0
    mkdir -p "/etc/systemd/system/serial-getty@\${SERIAL_AUTOLOGIN_TTY}.service.d"
    cat > "/etc/systemd/system/serial-getty@\${SERIAL_AUTOLOGIN_TTY}.service.d/autologin.conf" <<EOSERIAL
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin \${USERNAME} --keep-baud 115200,57600,38400,9600 %I \$TERM
EOSERIAL
}

ensure_user
install_sudoers
install_marker

if [ "\${AUTLOGIN_TTY1}" = "1" ]; then
    enable_tty1_autologin
fi

enable_serial_autologin
EOF

chmod +x "${MOUNT_POINT}/tmp/inject_temp_user.sh"

chroot "${MOUNT_POINT}" /usr/bin/qemu-aarch64-static /bin/sh /tmp/inject_temp_user.sh

echo ""
echo "Result:"
grep "^${USERNAME}:" "${MOUNT_POINT}/etc/passwd" || true
if [ -f "${MOUNT_POINT}/etc/sudoers.d/90-temp-${USERNAME}" ]; then
    echo " -> sudo enabled"
fi
if [ -f "${MOUNT_POINT}/etc/systemd/system/getty@tty1.service.d/autologin.conf" ]; then
    echo " -> tty1 autologin enabled"
fi
if [ -n "${SERIAL_AUTOLOGIN_TTY}" ] && [ -f "${MOUNT_POINT}/etc/systemd/system/serial-getty@${SERIAL_AUTOLOGIN_TTY}.service.d/autologin.conf" ]; then
    echo " -> serial autologin enabled on ${SERIAL_AUTOLOGIN_TTY}"
fi

sync "${MOUNT_POINT}" || true
sync || true

echo ""
echo "[OK] Temporary user injected successfully."
