#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  sudo ./tools/enable_oobe_in_image.sh <image.img> [rootfs_start_sector]

Description:
  Mount the rootfs partition inside a raw image and arm the KDE first-boot
  OOBE flow from outside the image. The script prefers Kubuntu's Calamares
  OEM mode so a preinstalled image can boot into the account-setup wizard
  instead of stopping at the login screen.

Arguments:
  image.img            Raw disk image to patch
  rootfs_start_sector  Rootfs partition start sector, default: 32768

Example:
  sudo ./tools/enable_oobe_in_image.sh \
    out/target/product/armsom_w3/image/armsom-w3-ubuntu-resolute.img
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ $# -lt 1 ]; then
    usage >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root." >&2
    exit 1
fi

IMG_PATH="$1"
ROOTFS_START_SECTOR="${2:-32768}"
SECTOR_SIZE=512
ROOTFS_OFFSET=$((ROOTFS_START_SECTOR * SECTOR_SIZE))

if [ ! -f "${IMG_PATH}" ]; then
    echo "[ERR] Image not found: ${IMG_PATH}" >&2
    exit 1
fi

for cmd in losetup mount umount chroot install; do
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

HOST_RESOLV_CONF="/etc/resolv.conf"
if [ -f /run/systemd/resolve/resolv.conf ]; then
    HOST_RESOLV_CONF="/run/systemd/resolve/resolv.conf"
fi

