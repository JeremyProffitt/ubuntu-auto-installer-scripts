#!/bin/bash
# ============================================================================
# Ubuntu Driver Installation Script for Home Lab Computers
# Supports: HP Elite 8300, HP EliteDesk 800 G1, Lenovo ThinkCentre M92p,
#           Lenovo ThinkCentre M72, ASUS Z97 motherboards,
#           ASUS Hyper M.2 x16 Card V2, Dell Precision T7910,
#           ASUS ROG Strix G733QS (and similar ROG laptops)
# ============================================================================

set +e

# Prevent interactive dpkg prompts (conffile questions hang in systemd service context)
export DEBIAN_FRONTEND=noninteractive

ERROR_COUNT=0
GRUB_UPDATE_NEEDED=false
track_error() { ERROR_COUNT=$((ERROR_COUNT + 1)); }

LOG_FILE="/var/log/driver-installation.log"
touch "$LOG_FILE"
chmod 640 "$LOG_FILE"
chown root:adm "$LOG_FILE" 2>/dev/null || true
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo "Driver Installation Script"
echo "Started: $(date)"
echo "=========================================="

# Load configuration safely for standalone use (INSTALL_GUI, etc.)
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

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Detect hardware
detect_hardware() {
    log_info "Detecting hardware..."

    # Get system information
    SYSTEM_VENDOR=$(dmidecode -s system-manufacturer 2>/dev/null || echo "Unknown")
    SYSTEM_PRODUCT=$(dmidecode -s system-product-name 2>/dev/null || echo "Unknown")
    BASEBOARD_VENDOR=$(dmidecode -s baseboard-manufacturer 2>/dev/null || echo "Unknown")
    BASEBOARD_PRODUCT=$(dmidecode -s baseboard-product-name 2>/dev/null || echo "Unknown")

    # Hardware inventory for asset management
    local BIOS_VERSION SERIAL_NUMBER ASSET_TAG
    BIOS_VERSION=$(dmidecode -s bios-version 2>/dev/null || echo "Unknown")
    SERIAL_NUMBER=$(dmidecode -s system-serial-number 2>/dev/null || echo "Unknown")
    ASSET_TAG=$(dmidecode -s chassis-asset-tag 2>/dev/null || echo "Unknown")

    echo "System Vendor: $SYSTEM_VENDOR"
    echo "System Product: $SYSTEM_PRODUCT"
    echo "Baseboard Vendor: $BASEBOARD_VENDOR"
    echo "Baseboard Product: $BASEBOARD_PRODUCT"
    echo "BIOS Version: $BIOS_VERSION"
    echo "Serial Number: $SERIAL_NUMBER"
    echo "Asset Tag: $ASSET_TAG"

    # Detect specific hardware
    IS_HP_ELITE_8300=false
    IS_HP_800_G1=false
    IS_LENOVO_M92P=false
    IS_LENOVO_M72=false
    IS_ASUS_Z97=false
    IS_DELL_T7910=false
    IS_ASUS_ROG=false
    HAS_HYPER_M2=false

    if [[ "$SYSTEM_PRODUCT" == *"Elite 8300"* ]] || [[ "$SYSTEM_PRODUCT" == *"HP Compaq 8300"* ]]; then
        IS_HP_ELITE_8300=true
        log_info "Detected: HP Elite 8300"
    fi

    if [[ "$SYSTEM_PRODUCT" == *"EliteDesk 800 G1"* ]] || [[ "$SYSTEM_PRODUCT" == *"HP EliteDesk 800 G1"* ]]; then
        IS_HP_800_G1=true
        log_info "Detected: HP EliteDesk 800 G1 SFF"
    fi

    if [[ "$SYSTEM_PRODUCT" == *"M92p"* ]] || [[ "$SYSTEM_PRODUCT" == *"ThinkCentre M92p"* ]]; then
        IS_LENOVO_M92P=true
        log_info "Detected: Lenovo ThinkCentre M92p"
    fi

    if [[ "$SYSTEM_PRODUCT" == *"M72"* ]] || [[ "$SYSTEM_PRODUCT" == *"ThinkCentre M72"* ]]; then
        IS_LENOVO_M72=true
        log_info "Detected: Lenovo ThinkCentre M72"
    fi

    if [[ "$BASEBOARD_VENDOR" == *"ASUSTeK"* ]] && [[ "$BASEBOARD_PRODUCT" == *"Z97"* ]]; then
        IS_ASUS_Z97=true
        log_info "Detected: ASUS Z97 Motherboard"
    fi

    if [[ "$SYSTEM_VENDOR" == *"Dell"* ]] && { [[ "$SYSTEM_PRODUCT" == *"T7910"* ]] || [[ "$SYSTEM_PRODUCT" == *"Precision Tower 7910"* ]]; }; then
        IS_DELL_T7910=true
        log_info "Detected: Dell Precision T7910"
    fi

    if [[ "$SYSTEM_VENDOR" == *"ASUSTeK"* ]] && [[ "$SYSTEM_PRODUCT" == *"ROG Strix"* ]]; then
        IS_ASUS_ROG=true
        log_info "Detected: ASUS ROG Strix Laptop ($SYSTEM_PRODUCT)"
    fi

    # Check for ASUS Hyper M.2 x16 Card V2 (multiple NVMe controllers on single slot)
    # Only flag as Hyper M.2 on ASUS Z97 boards to avoid false positives on systems
    # with multiple NVMe drives in separate M.2 slots
    NVME_COUNT=$(lspci | grep -c "Non-Volatile memory" || true)
    NVME_COUNT=${NVME_COUNT:-0}
    if [ "$IS_ASUS_Z97" = true ] && [ "$NVME_COUNT" -ge 2 ]; then
        HAS_HYPER_M2=true
        log_info "Detected: Multiple NVMe controllers ($NVME_COUNT) on ASUS Z97 - ASUS Hyper M.2 card"
    fi
}

# Update package lists
update_packages() {
    log_info "Updating package lists..."
    apt-get update || true
}

