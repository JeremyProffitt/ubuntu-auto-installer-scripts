#!/bin/bash
# ============================================================================
# Post-Installation Script for Ubuntu Auto Installer
# Runs on first boot to complete system configuration
# Enhanced with retry logic, error handling, and status reporting
# ============================================================================

# Don't exit on error - we handle errors manually for better reliability
set +e

# ============================================================================
# INITIALIZATION
# ============================================================================

LOG_FILE="/var/log/post-install.log"
STATUS_FILE="/var/log/install-complete"
ERROR_LOG="/var/log/post-install-errors.log"
START_TIME=$(date +%s)

# Ensure log directory exists
mkdir -p /var/log

# Initialize error log
echo "=== Post-Install Errors ===" > "$ERROR_LOG"
echo "Started: $(date)" >> "$ERROR_LOG"

# Redirect output to log file while keeping console output
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo "Post-Installation Setup"
echo "Started: $(date)"
echo "=========================================="

# Track success/failure of each step
declare -A STEP_STATUS
CRITICAL_FAILURE=false

# ============================================================================
# PARSE ARGUMENTS AND LOAD CONFIG
# ============================================================================

UNATTENDED_FLAG=false
for arg in "$@"; do
    case $arg in
        --unattended)
            UNATTENDED_FLAG=true
            shift
            ;;
    esac
done

CONFIG_FILE="/opt/ubuntu-installer/config.env"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo "Loaded configuration from $CONFIG_FILE"
else
    echo "Warning: Configuration file not found, using defaults"
fi

# Set unattended mode from flag or config
if [ "$UNATTENDED_FLAG" = "true" ] || [ "${UNATTENDED:-false}" = "true" ]; then
    UNATTENDED=true
    INTERACTIVE_DRIVE_CONFIG=false
    SHOW_OPTIONAL_MENU=false
    echo "Running in UNATTENDED mode - skipping all interactive prompts"
fi

# ============================================================================
# LOGGING AND STATUS FUNCTIONS
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    echo "[WARN] $(date): $1" >> "$ERROR_LOG"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    echo "[ERROR] $(date): $1" >> "$ERROR_LOG"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Record step status
record_step() {
    local step_name="$1"
    local status="$2"
    STEP_STATUS["$step_name"]="$status"
    if [ "$status" = "FAILED" ]; then
        log_error "Step failed: $step_name"
    else
        log_info "Step completed: $step_name"
    fi
}

# ============================================================================
# RETRY LOGIC FUNCTIONS
# ============================================================================

# Retry a command with exponential backoff
# Usage: retry_command <max_attempts> <delay> <command...>
retry_command() {
    local max_attempts=$1
    local delay=$2
    shift 2
    local cmd="$@"
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        log_info "Attempt $attempt/$max_attempts: $cmd"
        if eval "$cmd"; then
            return 0
        fi
        log_warn "Attempt $attempt failed, waiting ${delay}s before retry..."
        sleep $delay
        delay=$((delay * 2))  # Exponential backoff
        attempt=$((attempt + 1))
    done

    log_error "Command failed after $max_attempts attempts: $cmd"
    return 1
}

# Retry apt-get operations with lock handling
apt_retry() {
    local max_attempts=5
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        # Wait for apt locks to be released
        while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
              fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
              fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
            log_info "Waiting for apt locks to be released..."
            sleep 5
        done

        log_info "Attempt $attempt/$max_attempts: apt-get $@"
        if DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" "$@"; then
            return 0
        fi

        log_warn "apt-get failed, attempt $attempt/$max_attempts"
        sleep $((attempt * 10))
        attempt=$((attempt + 1))
    done

    log_error "apt-get failed after $max_attempts attempts"
    return 1
}

# ============================================================================
# NETWORK FUNCTIONS
# ============================================================================

wait_for_network() {
    log_step "Waiting for network connection..."
    local max_attempts=60
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        # Try multiple endpoints
        if ping -c 1 -W 2 8.8.8.8 &>/dev/null || \
           ping -c 1 -W 2 1.1.1.1 &>/dev/null || \
           ping -c 1 -W 2 208.67.222.222 &>/dev/null; then
            log_info "Network is available"

            # Also verify DNS is working
            if host google.com &>/dev/null || nslookup google.com &>/dev/null 2>&1; then
                log_info "DNS resolution working"
                record_step "network" "SUCCESS"
                return 0
            fi
        fi
        attempt=$((attempt + 1))
        echo -n "."
        sleep 2
    done
    echo ""

    log_warn "Network may not be fully available after ${max_attempts} attempts"
    record_step "network" "PARTIAL"
    return 1
}

# ============================================================================
# WEBHOOK NOTIFICATION
# ============================================================================