cleanup() {
    set +e
    if [ -n "${MOUNT_POINT:-}" ] && [ -e "${MOUNT_POINT}/etc/resolv.conf.codex-backup" ]; then
        rm -f "${MOUNT_POINT}/etc/resolv.conf"
        mv "${MOUNT_POINT}/etc/resolv.conf.codex-backup" "${MOUNT_POINT}/etc/resolv.conf" || true
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
MOUNT_POINT="$(mktemp -d /tmp/enable-oobe.XXXXXX)"
LOOP_DEV="$(losetup -f)"

if [ ! -b "${LOOP_DEV}" ]; then
    minor="${LOOP_DEV#/dev/loop}"
    mknod -m 0660 "${LOOP_DEV}" b 7 "${minor}" 2>/dev/null || true
fi

echo "============================================"
echo " Enable OOBE In Image"
echo " Image     : ${IMG_PATH}"
echo " Rootfs ofs: ${ROOTFS_OFFSET} bytes"
echo " Mount     : ${MOUNT_POINT}"
echo "============================================"

losetup -o "${ROOTFS_OFFSET}" "${LOOP_DEV}" "${IMG_PATH}"
mount "${LOOP_DEV}" "${MOUNT_POINT}"

if [ ! -f "${MOUNT_POINT}/etc/os-release" ]; then
    echo "[ERR] Mounted rootfs does not look like a Linux rootfs: ${MOUNT_POINT}" >&2
    exit 1
fi

mkdir -p "${MOUNT_POINT}/dev/pts" "${MOUNT_POINT}/proc" "${MOUNT_POINT}/sys" "${MOUNT_POINT}/usr/bin"
mount --bind /dev "${MOUNT_POINT}/dev"
mount --bind /dev/pts "${MOUNT_POINT}/dev/pts"
mount -t proc proc "${MOUNT_POINT}/proc"
mount -t sysfs sysfs "${MOUNT_POINT}/sys"
if [ -f "${HOST_RESOLV_CONF}" ]; then
    if [ -e "${MOUNT_POINT}/etc/resolv.conf" ] || [ -L "${MOUNT_POINT}/etc/resolv.conf" ]; then
        mv "${MOUNT_POINT}/etc/resolv.conf" "${MOUNT_POINT}/etc/resolv.conf.codex-backup"
    fi
    cp -L "${HOST_RESOLV_CONF}" "${MOUNT_POINT}/etc/resolv.conf"
fi
install -m 0755 "$(command -v qemu-aarch64-static)" "${MOUNT_POINT}/usr/bin/qemu-aarch64-static"

if ! chroot "${MOUNT_POINT}" /usr/bin/qemu-aarch64-static /bin/sh -ec '
set -e

export DEBIAN_FRONTEND=noninteractive

pick_groups() {
    groups=""

    for g in adm audio cdrom dialout dip lpadmin netdev plugdev render sambashare sudo users video; do
        if getent group "${g}" >/dev/null 2>&1; then
            if [ -n "${groups}" ]; then
                groups="${groups},${g}"
            else
                groups="${g}"
            fi
        fi
    done

    printf "%s\n" "${groups}"
}

ensure_oem_user() {
    groups="$(pick_groups)"

    if id -u oem >/dev/null 2>&1; then
        usermod -s /bin/bash oem >/dev/null 2>&1 || true
        if [ -n "${groups}" ]; then
            usermod -a -G "${groups}" oem >/dev/null 2>&1 || true
        fi
    else
        if [ -n "${groups}" ]; then
            useradd -m -s /bin/bash -G "${groups}" oem
        else
            useradd -m -s /bin/bash oem
        fi
    fi

    passwd -d oem >/dev/null 2>&1 || true
}

cleanup_calamares_conflicts() {
    rm -f /var/lib/oem-config/run /etc/calamares/OEM_MODE_ACTIVATED
    rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf

    if [ -d /etc/systemd/system/getty@tty1.service.d ] && [ -z "$(ls -A /etc/systemd/system/getty@tty1.service.d 2>/dev/null)" ]; then
        rmdir /etc/systemd/system/getty@tty1.service.d || true
    fi

    if [ -x /usr/bin/sddm ]; then
        mkdir -p /etc/X11
        printf "%s\n" "/usr/bin/sddm" > /etc/X11/default-display-manager
    fi
}

backup_sddm_conf() {
    if [ -f /etc/sddm.conf ] && [ ! -f /etc/sddm.conf.oem-orig ]; then
        cp -a /etc/sddm.conf /etc/sddm.conf.oem-orig
    fi
}

install_platform_oem_install() {
    mkdir -p /usr/local/sbin
    cat > /usr/local/sbin/platform-oem-install <<'\''EOF'\''
#!/bin/bash

set -euo pipefail

LOG_FILE="/var/log/platform-oem-install.log"
STATE_DIR="/var/lib/platform-oem"
STATE_FILE="${STATE_DIR}/install-complete"
SDDM_CONF="/etc/sddm.conf"
SDDM_CONF_BACKUP="/etc/sddm.conf.oem-orig"

mkdir -p "${STATE_DIR}"
touch "${LOG_FILE}"

log() {
    printf "[platform-oem-install] %s\n" "$*" | tee -a "${LOG_FILE}"
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

append_root_growfs_fstab() {
    fstab="/etc/fstab"

    if [ ! -f "${fstab}" ]; then
        return 0
    fi

    tmp="$(mktemp /etc/fstab.platform-oem.XXXXXX)"
    awk_script="$(mktemp /tmp/platform-oem-fstab.XXXXXX)"
    cat > "${awk_script}" <<"AWK"
$1 ~ /^[[:space:]]*#/ || NF == 0 { print; next }
$2 != "/" { print; next }
{
    if ($4 == "" || $4 == "-") {
        $4 = "defaults"
    }
    n = split($4, opts, ",")
    found = 0
    rebuilt = ""
    for (i = 1; i <= n; ++i) {
        if (opts[i] == "x-systemd.growfs") {
            found = 1
        }
        if (opts[i] != "") {
            if (rebuilt != "") {
                rebuilt = rebuilt "," opts[i]
            } else {
                rebuilt = opts[i]
            }
        }
    }
    if (!found) {
        if (rebuilt != "") {
            rebuilt = rebuilt ",x-systemd.growfs"
        } else {
            rebuilt = "defaults,x-systemd.growfs"
        }
    }
    $4 = rebuilt
    print
}
AWK
    awk -f "${awk_script}" "${fstab}" > "${tmp}"
    rm -f "${awk_script}"
    mv -f "${tmp}" "${fstab}"
}

cleanup_oem_state() {
    rm -f /var/lib/oem-config/run /etc/calamares/OEM_MODE_ACTIVATED
    rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf
    if [ -d /etc/systemd/system/getty@tty1.service.d ] && [ -z "$(ls -A /etc/systemd/system/getty@tty1.service.d 2>/dev/null)" ]; then
        rmdir /etc/systemd/system/getty@tty1.service.d || true
    fi

    if [ -f /etc/sudoers.orig ]; then
        mv -f /etc/sudoers.orig /etc/sudoers
        chmod 0440 /etc/sudoers || true
    fi

    preserve_current_sddm_conf=0
    if [ -f "${SDDM_CONF}" ]; then
        current_autologin_user="$(
            sed -n "/^[[:space:]]*\\[Autologin\\][[:space:]]*$/,/^[[:space:]]*\\[/{s/^[[:space:]]*User[[:space:]]*=[[:space:]]*//p;}" "${SDDM_CONF}" 2>/dev/null | head -n1 | tr -d "[:space:]"
        )"
        if [ -n "${current_autologin_user}" ] && [ "${current_autologin_user}" != "oem" ]; then
            preserve_current_sddm_conf=1
            log "preserving SDDM autologin for user ${current_autologin_user}"
        fi
    fi

    if [ "${preserve_current_sddm_conf}" -eq 0 ]; then
        if [ -f "${SDDM_CONF_BACKUP}" ]; then
            mv -f "${SDDM_CONF_BACKUP}" "${SDDM_CONF}"
        else
            rm -f "${SDDM_CONF}"
        fi
    else
        rm -f "${SDDM_CONF_BACKUP}"
    fi

    rm -f /usr/share/applications/calamares-finish-oem.desktop
    rm -f /usr/share/xsessions/kubuntu-oem-environment.desktop
    rm -f /usr/share/wayland-sessions/kubuntu-oem-environment.desktop
    rm -f /usr/libexec/start-kubuntu-oem-env

    if id -u oem >/dev/null 2>&1; then
        userdel -r oem >/dev/null 2>&1 || userdel oem >/dev/null 2>&1 || true
    fi
}

grow_rootfs() {
    root_source="$(findmnt -n -o SOURCE / || true)"
    root_fstype="$(findmnt -n -o FSTYPE / || true)"

    log "root source: [${root_source}], fstype: [${root_fstype}]"

    if [ -z "${root_source}" ]; then
        log "ERROR: unable to determine root source (findmnt returned empty)"
        return 1
    fi

    if [ -L "${root_source}" ]; then
        root_source="$(readlink -f "${root_source}")"
        log "resolved symlink to: ${root_source}"
    fi

    if [ ! -b "${root_source}" ]; then
        log "ERROR: root source is not a block device: ${root_source}"
        return 1
    fi

    disk_name="$(lsblk -no PKNAME "${root_source}" 2>/dev/null | head -n1 || true)"
    part_num="$(lsblk -no PARTNUM "${root_source}" 2>/dev/null | head -n1 || true)"

    if [ -z "${part_num}" ]; then
        part_num="$(echo "${root_source}" | sed "s/.*[^0-9]\\([0-9]\\+\\)$/\\1/")"
        log "PARTNUM fallback from device name: ${part_num}"
    fi
    if [ -z "${disk_name}" ]; then
        base_dev="${root_source#/dev/}"
        disk_name="$(echo "${base_dev}" | sed "s/p\\?[0-9]\\+$//")"
        log "PKNAME fallback from device name: ${disk_name}"
    fi

    if [ -z "${disk_name}" ] || [ -z "${part_num}" ]; then
        log "ERROR: unable to determine parent disk or partition number for ${root_source}"
        log "  disk_name=[${disk_name}] part_num=[${part_num}]"
        log "  lsblk output: $(lsblk -o NAME,PKNAME,PARTNUM "${root_source}" 2>&1 || true)"
        return 1
    fi

    disk="/dev/${disk_name}"
    log "plan: grow partition ${part_num} on ${disk} (device: ${root_source})"

    log "available tools: parted=$(have_cmd parted && echo yes || echo NO) resize2fs=$(have_cmd resize2fs && echo yes || echo NO) growpart=$(have_cmd growpart && echo yes || echo NO)"

    if ! have_cmd resize2fs; then
        log "ERROR: resize2fs is missing (install e2fsprogs)"
        return 1
    fi

    part_grown=0
    if have_cmd growpart; then
        log "growing partition with growpart ${disk} ${part_num}"
        growpart "${disk}" "${part_num}" >>"${LOG_FILE}" 2>&1 && part_grown=1 || {
            rc=$?
            if [ "${rc}" -eq 1 ]; then
                log "growpart: partition already at maximum size"
                part_grown=1
            else
                log "growpart failed (rc=${rc}), trying parted fallback"
            fi
        }
    fi

    if [ "${part_grown}" -eq 0 ]; then
        if have_cmd parted; then
            log "growing partition with parted resizepart ${part_num} 100%"
            parted -s "${disk}" resizepart "${part_num}" 100% >>"${LOG_FILE}" 2>&1 || {
                log "ERROR: parted resizepart failed"
                return 1
            }
        else
            log "ERROR: neither growpart nor parted is available"
            return 1
        fi
    fi

    log "refreshing kernel partition table"
    if have_cmd partprobe; then
        partprobe "${disk}" >>"${LOG_FILE}" 2>&1 || true
    fi
    if have_cmd udevadm; then
        udevadm settle --timeout=10 >>"${LOG_FILE}" 2>&1 || true
    fi
    if [ -b "${root_source}" ]; then
        blockdev --rereadpt "${disk}" >>"${LOG_FILE}" 2>&1 || true
    fi
    sleep 2

    log "partition size after grow: $(lsblk -bno SIZE "${root_source}" 2>/dev/null || echo unknown)"
    log "disk total size: $(lsblk -bno SIZE "${disk}" 2>/dev/null || echo unknown)"

    case "${root_fstype}" in
        ext2|ext3|ext4)
            log "resizing ${root_fstype} filesystem on ${root_source}"
            resize2fs "${root_source}" >>"${LOG_FILE}" 2>&1 || {
                log "ERROR: resize2fs failed for ${root_source}"
                return 1
            }
            log "resize2fs completed successfully"
            ;;
        btrfs)
            if have_cmd btrfs; then
                log "resizing btrfs filesystem"
                btrfs filesystem resize max / >>"${LOG_FILE}" 2>&1 || {
                    log "ERROR: btrfs resize failed"
                    return 1
                }
            fi
            ;;
        *)
            log "WARNING: root filesystem ${root_fstype:-unknown} is not handled; relying on x-systemd.growfs fallback"
            ;;
    esac

    final_size="$(df -h / 2>/dev/null | tail -1 || true)"
    log "rootfs size after expansion: ${final_size}"

    append_root_growfs_fstab
    return 0
}

