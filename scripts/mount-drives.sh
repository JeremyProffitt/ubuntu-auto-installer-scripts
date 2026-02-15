#!/bin/bash
# ============================================================================
# Auto Mount Script - Mounts all detected drives
# ============================================================================

set +e
ERROR_COUNT=0
export DEBIAN_FRONTEND=noninteractive

LOG_FILE="/var/log/mount-drives.log"
touch "$LOG_FILE"
chmod 640 "$LOG_FILE"
chown root:adm "$LOG_FILE" 2>/dev/null || true
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo "Auto Mount Drives Script"
echo "Started: $(date)"
echo "=========================================="

# Load configuration safely for standalone use (INSTALL_USERNAME, etc.)
CONFIG_FILE="/opt/ubuntu-installer/config.env"
if [ -f "$CONFIG_FILE" ]; then
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            case "$key" in PATH|LD_PRELOAD|LD_LIBRARY_PATH|LD_AUDIT|LD_DEBUG_OUTPUT|HOME|SHELL|USER|IFS|TERM|LANG|PS1|ENV|BASH_ENV|PROMPT_COMMAND|CDPATH|GLOBIGNORE|PYTHONPATH|PYTHONSTARTUP|NODE_OPTIONS|NODE_PATH|HISTFILE) continue ;; esac
            export "$key=$value"
        fi
    done < "$CONFIG_FILE"
fi

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
    # Resolve the root mount to its parent block device, handling LVM and partitions
    local root_source
    root_source=$(findmnt -n -o SOURCE /)

    # Use lsblk to find the parent device (works for LVM, partitions, NVMe, etc.)
    local parent
    parent=$(lsblk -no PKNAME "$root_source" 2>/dev/null | head -1)

    if [ -n "$parent" ]; then
        # For LVM, PKNAME gives the LV device; trace further to the PV's parent disk
        if [[ "$root_source" == /dev/mapper/* ]] || [[ "$root_source" == /dev/dm-* ]]; then
            local pv_dev
            pv_dev=$(pvs --noheadings -o pv_name -S "lv_path=$root_source" 2>/dev/null | awk '{print $1}' | head -1)
            if [ -z "$pv_dev" ]; then
                # Fallback: get PV from the VG that contains this LV
                local vg_name
                vg_name=$(lvs --noheadings -o vg_name "$root_source" 2>/dev/null | awk '{print $1}')
                pv_dev=$(pvs --noheadings -o pv_name -S "vg_name=$vg_name" 2>/dev/null | awk '{print $1}' | head -1)
            fi
            if [ -n "$pv_dev" ]; then
                parent=$(lsblk -no PKNAME "$pv_dev" 2>/dev/null | head -1)
                [ -z "$parent" ] && parent=$(echo "$pv_dev" | sed 's|/dev/||; s/p[0-9]*$//; s/[0-9]*$//')
            fi
        fi
        echo "/dev/$parent"
    else
        # Final fallback
        echo "$root_source" | sed 's/[0-9]*$//' | sed 's/p$//'
    fi
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

    # Sanitize label to prevent path traversal (strip slashes, dots-only, control chars, leading hyphens)
    if [ -n "$label" ]; then
        label=$(echo "$label" | tr -d '/\\' | sed 's/^\.\.*//' | tr -cd '[:alnum:]._-' | sed 's/^-*//')
        [ -z "$label" ] && label="$dev_name"
    fi

    # Handle label collision: append numeric suffix if mount point is in use
    if [ -n "$label" ]; then
        mount_point="$MOUNT_BASE/$label"
        local suffix=2
        while findmnt -n "$mount_point" &>/dev/null; do
            mount_point="$MOUNT_BASE/${label}-${suffix}"
            suffix=$((suffix + 1))
            if [ "$suffix" -gt 100 ]; then
                log_warn "Too many mount point collisions for label $label, falling back to device name"
                mount_point="$MOUNT_BASE/$dev_name"
                break
            fi
        done
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

    # Dynamic UID/GID lookup for the install user
    local user_uid=$(id -u "${INSTALL_USERNAME:-admin}" 2>/dev/null || echo "1000")
    local user_gid=$(id -g "${INSTALL_USERNAME:-admin}" 2>/dev/null || echo "1000")

    # Mount options based on filesystem (nosuid,nodev,noexec for data drives)
    local mount_opts="defaults,nosuid,nodev,noexec"
    case "$fs_type" in
        ext4|ext3|ext2)
            mount_opts="defaults,noatime,nosuid,nodev,noexec"
            ;;
        ntfs)
            mount_opts="defaults,uid=${user_uid},gid=${user_gid},umask=022,nosuid,nodev,noexec"
            # Need ntfs-3g for full read-write NTFS support (kernel ntfs driver is read-only on <24.04)
            apt-get install -y ntfs-3g 2>/dev/null || true
            fs_type="ntfs-3g"
            ;;
        vfat|exfat)
            mount_opts="defaults,uid=${user_uid},gid=${user_gid},umask=022,nosuid,nodev,noexec"
            apt-get install -y exfatprogs 2>/dev/null || true
            ;;
        xfs)
            mount_opts="defaults,noatime,nosuid,nodev,noexec"
            ;;
        btrfs)
            mount_opts="defaults,noatime,compress=zstd,nosuid,nodev,noexec"
            ;;
    esac

    # Mount
    if mount -t "$fs_type" -o "$mount_opts" "$partition" "$mount_point"; then
        log_info "Mounted $partition ($fs_type) at $mount_point"

        # Add to fstab for persistence (update existing entry if mount point changed)
        local uuid=$(blkid -o value -s UUID "$partition")
        if [ -n "$uuid" ]; then
            local fstab_entry="UUID=$uuid $mount_point $fs_type $mount_opts,nofail,x-systemd.device-timeout=10s 0 0"
            if grep -q "UUID=$uuid" /etc/fstab; then
                # UUID already in fstab - verify mount point matches, update if changed
                local existing_mp
                existing_mp=$(grep "UUID=$uuid" /etc/fstab | awk '{print $2}')
                if [ "$existing_mp" != "$mount_point" ]; then
                    log_info "Updating fstab entry for $partition: $existing_mp -> $mount_point"
                    sed -i "\|UUID=$uuid|d" /etc/fstab
                    echo "$fstab_entry" >> /etc/fstab
                fi
            else
                echo "$fstab_entry" >> /etc/fstab
                log_info "Added $partition to /etc/fstab"
            fi
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

        # Verify it's actually a block device
        [ -b "$nvme_dev" ] || continue

        local dev_name=$(basename "$nvme_dev")
        log_info "Found NVMe device: $nvme_dev"

        # Check if this is the root device
        if [ "/dev/$dev_name" = "$ROOT_BASE" ]; then
            log_info "Skipping root device $nvme_dev"
            continue
        fi

        # Mount partitions
        for partition in ${nvme_dev}p*; do
            [ -e "$partition" ] || continue

            local fs_type=$(get_fs_type "$partition")
            local label=$(get_partition_label "$partition")

            # Skip swap partitions
            if [ "$fs_type" = "swap" ]; then
                log_info "Skipping swap partition $partition"
                continue
            fi

            # Skip LVM, RAID, and LUKS partitions (managed by their own subsystems)
            case "$fs_type" in
                LVM2_member|linux_raid_member|crypto_LUKS)
                    log_info "Skipping $fs_type partition $partition (managed by subsystem)"
                    continue
                    ;;
            esac

            # Skip EFI/system partitions (check both label and GPT partition type GUID)
            if [ "$fs_type" = "vfat" ]; then
                local part_type
                part_type=$(blkid -o value -s PART_ENTRY_TYPE "$partition" 2>/dev/null || true)
                if [[ "$part_type" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] || \
                   { [ -n "$label" ] && [[ "$label" =~ ^(EFI|SYSTEM) ]]; }; then
                    log_info "Skipping EFI partition $partition"
                    continue
                fi
            fi

            if [ -n "$fs_type" ]; then
                mount_partition "$partition" "$fs_type" "$label" || ERROR_COUNT=$((ERROR_COUNT + 1))
            else
                log_warn "No filesystem detected on $partition"
            fi
        done
    done
}

