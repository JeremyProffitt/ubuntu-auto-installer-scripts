#!/bin/bash
# ============================================================================
# Interactive Drive Configuration Script
# Allows user to view, format, partition, and mount drives with custom names
# ============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Default mount base
MOUNT_BASE="/mnt"

# Log file
LOG_FILE="/var/log/drive-configuration.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

print_header() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}        ${BOLD}Interactive Drive Configuration Utility${NC}                  ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}        Ubuntu Auto Installer - Home Lab Setup                    ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_menu() {
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC}  ${BOLD}Main Menu${NC}                                                      ${CYAN}│${NC}"
    echo -e "${CYAN}├─────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC}  1. View all drives and partitions                              ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  2. View current mount points                                   ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  3. Format a drive/partition                                    ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  4. Partition a drive (fdisk/parted)                            ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  5. Mount a partition with custom name                          ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  6. Unmount a partition                                         ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  7. Configure auto-mount (fstab)                                ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  8. Create RAID array (mdadm)                                   ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  9. View SMART disk health                                      ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  0. Exit and save configuration                                 ${CYAN}│${NC}"
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
}

# Get root device to protect from accidental operations
get_root_device() {
    ROOT_DEV=$(findmnt -n -o SOURCE /)
    ROOT_BASE=$(echo "$ROOT_DEV" | sed 's/[0-9]*$//' | sed 's/p[0-9]*$//')
    echo "$ROOT_BASE"
}

# View all drives
view_drives() {
    print_header
    echo -e "${BOLD}All Detected Drives and Partitions:${NC}"
    echo ""

    # Get root device for highlighting
    ROOT_BASE=$(get_root_device)

    echo -e "${YELLOW}Legend: ${GREEN}[ROOT]${NC} = System drive, ${RED}[USB]${NC} = Removable${NC}"
    echo ""

    # Show block devices with details
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT,MODEL | while read line; do
        if echo "$line" | grep -q "$ROOT_BASE"; then
            echo -e "${GREEN}$line ${GREEN}[ROOT]${NC}"
        elif echo "$line" | grep -qi "usb\|removable"; then
            echo -e "${RED}$line${NC}"
        else
            echo "$line"
        fi
    done
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    echo ""
    echo -e "${BOLD}NVMe Drives:${NC}"
    if command -v nvme &> /dev/null; then
        nvme list 2>/dev/null || echo "  No NVMe drives detected"
    else
        echo "  nvme-cli not installed"
    fi

    echo ""
    read -p "Press Enter to continue..."
}

# View current mounts
view_mounts() {
    print_header
    echo -e "${BOLD}Current Mount Points:${NC}"
    echo ""

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    printf "%-20s %-15s %-10s %-10s %s\n" "DEVICE" "MOUNT POINT" "FSTYPE" "SIZE" "USED%"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    df -h --output=source,target,fstype,size,pcent | grep -E "^/dev" | while read line; do
        printf "%-20s %-15s %-10s %-10s %s\n" $line
    done

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    echo ""
    echo -e "${BOLD}fstab Entries:${NC}"
    grep -v "^#" /etc/fstab | grep -v "^$" | head -20

    echo ""
    read -p "Press Enter to continue..."
}