send_webhook() {
    local status="$1"
    local message="$2"

    if [ -z "${WEBHOOK_URL:-}" ]; then
        log_info "No webhook URL configured, skipping notification"
        return 0
    fi

    local hostname=$(hostname)
    local ip_addr=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)
    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))

    local payload=$(cat <<EOF
{
    "status": "$status",
    "hostname": "$hostname",
    "ip_address": "$ip_addr",
    "message": "$message",
    "duration_seconds": $duration,
    "timestamp": "$(date -Iseconds)"
}
EOF
)

    log_info "Sending webhook notification to $WEBHOOK_URL"
    if curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL" --max-time 30; then
        log_info "Webhook notification sent successfully"
    else
        log_warn "Failed to send webhook notification"
    fi
}

# ============================================================================
# CONFIGURATION FUNCTIONS
# ============================================================================

configure_log_rotation() {
    log_step "Configuring log rotation (7 day retention)..."

    # Create logrotate config for installation logs
    cat > /etc/logrotate.d/ubuntu-installer << 'EOF'
/var/log/post-install.log
/var/log/post-install-errors.log
/var/log/install-complete
{
    daily
    rotate 7
    nocompress
    missingok
    notifempty
    create 0640 root adm
}
EOF

    # Also configure general system log rotation for reliability
    cat > /etc/logrotate.d/ubuntu-installer-system << 'EOF'
/var/log/syslog
/var/log/kern.log
/var/log/auth.log
{
    daily
    rotate 7
    nocompress
    missingok
    notifempty
    create 0640 syslog adm
    sharedscripts
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate 2>/dev/null || true
    endscript
}

/var/log/dpkg.log
/var/log/apt/history.log
/var/log/apt/term.log
{
    daily
    rotate 7
    nocompress
    missingok
    notifempty
    create 0640 root adm
}
EOF

    # Set up journald to limit disk usage (100MB max, 7 days retention)
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/retention.conf << 'EOF'
[Journal]
SystemMaxUse=100M
SystemKeepFree=100M
MaxRetentionSec=7day
MaxFileSec=1day
Compress=no
EOF

    # Restart journald to apply changes
    systemctl restart systemd-journald 2>/dev/null || true

    # Run logrotate once to ensure it's working
    logrotate -f /etc/logrotate.d/ubuntu-installer 2>/dev/null || true

    record_step "log_rotation" "SUCCESS"
    log_info "Log rotation configured: 7 day retention"
}

configure_ssh() {
    log_step "Configuring SSH..."

    systemctl enable ssh 2>/dev/null || true
    systemctl start ssh 2>/dev/null || true

    cat > /etc/ssh/sshd_config.d/99-ubuntu-installer.conf << 'EOF'
# Ubuntu Auto Installer SSH Configuration
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin prohibit-password
X11Forwarding yes
ClientAliveInterval 60
ClientAliveCountMax 3
EOF

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

    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

    if systemctl is-active ssh &>/dev/null || systemctl is-active sshd &>/dev/null; then
        record_step "ssh" "SUCCESS"
        log_info "SSH configured and enabled"
    else
        record_step "ssh" "FAILED"
        log_error "SSH service may not be running"
    fi
}

configure_network() {
    log_step "Configuring network..."

    if [ "${STATIC_IP:-false}" = "true" ]; then
        log_info "Configuring static IP: ${IP_ADDRESS:-not set}"

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
            netplan apply 2>/dev/null || true
            record_step "static_ip" "SUCCESS"
            log_info "Static IP configured on $IFACE"
        else
            record_step "static_ip" "FAILED"
            log_warn "Could not detect network interface for static IP"
        fi
    else
        record_step "network_config" "SUCCESS"
        log_info "Using DHCP (default)"
    fi
}

configure_timezone() {
    log_step "Configuring timezone..."
    TIMEZONE="${TIMEZONE:-America/New_York}"

    if timedatectl set-timezone "$TIMEZONE" 2>/dev/null; then
        record_step "timezone" "SUCCESS"
        log_info "Timezone set to $TIMEZONE"
    else
        record_step "timezone" "FAILED"
        log_warn "Failed to set timezone"
    fi
}

# ============================================================================
# INSTALLATION FUNCTIONS
# ============================================================================

install_drivers() {
    log_step "Running driver installation script..."

    local script_path=""
    if [ -x /opt/ubuntu-installer-scripts/install-drivers.sh ]; then
        script_path="/opt/ubuntu-installer-scripts/install-drivers.sh"
    elif [ -x /opt/install-drivers.sh ]; then
        script_path="/opt/install-drivers.sh"
    fi

    if [ -n "$script_path" ]; then
        if "$script_path"; then
            record_step "drivers" "SUCCESS"
        else
            record_step "drivers" "PARTIAL"
            log_warn "Driver installation completed with warnings"
        fi
    else
        record_step "drivers" "SKIPPED"
        log_warn "Driver installation script not found"
    fi
}