# Install essential firmware and microcode
install_essential_firmware() {
    log_info "Installing essential firmware packages..."

    apt-get install -y \
        linux-firmware \
        intel-microcode \
        amd64-microcode \
        || { track_error; true; }
}

# Install Intel graphics drivers (for HD 2500/4000/4600)
install_intel_graphics() {
    if ! lspci | grep -qiE "Intel.*(Graphics|HD|UHD|Iris)"; then
        log_info "No Intel GPU detected - skipping Intel graphics drivers"
        return 0
    fi
    log_info "Installing Intel graphics drivers..."

    # Core Mesa/DRI and VA-API packages (useful for hardware video decode even on headless)
    apt-get install -y \
        mesa-utils \
        libgl1-mesa-dri \
        libgl1 \
        libva2 \
        libva-drm2 \
        intel-gpu-tools \
        || { track_error; true; }

    # X11-specific packages only when GUI is being installed
    if [ "${INSTALL_GUI:-false}" = "true" ]; then
        apt-get install -y \
            xserver-xorg-video-intel \
            mesa-vulkan-drivers \
            libva-x11-2 \
            vainfo \
            i965-va-driver \
            intel-media-va-driver \
            || { track_error; true; }
    fi
}

# Install NVIDIA graphics drivers (for Quadro/GeForce/Tesla GPUs)
# Supports: RTX 3060 (Ampere), Tesla P40 (Pascal), Quadro series
install_nvidia_graphics() {
    if ! lspci | grep -qi "NVIDIA"; then
        log_info "No NVIDIA GPU detected, skipping"
        return 0
    fi

    log_info "NVIDIA GPU detected, installing drivers..."

    # Identify specific GPU models
    local HAS_TESLA=false
    local HAS_RTX=false
    local GPU_LIST
    GPU_LIST=$(lspci | grep -i "NVIDIA" | grep -iE "VGA|3D|Display")
    echo "$GPU_LIST"

    if echo "$GPU_LIST" | grep -qi "Tesla"; then
        HAS_TESLA=true
        log_info "Detected: NVIDIA Tesla compute GPU"
    fi
    if echo "$GPU_LIST" | grep -qi "RTX\|GeForce"; then
        HAS_RTX=true
        log_info "Detected: NVIDIA RTX/GeForce display GPU"
    fi

    # Unload nouveau before installing NVIDIA proprietary driver
    rmmod nouveau 2>/dev/null || true

    # Add ubuntu-drivers PPA and detect recommended driver
    apt-get install -y ubuntu-drivers-common || { track_error; true; }

    RECOMMENDED_DRIVER=$(ubuntu-drivers devices 2>/dev/null | grep "recommended" | awk '{print $3}' | head -1)

    if [ "$HAS_TESLA" = true ] && [ "$HAS_RTX" = false ]; then
        # Tesla P40 (or other Tesla) is compute-only, no display outputs
        # Use headless/server driver variant
        log_info "Installing NVIDIA headless server driver for Tesla GPU..."
        if [ -n "$RECOMMENDED_DRIVER" ]; then
            # Convert to server variant if available
            # Strip -open and/or -server suffixes before appending -server
            SERVER_DRIVER="${RECOMMENDED_DRIVER%-server}"
            SERVER_DRIVER="${SERVER_DRIVER%-open}-server"
            apt-get install -y "$SERVER_DRIVER" 2>/dev/null || apt-get install -y "$RECOMMENDED_DRIVER" || { track_error; true; }
        else
            ubuntu-drivers autoinstall || { track_error; true; }
        fi
    else
        # RTX 3060, Quadro, or mixed (Tesla + display GPU) - install full driver
        log_info "Installing NVIDIA display driver..."
        if [ -n "$RECOMMENDED_DRIVER" ]; then
            log_info "Installing recommended NVIDIA driver: $RECOMMENDED_DRIVER"
            apt-get install -y "$RECOMMENDED_DRIVER" || { track_error; true; }
        else
            ubuntu-drivers autoinstall || { track_error; true; }
        fi
    fi

    # Install matching NVIDIA utilities (version must match installed driver)
    NVIDIA_VER=$(dpkg -l 2>/dev/null | grep -oP 'nvidia-driver-\K[0-9]+' | head -1)
    if [ -n "$NVIDIA_VER" ]; then
        apt-get install -y "nvidia-utils-${NVIDIA_VER}" nvidia-settings || true
    else
        apt-get install -y nvidia-settings || true
    fi

    # Install CUDA toolkit support (useful for Tesla P40 and RTX 3060 compute)
    if [ "$HAS_TESLA" = true ] || echo "$GPU_LIST" | grep -qi "RTX"; then
        log_info "Installing NVIDIA CUDA toolkit..."
        apt-get install -y nvidia-cuda-toolkit || true
    fi

    # Enable persistence mode for compute GPUs (Tesla P40, etc.)
    # Keeps the driver loaded to reduce initialization latency
    if [ "$HAS_TESLA" = true ]; then
        log_info "Enabling NVIDIA persistence mode for Tesla GPU..."
        # Explicitly install nvidia-persistenced package (not always pulled as dependency)
        apt-get install -y nvidia-persistenced 2>/dev/null || true
        # Create dedicated user for security (avoid running as root)
        useradd -r -s /bin/false -d /var/run/nvidia-persistenced nvidia-persistenced 2>/dev/null || true
        # Use a drop-in override to customize the package-provided service unit
        # (avoids conflicts on nvidia-persistenced package upgrades)
        mkdir -p /etc/systemd/system/nvidia-persistenced.service.d
        cat > /etc/systemd/system/nvidia-persistenced.service.d/override.conf << 'EOFNV'
[Service]
ExecStart=
ExecStart=/usr/bin/nvidia-persistenced --user nvidia-persistenced
ProtectHome=yes
EOFNV
        systemctl daemon-reload
        systemctl enable nvidia-persistenced 2>/dev/null || true
        log_info "NVIDIA persistence mode enabled (reduces GPU init latency for compute)"
    fi

    # Blacklist nouveau if NVIDIA proprietary driver installed
    if dpkg -l | grep -q "nvidia-driver"; then
        cat > /etc/modprobe.d/blacklist-nouveau.conf << 'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
        log_info "Blacklisted nouveau driver in favor of NVIDIA proprietary"
    fi
}