# Format a partition
format_partition() {
    print_header
    echo -e "${BOLD}Format a Drive/Partition${NC}"
    echo ""
    echo -e "${RED}WARNING: This will ERASE ALL DATA on the selected partition!${NC}"
    echo ""

    # Show available partitions (excluding root)
    ROOT_BASE=$(get_root_device)
    echo -e "${BOLD}Available partitions (excluding system drive):${NC}"
    echo ""

    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT | grep -v "$ROOT_BASE" | grep -E "part|disk"

    echo ""
    read -p "Enter partition to format (e.g., sdb1, nvme1n1p1) or 'q' to cancel: " PARTITION

    if [ "$PARTITION" = "q" ] || [ -z "$PARTITION" ]; then
        return
    fi

    # Add /dev/ prefix if not present
    if [[ ! "$PARTITION" =~ ^/dev/ ]]; then
        PARTITION="/dev/$PARTITION"
    fi

    # Safety check - don't format root
    if [[ "$PARTITION" =~ "$ROOT_BASE" ]]; then
        echo -e "${RED}ERROR: Cannot format the system drive!${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    # Check if partition exists
    if [ ! -b "$PARTITION" ]; then
        echo -e "${RED}ERROR: $PARTITION does not exist!${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    # Check if mounted
    if findmnt -n "$PARTITION" &>/dev/null; then
        echo -e "${YELLOW}Partition is currently mounted. Unmounting...${NC}"
        umount "$PARTITION" || {
            echo -e "${RED}Failed to unmount. Please unmount manually first.${NC}"
            read -p "Press Enter to continue..."
            return
        }
    fi

    echo ""
    echo -e "${BOLD}Select filesystem type:${NC}"
    echo "  1. ext4 (recommended for Linux)"
    echo "  2. xfs (good for large files)"
    echo "  3. btrfs (snapshots, compression)"
    echo "  4. ntfs (Windows compatible)"
    echo "  5. exfat (cross-platform, large files)"
    echo "  6. fat32/vfat (universal compatibility)"
    echo ""
    read -p "Enter choice (1-6): " FS_CHOICE

    case $FS_CHOICE in
        1) FSTYPE="ext4"; MKFS_CMD="mkfs.ext4" ;;
        2) FSTYPE="xfs"; MKFS_CMD="mkfs.xfs -f" ;;
        3) FSTYPE="btrfs"; MKFS_CMD="mkfs.btrfs -f" ;;
        4) FSTYPE="ntfs"; MKFS_CMD="mkfs.ntfs -f"; apt-get install -y ntfs-3g 2>/dev/null ;;
        5) FSTYPE="exfat"; MKFS_CMD="mkfs.exfat"; apt-get install -y exfat-utils 2>/dev/null ;;
        6) FSTYPE="vfat"; MKFS_CMD="mkfs.vfat" ;;
        *) echo "Invalid choice"; return ;;
    esac

    echo ""
    read -p "Enter a label for this partition (optional): " LABEL

    echo ""
    echo -e "${YELLOW}You are about to format:${NC}"
    echo "  Partition: $PARTITION"
    echo "  Filesystem: $FSTYPE"
    echo "  Label: ${LABEL:-<none>}"
    echo ""
    echo -e "${RED}ALL DATA WILL BE PERMANENTLY ERASED!${NC}"
    read -p "Type 'YES' to confirm: " CONFIRM

    if [ "$CONFIRM" != "YES" ]; then
        echo "Operation cancelled."
        read -p "Press Enter to continue..."
        return
    fi

    echo ""
    echo "Formatting $PARTITION as $FSTYPE..."

    if [ -n "$LABEL" ]; then
        case $FSTYPE in
            ext4) $MKFS_CMD -L "$LABEL" "$PARTITION" ;;
            xfs) $MKFS_CMD -L "$LABEL" "$PARTITION" ;;
            btrfs) $MKFS_CMD -L "$LABEL" "$PARTITION" ;;
            ntfs) $MKFS_CMD -L "$LABEL" "$PARTITION" ;;
            exfat) $MKFS_CMD -n "$LABEL" "$PARTITION" ;;
            vfat) $MKFS_CMD -n "$LABEL" "$PARTITION" ;;
        esac
    else
        $MKFS_CMD "$PARTITION"
    fi

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Format complete!${NC}"
        log "Formatted $PARTITION as $FSTYPE with label '$LABEL'"
    else
        echo -e "${RED}Format failed!${NC}"
    fi

    read -p "Press Enter to continue..."
}