mount_drives() {
    log_step "Running drive mount script..."

    local script_path=""
    if [ -x /opt/ubuntu-installer-scripts/mount-drives.sh ]; then
        script_path="/opt/ubuntu-installer-scripts/mount-drives.sh"
    elif [ -x /opt/mount-drives.sh ]; then
        script_path="/opt/mount-drives.sh"
    fi

    if [ -n "$script_path" ]; then
        if "$script_path"; then
            record_step "mount_drives" "SUCCESS"
        else
            record_step "mount_drives" "PARTIAL"
            log_warn "Drive mounting completed with warnings"
        fi
    else
        record_step "mount_drives" "SKIPPED"
        log_warn "Drive mount script not found"
    fi
}

interactive_drive_config() {
    if [ "${UNATTENDED:-false}" = "true" ]; then
        log_info "Unattended mode - skipping interactive drive configuration"
        record_step "interactive_drives" "SKIPPED"
        return 0
    fi

    if [ "${INTERACTIVE_DRIVE_CONFIG:-false}" = "true" ] && [ -t 0 ]; then
        echo ""
        echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  Interactive Drive Configuration Available                    ║${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        read -t 60 -p "Run interactive drive configuration? (y/n) [n]: " INTERACTIVE_CHOICE || INTERACTIVE_CHOICE="n"

        if [ "$INTERACTIVE_CHOICE" = "y" ] || [ "$INTERACTIVE_CHOICE" = "Y" ]; then
            if [ -x /opt/ubuntu-installer-scripts/configure-drives.sh ]; then
                /opt/ubuntu-installer-scripts/configure-drives.sh
                record_step "interactive_drives" "SUCCESS"
            else
                record_step "interactive_drives" "FAILED"
                log_warn "Interactive drive configuration script not found"
            fi
        else
            record_step "interactive_drives" "SKIPPED"
        fi
    else
        record_step "interactive_drives" "SKIPPED"
    fi
}

install_gui() {
    if [ "${INSTALL_GUI:-false}" = "true" ]; then
        log_step "Installing GUI..."

        local script_path=""
        if [ -x /opt/ubuntu-installer-scripts/install-gui.sh ]; then
            script_path="/opt/ubuntu-installer-scripts/install-gui.sh"
        elif [ -x /opt/install-gui.sh ]; then
            script_path="/opt/install-gui.sh"
        fi

        if [ -n "$script_path" ]; then
            if "$script_path"; then
                record_step "gui" "SUCCESS"
            else
                record_step "gui" "PARTIAL"
                log_warn "GUI installation completed with warnings"
            fi
        else
            record_step "gui" "FAILED"
            log_warn "GUI installation script not found"
        fi
    else
        record_step "gui" "SKIPPED"
        log_info "Headless server mode - skipping GUI installation"
    fi
}

install_optional_features() {
    log_step "Installing optional features..."

    local script_path=""
    if [ -x /opt/ubuntu-installer-scripts/install-optional-features.sh ]; then
        script_path="/opt/ubuntu-installer-scripts/install-optional-features.sh"
    elif [ -x /opt/install-optional-features.sh ]; then
        script_path="/opt/install-optional-features.sh"
    fi

    if [ -n "$script_path" ]; then
        if "$script_path"; then
            record_step "optional_features" "SUCCESS"
        else
            record_step "optional_features" "PARTIAL"
            log_warn "Optional features installation completed with warnings"
        fi
    else
        record_step "optional_features" "SKIPPED"
        log_warn "Optional features script not found"
    fi

    # Skip interactive menu in unattended mode
    if [ "${UNATTENDED:-false}" = "true" ]; then
        return 0
    fi

    if [ "${SHOW_OPTIONAL_MENU:-false}" = "true" ] && [ -t 0 ]; then
        read -t 60 -p "Open optional features menu? (y/n) [n]: " OPTIONAL_CHOICE || OPTIONAL_CHOICE="n"
        if [ "$OPTIONAL_CHOICE" = "y" ] || [ "$OPTIONAL_CHOICE" = "Y" ]; then
            [ -n "$script_path" ] && "$script_path" --interactive
        fi
    fi
}

install_extra_packages() {
    if [ -n "${EXTRA_PACKAGES:-}" ]; then
        log_step "Installing extra packages: $EXTRA_PACKAGES"

        PACKAGES=$(echo "$EXTRA_PACKAGES" | tr ',' ' ')

        if apt_retry update && apt_retry install $PACKAGES; then
            record_step "extra_packages" "SUCCESS"
        else
            record_step "extra_packages" "PARTIAL"
            log_warn "Some extra packages may not have installed"
        fi
    else
        record_step "extra_packages" "SKIPPED"
    fi
}

final_updates() {
    log_step "Running final system updates..."

    local update_success=true

    if ! apt_retry update; then
        update_success=false
    fi

    if ! apt_retry upgrade; then
        update_success=false
    fi

    apt_retry autoremove || true
    apt-get clean || true

    if [ "$update_success" = true ]; then
        record_step "updates" "SUCCESS"
    else
        record_step "updates" "PARTIAL"
        log_warn "System updates completed with some issues"
    fi
}

# ============================================================================
# STATUS REPORTING
# ============================================================================

generate_status_report() {
    log_step "Generating status report..."

    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    local duration_min=$((duration / 60))
    local duration_sec=$((duration % 60))

    local hostname=$(hostname)
    local ip_addr=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)
    local kernel=$(uname -r)
    local ssh_status=$(systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null || echo "unknown")

    # Count successes and failures
    local success_count=0
    local failed_count=0
    local partial_count=0

    for step in "${!STEP_STATUS[@]}"; do
        case "${STEP_STATUS[$step]}" in
            SUCCESS) ((success_count++)) ;;
            FAILED) ((failed_count++)) ;;
            PARTIAL) ((partial_count++)) ;;
        esac
    done

    # Determine overall status
    local overall_status="SUCCESS"
    if [ $failed_count -gt 0 ]; then
        overall_status="PARTIAL"
    fi
    if [ "$CRITICAL_FAILURE" = true ]; then
        overall_status="FAILED"
    fi

    # Write status file
    cat > "$STATUS_FILE" << EOF
