#!/bin/bash
# ============================================================================
# GUI Installation Script
# Installs Ubuntu Desktop or minimal GUI based on configuration
# ============================================================================

set -e

LOG_FILE="/var/log/install-gui.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo "GUI Installation Script"
echo "Started: $(date)"
echo "=========================================="

CONFIG_FILE="/opt/ubuntu-installer/config.env"

# Load configuration
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

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

# Check if running as root
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root"
    exit 1
fi

# Update package lists
log_info "Updating package lists..."
apt-get update

# Get Ubuntu version
UBUNTU_VERSION=$(lsb_release -rs)
log_info "Ubuntu version: $UBUNTU_VERSION"

# Install full Ubuntu Desktop
install_full_desktop() {
    log_info "Installing full Ubuntu Desktop..."

    # Install Ubuntu Desktop metapackage
    apt-get install -y ubuntu-desktop

    # Additional recommended packages
    apt-get install -y \
        firefox \
        gnome-tweaks \
        gnome-shell-extensions \
        gnome-software \
        nautilus-admin \
        || true

    log_info "Full Ubuntu Desktop installed"
}

# Install minimal GUI (lightweight)
install_minimal_gui() {
    log_info "Installing minimal GUI (XFCE)..."

    apt-get install -y \
        xubuntu-core \
        lightdm \
        lightdm-gtk-greeter \
        thunar \
        xfce4-terminal \
        || true

    log_info "Minimal GUI (XFCE) installed"
}

# Install display manager and enable graphical target
configure_display_manager() {
    log_info "Configuring display manager..."

    # Enable graphical target
    systemctl set-default graphical.target

    # Configure LightDM or GDM based on what's installed
    if dpkg -l | grep -q gdm3; then
        log_info "Using GDM3 as display manager"
        systemctl enable gdm3 || true
    elif dpkg -l | grep -q lightdm; then
        log_info "Using LightDM as display manager"
        systemctl enable lightdm || true

        # Configure LightDM for auto-login if desired
        # (uncomment below to enable auto-login)
        # INSTALL_USERNAME="${INSTALL_USERNAME:-admin}"
        # mkdir -p /etc/lightdm/lightdm.conf.d
        # cat > /etc/lightdm/lightdm.conf.d/50-autologin.conf << EOF
        # [Seat:*]
        # autologin-user=$INSTALL_USERNAME
        # EOF
    fi
}

# Install Intel graphics support for GUI
install_intel_graphics_gui() {
    log_info "Installing Intel graphics support for GUI..."

    apt-get install -y \
        xserver-xorg-video-intel \
        intel-media-va-driver \
        vainfo \
        || true

    # Create Intel Xorg config for better performance
    mkdir -p /etc/X11/xorg.conf.d
    cat > /etc/X11/xorg.conf.d/20-intel.conf << 'EOF'
Section "Device"
    Identifier "Intel Graphics"
    Driver "intel"
    Option "TearFree" "true"
    Option "DRI" "3"
    Option "AccelMethod" "sna"
EndSection
EOF

    log_info "Intel graphics configured"
}

# Install AMD/Radeon graphics support for GUI
install_amd_graphics_gui() {
    log_info "Installing AMD graphics support for GUI..."

    apt-get install -y \
        xserver-xorg-video-radeon \
        xserver-xorg-video-amdgpu \
        mesa-vulkan-drivers \
        || true

    log_info "AMD graphics support installed"
}

# Detect graphics hardware
detect_and_configure_graphics() {
    log_info "Detecting graphics hardware..."

    # Check for Intel graphics
    if lspci | grep -qi "Intel.*Graphics\|Intel.*HD"; then
        log_info "Intel graphics detected"
        install_intel_graphics_gui
    fi

    # Check for AMD/Radeon graphics
    if lspci | grep -qi "AMD\|Radeon\|ATI"; then
        log_info "AMD/Radeon graphics detected"
        install_amd_graphics_gui
    fi
}

# Main installation
main() {
    log_info "Starting GUI installation..."

    # Install based on GUI type preference
    GUI_TYPE="${GUI_TYPE:-full}"

    case "$GUI_TYPE" in
        minimal|xfce)
            install_minimal_gui
            ;;
        full|ubuntu|gnome|*)
            install_full_desktop
            ;;
    esac

    # Detect and configure graphics
    detect_and_configure_graphics

    # Configure display manager
    configure_display_manager

    # Final cleanup
    apt-get autoremove -y
    apt-get clean

    log_info "=========================================="
    log_info "GUI installation completed!"
    log_info "The system will boot to graphical mode"
    log_info "after the next reboot."
    log_info "=========================================="
}

main "$@"
