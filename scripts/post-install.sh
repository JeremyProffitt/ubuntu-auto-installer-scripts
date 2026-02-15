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

# Set explicit permissions on log files
touch "$LOG_FILE" "$ERROR_LOG"
chmod 640 "$LOG_FILE" "$ERROR_LOG"
chown root:adm "$LOG_FILE" "$ERROR_LOG"

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
REPORT_GENERATED=false

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
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        # Strip whitespace using parameter expansion (safe for special characters)
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        # Only allow safe variable names
        if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            # Reject dangerous environment variables
            case "$key" in
                PATH|LD_PRELOAD|LD_LIBRARY_PATH|LD_AUDIT|LD_DEBUG_OUTPUT|HOME|SHELL|USER|IFS|TERM|LANG|PS1|ENV|BASH_ENV|PROMPT_COMMAND|CDPATH|GLOBIGNORE|PYTHONPATH|PYTHONSTARTUP|NODE_OPTIONS|NODE_PATH|HISTFILE)
                    echo "[WARN] Ignoring dangerous variable from config: $key"
                    continue
                    ;;
            esac
            export "$key=$value"
        fi
    done < "$CONFIG_FILE"
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
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        log_info "Attempt $attempt/$max_attempts: $*"
        if "$@"; then
            return 0
        fi
        log_warn "Attempt $attempt failed, waiting ${delay}s before retry..."
        sleep $delay
        delay=$((delay * 2))  # Exponential backoff
        attempt=$((attempt + 1))
    done

    log_error "Command failed after $max_attempts attempts: $*"
    return 1
}

