#!/bin/bash
# ============================================================================
# Auto Mount Script - Mounts all detected drives
# ============================================================================

set -e

LOG_FILE="/var/log/mount-drives.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo "Auto Mount Drives Script"
echo "Started: $(date)"
echo "=========================================="

MOUNT_BASE="/mnt"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Get root device to exclude
get_root_device() {
    ROOT_DEV=$(findmnt -n -o SOURCE /)
    # Get base device (without partition number)
    ROOT_BASE=$(echo "$ROOT_DEV" | sed 's/[0-9]*$//' | sed 's/p$//')
    echo "$ROOT_BASE"
}

# Check if device is a removable/USB device
is_removable() {
    local dev=$1
    local dev_name=$(basename "$dev")

    # Check if it's removable
    if [ -f "/sys/block/$dev_name/removable" ]; then
        if [ "$(cat /sys/block/$dev_name/removable)" = "1" ]; then
            return 0
        fi
    fi

    # Check if it's USB
    if readlink -f "/sys/block/$dev_name" | grep -q "usb"; then
        return 0
    fi

    return 1
}

# Get filesystem type
get_fs_type() {
    local partition=$1
    blkid -o value -s TYPE "$partition" 2>/dev/null || echo ""
}

# Get partition label
get_partition_label() {
    local partition=$1
    blkid -o value -s LABEL "$partition" 2>/dev/null || echo ""
}

# Mount a partition
mount_partition() {
    local partition=$1
    local fs_type=$2
    local label=$3

    # Create mount point name
    local dev_name=$(basename "$partition")
    local mount_point=""

    if [ -n "$label" ]; then
        mount_point="$MOUNT_BASE/$label"
    else
        mount_point="$MOUNT_BASE/$dev_name"
    fi

    # Skip if already mounted
    if findmnt -n "$partition" &>/dev/null; then
        log_info "$partition is already mounted at $(findmnt -n -o TARGET $partition)"
        return 0
    fi

    # Create mount point
    mkdir -p "$mount_point"

    # Mount options based on filesystem
    local mount_opts="defaults"
    case "$fs_type" in
        ext4|ext3|ext2)
            mount_opts="defaults,noatime"
            ;;
        ntfs)
            mount_opts="defaults,uid=1000,gid=1000,umask=022"
            # Need ntfs-3g for full NTFS support
            apt-get install -y ntfs-3g 2>/dev/null || true
            ;;
        vfat|fat32|exfat)
            mount_opts="defaults,uid=1000,gid=1000,umask=022"
            apt-get install -y exfat-fuse exfat-utils 2>/dev/null || true
            ;;
        xfs)
            mount_opts="defaults,noatime"
            ;;
        btrfs)
            mount_opts="defaults,noatime,compress=zstd"
            ;;
    esac

    # Mount
    if mount -t "$fs_type" -o "$mount_opts" "$partition" "$mount_point"; then
        log_info "Mounted $partition ($fs_type) at $mount_point"

        # Add to fstab for persistence
        local uuid=$(blkid -o value -s UUID "$partition")
        if [ -n "$uuid" ] && ! grep -q "$uuid" /etc/fstab; then
            echo "UUID=$uuid $mount_point $fs_type $mount_opts 0 2" >> /etc/fstab
            log_info "Added $partition to /etc/fstab"
        fi

        return 0
    else
        log_warn "Failed to mount $partition"
        rmdir "$mount_point" 2>/dev/null || true
        return 1
    fi
}

# Detect and mount NVMe drives
mount_nvme_drives() {
    log_info "Scanning for NVMe drives..."

    for nvme_dev in /dev/nvme*n*; do
        [ -e "$nvme_dev" ] || continue

        # Skip if it's a partition
        [[ "$nvme_dev" =~ p[0-9]+$ ]] && continue

        local dev_name=$(basename "$nvme_dev")
        log_info "Found NVMe device: $nvme_dev"

        # Check if this is the root device
        if [[ "$ROOT_BASE" == *"$dev_name"* ]]; then
            log_info "Skipping root device $nvme_dev"
            continue
        fi

        # Mount partitions
        for partition in ${nvme_dev}p*; do
            [ -e "$partition" ] || continue

            local fs_type=$(get_fs_type "$partition")
            local label=$(get_partition_label "$partition")

            if [ -n "$fs_type" ]; then
                mount_partition "$partition" "$fs_type" "$label"
            else
                log_warn "No filesystem detected on $partition"
            fi
        done
    done
}

# Detect and mount SATA/SSD drives
mount_sata_drives() {
    log_info "Scanning for SATA drives..."

    for disk in /dev/sd[a-z]; do
        [ -e "$disk" ] || continue

        local dev_name=$(basename "$disk")
        log_info "Found SATA device: $disk"

        # Skip removable devices
        if is_removable "$disk"; then
            log_info "Skipping removable device $disk"
            continue
        fi

        # Check if this is the root device
        if [[ "$ROOT_BASE" == *"$dev_name"* ]]; then
            log_info "Skipping root device $disk"
            continue
        fi

        # Mount partitions
        for partition in ${disk}[0-9]*; do
            [ -e "$partition" ] || continue

            local fs_type=$(get_fs_type "$partition")
            local label=$(get_partition_label "$partition")

            # Skip swap partitions
            if [ "$fs_type" = "swap" ]; then
                log_info "Skipping swap partition $partition"
                continue
            fi

            # Skip EFI partitions
            if [ "$fs_type" = "vfat" ] && [ -n "$label" ] && [[ "$label" =~ ^EFI|SYSTEM ]]; then
                log_info "Skipping EFI partition $partition"
                continue
            fi

            if [ -n "$fs_type" ]; then
                mount_partition "$partition" "$fs_type" "$label"
            else
                log_warn "No filesystem detected on $partition"
            fi
        done
    done
}

# Display mounted drives
display_mounts() {
    log_info "=========================================="
    log_info "Currently Mounted Drives"
    log_info "=========================================="

    echo ""
    echo "Mount Point                  Device              Filesystem  Size"
    echo "-------------------------------------------------------------------"

    findmnt -r -n -o TARGET,SOURCE,FSTYPE,SIZE | grep "^$MOUNT_BASE" | while read line; do
        printf "%-28s %-18s %-10s %s\n" $line
    done

    echo ""
    echo "All storage devices:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
}

# Main
main() {
    log_info "Starting auto-mount process..."

    # Get root device
    ROOT_BASE=$(get_root_device)
    log_info "Root device: $ROOT_BASE"

    # Create base mount directory
    mkdir -p "$MOUNT_BASE"

    # Mount different drive types
    mount_nvme_drives
    mount_sata_drives

    # Reload systemd to recognize fstab changes
    systemctl daemon-reload

    # Display results
    display_mounts

    log_info "=========================================="
    log_info "Auto-mount completed!"
    log_info "=========================================="
}

main "$@"