# Partition a drive with fdisk/parted
partition_drive() {
    print_header
    echo -e "${BOLD}Partition a Drive${NC}"
    echo ""
    echo -e "${RED}WARNING: This can DESTROY DATA if used incorrectly!${NC}"
    echo ""

    # Show available drives (excluding root)
    ROOT_BASE=$(get_root_device)
    echo -e "${BOLD}Available drives (excluding system drive):${NC}"
    echo ""

    lsblk -d -o NAME,SIZE,TYPE,MODEL | grep -v "$ROOT_BASE" | grep disk

    echo ""
    read -p "Enter drive to partition (e.g., sdb, nvme1n1) or 'q' to cancel: " DRIVE

    if [ "$DRIVE" = "q" ] || [ -z "$DRIVE" ]; then
        return
    fi

    # Add /dev/ prefix if not present
    if [[ ! "$DRIVE" =~ ^/dev/ ]]; then
        DRIVE="/dev/$DRIVE"
    fi

    # Safety check
    if [[ "$DRIVE" =~ "$ROOT_BASE" ]]; then
        echo -e "${RED}ERROR: Cannot partition the system drive!${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    if [ ! -b "$DRIVE" ]; then
        echo -e "${RED}ERROR: $DRIVE does not exist!${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    echo ""
    echo -e "${BOLD}Select partitioning tool:${NC}"
    echo "  1. fdisk (interactive, MBR/GPT)"
    echo "  2. parted (command-line, GPT recommended)"
    echo "  3. cfdisk (visual, easy to use)"
    echo "  4. gdisk (GPT-specific)"
    echo ""
    read -p "Enter choice (1-4): " TOOL_CHOICE

    echo ""
    echo -e "${YELLOW}Launching partitioning tool for $DRIVE${NC}"
    echo -e "${YELLOW}Follow the tool's prompts to create partitions.${NC}"
    echo ""
    read -p "Press Enter to launch..."

    case $TOOL_CHOICE in
        1) fdisk "$DRIVE" ;;
        2) parted "$DRIVE" ;;
        3) cfdisk "$DRIVE" ;;
        4) gdisk "$DRIVE" ;;
        *) echo "Invalid choice"; return ;;
    esac

    # Reload partition table
    partprobe "$DRIVE" 2>/dev/null || true

    echo ""
    echo -e "${GREEN}Partitioning complete. New partition layout:${NC}"
    lsblk "$DRIVE"

    log "Partitioned drive $DRIVE"
    read -p "Press Enter to continue..."
}

# Mount a partition with custom name
mount_partition_custom() {
    print_header
    echo -e "${BOLD}Mount a Partition with Custom Name${NC}"
    echo ""

    # Show unmounted partitions
    echo -e "${BOLD}Available unmounted partitions:${NC}"
    echo ""

    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT | grep -v "MOUNTPOINT" | while read line; do
        # Show only unmounted partitions with filesystems
        MOUNTPOINT=$(echo "$line" | awk '{print $NF}')
        FSTYPE=$(echo "$line" | awk '{print $3}')
        if [ -z "$MOUNTPOINT" ] || [ "$MOUNTPOINT" = "$FSTYPE" ]; then
            if [ -n "$FSTYPE" ] && [ "$FSTYPE" != "TYPE" ] && [ "$FSTYPE" != "swap" ]; then
                echo "  $line"
            fi
        fi
    done

    echo ""
    read -p "Enter partition to mount (e.g., sdb1, nvme1n1p1) or 'q' to cancel: " PARTITION

    if [ "$PARTITION" = "q" ] || [ -z "$PARTITION" ]; then
        return
    fi

    # Add /dev/ prefix if not present
    if [[ ! "$PARTITION" =~ ^/dev/ ]]; then
        PARTITION="/dev/$PARTITION"
    fi

    if [ ! -b "$PARTITION" ]; then
        echo -e "${RED}ERROR: $PARTITION does not exist!${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    # Get filesystem type
    FSTYPE=$(blkid -o value -s TYPE "$PARTITION" 2>/dev/null)
    if [ -z "$FSTYPE" ]; then
        echo -e "${RED}ERROR: No filesystem detected on $PARTITION${NC}"
        echo "Please format the partition first."
        read -p "Press Enter to continue..."
        return
    fi

    # Get current label if any
    CURRENT_LABEL=$(blkid -o value -s LABEL "$PARTITION" 2>/dev/null)

    echo ""
    echo "Partition: $PARTITION"
    echo "Filesystem: $FSTYPE"
    echo "Current Label: ${CURRENT_LABEL:-<none>}"
    echo ""

    echo -e "${BOLD}Enter mount point name:${NC}"
    echo "  Examples: data, storage, backup, media, nvme-raid"
    echo "  The mount point will be: $MOUNT_BASE/<name>"
    echo ""
    read -p "Mount point name: " MOUNT_NAME

    if [ -z "$MOUNT_NAME" ]; then
        echo "No name provided, using partition name."
        MOUNT_NAME=$(basename "$PARTITION")
    fi

    MOUNT_POINT="$MOUNT_BASE/$MOUNT_NAME"

    # Create mount point
    mkdir -p "$MOUNT_POINT"

    # Determine mount options
    case "$FSTYPE" in
        ext4|ext3|ext2) MOUNT_OPTS="defaults,noatime" ;;
        xfs) MOUNT_OPTS="defaults,noatime" ;;
        btrfs) MOUNT_OPTS="defaults,noatime,compress=zstd" ;;
        ntfs) MOUNT_OPTS="defaults,uid=1000,gid=1000,umask=022" ;;
        exfat|vfat) MOUNT_OPTS="defaults,uid=1000,gid=1000,umask=022" ;;
        *) MOUNT_OPTS="defaults" ;;
    esac

    echo ""
    echo "Mounting $PARTITION to $MOUNT_POINT..."

    if mount -t "$FSTYPE" -o "$MOUNT_OPTS" "$PARTITION" "$MOUNT_POINT"; then
        echo -e "${GREEN}Successfully mounted!${NC}"
        echo ""
        echo "Mount point: $MOUNT_POINT"
        df -h "$MOUNT_POINT"

        log "Mounted $PARTITION to $MOUNT_POINT"

        echo ""
        read -p "Add to fstab for auto-mount on boot? (y/n): " ADD_FSTAB
        if [ "$ADD_FSTAB" = "y" ]; then
            add_to_fstab "$PARTITION" "$MOUNT_POINT" "$FSTYPE" "$MOUNT_OPTS"
        fi
    else
        echo -e "${RED}Mount failed!${NC}"
        rmdir "$MOUNT_POINT" 2>/dev/null
    fi

    read -p "Press Enter to continue..."
}