# Retry apt-get operations with lock handling
apt_retry() {
    local max_attempts=5
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        # Wait for apt locks to be released (max 5 minutes)
        local lock_wait=0
        while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
              fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
              fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
            lock_wait=$((lock_wait + 1))
            if [ $lock_wait -ge 60 ]; then
                log_warn "Apt locks still held after 5+ minutes - skipping this attempt"
                continue 2
            fi
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

    # Validate webhook URL scheme (prevent SSRF via file://, ftp://, etc.)
    case "$WEBHOOK_URL" in
        https://*) ;; # preferred
        http://*)
            log_warn "Webhook URL uses HTTP (not HTTPS) - notification data will be sent unencrypted"
            ;;
        *)
            log_error "Webhook URL must use http:// or https:// scheme - skipping notification"
            return 0
            ;;
    esac

    local hostname=$(hostname)
    local ip_addr=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)
    local end_time=$(date +%s)
    [ -z "$START_TIME" ] && START_TIME=0
    local duration=$((end_time - START_TIME))

    local payload
    # Use jq for safe JSON construction if available, otherwise escape manually
    if command -v jq &>/dev/null; then
        payload=$(jq -n \
            --arg status "$status" \
            --arg hostname "$hostname" \
            --arg ip "$ip_addr" \
            --arg message "$message" \
            --argjson duration "$duration" \
            --arg ts "$(date -Iseconds)" \
            '{status: $status, hostname: $hostname, ip_address: $ip, message: $message, duration_seconds: $duration, timestamp: $ts}')
    else
        # Escape backslashes, double quotes, and control characters for JSON
        local json_escape='s/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r/\\r/g'
        hostname=$(echo "$hostname" | tr -d '\n' | sed "$json_escape")
        message=$(echo "$message" | tr -d '\n' | sed "$json_escape")
        status=$(echo "$status" | tr -d '\n' | sed "$json_escape")
        ip_addr=$(echo "$ip_addr" | tr -d '\n' | sed "$json_escape")

        payload=$(cat <<EOF
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
    fi

    # Redact webhook URL in logs to avoid leaking tokens
    # Redact credentials and path-embedded tokens (e.g., Slack/Discord webhook tokens)
    local redacted_url
    redacted_url=$(echo "$WEBHOOK_URL" | sed 's|://[^@]*@|://***@|; s|\?.*|?***|; s|\(https\{0,1\}://[^/]*/[^/]*/\).*|\1***|')
    log_info "Sending webhook notification to $redacted_url"
    local webhook_sent=false
    for i in 1 2 3; do
        if curl -sf -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL" --max-time 30; then
            webhook_sent=true
            break
        fi
        log_warn "Webhook attempt $i failed, retrying in $((i * 5))s..."
        sleep $((i * 5))
    done
    if [ "$webhook_sent" = true ]; then
        log_info "Webhook notification sent successfully"
    else
        log_warn "Failed to send webhook notification after 3 attempts"
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

    # Configure dpkg/apt log rotation (syslog/kern/auth managed by rsyslog default)
    cat > /etc/logrotate.d/ubuntu-installer-apt << 'EOF'
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

    # Skip base SSH config if hardening config already exists (from install-optional-features.sh)
    # OpenSSH uses first-match semantics: 50-* takes precedence over 99-*, so avoid conflicting settings
    if [ -f /etc/ssh/sshd_config.d/99-hardening.conf ]; then
        log_info "SSH hardening config already in place - skipping base configuration"
        record_step "ssh" "SUCCESS"
        return 0
    fi

    # Deploy SSH keys first, then decide whether to disable password auth
    local password_auth="yes"
    if [ -n "${SSH_AUTHORIZED_KEYS:-}" ]; then
        log_info "Adding SSH authorized keys..."
        INSTALL_USERNAME="${INSTALL_USERNAME:-admin}"
        USER_HOME=$(getent passwd "$INSTALL_USERNAME" | cut -d: -f6)
        [ -z "$USER_HOME" ] && USER_HOME="/home/$INSTALL_USERNAME"
        mkdir -p "$USER_HOME/.ssh"
        while IFS= read -r key_line; do
            [ -z "$key_line" ] && continue
            if ! grep -qF "$key_line" "$USER_HOME/.ssh/authorized_keys" 2>/dev/null; then
                echo "$key_line" >> "$USER_HOME/.ssh/authorized_keys"
            fi
        done <<< "$SSH_AUTHORIZED_KEYS"
        chmod 700 "$USER_HOME/.ssh"
        chmod 600 "$USER_HOME/.ssh/authorized_keys"
        chown -R "$INSTALL_USERNAME:$INSTALL_USERNAME" "$USER_HOME/.ssh"
        # Only disable password auth if keys were actually written
        if [ -s "$USER_HOME/.ssh/authorized_keys" ]; then
            password_auth="no"
        else
            log_warn "SSH keys configured but authorized_keys is empty - keeping password auth enabled"
        fi
    fi

    cat > /etc/ssh/sshd_config.d/50-ubuntu-installer.conf << EOF
# Ubuntu Auto Installer SSH Configuration
PasswordAuthentication $password_auth
PubkeyAuthentication yes
PermitRootLogin no
X11Forwarding no
ClientAliveInterval 60
ClientAliveCountMax 3
EOF

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

        # Validate network config values to prevent YAML injection
        local ip_val="${IP_ADDRESS:-192.168.1.100}"
        local mask_val="${NETMASK:-24}"
        local gw_val="${GATEWAY:-192.168.1.1}"
        local dns_val="${DNS_SERVERS:-8.8.8.8,8.8.4.4}"

        if ! echo "$ip_val" | grep -qP '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$'; then
            log_error "Invalid IP_ADDRESS format: $ip_val"
            record_step "static_ip" "FAILED"
            return
        fi
        if ! echo "$gw_val" | grep -qP '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$'; then
            log_error "Invalid GATEWAY format: $gw_val"
            record_step "static_ip" "FAILED"
            return
        fi
        # Validate CIDR prefix
        if ! echo "$mask_val" | grep -qP '^\d{1,2}$' || [ "$mask_val" -lt 1 ] || [ "$mask_val" -gt 32 ]; then
            log_error "Invalid CIDR prefix: $mask_val (must be 1-32)"
            record_step "static_ip" "FAILED"
            return
        fi
        # Validate DNS servers (comma-separated IPs)
        for dns_entry in $(echo "$dns_val" | tr ',' ' '); do
            if ! echo "$dns_entry" | grep -qP '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$'; then
                log_error "Invalid DNS server: $dns_entry"
                record_step "static_ip" "FAILED"
                return
            fi
        done

        IFACE=$(ip -o link show | awk -F': ' '$2 !~ /^(lo|docker|veth|br-|virbr|wl|tun|tap|zt|tailscale)/ {print $2; exit}')

        if [ -n "$IFACE" ]; then
            # Format DNS list for proper YAML (comma-space separated)
            local dns_yaml
            dns_yaml=$(echo "$dns_val" | sed 's/,/, /g')
            cat > /etc/netplan/01-static-config.yaml << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $IFACE:
      dhcp4: false
      addresses:
        - ${ip_val}/${mask_val}
      routes:
        - to: default
          via: ${gw_val}
      nameservers:
        addresses: [${dns_yaml}]
EOF
            chmod 600 /etc/netplan/01-static-config.yaml
            # Backup installer's DHCP config before removing (restore on failure)
            if [ -f /etc/netplan/00-installer-config.yaml ]; then
                cp /etc/netplan/00-installer-config.yaml /etc/netplan/00-installer-config.yaml.bak
            fi
            rm -f /etc/netplan/00-installer-config.yaml 2>/dev/null || true
            netplan apply 2>/dev/null || true
            # Verify connectivity after applying netplan (multiple retries for slow interfaces)
            local net_verify_ok=false
            for _i in 1 2 3; do
                sleep 5
                if ping -c 1 -W 5 "$gw_val" &>/dev/null; then
                    net_verify_ok=true
                    break
                fi
            done
            if [ "$net_verify_ok" = true ]; then
                log_info "Network connectivity verified (gateway reachable)"
                rm -f /etc/netplan/00-installer-config.yaml.bak
                record_step "static_ip" "SUCCESS"
            else
                log_warn "Gateway $gw_val not reachable after netplan apply - restoring DHCP config"
                rm -f /etc/netplan/01-static-config.yaml
                if [ -f /etc/netplan/00-installer-config.yaml.bak ]; then
                    mv /etc/netplan/00-installer-config.yaml.bak /etc/netplan/00-installer-config.yaml
                    netplan apply 2>/dev/null || true
                fi
                record_step "static_ip" "PARTIAL"
            fi
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

    # Validate timezone format to prevent injection (must be Region/City pattern, allows digits/hyphens for Etc/GMT+5 etc.)
    if ! echo "$TIMEZONE" | grep -qP '^[A-Za-z_][A-Za-z0-9_+-]+/[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)?$'; then
        log_warn "Invalid TIMEZONE format: $TIMEZONE - using default America/New_York"
        TIMEZONE="America/New_York"
    fi

    if timedatectl set-timezone "$TIMEZONE" 2>/dev/null; then
        record_step "timezone" "SUCCESS"
        log_info "Timezone set to $TIMEZONE"
    else
        record_step "timezone" "FAILED"
        log_warn "Failed to set timezone"
    fi
}