ensure_network_manager_ready() {
    if ! have_cmd systemctl; then
        return 0
    fi

    if systemctl list-unit-files NetworkManager.service >/dev/null 2>&1; then
        mkdir -p /etc/netplan
        if [ ! -f /etc/netplan/01-network-manager-all.yaml ]; then
            cat > /etc/netplan/01-network-manager-all.yaml <<'\''EOF_NETPLAN'\''
network:
  version: 2
  renderer: NetworkManager
EOF_NETPLAN
            chmod 0600 /etc/netplan/01-network-manager-all.yaml || true
            log "created /etc/netplan/01-network-manager-all.yaml"
        fi

        systemctl unmask NetworkManager.service >/dev/null 2>&1 || true
        systemctl enable NetworkManager.service >/dev/null 2>&1 || true
        systemctl restart NetworkManager.service >/dev/null 2>&1 || true
    fi

    if systemctl list-unit-files wpa_supplicant.service >/dev/null 2>&1; then
        systemctl unmask wpa_supplicant.service >/dev/null 2>&1 || true
        systemctl enable wpa_supplicant.service >/dev/null 2>&1 || true
        systemctl restart wpa_supplicant.service >/dev/null 2>&1 || true
    fi
}

if [ -e "${STATE_FILE}" ]; then
    log "already completed; skipping duplicate run"
    exit 0
