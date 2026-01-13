#!/bin/bash
# ============================================================================
# Post-Installation Script for Ubuntu Auto Installer
# Runs on first boot to complete system configuration
# ============================================================================

set -e

LOG_FILE="/var/log/post-install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo "Post-Installation Setup"
echo "Started: $(date)"
echo "=========================================="

CONFIG_FILE="/opt/ubuntu-installer/config.env"

# Load configuration
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo "Loaded configuration from $CONFIG_FILE"
else
    echo "Warning: Configuration file not found, using defaults"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Wait for network
wait_for_network() {
    log_info "Waiting for network connection..."
    local max_attempts=30
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if ping -c 1 8.8.8.8 &>/dev/null; then
            log_info "Network is available"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done

    log_warn "Network may not be fully available"
    return 1
}

# Configure SSH
configure_ssh() {
    log_info "Configuring SSH..."

    # Enable SSH
    systemctl enable ssh
    systemctl start ssh

    # Configure SSH settings
    cat > /etc/ssh/sshd_config.d/99-ubuntu-installer.conf << 'EOF'
# Ubuntu Auto Installer SSH Configuration
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin prohibit-password
X11Forwarding yes
EOF

    # Add authorized keys if provided
    if [ -n "${SSH_AUTHORIZED_KEYS:-}" ]; then
        log_info "Adding SSH authorized keys..."
        INSTALL_USERNAME="${INSTALL_USERNAME:-admin}"
        USER_HOME=$(eval echo ~$INSTALL_USERNAME)
        mkdir -p "$USER_HOME/.ssh"
        echo "$SSH_AUTHORIZED_KEYS" >> "$USER_HOME/.ssh/authorized_keys"
        chmod 700 "$USER_HOME/.ssh"
        chmod 600 "$USER_HOME/.ssh/authorized_keys"
        chown -R "$INSTALL_USERNAME:$INSTALL_USERNAME" "$USER_HOME/.ssh"
    fi

    systemctl restart ssh
    log_info "SSH configured and enabled"
}

# Configure static IP if requested
configure_network() {
    log_info "Configuring network..."

    if [ "${STATIC_IP:-false}" = "true" ]; then
        log_info "Configuring static IP: ${IP_ADDRESS:-not set}"

        # Get the first ethernet interface
        IFACE=$(ip -o link show | awk -F': ' '$2 !~ /^(lo|docker|veth|br-)/ {print $2; exit}')

        if [ -n "$IFACE" ]; then
            cat > /etc/netplan/01-static-config.yaml << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $IFACE:
      dhcp4: false
      addresses:
        - ${IP_ADDRESS:-192.168.1.100}/${NETMASK:-24}
      routes:
        - to: default
          via: ${GATEWAY:-192.168.1.1}
      nameservers:
        addresses: [${DNS_SERVERS:-8.8.8.8,8.8.4.4}]
EOF
            netplan apply
            log_info "Static IP configured on $IFACE"
        else
            log_warn "Could not detect network interface for static IP"
        fi
    else
        log_info "Using DHCP (default)"
    fi
}

# Run driver installation
install_drivers() {
    log_info "Running driver installation script..."

    if [ -x /opt/install-drivers.sh ]; then
        /opt/install-drivers.sh
    else
        log_warn "Driver installation script not found"
    fi
}

# Mount all drives
mount_drives() {
    log_info "Running drive mount script..."

    if [ -x /opt/mount-drives.sh ]; then
        /opt/mount-drives.sh
    else
        log_warn "Drive mount script not found"
    fi
}

# Interactive drive configuration
interactive_drive_config() {
    if [ "${INTERACTIVE_DRIVE_CONFIG:-true}" = "true" ]; then
        log_info "Interactive drive configuration available..."

        # Check if we have a TTY for interactive input
        if [ -t 0 ]; then
            echo ""
            echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${YELLOW}║  Interactive Drive Configuration Available                    ║${NC}"
            echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo "Would you like to configure drives interactively?"
            echo "This allows you to:"
            echo "  - Format and partition drives"
            echo "  - Set custom mount point names"
            echo "  - Create RAID arrays"
            echo "  - Configure auto-mount (fstab)"
            echo ""
            read -t 60 -p "Run interactive drive configuration? (y/n) [n]: " INTERACTIVE_CHOICE || INTERACTIVE_CHOICE="n"
            echo ""

            if [ "$INTERACTIVE_CHOICE" = "y" ] || [ "$INTERACTIVE_CHOICE" = "Y" ]; then
                if [ -x /opt/ubuntu-installer-scripts/configure-drives.sh ]; then
                    /opt/ubuntu-installer-scripts/configure-drives.sh
                elif [ -x /opt/configure-drives.sh ]; then
                    /opt/configure-drives.sh
                else
                    log_warn "Interactive drive configuration script not found"
                    log_info "You can run it later with: sudo /opt/ubuntu-installer-scripts/configure-drives.sh"
                fi
            else
                log_info "Skipping interactive configuration."
                log_info "You can run it later with: sudo /opt/ubuntu-installer-scripts/configure-drives.sh"
            fi
        else
            log_info "No TTY available for interactive mode."
            log_info "Run drive configuration manually: sudo /opt/ubuntu-installer-scripts/configure-drives.sh"
        fi
    fi
}