# Install AMD/Radeon graphics drivers (only if AMD GPU detected)
install_amd_graphics() {
    if ! lspci | grep -iE "VGA|3D|Display" | grep -qi "AMD\|Radeon\|ATI"; then
        log_info "No AMD/Radeon GPU detected - skipping AMD graphics drivers"
        return
    fi

    log_info "Installing AMD/Radeon graphics drivers..."

    # Core DRM/Mesa packages always (needed for compute and video acceleration)
    apt-get install -y \
        libdrm-radeon1 \
        mesa-va-drivers \
        || { track_error; true; }

    # X11 DDX drivers only when GUI is being installed
    if [ "${INSTALL_GUI:-false}" = "true" ]; then
        apt-get install -y \
            xserver-xorg-video-radeon \
            xserver-xorg-video-amdgpu \
            || { track_error; true; }
    fi
}

# Install Intel network drivers
install_intel_network() {
    log_info "Intel network drivers are built into kernel (e1000e, igb)..."
    log_info "Installing network utilities..."

    apt-get install -y \
        ethtool \
        net-tools \
        network-manager \
        || true
}

# Install Realtek network drivers (for Lenovo M72)
install_realtek_network() {
    log_info "Installing Realtek network support..."

    # Check if Realtek RTL8111 is present
    if lspci | grep -qi "RTL8111\|RTL8168"; then
        log_info "Realtek RTL8111/8168 detected"

        # The r8169 driver is built into the kernel
        # Install r8168-dkms if there are issues
        apt-get install -y dkms build-essential || true

        # Only install r8168-dkms if r8169 is causing issues
        # (uncomment if needed)
        # apt-get install -y r8168-dkms || true
    fi
}

# Install Broadcom WiFi drivers (for ASUS Z97 WiFi models)
install_broadcom_wifi() {
    log_info "Checking for Broadcom WiFi..."

    if lspci | grep -qi "BCM4352\|BCM4360\|BCM4331\|BCM43142\|BCM43228"; then
        log_info "Broadcom WiFi detected, installing drivers..."
        apt-get install -y bcmwl-kernel-source || true

        # Blacklist conflicting drivers
        cat > /etc/modprobe.d/blacklist-bcm.conf << 'EOF'
blacklist b43
blacklist bcma
blacklist brcmsmac
EOF
        log_info "Broadcom WiFi driver installed"
    else
        log_info "No Broadcom WiFi detected"
    fi
}

# Install Intel WiFi drivers
install_intel_wifi() {
    log_info "Intel WiFi drivers are built into kernel (iwlwifi)..."

    # Ensure firmware is installed
    apt-get install -y linux-firmware || true

    # Load module if Intel WiFi present
    if lspci | grep -qi "Intel.*Wireless\|Intel.*WiFi"; then
        log_info "Intel WiFi detected"
        modprobe iwlwifi 2>/dev/null || true
    fi
}

# Install audio drivers
install_audio_drivers() {
    log_info "Installing audio drivers and utilities..."

    # libasound2t64 only exists in Ubuntu 24.04+; 22.04 uses libasound2
    local alsa_lib="libasound2t64"
    if dpkg --compare-versions "$(lsb_release -rs 2>/dev/null || echo '24.04')" lt "24.04"; then
        alsa_lib="libasound2"
    fi
    apt-get install -y \
        alsa-utils \
        alsa-tools \
        "$alsa_lib" \
        libasound2-plugins \
        || { track_error; true; }

    # Install PulseAudio and pavucontrol only if a GUI is being installed
    if [ "${INSTALL_GUI:-false}" = "true" ]; then
        apt-get install -y \
            pulseaudio \
            pulseaudio-utils \
            pavucontrol \
            || true
    fi

    # Realtek audio codec configuration (use drop-in file, not alsa-base.conf)
    if ! grep -q "snd-hda-intel" /etc/modprobe.d/99-hda-intel-auto.conf 2>/dev/null; then
        echo "options snd-hda-intel model=auto" > /etc/modprobe.d/99-hda-intel-auto.conf
    fi
}

# Install storage/NVMe drivers
install_storage_drivers() {
    log_info "Installing storage drivers and utilities..."

    apt-get install -y \
        nvme-cli \
        smartmontools \
        hdparm \
        mdadm \
        lvm2 \
        || true

    # Enable smartd for continuous SMART health monitoring
    if [ -f /etc/default/smartmontools ]; then
        sed -i 's/^#start_smartd=yes/start_smartd=yes/' /etc/default/smartmontools 2>/dev/null || true
    fi
    systemctl enable smartd 2>/dev/null || true
    systemctl start smartd 2>/dev/null || true

    # Ensure NVMe modules are in initramfs (update-initramfs runs once at the end of main())
    if ! grep -q "^nvme" /etc/initramfs-tools/modules 2>/dev/null; then
        echo "nvme" >> /etc/initramfs-tools/modules
        echo "nvme_core" >> /etc/initramfs-tools/modules
    fi

    # Set NVMe I/O scheduler (none is recommended for NVMe)
    cat > /etc/udev/rules.d/60-nvme-scheduler.rules << 'EOF'
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", ATTR{queue/scheduler}="none"
EOF
}

# Install USB drivers
install_usb_drivers() {
    log_info "USB drivers are built into kernel (xhci_hcd, ehci_hcd)..."
    log_info "Installing USB utilities..."

    apt-get install -y \
        usbutils \
        || true
}

