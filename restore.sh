#!/bin/bash
set -e

# Ensure script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root. Please run 'sudo -i' or execute with sudo."
    exit 1
fi

echo ""
echo "==================================================="
echo "          Debian Live USB Restore Utility          "
echo "==================================================="

# Display available block devices overview
echo ""
lsblk -f
echo ""

# Dynamically scan for BTRFS pools (handles multi-disk pools)
btrfs device scan

# Helper function to construct partition paths (handles both nvme0n1p1 and sda1)
get_part() {
    local disk=$1
    local num=$2
    if [[ "$disk" =~ [0-9]$ ]]; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

# Helper function to list snapshot numbers in numeric order with 8-digit placeholders
list_snapshots() {
    local snap_dir="$1"
    echo ""

    local raw_nums=()
    for dir in "$snap_dir"/*/; do
        [ -d "$dir" ] || continue
        local base
        base=$(basename "$dir")
        if [[ "$base" =~ ^[0-9]+$ ]] && [ -f "$snap_dir/$base/info.xml" ]; then
            raw_nums+=("$base")
        fi
    done

    if [ ${#raw_nums[@]} -eq 0 ]; then
        echo " No snapshots found!"
        return
    fi

    # Sort snapshot IDs numerically (lowest to highest)
    local sorted_nums
    sorted_nums=($(printf '%s\n' "${raw_nums[@]}" | sort -n))

    for num in "${sorted_nums[@]}"; do
        local xml="${snap_dir}/${num}/info.xml"
        local date desc formatted_id

        # Format snapshot ID with 8-digit zero padding (e.g. 00000001, 00000007, 00000043)
        formatted_id=$(printf "%08d" "$num")
        date=$(grep -oP '(?<=<date>).*?(?=</date>)' "$xml" 2>/dev/null || sed -n 's/.*<date>\(.*\)<\/date>.*/\1/p' "$xml")
        desc=$(grep -oP '(?<=<description>).*?(?=</description>)' "$xml" 2>/dev/null || sed -n 's/.*<description>\(.*\)<\/description>.*/\1/p' "$xml")

        echo "    ID    |      Date (UTC)     |   Description"
        echo " $formatted_id | $date | $desc"
    done
    echo ""
}

# Prompt 1: System Profile
echo ""
echo "Select Configuration:"
echo " 1) Desktop (No LUKS: p1=/boot/efi, p2=/)"
echo " 2) Laptop  (LUKS:    p1=/boot/efi, p2=/boot, p3=/)"
echo ""
read -rp "Enter choice [1 or 2]: " PROFILE < /dev/tty

# Prompt 2: Dynamic Target Disk Selection Menu
DISK_LIST=($(lsblk -p -d -n -o NAME,TYPE | awk '$2=="disk" {print $1}'))

if [ ${#DISK_LIST[@]} -eq 0 ]; then
    echo "Error: No physical disk devices detected!"
    exit 1
fi

echo ""
echo "Select target disk to install /boot/efi system partition:"
for i in "${!DISK_LIST[@]}"; do
    d="${DISK_LIST[$i]}"
    size=$(lsblk -d -n -o SIZE "$d" 2>/dev/null)
    model=$(lsblk -d -n -o MODEL "$d" 2>/dev/null | xargs)
    echo "  $((i+1))) $d ($size ${model:-Unknown Model})"
done
echo ""

while true; do
    read -rp "Enter choice [1-${#DISK_LIST[@]}]: " DISK_CHOICE < /dev/tty
    if [[ "$DISK_CHOICE" =~ ^[0-9]+$ ]] && [ "$DISK_CHOICE" -ge 1 ] && [ "$DISK_CHOICE" -le "${#DISK_LIST[@]}" ]; then
        TARGET_DISK="${DISK_LIST[$((DISK_CHOICE-1))]}"
        break
    else
        echo "Invalid selection. Please enter a number between 1 and ${#DISK_LIST[@]}."
    fi
done

EFI_DEV=$(get_part "$TARGET_DISK" 1)

if [ "$PROFILE" -eq 1 ]; then
    IS_LUKS=false
    ROOT_DEV=$(get_part "$TARGET_DISK" 2)
    BOOT_DEV=""
elif [ "$PROFILE" -eq 2 ]; then
    IS_LUKS=true
    BOOT_DEV=$(get_part "$TARGET_DISK" 2)
    LUKS_DEV=$(get_part "$TARGET_DISK" 3)
    MAPPER_NAME="$(basename "$LUKS_DEV")_crypt"
    ROOT_DEV="/dev/mapper/$MAPPER_NAME"

    # Prompt LUKS Crypt Unlock
    echo ""
    cryptsetup open "$LUKS_DEV" "$MAPPER_NAME" < /dev/tty
    echo ""
    
    # Rescan BTRFS pools after LUKS unlock
    btrfs device scan
else
    echo "Invalid profile selection. Aborting."
    exit 1
fi

# Prompt 3: Restore Root Snapshot?
echo ""
read -rp "Do you want to restore a ROOT snapshot? (y/N): " RESTORE_ROOT < /dev/tty
if [[ "$RESTORE_ROOT" =~ ^[Yy]$ ]]; then
    mkdir -p /mnt/root
    mount -o subvolid=5 "$ROOT_DEV" /mnt/root

    # Interactively list available root snapshots in sorted order
    list_snapshots "/mnt/root/@rootfs/.snapshots"
    read -rp "Enter snapshot ID to restore for ROOT: " INPUT_SNAP < /dev/tty
    echo ""

    # Strip leading zeros safely using sed
    ROOT_SNAP=$(echo "$INPUT_SNAP" | sed 's/^0*//')
    [ -z "$ROOT_SNAP" ] && ROOT_SNAP="0"

    if [ -n "$ROOT_SNAP" ] && [ -d "/mnt/root/@rootfs/.snapshots/$ROOT_SNAP" ]; then
        mv /mnt/root/@rootfs/.snapshots /mnt/root/.snapshots
        btrfs subvolume delete /mnt/root/@rootfs
        btrfs subvolume snapshot "/mnt/root/.snapshots/$ROOT_SNAP/snapshot" /mnt/root/@rootfs
        rm -rf /mnt/root/@rootfs/.snapshots
        mv /mnt/root/.snapshots /mnt/root/@rootfs/.snapshots
        echo "Root snapshot $(printf '%08d' "$ROOT_SNAP") restored successfully."
    else
        echo "Error: Snapshot $INPUT_SNAP does not exist."
        umount /mnt/root
        exit 1
    fi
    umount /mnt/root
fi

# Restore Boot Snapshot (Laptop profile only)
if [ "$PROFILE" -eq 2 ]; then
    echo ""
    read -rp "Do you want to restore a BOOT snapshot? (y/N): " RESTORE_BOOT < /dev/tty
    if [[ "$RESTORE_BOOT" =~ ^[Yy]$ ]]; then
        mkdir -p /mnt/boot
        mount "$BOOT_DEV" /mnt/boot

        # Interactively list available boot snapshots in sorted order
        list_snapshots "/mnt/boot/.snapshots"
        read -rp "Enter snapshot ID to restore for BOOT: " INPUT_SNAP < /dev/tty
        echo ""

        # Strip leading zeros safely using sed
        BOOT_SNAP=$(echo "$INPUT_SNAP" | sed 's/^0*//')
        [ -z "$BOOT_SNAP" ] && BOOT_SNAP="0"

        if [ -n "$BOOT_SNAP" ] && [ -d "/mnt/boot/.snapshots/$BOOT_SNAP" ]; then
            rm -rf /mnt/boot/*
            cp -a "/mnt/boot/.snapshots/$BOOT_SNAP/snapshot/"* /mnt/boot/
            echo "Boot snapshot $(printf '%08d' "$BOOT_SNAP") restored successfully."
        else
            echo "Error: Snapshot $INPUT_SNAP does not exist."
            umount /mnt/boot
            exit 1
        fi
        umount /mnt/boot
    fi
fi

# Must restore EFI System Partition & GRUB
echo ""
echo "Mounting partitions and re-installing GRUB..."

mount -o subvol=@rootfs "$ROOT_DEV" /mnt
mkdir -p /mnt/boot

if [ -n "$BOOT_DEV" ]; then
    mount "$BOOT_DEV" /mnt/boot
fi

mkdir -p /mnt/boot/efi
mount "$EFI_DEV" /mnt/boot/efi

rm -rf /mnt/boot/efi/EFI/debian /mnt/boot/efi/EFI/BOOT

mount --bind /proc /mnt/proc
mount --bind /run /mnt/run
mount --rbind /sys /mnt/sys
mount --rbind /dev /mnt/dev
mount --make-rslave /mnt/sys
mount --make-rslave /mnt/dev

# Run chroot commands
chroot /mnt /bin/bash -c "
    update-initramfs -u -k all
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck --force-extra-removable
    update-grub
"

# Configure post-reboot one-time GRUB reconfigure script and autostart launchers
mkdir -p /mnt/usr/local/bin /mnt/etc/xdg/autostart /mnt/etc/profile.d

cat << 'EOF' > /mnt/usr/local/bin/one-time-grub-setup.sh
#!/bin/bash
if [ -f /usr/local/bin/one-time-grub-setup.sh ]; then
    echo ""
    echo "==================================================="
    echo "          Debian Live USB Restore Utility          "
    echo "==================================================="
    echo ""
    sudo dpkg-reconfigure grub-efi-amd64
    
    echo ""
    echo "Restore complete!"
    echo ""
    read -rp "Press enter to exit..." < /dev/tty

    # Cleanly remove all traces of this one-time setup
    sudo rm -f /etc/xdg/autostart/one-time-grub.desktop
    sudo rm -f /etc/profile.d/one-time-grub.sh
    sudo rm -f /usr/local/bin/one-time-grub-setup.sh
fi
EOF

chmod +x /mnt/usr/local/bin/one-time-grub-setup.sh

cat << 'EOF' > /mnt/etc/xdg/autostart/one-time-grub.desktop
[Desktop Entry]
Type=Application
Name=One-Time GRUB Setup
Exec=x-terminal-emulator -e /usr/local/bin/one-time-grub-setup.sh
Terminal=false
X-GNOME-Autostart-enabled=true
EOF

cat << 'EOF' > /mnt/etc/profile.d/one-time-grub.sh
if [ -f /usr/local/bin/one-time-grub-setup.sh ] && [ -t 0 ]; then
    /usr/local/bin/one-time-grub-setup.sh
fi
EOF

# Flush pending disk writes
sync

# Clean up mounts in reverse order using lazy unmount (-l)
umount -l /mnt/dev/pts 2>/dev/null || true
umount -l /mnt/dev 2>/dev/null || true
umount -l /mnt/sys 2>/dev/null || true
umount -l /mnt/proc 2>/dev/null || true
umount -l /mnt/run 2>/dev/null || true
umount -l /mnt/boot/efi 2>/dev/null || true
umount -l /mnt/boot 2>/dev/null || true
umount -l /mnt 2>/dev/null || true

# Wait for udev to process events and release handles
udevadm settle 2>/dev/null || true

if [ "$IS_LUKS" = true ]; then
    if ! cryptsetup close "$MAPPER_NAME" 2>/dev/null; then
        sleep 1
        udevadm settle 2>/dev/null || true
        cryptsetup close "$MAPPER_NAME" 2>/dev/null || dmsetup remove --retry "$MAPPER_NAME" 2>/dev/null || true
    fi
fi

echo ""

CANCEL_REBOOT=false
REBOOT_IMMEDIATELY=false

for i in {10..1}; do
    echo -ne "\rRebooting in ${i}s (Y/n): "
    if read -rt 1 -n 1 key < /dev/tty 2>/dev/null; then
        if [[ "$key" =~ ^[Nn]$ ]]; then
            CANCEL_REBOOT=true
            break
        else
            REBOOT_IMMEDIATELY=true
            break
        fi
    fi
done

echo ""
if [ "$CANCEL_REBOOT" = true ]; then
    echo "Reboot canceled."
else
    if [ "$REBOOT_IMMEDIATELY" = true ]; then
        echo "Rebooting immediately..."
    else
        echo "Rebooting..."
    fi
    reboot
fi
