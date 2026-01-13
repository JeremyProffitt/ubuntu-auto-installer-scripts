#!/bin/bash
# ============================================================================
# Ubuntu Driver Installation Script for Home Lab Computers
# Supports: HP Elite 8300, Lenovo ThinkCentre M92p, Lenovo ThinkCentre M72,
#           ASUS Z97 motherboards, ASUS Hyper M.2 x16 Card V2
# ============================================================================

set -e

LOG_FILE="/var/log/driver-installation.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo "Driver Installation Script"
echo "Started: $(date)"
echo "=========================================="

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

    echo "System Vendor: $SYSTEM_VENDOR"
    echo "System Product: $SYSTEM_PRODUCT"
    echo "Baseboard Vendor: $BASEBOARD_VENDOR"
    echo "Baseboard Product: $BASEBOARD_PRODUCT"

    # Detect specific hardware
    IS_HP_ELITE_8300=false
    IS_LENOVO_M92P=false
    IS_LENOVO_M72=false
    IS_ASUS_Z97=false
    HAS_HYPER_M2=false

    if [[ "$SYSTEM_PRODUCT" == *"Elite 8300"* ]] || [[ "$SYSTEM_PRODUCT" == *"HP Compaq 8300"* ]]; then
        IS_HP_ELITE_8300=true
        log_info "Detected: HP Elite 8300"
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

    # Check for ASUS Hyper M.2 x16 Card V2 (multiple NVMe controllers on single slot)
    NVME_COUNT=$(lspci | grep -c "Non-Volatile memory" || echo "0")
    if [ "$NVME_COUNT" -ge 2 ]; then
        HAS_HYPER_M2=true
        log_info "Detected: Multiple NVMe controllers ($NVME_COUNT) - likely ASUS Hyper M.2 card"
    fi
}

# Update package lists
update_packages() {
    log_info "Updating package lists..."
    apt-get update
}

# Install essential firmware and microcode
install_essential_firmware() {
    log_info "Installing essential firmware packages..."

    apt-get install -y \
        linux-firmware \
        intel-microcode \
        amd64-microcode \
        firmware-linux-free \
        || true
}

# Install Intel graphics drivers (for HD 2500/4000/4600)
install_intel_graphics() {
    log_info "Installing Intel graphics drivers..."

    apt-get install -y \
        xserver-xorg-video-intel \
        mesa-utils \
        libgl1-mesa-dri \
        libgl1-mesa-glx \
        mesa-vulkan-drivers \
        libva2 \
        libva-drm2 \
        libva-x11-2 \
        vainfo \
        i965-va-driver \
        intel-media-va-driver \
        intel-gpu-tools \
        || true
}

# Install AMD/Radeon graphics drivers (for optional discrete GPUs)
install_amd_graphics() {
    log_info "Installing AMD/Radeon graphics drivers..."

    apt-get install -y \
        xserver-xorg-video-radeon \
        xserver-xorg-video-amdgpu \
        libdrm-radeon1 \
        mesa-va-drivers \
        || true
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

    if lspci | grep -qi "BCM4352\|BCM43"; then
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

    apt-get install -y \
        alsa-base \
        alsa-utils \
        alsa-tools \
        pulseaudio \
        pulseaudio-utils \
        pavucontrol \
        libasound2 \
        libasound2-plugins \
        || true

    # Realtek audio codec configuration
    if ! grep -q "snd-hda-intel" /etc/modprobe.d/alsa-base.conf 2>/dev/null; then
        echo "options snd-hda-intel model=auto" >> /etc/modprobe.d/alsa-base.conf
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

    # Ensure NVMe modules are in initramfs
    if ! grep -q "^nvme" /etc/initramfs-tools/modules 2>/dev/null; then
        echo "nvme" >> /etc/initramfs-tools/modules
        echo "nvme_core" >> /etc/initramfs-tools/modules
        update-initramfs -u -k all
    fi

    # Set NVMe I/O scheduler (none is recommended for NVMe)
    cat > /etc/udev/rules.d/60-nvme-scheduler.rules << 'EOF'
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
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
        hddtemp \
        || true

    # Detect sensors
    sensors-detect --auto 2>/dev/null || true

    # Load common monitoring modules
    modprobe coretemp 2>/dev/null || true
    modprobe nct6775 2>/dev/null || true

    # Persist modules
    cat > /etc/modules-load.d/hwmon.conf << 'EOF'
coretemp
nct6775
EOF
}

# Install power management
install_power_management() {
    log_info "Installing power management tools..."

    apt-get install -y \
        thermald \
        powertop \
        cpufrequtils \
        || true

    # Enable thermald for Intel systems
    systemctl enable thermald 2>/dev/null || true
}

# Install TPM tools
install_tpm() {
    log_info "Installing TPM tools..."

    apt-get install -y \
        tpm-tools \
        tpm2-tools \
        || true
}

# HP Elite 8300 specific setup
setup_hp_elite_8300() {
    log_info "Applying HP Elite 8300 specific configuration..."

    # Intel Q77 chipset - ensure i2c-i801 module loads
    modprobe i2c-i801 2>/dev/null || true
    echo "i2c-i801" >> /etc/modules-load.d/hp-elite-8300.conf

    # Intel MEI
    modprobe mei_me 2>/dev/null || true
}

# Lenovo ThinkCentre M92p specific setup
setup_lenovo_m92p() {
    log_info "Applying Lenovo ThinkCentre M92p specific configuration..."

    # Intel Q77 chipset - same as HP Elite 8300
    modprobe i2c-i801 2>/dev/null || true
    echo "i2c-i801" >> /etc/modules-load.d/lenovo-m92p.conf

    # Intel MEI
    modprobe mei_me 2>/dev/null || true
}

# Lenovo ThinkCentre M72 specific setup
setup_lenovo_m72() {
    log_info "Applying Lenovo ThinkCentre M72 specific configuration..."

    # Intel H61 chipset
    modprobe i2c-i801 2>/dev/null || true
    echo "i2c-i801" >> /etc/modules-load.d/lenovo-m72.conf

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
    echo "nct6775" >> /etc/modules-load.d/asus-z97.conf

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
        update-grub
    fi

    # Verify NVMe drives
    log_info "NVMe drives detected:"
    nvme list 2>/dev/null || true
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

    if [ "$IS_LENOVO_M92P" = true ]; then
        setup_lenovo_m92p
    fi

    if [ "$IS_LENOVO_M72" = true ]; then
        setup_lenovo_m72
    fi

    if [ "$IS_ASUS_Z97" = true ]; then
        setup_asus_z97
    fi

    if [ "$HAS_HYPER_M2" = true ]; then
        setup_hyper_m2
    fi

    # Update initramfs with all new modules
    log_info "Updating initramfs..."
    update-initramfs -u -k all

    log_info "=========================================="
    log_info "Driver installation completed!"
    log_info "=========================================="
}

main "$@"