fi

if ! grow_rootfs; then
    log "rootfs grow step failed; OEM cleanup will still continue"
fi

ensure_network_manager_ready
cleanup_oem_state
touch "${STATE_FILE}"
log "OEM install finished successfully"
EOF
    chmod 0755 /usr/local/sbin/platform-oem-install
}

configure_oem_finish() {
    install_platform_oem_install

    [ -f /etc/calamares/modules/shellprocess_oemfinish.conf ]
    sed -i \
        -e "s|/usr/libexec/calamares-oemfinish.sh|/usr/local/sbin/platform-oem-install|g" \
        -e "s|/var/lib/platform-kubuntu/oobe/calamares-oemfinish.sh|/usr/local/sbin/platform-oem-install|g" \
        /etc/calamares/modules/shellprocess_oemfinish.conf
    grep -q "/usr/local/sbin/platform-oem-install" /etc/calamares/modules/shellprocess_oemfinish.conf
}

enable_calamares_oem() {
    echo "[INFO] Preparing Calamares OEM mode..."
    if ! command -v calamares >/dev/null 2>&1 || [ ! -x /usr/bin/calamares-launch-oem ] || [ ! -f /etc/calamares/oemconfig.tar.gz ]; then
        echo "[INFO] Installing Calamares packages inside image..."
        apt-get update
        apt-get install -y calamares calamares-settings-kubuntu
    fi

    echo "[INFO] Ensuring disk expansion tools are installed..."
    for pkg in parted e2fsprogs cloud-guest-utils; do
        if ! dpkg -s "${pkg}" >/dev/null 2>&1; then
            echo "[INFO] Installing ${pkg}..."
            apt-get install -y "${pkg}" || echo "[WARN] Failed to install ${pkg}, expansion may not work"
        fi
    done

    command -v calamares >/dev/null 2>&1
    [ -x /usr/bin/calamares-launch-oem ]
    [ -f /etc/calamares/oemconfig.tar.gz ]

    cleanup_calamares_conflicts
    ensure_oem_user
    backup_sddm_conf

    echo "[INFO] Extracting Kubuntu OEM session files..."
    mkdir -p /etc/calamares/modules /usr/libexec /usr/share/xsessions /usr/share/applications /home/oem/Desktop
    tar xvzf /etc/calamares/oemconfig.tar.gz -C / --strip-components=2 >/dev/null
    configure_oem_finish

    if [ ! -x /usr/libexec/start-kubuntu-oem-env ]; then
        cat > /usr/libexec/start-kubuntu-oem-env <<'\''EOF'\''
#!/bin/bash
export QT_STYLE_OVERRIDE="Breeze"
export BROWSER="sudo -H -u kubuntu firefox"

/usr/bin/kwin_x11 &
if [ -x /usr/bin/basicwallpaper ]; then
    /usr/bin/basicwallpaper /usr/share/wallpapers/Next/contents/3840x2160.png &
fi
sudo -E /usr/bin/calamares -D8
killall basicwallpaper 2>/dev/null || true
killall kwin_x11 2>/dev/null || true
EOF
        chmod 0755 /usr/libexec/start-kubuntu-oem-env
    fi

    if [ ! -f /usr/share/xsessions/kubuntu-oem-environment.desktop ]; then
        cat > /usr/share/xsessions/kubuntu-oem-environment.desktop <<'\''EOF'\''
[Desktop Entry]
Exec=/usr/libexec/start-kubuntu-oem-env
Name=Kubuntu OEM Environment
Comment=Starts the Kubuntu OEM Environment
Type=Application
EOF
    fi
    if [ ! -f /usr/share/applications/calamares-finish-oem.desktop ]; then
        cat > /usr/share/applications/calamares-finish-oem.desktop <<'\''EOF'\''
[Desktop Entry]
Type=Application
Version=1.0
Name=Finish OEM preparation
Exec=/usr/bin/calamares-finish-oem
Icon=system-software-install
Terminal=false
StartupNotify=true
Categories=Qt;System;
Keywords=installer;calamares;system;
EOF
    fi

    [ -x /usr/libexec/start-kubuntu-oem-env ]
    [ -f /usr/share/xsessions/kubuntu-oem-environment.desktop ]

    if [ -f /etc/sudoers ] && [ ! -f /etc/sudoers.orig ]; then
        cp -a /etc/sudoers /etc/sudoers.orig
    fi
    if [ -f /etc/sudoers.oem ]; then
        cp -f /etc/sudoers.oem /etc/sudoers
        chmod 0440 /etc/sudoers
    fi

    chown -R oem:oem /home/oem
    printf "%s\n" "[Autologin]" "Session=kubuntu-oem-environment" "User=oem" > /etc/sddm.conf
    echo "[INFO] SDDM autologin configured for kubuntu-oem-environment."
}
if ! apt-cache show calamares-settings-kubuntu >/dev/null 2>&1; then
    echo "[ERR] calamares-settings-kubuntu is unavailable in this image." >&2
    exit 1
fi

enable_calamares_oem
'
then
    exit 1
fi

echo ""
echo "Result:"
if [ -f "${MOUNT_POINT}/etc/sddm.conf" ] && grep -q 'Session=kubuntu-oem-environment' "${MOUNT_POINT}/etc/sddm.conf"; then
    echo " -> SDDM autologin is set to kubuntu-oem-environment"
fi
if [ -x "${MOUNT_POINT}/usr/bin/calamares-launch-oem" ]; then
    echo " -> calamares-launch-oem present"
fi
if [ -x "${MOUNT_POINT}/usr/local/sbin/platform-oem-install" ]; then
    echo " -> platform-oem-install injected"
fi
if [ -d "${MOUNT_POINT}/home/oem" ]; then
    echo " -> OEM user home prepared"
fi

sync "${MOUNT_POINT}" || true
sync || true

echo ""
echo "[OK] Calamares OEM first-run has been armed for next boot."