configure_tmpfs_tmp() {
    if [ "${ENABLE_TMPFS_TMP:-false}" != "true" ]; then
        record_step "tmpfs_tmp" "SKIPPED"
        return 0
    fi

    log_step "Configuring tmpfs for /tmp..."

    local size="${TMPFS_TMP_SIZE:-50%}"

    # Validate size (e.g., 50%, 4G, 2048M)
    if ! echo "$size" | grep -qP '^[0-9]+(%|[GgMmKk])?$'; then
        log_warn "Invalid TMPFS_TMP_SIZE: $size - using default 50%"
        size="50%"
    fi

    # Create systemd drop-in to configure tmp.mount with desired size
    mkdir -p /etc/systemd/system/tmp.mount.d
    cat > /etc/systemd/system/tmp.mount.d/size.conf << EOF
[Mount]
Options=mode=1777,strictatime,nosuid,nodev,size=${size}
EOF

    systemctl daemon-reload

    if systemctl enable tmp.mount && systemctl start tmp.mount 2>/dev/null; then
        record_step "tmpfs_tmp" "SUCCESS"
        log_info "tmpfs /tmp enabled (size cap: ${size})"
    else
        # tmp.mount may fail to start if /tmp is in use; will activate on next boot
        systemctl enable tmp.mount 2>/dev/null
        record_step "tmpfs_tmp" "PARTIAL"
        log_warn "tmpfs /tmp enabled but will activate on next reboot (/tmp currently in use)"
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

        # Validate package names (alphanumeric, hyphens, dots, plus signs only)
        PACKAGES=""
        for pkg in $(echo "$EXTRA_PACKAGES" | tr ',' ' '); do
            if echo "$pkg" | grep -qP '^[a-zA-Z0-9][a-zA-Z0-9.+\-]+$'; then
                PACKAGES="$PACKAGES $pkg"
            else
                log_warn "Skipping invalid package name: $pkg"
            fi
        done
        PACKAGES=$(echo "$PACKAGES" | xargs)  # trim whitespace

        if [ -z "$PACKAGES" ]; then
            log_warn "No valid packages to install"
            record_step "extra_packages" "SKIPPED"
            return
        fi

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
    # Guard against re-entrancy (trap handler calling this while already running)
    if [ "$REPORT_GENERATED" = true ]; then
        return 0
    fi
    REPORT_GENERATED=true

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

    # Write status report to a temporary file first;
    # STATUS_FILE is only created on success (so ConditionPathExists retry works)
    local report_file="/var/log/install-report"
    cat > "$report_file" << EOF
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
        printf "  %-25s %s\n" "$step:" "${STEP_STATUS[$step]}" >> "$report_file"
    done

    cat >> "$report_file" << EOF

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
    cat "$report_file"

    # Only create STATUS_FILE on success (so first-boot systemd ConditionPathExists retry works)
    if [ "$overall_status" != "FAILED" ]; then
        cp "$report_file" "$STATUS_FILE"
    else
        log_warn "Installation FAILED - $STATUS_FILE NOT created so first-boot service will retry"
    fi

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
        for disk in /dev/sd[a-z] /dev/sd[a-z][a-z] /dev/nvme*n1; do
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
    # Idempotency guard: skip if already completed
    if [ -f "/var/log/install-complete" ]; then
        echo "Post-install already completed. Remove /var/log/install-complete to re-run."
        exit 0
    fi

    log_info "Starting post-installation setup..."
    log_info "Installation ID: $(cat /etc/machine-id 2>/dev/null || echo 'unknown')"

    # Check available disk space before installing potentially GBs of software
    local avail_mb
    avail_mb=$(df --output=avail -BM / 2>/dev/null | tail -1 | tr -d ' M')
    if [ -n "$avail_mb" ] && [ "$avail_mb" -lt 3000 ] 2>/dev/null; then
        log_error "Less than 3GB available on root filesystem (${avail_mb}MB). Installations may fail."
        log_error "Consider using a larger disk or reducing optional features."
    elif [ -n "$avail_mb" ] && [ "$avail_mb" -lt 5000 ] 2>/dev/null; then
        log_warn "Less than 5GB available on root filesystem (${avail_mb}MB). Large feature sets (GUI, dev tools) may fail."
    fi

    # Configure log rotation early to manage disk space
    configure_log_rotation

    # Critical steps - if these fail, we note it but continue
    wait_for_network

    # Essential configuration
    configure_ssh
    configure_network
    configure_timezone
    configure_tmpfs_tmp

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

# Reset trap to prevent race between trap and exit-code computation
trap - INT TERM

# Propagate failure exit code so systemd Restart=on-failure works correctly
# Count failures from the status report
_failed=0
for _step in "${!STEP_STATUS[@]}"; do
    [ "${STEP_STATUS[$_step]}" = "FAILED" ] && _failed=$((_failed + 1))
done

if [ "$CRITICAL_FAILURE" = true ] || [ $_failed -gt 0 ]; then
    sleep 0.5  # Allow tee process substitution to flush final log lines
    exit 1
fi
sleep 0.5  # Allow tee process substitution to flush final log lines
exit 0