# Install hardware monitoring
install_hwmon() {
    log_info "Installing hardware monitoring tools..."

    apt-get install -y \
        lm-sensors \
        fancontrol \
        i2c-tools \
        || true

    # Detect sensors (capture output for audit)
    # Skip on Dell T7910: aggressive I2C probing can interfere with iDRAC BMC on shared SMBus
    # Skip on ASUS ROG laptops: embedded controller on shared SMBus, asus-wmi provides sensor data
    if [ "$IS_DELL_T7910" = true ]; then
        log_info "Skipping sensors-detect on Dell T7910 (iDRAC SMBus conflict risk)"
        log_info "Loading known T7910 sensor modules (coretemp) only"
    elif [ "$IS_ASUS_ROG" = true ]; then
        log_info "Skipping sensors-detect on ASUS ROG (asus-wmi provides sensor data)"
    else
        sensors-detect --auto 2>&1 | tee /var/log/sensors-detect.log || true
        # Deduplicate /etc/modules entries (sensors-detect --auto appends on each run)
        if [ -f /etc/modules ]; then
            sort -u /etc/modules -o /etc/modules
        fi
    fi

    # Load common monitoring modules
    modprobe coretemp 2>/dev/null || true

    # Persist modules (nct6775 loaded only for ASUS Z97 in setup_asus_z97)
    cat > /etc/modules-load.d/hwmon.conf << 'EOF'
coretemp
EOF
}

# Install power management
install_power_management() {
    log_info "Installing power management tools..."

    # Skip thermald on dual-socket systems (iDRAC/BMC handles thermal management)
    # Skip thermald on ASUS ROG laptops (TLP handles power management, thermald conflicts)
    local socket_count=$(LANG=C lscpu | grep "Socket(s):" | awk '{print $2}')
    if [ "$IS_ASUS_ROG" = true ]; then
        log_info "ASUS ROG laptop detected - skipping thermald (TLP manages power/thermals)"
    elif [ "${socket_count:-1}" -le 1 ]; then
        apt-get install -y thermald || true
        systemctl enable thermald 2>/dev/null || true
    else
        log_info "Multi-socket system detected - skipping thermald (BMC manages thermals)"
    fi

    apt-get install -y powertop || true
}

# Install TPM tools
install_tpm() {
    log_info "Installing TPM tools..."

    # tpm-tools (TPM 1.2) removed in Ubuntu 22.04+; only tpm2-tools available
    apt-get install -y \
        tpm2-tools \
        || { track_error; true; }
}

# Install Dell PERC RAID controller tools
install_raid_tools() {
    log_info "Checking for hardware RAID controllers..."

    if lspci | grep -qi "MegaRAID\|PERC"; then
        log_info "Dell PERC / MegaRAID controller detected"

        # perccli/storcli - Dell provides perccli as the management tool
        # It's not in Ubuntu repos, but we can install dependencies
        apt-get install -y \
            sg3-utils \
            sdparm \
            || true

        # Check if megaraid_sas module is loaded
        if lsmod | grep -q "megaraid_sas"; then
            log_info "megaraid_sas driver loaded"
        else
            modprobe megaraid_sas 2>/dev/null || true
            log_info "Loaded megaraid_sas driver"
        fi

        log_info "NOTE: For full RAID management, install Dell perccli from dell.com/support"
    fi
}

# Install IPMI tools for out-of-band management and Serial-Over-LAN
install_ipmi_tools() {
    log_info "Installing IPMI and out-of-band management tools..."

    apt-get install -y \
        ipmitool \
        freeipmi-tools \
        openipmi \
        || true

    # Enable IPMI kernel modules
    modprobe ipmi_devintf 2>/dev/null || true
    modprobe ipmi_si 2>/dev/null || true
    modprobe ipmi_msghandler 2>/dev/null || true

    # Persist IPMI modules
    cat > /etc/modules-load.d/ipmi.conf << 'EOF'
ipmi_devintf
ipmi_si
ipmi_msghandler
EOF

    # Enable and start OpenIPMI service
    systemctl enable openipmi 2>/dev/null || true
    systemctl start openipmi 2>/dev/null || true
}