# Unmount a partition
unmount_partition() {
    print_header
    echo -e "${BOLD}Unmount a Partition${NC}"
    echo ""

    echo -e "${BOLD}Currently mounted partitions:${NC}"
    echo ""

    findmnt -r -n -o TARGET,SOURCE,FSTYPE | grep -E "^/mnt|^/media" | while read line; do
        echo "  $line"
    done

    echo ""
    read -p "Enter mount point to unmount (e.g., /mnt/data) or 'q' to cancel: " MOUNT_POINT

    if [ "$MOUNT_POINT" = "q" ] || [ -z "$MOUNT_POINT" ]; then
        return
    fi

    if ! findmnt -n "$MOUNT_POINT" &>/dev/null; then
        echo -e "${RED}ERROR: $MOUNT_POINT is not mounted${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    echo "Unmounting $MOUNT_POINT..."

    if umount "$MOUNT_POINT"; then
        echo -e "${GREEN}Successfully unmounted!${NC}"
        log "Unmounted $MOUNT_POINT"

        # Ask about fstab
        if grep -q "$MOUNT_POINT" /etc/fstab; then
            echo ""
            read -p "Remove from fstab? (y/n): " REMOVE_FSTAB
            if [ "$REMOVE_FSTAB" = "y" ]; then
                sed -i "\|$MOUNT_POINT|d" /etc/fstab
                echo "Removed from fstab."
            fi
        fi

        # Remove empty mount point directory
        rmdir "$MOUNT_POINT" 2>/dev/null || true
    else
        echo -e "${RED}Unmount failed! The partition may be in use.${NC}"
        echo "Try: lsof $MOUNT_POINT"
    fi

    read -p "Press Enter to continue..."
}

# Add entry to fstab
add_to_fstab() {
    local PARTITION=$1
    local MOUNT_POINT=$2
    local FSTYPE=$3
    local MOUNT_OPTS=$4

    # Get UUID
    UUID=$(blkid -o value -s UUID "$PARTITION")

    if [ -z "$UUID" ]; then
        echo -e "${YELLOW}Warning: Could not get UUID, using device path${NC}"
        FSTAB_ENTRY="$PARTITION $MOUNT_POINT $FSTYPE $MOUNT_OPTS 0 2"
    else
        FSTAB_ENTRY="UUID=$UUID $MOUNT_POINT $FSTYPE $MOUNT_OPTS 0 2"
    fi

    # Check if already in fstab
    if grep -q "$UUID" /etc/fstab 2>/dev/null || grep -q "$MOUNT_POINT" /etc/fstab; then
        echo -e "${YELLOW}Entry already exists in fstab${NC}"
        return
    fi

    # Add to fstab
    echo "$FSTAB_ENTRY" >> /etc/fstab
    echo -e "${GREEN}Added to fstab:${NC}"
    echo "  $FSTAB_ENTRY"

    log "Added fstab entry: $FSTAB_ENTRY"
}