# Detect and mount SATA/SSD drives
mount_sata_drives() {
    log_info "Scanning for SATA drives..."

    for disk in /dev/sd[a-z] /dev/sd[a-z][a-z]; do
        [ -b "$disk" ] || continue

        local dev_name=$(basename "$disk")
        log_info "Found SATA device: $disk"

        # Skip removable devices
        if is_removable "$disk"; then
            log_info "Skipping removable device $disk"
            continue
        fi

        # Check if this is the root device
        if [ "/dev/$dev_name" = "$ROOT_BASE" ]; then
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

            # Skip LVM, RAID, and LUKS partitions (managed by their own subsystems)
            case "$fs_type" in
                LVM2_member|linux_raid_member|crypto_LUKS)
                    log_info "Skipping $fs_type partition $partition (managed by subsystem)"
                    continue
                    ;;
            esac

            # Skip EFI partitions (check both label and GPT partition type GUID)
            if [ "$fs_type" = "vfat" ]; then
                local part_type
                part_type=$(blkid -o value -s PART_ENTRY_TYPE "$partition" 2>/dev/null || true)
                if [[ "$part_type" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] || \
                   { [ -n "$label" ] && [[ "$label" =~ ^(EFI|SYSTEM) ]]; }; then
                    log_info "Skipping EFI partition $partition"
                    continue
                fi
            fi

            if [ -n "$fs_type" ]; then
                mount_partition "$partition" "$fs_type" "$label" || ERROR_COUNT=$((ERROR_COUNT + 1))
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

    findmnt -r -n -o TARGET,SOURCE,FSTYPE,SIZE | grep "^$MOUNT_BASE" | while read -r target source fstype size; do
        printf "%-28s %-18s %-10s %s\n" "$target" "$source" "$fstype" "$size"
    done

    echo ""
    echo "All storage devices:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
}

# Main
main() {
    if [ "$(id -u)" != "0" ]; then
        echo "This script must be run as root"
        exit 1
    fi

    log_info "Starting auto-mount process..."

    # Refresh apt cache if stale (needed for standalone runs where ntfs-3g/exfatprogs may not be cached)
    local apt_cache="/var/cache/apt/pkgcache.bin"
    if [ ! -f "$apt_cache" ] || [ $(($(date +%s) - $(stat -c %Y "$apt_cache"))) -gt 3600 ]; then
        log_info "Refreshing apt cache..."
        apt-get update 2>/dev/null || true
    fi

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

    # Cap exit code at 125 to avoid wrapping
    [ "$ERROR_COUNT" -gt 125 ] && ERROR_COUNT=125
    sleep 0.5  # Allow tee process substitution to flush final log lines
    exit $ERROR_COUNT
}

main "$@"