# Configure serial console for Serial-Over-LAN (SOL)
# Enables console output on both serial port and all attached monitors
configure_serial_console() {
    local SERIAL_PORT="${1:-ttyS1}"
    local BAUD_RATE="${2:-115200}"

    log_info "Configuring serial console on ${SERIAL_PORT} at ${BAUD_RATE} baud..."

    # Validate serial port name is a standard ISA UART
    if ! echo "$SERIAL_PORT" | grep -qE '^ttyS[0-3]$'; then
        log_warn "Serial port ${SERIAL_PORT} is not a standard ISA UART (ttyS0-ttyS3) - GRUB serial console may not work"
    fi

    # Validate baud rate is a standard value
    case "$BAUD_RATE" in
        9600|19200|38400|57600|115200) ;;
        *) log_warn "Non-standard baud rate: $BAUD_RATE - defaulting to 115200"; BAUD_RATE="115200" ;;
    esac

    # Verify the serial port exists and is not a phantom UART
    # Intel 8250 legacy detection can create /dev/ttyS* for non-existent hardware
    if [ ! -c "/dev/${SERIAL_PORT}" ]; then
        log_warn "Serial port /dev/${SERIAL_PORT} does not exist - skipping serial console"
        return
    fi
    if command -v setserial &>/dev/null; then
        if setserial "/dev/${SERIAL_PORT}" -a 2>/dev/null | grep -q "UART: unknown"; then
            log_warn "Serial port /dev/${SERIAL_PORT} is a phantom UART (no hardware) - skipping serial console"
            return
        fi
    fi

    # --- GRUB Configuration ---
    # Output to both serial and normal video console
    if ! grep -q "^GRUB_TERMINAL=" /etc/default/grub 2>/dev/null; then
        # Remove any existing GRUB_TERMINAL_OUTPUT line (default is just console)
        sed -i '/^GRUB_TERMINAL_OUTPUT=/d' /etc/default/grub

        # Set GRUB to use both serial and console (video) output
        # Use --port= (I/O address) instead of --unit= for UEFI GRUB compatibility
        local SERIAL_IO_PORT
        case "$SERIAL_PORT" in
            ttyS0) SERIAL_IO_PORT="0x3f8" ;;
            ttyS1) SERIAL_IO_PORT="0x2f8" ;;
            ttyS2) SERIAL_IO_PORT="0x3e8" ;;
            ttyS3) SERIAL_IO_PORT="0x2e8" ;;
            *) SERIAL_IO_PORT="" ;;
        esac
        echo "GRUB_TERMINAL=\"serial console\"" >> /etc/default/grub
        if [ -n "$SERIAL_IO_PORT" ]; then
            echo "GRUB_SERIAL_COMMAND=\"serial --port=${SERIAL_IO_PORT} --speed=${BAUD_RATE} --word=8 --parity=no --stop=1\"" >> /etc/default/grub
        else
            echo "GRUB_SERIAL_COMMAND=\"serial --unit=${SERIAL_PORT##ttyS} --speed=${BAUD_RATE} --word=8 --parity=no --stop=1\"" >> /etc/default/grub
        fi
    fi

    # --- Kernel Console Configuration ---
    # Add console parameters to kernel command line for both serial and VGA
    # The last 'console=' entry becomes the primary (where /dev/console points),
    # but all listed consoles receive boot messages.
    # Serial console is listed LAST so it becomes /dev/console (important for headless SOL debugging).
    CURRENT_CMDLINE=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" /etc/default/grub | sed 's/GRUB_CMDLINE_LINUX_DEFAULT="\([^"]*\)"/\1/')
    NEW_PARAMS=""

    # Add VGA console first (tty0 = all virtual terminals / monitors)
    if ! echo "$CURRENT_CMDLINE" | grep -q "console=tty0"; then
        NEW_PARAMS="console=tty0"
    fi

    # Add serial console LAST so it becomes the primary /dev/console
    if ! echo "$CURRENT_CMDLINE" | grep -q "console=${SERIAL_PORT}"; then
        NEW_PARAMS="${NEW_PARAMS} console=${SERIAL_PORT},${BAUD_RATE}n8"
    fi

    if [ -n "$NEW_PARAMS" ]; then
        sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 ${NEW_PARAMS}\"/" /etc/default/grub
        # Clean up any double spaces
        sed -i '/^GRUB_CMDLINE_LINUX/s/  */ /g' /etc/default/grub
    fi

    # --- Kernel messages on serial ---
    # Also update GRUB_CMDLINE_LINUX for recovery/single-user mode
    # console=tty0 first (VGA), serial LAST so it becomes primary /dev/console for SOL
    local CONSOLE_PARAMS="console=tty0 console=${SERIAL_PORT},${BAUD_RATE}n8"
    if ! grep -q "^GRUB_CMDLINE_LINUX=" /etc/default/grub; then
        # Line doesn't exist at all - add it
        echo "GRUB_CMDLINE_LINUX=\"${CONSOLE_PARAMS}\"" >> /etc/default/grub
    else
        CURRENT_CMDLINE_LINUX=$(grep "^GRUB_CMDLINE_LINUX=" /etc/default/grub | sed 's/GRUB_CMDLINE_LINUX="\([^"]*\)"/\1/')
        if ! echo "$CURRENT_CMDLINE_LINUX" | grep -q "console=${SERIAL_PORT}"; then
            # Only add console=tty0 if not already present (dedup across re-runs)
            if echo "$CURRENT_CMDLINE_LINUX" | grep -q "console=tty0"; then
                CONSOLE_PARAMS="console=${SERIAL_PORT},${BAUD_RATE}n8"
            fi
            if [ -z "$CURRENT_CMDLINE_LINUX" ]; then
                # Line exists but is empty (GRUB_CMDLINE_LINUX="") - replace directly
                sed -i "s/^GRUB_CMDLINE_LINUX=\"\"/GRUB_CMDLINE_LINUX=\"${CONSOLE_PARAMS}\"/" /etc/default/grub
            else
                # Line has existing params - append
                sed -i "s/^GRUB_CMDLINE_LINUX=\"\([^\"]*\)\"/GRUB_CMDLINE_LINUX=\"\1 ${CONSOLE_PARAMS}\"/" /etc/default/grub
            fi
        fi
    fi

    # GRUB will be updated once at the end of main() to consolidate all changes
    GRUB_UPDATE_NEEDED=true

    # --- systemd serial getty ---
    # Enable serial console login via systemd
    systemctl enable "serial-getty@${SERIAL_PORT}.service" 2>/dev/null || true
    systemctl start "serial-getty@${SERIAL_PORT}.service" 2>/dev/null || true

    log_info "Serial console configured: ${SERIAL_PORT} @ ${BAUD_RATE} baud"
    log_info "Boot messages will appear on both serial console and attached monitors"
}

# HP Elite 8300 specific setup
setup_hp_elite_8300() {
    log_info "Applying HP Elite 8300 specific configuration..."

    # Intel Q77 chipset - ensure i2c-i801 module loads
    modprobe i2c-i801 2>/dev/null || true
    cat > /etc/modules-load.d/hp-elite-8300.conf << 'EOF'
i2c-i801
EOF

    # Intel MEI
    modprobe mei_me 2>/dev/null || true

    # HP 8300 BIOS may not honor named EFI boot entries; ensure fallback path exists
    # Some HP BIOS versions only look for \EFI\BOOT\BOOTX64.EFI, not \EFI\ubuntu\shimx64.efi
    if [ -d /boot/efi/EFI/ubuntu ] && [ ! -f /boot/efi/EFI/BOOT/BOOTX64.EFI ]; then
        mkdir -p /boot/efi/EFI/BOOT
        cp /boot/efi/EFI/ubuntu/shimx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI 2>/dev/null || \
            cp /boot/efi/EFI/ubuntu/grubx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI 2>/dev/null || true
        log_info "Created EFI fallback boot path for HP 8300 BIOS compatibility"
    fi

    # Log EFI boot order for diagnostics
    if command -v efibootmgr &>/dev/null; then
        efibootmgr -v 2>/dev/null | head -20 >> "$LOG_FILE" || true
    fi
}

# HP EliteDesk 800 G1 SFF specific setup
setup_hp_800_g1() {
    log_info "Applying HP EliteDesk 800 G1 SFF specific configuration..."

    # Intel Q87 chipset - ensure i2c-i801 module loads
    modprobe i2c-i801 2>/dev/null || true
    cat > /etc/modules-load.d/hp-800-g1.conf << 'EOF'
i2c-i801
EOF

    # Intel MEI
    modprobe mei_me 2>/dev/null || true

    # HP 800 G1 BIOS has the same EFI boot path quirk as the 8300 series
    if [ -d /boot/efi/EFI/ubuntu ] && [ ! -f /boot/efi/EFI/BOOT/BOOTX64.EFI ]; then
        mkdir -p /boot/efi/EFI/BOOT
        cp /boot/efi/EFI/ubuntu/shimx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI 2>/dev/null || \
            cp /boot/efi/EFI/ubuntu/grubx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI 2>/dev/null || true
        log_info "Created EFI fallback boot path for HP 800 G1 BIOS compatibility"
    fi

    # Log EFI boot order for diagnostics
    if command -v efibootmgr &>/dev/null; then
        efibootmgr -v 2>/dev/null | head -20 >> "$LOG_FILE" || true
    fi
}

# Lenovo ThinkCentre M92p specific setup
setup_lenovo_m92p() {
    log_info "Applying Lenovo ThinkCentre M92p specific configuration..."

    # Intel Q77 chipset - same as HP Elite 8300
    modprobe i2c-i801 2>/dev/null || true
    cat > /etc/modules-load.d/lenovo-m92p.conf << 'EOF'
i2c-i801
EOF

    # Intel MEI
    modprobe mei_me 2>/dev/null || true
}

# Lenovo ThinkCentre M72 specific setup
setup_lenovo_m72() {
    log_info "Applying Lenovo ThinkCentre M72 specific configuration..."

    # Intel H61 chipset
    modprobe i2c-i801 2>/dev/null || true
    cat > /etc/modules-load.d/lenovo-m72.conf << 'EOF'
i2c-i801
EOF

    # Realtek RTL8111E network - check if driver working properly
    if lspci -k | grep -A2 "RTL8111" | grep -q "r8169"; then
        log_info "Realtek using r8169 driver"
    fi
}

# ASUS Z97 specific setup
setup_asus_z97() {
    log_info "Applying ASUS Z97 specific configuration..."

    # Nuvoton NCT6791D hardware monitoring
    modprobe nct6775 2>/dev/null || true
    cat > /etc/modules-load.d/asus-z97.conf << 'EOF'
nct6775
EOF

    # Intel MEI
    modprobe mei_me 2>/dev/null || true
}

# ASUS Hyper M.2 x16 Card V2 specific setup
setup_hyper_m2() {
    log_info "Applying ASUS Hyper M.2 x16 Card V2 specific configuration..."

    # Ensure NVMe modules are loaded
    modprobe nvme 2>/dev/null || true
    modprobe nvme_core 2>/dev/null || true

    # Add kernel parameters for NVMe stability
    if ! grep -q "nvme_core.default_ps_max_latency_us" /etc/default/grub; then
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 nvme_core.default_ps_max_latency_us=0"/' /etc/default/grub
        log_warn "nvme_core.default_ps_max_latency_us=0 disables NVMe power saving on ALL drives (required for Hyper M.2 stability)"
        GRUB_UPDATE_NEEDED=true
    fi

    # Verify NVMe drives and check temperatures (Hyper M.2 cards have limited airflow)
    log_info "NVMe drives detected:"
    nvme list 2>/dev/null || true

    # Check NVMe temperatures (thermal throttling common on Hyper M.2 x16 due to shared slot airflow)
    for nvme_dev in /dev/nvme*n1; do
        [ -e "$nvme_dev" ] || continue
        local temp
        temp=$(nvme smart-log "$nvme_dev" 2>/dev/null | grep -i "^temperature" | head -1 | awk -F: '{print $2}' | tr -d ' C' | cut -d. -f1)
        if [ -n "$temp" ] && [ "$temp" -ge 70 ] 2>/dev/null; then
            log_warn "NVMe $nvme_dev running hot: ${temp}C (throttling likely above 80C)"
            log_warn "Check airflow to NVMe drives on Hyper M.2 x16 Card"
        elif [ -n "$temp" ]; then
            log_info "NVMe $nvme_dev temperature: ${temp}C"
        fi
    done
}

# Dell Precision T7910 specific setup
setup_dell_t7910() {
    log_info "Applying Dell Precision T7910 specific configuration..."

    # Intel C612 (Wellsburg) chipset - SMBus
    modprobe i2c-i801 2>/dev/null || true

    # Intel MEI
    modprobe mei_me 2>/dev/null || true

    # Persist chipset modules
    cat > /etc/modules-load.d/dell-t7910.conf << 'EOF'
i2c-i801
mei_me
ipmi_devintf
ipmi_si
ipmi_msghandler
EOF

    # EDAC - ECC memory error detection (Xeon E5 v3/v4 with ECC RAM)
    # Check for ghes_edac (provided by iDRAC GHES) before loading sb_edac
    if lsmod | grep -q "ghes_edac"; then
        log_info "ghes_edac already active (via iDRAC GHES) - ECC reporting functional"
    else
        modprobe sb_edac 2>/dev/null || true
        if lsmod | grep -q "sb_edac"; then
            grep -q "^sb_edac$" /etc/modules-load.d/dell-t7910.conf 2>/dev/null || \
                echo "sb_edac" >> /etc/modules-load.d/dell-t7910.conf
        fi
    fi

    # ECC memory error baseline (detect pre-existing DIMM issues)
    if [ -d /sys/devices/system/edac/mc ]; then
        log_info "ECC Memory Error Baseline:"
        for mc in /sys/devices/system/edac/mc/mc*; do
            [ -d "$mc" ] || continue
            local ce ue
            ce=$(cat "$mc/ce_count" 2>/dev/null || echo "N/A")
            ue=$(cat "$mc/ue_count" 2>/dev/null || echo "N/A")
            log_info "  $(basename "$mc"): correctable=$ce uncorrectable=$ue"
            if [ "$ue" != "N/A" ] && [ "$ue" -gt 0 ] 2>/dev/null; then
                log_warn "UNCORRECTABLE ECC errors detected on $(basename "$mc") - DIMM replacement recommended"
            fi
            # Per-DIMM error reporting (helps identify which physical slot to replace)
            for dimm in "$mc"/dimm*; do
                [ -d "$dimm" ] || continue
                local dimm_label dimm_ce dimm_ue
                dimm_label=$(cat "$dimm/dimm_label" 2>/dev/null || basename "$dimm")
                dimm_ce=$(cat "$dimm/dimm_ce_count" 2>/dev/null || echo "0")
                dimm_ue=$(cat "$dimm/dimm_ue_count" 2>/dev/null || echo "0")
                if [ "$dimm_ue" != "0" ] && [ "$dimm_ue" -gt 0 ] 2>/dev/null; then
                    log_warn "  DIMM $dimm_label: $dimm_ue UNCORRECTABLE errors - REPLACE THIS DIMM"
                elif [ "$dimm_ce" != "0" ] && [ "$dimm_ce" -gt 50 ] 2>/dev/null; then
                    log_warn "  DIMM $dimm_label: $dimm_ce correctable errors - monitor closely"
                fi
            done
        done
    fi

    # NUMA awareness for dual-socket Xeon
    local numa_nodes
    numa_nodes=$(LANG=C lscpu | grep "^NUMA node(s):" | awk '{print $NF}')
    if [ "${numa_nodes:-1}" -ge 2 ]; then
        log_info "Dual-socket NUMA topology detected"
        apt-get install -y numactl || true
        # Note: numad not enabled - conflicts with GPU NUMA affinity
        # Use: numactl --cpunodebind=0 --membind=0 <command> for GPU workloads

        # Log GPU-to-NUMA mapping for operator awareness (helps with affinity tuning)
        if command -v nvidia-smi &>/dev/null; then
            log_info "GPU NUMA topology:"
            nvidia-smi topo -m 2>/dev/null | tee -a "$LOG_FILE" || true
            log_info "TIP: Pin GPU compute to correct NUMA node with: numactl --cpunodebind=<node> --membind=<node> <cmd>"
        fi
    fi

    # IPMI / BMC for out-of-band management and SOL
    install_ipmi_tools

    # Query and log BMC/iDRAC network configuration for operator awareness
    if command -v ipmitool &>/dev/null; then
        log_info "Querying BMC/iDRAC network configuration..."
        ipmitool lan print 1 2>/dev/null | tee -a "$LOG_FILE" || log_warn "Could not query BMC LAN channel 1"
        local bmc_ip
        bmc_ip=$(ipmitool lan print 1 2>/dev/null | grep "IP Address  " | awk -F: '{print $2}' | xargs)
        if [ -n "$bmc_ip" ] && [ "$bmc_ip" != "0.0.0.0" ]; then
            log_info "iDRAC/BMC IP: $bmc_ip"
            log_warn "SECURITY: Ensure iDRAC default credentials (root/calvin) have been changed"
            log_warn "SECURITY: Access iDRAC at https://$bmc_ip and update the admin password"
        else
            log_warn "iDRAC/BMC has no IP configured - out-of-band management unavailable"
            log_warn "Configure via: ipmitool lan set 1 ipaddr <ip>"
        fi
        local bmc_fw
        bmc_fw=$(ipmitool mc info 2>/dev/null | grep "Firmware Revision" | awk -F: '{print $2}' | xargs)
        [ -n "$bmc_fw" ] && log_info "BMC firmware: $bmc_fw"
    fi

    # Dell PERC RAID controller
    install_raid_tools

    # NVIDIA Quadro GPU (common on T7910)
    install_nvidia_graphics

    # Serial-Over-LAN via IPMI/BMC
    # Dell T7910 BMC typically uses COM2 (ttyS1) at 115200 baud for SOL
    configure_serial_console "ttyS1" "115200"

    log_info "Dell T7910 configuration complete"
    log_info "NOTE: Ensure BIOS Serial Communication is set to:"
    log_info "  - Serial Communication: On with Console Redirection via COM2"
    log_info "  - Serial Port Address: COM2 (2F8h)"
    log_info "  - Redirection After Boot: Enabled"
}

# ASUS ROG Strix laptop specific setup (G733QS, G713, G814, etc.)
# Handles hybrid AMD iGPU + NVIDIA dGPU, laptop power management, ASUS ACPI
setup_asus_rog() {
    log_info "Applying ASUS ROG Strix laptop specific configuration..."

    # --- Hybrid GPU switching (AMD Radeon iGPU + NVIDIA dGPU) ---
    # nvidia-prime enables switching between integrated and discrete GPU
    apt-get install -y nvidia-prime || { track_error; true; }
    log_info "NVIDIA PRIME installed for hybrid GPU switching"
    log_info "Use: prime-select intel|nvidia|on-demand to switch GPU modes"

    # --- ASUS WMI / ACPI modules for hotkeys, fan control, backlight ---
    modprobe asus-wmi 2>/dev/null || true
    modprobe asus-nb-wmi 2>/dev/null || true
    cat > /etc/modules-load.d/asus-rog.conf << 'EOF'
asus-wmi
asus-nb-wmi
EOF

    # --- Laptop power management (TLP) ---
    # TLP provides laptop-optimized power profiles (AC vs battery)
    apt-get install -y tlp tlp-rdw || { track_error; true; }
    # Disable power-profiles-daemon which conflicts with TLP on Ubuntu 24.04
    systemctl disable power-profiles-daemon 2>/dev/null || true
    systemctl mask power-profiles-daemon 2>/dev/null || true
    systemctl enable tlp 2>/dev/null || true
    systemctl start tlp 2>/dev/null || true
    log_info "TLP power management enabled (laptop optimized)"

    # --- Battery charge limit for battery health ---
    # ASUS laptops expose charge limit via ASUS WMI sysfs interface
    if [ -f /sys/class/power_supply/BAT0/charge_control_end_threshold ]; then
        echo 80 > /sys/class/power_supply/BAT0/charge_control_end_threshold 2>/dev/null || true
        log_info "Battery charge limit set to 80% for battery longevity"
        # Persist via udev rule
        cat > /etc/udev/rules.d/99-asus-battery-limit.rules << 'EOF'
SUBSYSTEM=="power_supply", ATTR{type}=="Battery", ATTR{charge_control_end_threshold}="80"
EOF
    else
        log_info "Battery charge limit sysfs not available (may require reboot with asus-wmi loaded)"
    fi

    # --- MediaTek WiFi (MT7921/MT7922 common in ROG laptops) ---
    if lspci | grep -qi "MediaTek"; then
        log_info "MediaTek WiFi detected (mt7921e driver built into kernel 5.15+)"
        apt-get install -y linux-firmware || true
        modprobe mt7921e 2>/dev/null || true
    fi

    # --- Display backlight control ---
    # Ensure backlight control works for both AMD and NVIDIA
    if ! grep -q "amdgpu.backlight" /etc/default/grub 2>/dev/null; then
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 amdgpu.backlight=0"/' /etc/default/grub
        GRUB_UPDATE_NEEDED=true
        log_info "Added amdgpu.backlight=0 (use NVIDIA backlight control for hybrid GPU)"
    fi

    log_info "ASUS ROG Strix configuration complete"
    log_info "Hybrid GPU: Use 'prime-select' to switch GPU modes"
    log_info "  - prime-select on-demand: iGPU by default, offload to dGPU with __NV_PRIME_RENDER_OFFLOAD=1"
    log_info "  - prime-select nvidia: Always use NVIDIA dGPU (higher performance, more power)"
    log_info "  - prime-select intel: Always use AMD iGPU (power saving, no NVIDIA)"
}

# Main installation routine
main() {
    log_info "Starting driver installation..."

    # Must run as root
    if [ "$(id -u)" != "0" ]; then
        log_error "This script must be run as root"
        exit 1
    fi

    # Detect hardware
    detect_hardware

    # Update package lists
    update_packages

    # Install essential firmware
    install_essential_firmware

    # Install all driver categories
    install_intel_graphics
    # NVIDIA is handled in setup_dell_t7910 for T7910 (after IPMI/RAID setup)
    if [ "$IS_DELL_T7910" != true ]; then
        install_nvidia_graphics
    fi
    install_amd_graphics
    install_intel_network
    install_realtek_network
    install_intel_wifi
    install_broadcom_wifi
    install_audio_drivers
    install_storage_drivers
    install_usb_drivers
    install_hwmon
    install_power_management
    install_tpm

    # Apply hardware-specific configurations
    if [ "$IS_HP_ELITE_8300" = true ]; then
        setup_hp_elite_8300
    fi

    if [ "$IS_HP_800_G1" = true ]; then
        setup_hp_800_g1
    fi

    if [ "$IS_LENOVO_M92P" = true ]; then
        setup_lenovo_m92p
    fi

    if [ "$IS_LENOVO_M72" = true ]; then
        setup_lenovo_m72
    fi

    if [ "$IS_ASUS_Z97" = true ]; then
        setup_asus_z97
    fi

    if [ "$IS_DELL_T7910" = true ]; then
        setup_dell_t7910
    fi

    if [ "$IS_ASUS_ROG" = true ]; then
        setup_asus_rog
    fi

    if [ "$HAS_HYPER_M2" = true ]; then
        setup_hyper_m2
    fi

    # Check for firmware updates via fwupd/LVFS (informational, not auto-applied)
    # Skip on platforms too old for LVFS coverage (saves ~30s + 20MB metadata download)
    if command -v fwupdmgr &>/dev/null; then
        if [ "$IS_HP_ELITE_8300" = true ] || [ "$IS_HP_800_G1" = true ] || [ "$IS_LENOVO_M92P" = true ] || [ "$IS_LENOVO_M72" = true ] || [ "$IS_ASUS_Z97" = true ]; then
            log_info "Skipping LVFS firmware check (platform too old for LVFS coverage)"
        else
            log_info "Checking for firmware updates via fwupd/LVFS..."
            fwupdmgr refresh --force 2>/dev/null || true
            fwupdmgr get-updates 2>/dev/null || log_info "No firmware updates available (or LVFS metadata not accessible)"
        fi
    fi

    # Verify CPU microcode was applied
    if [ -f /proc/cpuinfo ]; then
        local ucode_rev
        ucode_rev=$(grep "microcode" /proc/cpuinfo 2>/dev/null | head -1 | awk '{print $3}')
        log_info "CPU microcode revision: ${ucode_rev:-unknown}"
    fi

    # Consolidate GRUB and initramfs updates (run once at end for all changes)
    if [ "$GRUB_UPDATE_NEEDED" = true ]; then
        log_info "Updating GRUB configuration..."
        update-grub || true
    fi
    log_info "Updating initramfs..."
    update-initramfs -u -k all || true

    log_info "=========================================="
    log_info "Driver installation completed! (errors: $ERROR_COUNT)"
    log_info "=========================================="
    # Cap exit code at 125 to avoid wrapping
    [ "$ERROR_COUNT" -gt 125 ] && ERROR_COUNT=125
    sleep 0.5  # Allow tee process substitution to flush final log lines
    exit $ERROR_COUNT
}

main "$@"