# Configure fstab
configure_fstab() {
    print_header
    echo -e "${BOLD}Configure Auto-Mount (fstab)${NC}"
    echo ""

    echo -e "${BOLD}Current fstab entries:${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    cat -n /etc/fstab
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    echo ""
    echo "Options:"
    echo "  1. Add new fstab entry"
    echo "  2. Remove fstab entry"
    echo "  3. Test fstab (mount -a)"
    echo "  4. Edit fstab manually"
    echo "  5. Back to main menu"
    echo ""
    read -p "Enter choice: " FSTAB_CHOICE

    case $FSTAB_CHOICE in
        1)
            echo ""
            read -p "Enter partition (e.g., /dev/sdb1): " PARTITION
            read -p "Enter mount point (e.g., /mnt/data): " MOUNT_POINT
            read -p "Enter filesystem type (e.g., ext4): " FSTYPE
            read -p "Enter mount options [defaults,noatime]: " MOUNT_OPTS
            MOUNT_OPTS=${MOUNT_OPTS:-defaults,noatime}

            mkdir -p "$MOUNT_POINT"
            add_to_fstab "$PARTITION" "$MOUNT_POINT" "$FSTYPE" "$MOUNT_OPTS"
            ;;
        2)
            echo ""
            read -p "Enter mount point to remove from fstab: " MOUNT_POINT
            if grep -q "$MOUNT_POINT" /etc/fstab; then
                sed -i "\|$MOUNT_POINT|d" /etc/fstab
                echo -e "${GREEN}Removed from fstab${NC}"
            else
                echo "Mount point not found in fstab"
            fi
            ;;
        3)
            echo ""
            echo "Testing fstab configuration..."
            if mount -a; then
                echo -e "${GREEN}All fstab entries mounted successfully!${NC}"
            else
                echo -e "${RED}Some entries failed to mount${NC}"
            fi
            ;;
        4)
            ${EDITOR:-nano} /etc/fstab
            ;;
        5)
            return
            ;;
    esac

    read -p "Press Enter to continue..."
}