# Install GUI if requested
install_gui() {
    if [ "${INSTALL_GUI:-false}" = "true" ]; then
        log_info "GUI installation requested..."

        if [ -x /opt/ubuntu-installer-scripts/install-gui.sh ]; then
            /opt/ubuntu-installer-scripts/install-gui.sh
        elif [ -x /opt/install-gui.sh ]; then
            /opt/install-gui.sh
        else
            log_warn "GUI installation script not found"
        fi
    else
        log_info "Headless server mode - skipping GUI installation"
    fi
}

# Install optional features
install_optional_features() {
    log_info "Installing optional features..."

    SCRIPT_PATH=""
    if [ -x /opt/ubuntu-installer-scripts/install-optional-features.sh ]; then
        SCRIPT_PATH="/opt/ubuntu-installer-scripts/install-optional-features.sh"
    elif [ -x /opt/install-optional-features.sh ]; then
        SCRIPT_PATH="/opt/install-optional-features.sh"
    fi

    if [ -n "$SCRIPT_PATH" ]; then
        # Run non-interactively using config
        "$SCRIPT_PATH"
    else
        log_warn "Optional features script not found"
    fi

    # Offer interactive menu if TTY available
    if [ "${SHOW_OPTIONAL_MENU:-false}" = "true" ] && [ -t 0 ]; then
        echo ""
        echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}  Optional Features Menu Available${NC}"
        echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo "Would you like to install additional optional features?"
        echo "(Docker, Portainer, Cockpit, Tailscale, monitoring, etc.)"
        echo ""
        read -t 60 -p "Open optional features menu? (y/n) [n]: " OPTIONAL_CHOICE || OPTIONAL_CHOICE="n"

        if [ "$OPTIONAL_CHOICE" = "y" ] || [ "$OPTIONAL_CHOICE" = "Y" ]; then
            if [ -n "$SCRIPT_PATH" ]; then
                "$SCRIPT_PATH" --interactive
            fi
        fi
    fi
}

# Install extra packages
install_extra_packages() {
    if [ -n "${EXTRA_PACKAGES:-}" ]; then
        log_info "Installing extra packages: $EXTRA_PACKAGES"

        # Convert comma-separated to space-separated
        PACKAGES=$(echo "$EXTRA_PACKAGES" | tr ',' ' ')

        apt-get update
        apt-get install -y $PACKAGES || true
    fi
}

# Configure timezone
configure_timezone() {
    log_info "Configuring timezone..."
    TIMEZONE="${TIMEZONE:-America/New_York}"

    timedatectl set-timezone "$TIMEZONE"
    log_info "Timezone set to $TIMEZONE"
}

# Final system updates
final_updates() {
    log_info "Running final system updates..."

    apt-get update
    apt-get upgrade -y
    apt-get autoremove -y
    apt-get clean
}

# Display system information
display_system_info() {
    log_info "=========================================="
    log_info "System Information"
    log_info "=========================================="

    echo "Hostname: $(hostname)"
    echo "IP Addresses:"
    ip -4 addr show | grep inet | awk '{print "  " $2}'
    echo "SSH Status: $(systemctl is-active ssh)"
    echo "Kernel: $(uname -r)"
    echo "Disk Usage:"
    df -h /
    echo ""
    log_info "=========================================="
    log_info "Post-installation setup completed!"
    log_info "=========================================="
}

# Main
main() {
    log_info "Starting post-installation setup..."

    wait_for_network

    configure_ssh
    configure_network
    configure_timezone

    install_drivers

    # Offer interactive drive configuration before auto-mount
    interactive_drive_config

    # Auto-mount remaining drives (if interactive was skipped)
    if [ "${AUTO_MOUNT_DRIVES:-true}" = "true" ]; then
        mount_drives
    fi

    install_extra_packages
    install_gui
    install_optional_features

    final_updates
    display_system_info

    log_info "Setup complete. System is ready for use."
    log_info ""
    log_info "Useful commands:"
    log_info "  sudo /opt/ubuntu-installer-scripts/configure-drives.sh     # Drive configuration"
    log_info "  sudo /opt/ubuntu-installer-scripts/install-optional-features.sh -i  # Optional features menu"
}

main "$@"