========================================
Ubuntu Auto-Install Complete
========================================
Status: $overall_status
Hostname: $hostname
IP Address: $ip_addr
Kernel: $kernel
SSH Status: $ssh_status
Duration: ${duration_min}m ${duration_sec}s
Completed: $(date)

Step Results:
----------------------------------------
EOF

    for step in "${!STEP_STATUS[@]}"; do
        printf "  %-25s %s\n" "$step:" "${STEP_STATUS[$step]}" >> "$STATUS_FILE"
    done

    cat >> "$STATUS_FILE" << EOF

Summary:
  Successful: $success_count
  Partial:    $partial_count
  Failed:     $failed_count

Log files:
  Main log: $LOG_FILE
  Errors:   $ERROR_LOG
========================================
EOF

    # Display to console
    cat "$STATUS_FILE"

    # Send webhook notification
    local webhook_message="Installation completed on $hostname ($ip_addr). Status: $overall_status. Duration: ${duration_min}m ${duration_sec}s"
    send_webhook "$overall_status" "$webhook_message"

    return 0
}

display_system_info() {
    log_info "=========================================="
    log_info "System Information"
    log_info "=========================================="

    echo "Hostname: $(hostname)"
    echo "IP Addresses:"
    ip -4 addr show | grep inet | awk '{print "  " $2}'
    echo "SSH Status: $(systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null || echo 'unknown')"
    echo "Kernel: $(uname -r)"
    echo "Disk Usage:"
    df -h / 2>/dev/null || true
    echo ""

    # SMART health summary
    if command -v smartctl &>/dev/null; then
        echo "Disk Health:"
        for disk in /dev/sd? /dev/nvme?n1; do
            if [ -e "$disk" ]; then
                health=$(smartctl -H "$disk" 2>/dev/null | grep -i "SMART overall-health" | awk -F: '{print $2}' | xargs)
                [ -n "$health" ] && echo "  $disk: $health"
            fi
        done
    fi

    echo ""
    log_info "=========================================="
    log_info "Post-installation setup completed!"
    log_info "=========================================="
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    log_info "Starting post-installation setup..."
    log_info "Installation ID: $(cat /etc/machine-id 2>/dev/null || echo 'unknown')"

    # Configure log rotation early to manage disk space
    configure_log_rotation

    # Critical steps - if these fail, we note it but continue
    wait_for_network

    # Essential configuration
    configure_ssh
    configure_network
    configure_timezone

    # Driver and hardware setup
    install_drivers

    # Drive configuration
    interactive_drive_config

    if [ "${AUTO_MOUNT_DRIVES:-true}" = "true" ]; then
        mount_drives
    fi

    # Software installation
    install_extra_packages
    install_gui
    install_optional_features

    # Final updates
    final_updates

    # Generate reports
    display_system_info
    generate_status_report

    log_info ""
    log_info "Setup complete. System is ready for use."
    log_info ""
    log_info "Useful commands:"
    log_info "  sudo /opt/ubuntu-installer-scripts/configure-drives.sh     # Drive configuration"
    log_info "  sudo /opt/ubuntu-installer-scripts/install-optional-features.sh -i  # Optional features menu"
    log_info ""
    log_info "Status file: $STATUS_FILE"
    log_info "Full log: $LOG_FILE"
}

# Run main with error trapping
trap 'log_error "Script interrupted"; generate_status_report; exit 1' INT TERM

main "$@"

exit 0