# Create RAID array
create_raid() {
    print_header
    echo -e "${BOLD}Create RAID Array (mdadm)${NC}"
    echo ""

    # Check if mdadm is installed
    if ! command -v mdadm &> /dev/null; then
        echo "Installing mdadm..."
        apt-get install -y mdadm
    fi

    echo -e "${BOLD}Available drives for RAID:${NC}"
    ROOT_BASE=$(get_root_device)
    lsblk -d -o NAME,SIZE,TYPE,MODEL | grep -v "$ROOT_BASE" | grep disk

    echo ""
    echo "RAID Levels:"
    echo "  0 - Striping (speed, no redundancy, 2+ drives)"
    echo "  1 - Mirroring (redundancy, 2 drives)"
    echo "  5 - Striping with parity (redundancy, 3+ drives)"
    echo "  6 - Striping with double parity (4+ drives)"
    echo "  10 - Mirrored stripes (4+ drives)"
    echo ""

    read -p "Enter RAID level (0/1/5/6/10) or 'q' to cancel: " RAID_LEVEL

    if [ "$RAID_LEVEL" = "q" ]; then
        return
    fi

    read -p "Enter drives space-separated (e.g., sdb sdc sdd): " DRIVES_INPUT

    # Convert to array and add /dev/ prefix
    DRIVES=""
    DRIVE_COUNT=0
    for drive in $DRIVES_INPUT; do
        if [[ ! "$drive" =~ ^/dev/ ]]; then
            drive="/dev/$drive"
        fi
        if [ -b "$drive" ]; then
            DRIVES="$DRIVES $drive"
            DRIVE_COUNT=$((DRIVE_COUNT + 1))
        else
            echo -e "${RED}Warning: $drive does not exist, skipping${NC}"
        fi
    done

    if [ $DRIVE_COUNT -lt 2 ]; then
        echo -e "${RED}ERROR: Need at least 2 drives for RAID${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    read -p "Enter RAID array name (e.g., md0): " RAID_NAME
    RAID_DEV="/dev/$RAID_NAME"

    echo ""
    echo -e "${YELLOW}Creating RAID $RAID_LEVEL array:${NC}"
    echo "  Device: $RAID_DEV"
    echo "  Drives: $DRIVES"
    echo "  Count: $DRIVE_COUNT"
    echo ""
    echo -e "${RED}WARNING: All data on these drives will be ERASED!${NC}"
    read -p "Type 'YES' to confirm: " CONFIRM

    if [ "$CONFIRM" != "YES" ]; then
        echo "Operation cancelled."
        read -p "Press Enter to continue..."
        return
    fi

    echo "Creating RAID array..."
    mdadm --create "$RAID_DEV" --level="$RAID_LEVEL" --raid-devices="$DRIVE_COUNT" $DRIVES

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}RAID array created!${NC}"

        # Save configuration
        mdadm --detail --scan >> /etc/mdadm/mdadm.conf
        update-initramfs -u

        echo ""
        echo "RAID Status:"
        cat /proc/mdstat

        echo ""
        read -p "Format the RAID array now? (y/n): " FORMAT_RAID
        if [ "$FORMAT_RAID" = "y" ]; then
            echo "Formatting $RAID_DEV as ext4..."
            mkfs.ext4 -L "RAID-$RAID_NAME" "$RAID_DEV"
            echo -e "${GREEN}Format complete!${NC}"
        fi

        log "Created RAID $RAID_LEVEL array $RAID_DEV with drives: $DRIVES"
    else
        echo -e "${RED}Failed to create RAID array${NC}"
    fi

    read -p "Press Enter to continue..."
}

# View SMART health
view_smart() {
    print_header
    echo -e "${BOLD}Disk Health (SMART)${NC}"
    echo ""

    if ! command -v smartctl &> /dev/null; then
        echo "Installing smartmontools..."
        apt-get install -y smartmontools
    fi

    echo -e "${BOLD}Select drive to check:${NC}"
    lsblk -d -o NAME,SIZE,MODEL | grep -E "sd|nvme"

    echo ""
    read -p "Enter drive (e.g., sda, nvme0n1) or 'all' for all drives: " DRIVE

    if [ "$DRIVE" = "all" ]; then
        for dev in /dev/sd? /dev/nvme?n?; do
            if [ -b "$dev" ]; then
                echo ""
                echo -e "${CYAN}━━━ $dev ━━━${NC}"
                smartctl -H "$dev" 2>/dev/null || echo "SMART not supported"
            fi
        done
    else
        if [[ ! "$DRIVE" =~ ^/dev/ ]]; then
            DRIVE="/dev/$DRIVE"
        fi

        echo ""
        echo -e "${BOLD}Health Summary:${NC}"
        smartctl -H "$DRIVE"

        echo ""
        read -p "Show detailed SMART info? (y/n): " SHOW_DETAIL
        if [ "$SHOW_DETAIL" = "y" ]; then
            smartctl -a "$DRIVE" | less
        fi
    fi

    read -p "Press Enter to continue..."
}

# Main loop
main() {
    # Check if running as root
    if [ "$(id -u)" != "0" ]; then
        echo "This script must be run as root"
        exit 1
    fi

    # Install required tools if missing
    apt-get install -y parted gdisk smartmontools mdadm ntfs-3g exfat-fuse 2>/dev/null || true

    while true; do
        print_header
        print_menu
        read -p "Enter choice: " CHOICE

        case $CHOICE in
            1) view_drives ;;
            2) view_mounts ;;
            3) format_partition ;;
            4) partition_drive ;;
            5) mount_partition_custom ;;
            6) unmount_partition ;;
            7) configure_fstab ;;
            8) create_raid ;;
            9) view_smart ;;
            0)
                echo ""
                echo -e "${GREEN}Configuration saved. Exiting...${NC}"
                systemctl daemon-reload
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option${NC}"
                sleep 1
                ;;
        esac
    done
}

main "$@"
