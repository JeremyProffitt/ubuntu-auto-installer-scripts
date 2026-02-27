#!/bin/bash
# ============================================================================
# Optional Features Installation Script
# Installs optional software and configurations for home lab servers
# ============================================================================

set +e
ERROR_COUNT=0
export DEBIAN_FRONTEND=noninteractive

track_error() {
    ERROR_COUNT=$((ERROR_COUNT + 1))
}

LOG_FILE="/var/log/optional-features.log"
touch "$LOG_FILE"
chmod 640 "$LOG_FILE"
chown root:adm "$LOG_FILE" 2>/dev/null || true
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo "Optional Features Installation"
echo "Started: $(date)"
echo "=========================================="

CONFIG_FILE="/opt/ubuntu-installer/config.env"

# Load configuration safely (no arbitrary code execution)
if [ -f "$CONFIG_FILE" ]; then
    # Blocklist of dangerous environment variables that must never be overwritten
    _CONFIG_BLOCKLIST="PATH LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT LD_DEBUG_OUTPUT HOME SHELL USER IFS TERM LANG PS1 ENV BASH_ENV PROMPT_COMMAND CDPATH GLOBIGNORE PYTHONPATH PYTHONSTARTUP NODE_OPTIONS NODE_PATH HISTFILE"
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        # Strip whitespace using parameter expansion (safe for special chars)
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        # Only allow safe variable names
        if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            # Reject blocklisted variable names
            case " $_CONFIG_BLOCKLIST " in
                *" $key "*) echo "WARN: Refusing to set blocklisted variable: $key"; continue ;;
            esac
            export "$key=$value"
        fi
    done < "$CONFIG_FILE"
    echo "Loaded configuration from $CONFIG_FILE"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() { echo -e "\n${BLUE}━━━ $1 ━━━${NC}\n"; }

# Verify a downloaded file against a SHA256 checksum file
# Usage: verify_checksum <file> <checksums_file>
# Returns 0 if verified, 1 if failed
verify_checksum() {
    local file="$1"
    local checksums_file="$2"
    local filename
    filename=$(basename "$file")

    if [ ! -f "$checksums_file" ]; then
        log_warn "Checksum file not found: $checksums_file"
        return 1
    fi
    if [ ! -f "$file" ]; then
        log_warn "File not found: $file"
        return 1
    fi

    local expected
    expected=$(grep "[[:space:]]${filename}$" "$checksums_file" | head -1 | awk '{print $1}')
    if [ -z "$expected" ]; then
        log_warn "No checksum entry found for $filename"
        return 1
    fi

    local actual
    actual=$(sha256sum "$file" | awk '{print $1}')
    if [ "$expected" = "$actual" ]; then
        log_info "Checksum verified for $filename"
        return 0
    else
        log_error "CHECKSUM MISMATCH for $filename (expected: $expected, got: $actual)"
        return 1
    fi
}

# Fetch latest GitHub release tag with rate-limit awareness
# Usage: github_latest_tag <owner/repo>  → prints version (without leading "v") or empty on failure
github_latest_tag() {
    local repo="$1"
    local response
    response=$(curl -sS -w "\n%{http_code}" "https://api.github.com/repos/${repo}/releases/latest")
    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" = "403" ] || [ "$http_code" = "429" ]; then
        log_warn "GitHub API rate limit hit while fetching ${repo} release (HTTP ${http_code})"
        return 1
    fi
    if [ "$http_code" != "200" ]; then
        log_warn "GitHub API returned HTTP ${http_code} for ${repo}"
        return 1
    fi
    echo "$body" | grep -Po '"tag_name": "v?\K[^"]*'
}

# ============================================================================
# DOCKER & CONTAINER TOOLS
# ============================================================================

install_docker() {
    if [ "${INSTALL_DOCKER:-false}" != "true" ]; then
        return
    fi

    log_section "Installing Docker"

    # Remove old versions
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Install prerequisites
    apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Add repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker (apt-get update runs after adding new repo source)
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Add user to docker group
    INSTALL_USERNAME="${INSTALL_USERNAME:-admin}"
    usermod -aG docker "$INSTALL_USERNAME" || true

    # Enable and start Docker
    systemctl enable docker
    systemctl start docker

    log_info "Docker installed successfully"
    docker --version
}

install_portainer() {
    if [ "${INSTALL_PORTAINER:-false}" != "true" ]; then
        return
    fi

    if ! command -v docker &> /dev/null; then
        log_warn "Docker not installed, skipping Portainer"
        track_error
        return
    fi

    log_section "Installing Portainer"

    # Create volume for Portainer data
    docker volume create portainer_data

    # Run Portainer
    # NOTE: Docker socket access grants root-equivalent privileges to Portainer.
    # Port 8000 (Edge Agent) is not exposed as it is unnecessary for standalone use.
    docker run -d \
        -p 127.0.0.1:9443:9443 \
        --name portainer \
        --restart=always \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v portainer_data:/data \
        portainer/portainer-ce:2.21.5

    # Verify Portainer container started successfully
    sleep 5
    if ! docker inspect portainer --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
        log_warn "Portainer container may not be running - check: docker logs portainer"
        track_error
    fi

    log_info "Portainer installed - Listening on 127.0.0.1:9443 (use reverse proxy for remote access)"
    log_warn "Portainer has Docker socket access (root-equivalent). Monitor for CVEs and update manually: docker pull portainer/portainer-ce:<version> && docker stop portainer && docker rm portainer && re-run"
}

# ============================================================================
# WEB MANAGEMENT INTERFACES
# ============================================================================

install_cockpit() {
    if [ "${INSTALL_COCKPIT:-false}" != "true" ]; then
        return
    fi

    log_section "Installing Cockpit Web Management"

    apt-get install -y cockpit cockpit-storaged cockpit-networkmanager cockpit-packagekit

    # Enable and start Cockpit
    systemctl enable cockpit.socket
    systemctl start cockpit.socket

    log_info "Cockpit installed - Access at https://<ip>:9090"
}

install_webmin() {
    if [ "${INSTALL_WEBMIN:-false}" != "true" ]; then
        return
    fi

    log_section "Installing Webmin"

    # Add Webmin repository (verify GPG key fingerprint)
    # Fingerprint source: https://webmin.com/download/ (Jamie Cameron's official signing key)
    curl -fsSL https://download.webmin.com/jcameron-key.asc -o /tmp/webmin-key.asc
    # Verify the key fingerprint before trusting it
    local key_fp
    key_fp=$(gpg --with-fingerprint --with-colons /tmp/webmin-key.asc 2>/dev/null | grep '^fpr' | head -1 | cut -d: -f10)
    if [ "$key_fp" != "1719003ACE3E5A41E2DE70DFD97A3AE911F63C51" ]; then
        log_warn "Webmin GPG key fingerprint mismatch (got: $key_fp). Skipping Webmin installation for security."
        rm -f /tmp/webmin-key.asc
        return
    fi
    gpg --dearmor --yes -o /usr/share/keyrings/webmin.gpg < /tmp/webmin-key.asc
    rm -f /tmp/webmin-key.asc
    echo "deb [signed-by=/usr/share/keyrings/webmin.gpg] https://download.webmin.com/download/repository sarge contrib" > /etc/apt/sources.list.d/webmin.list

    apt-get update
    apt-get install -y webmin

    log_info "Webmin installed - Access at https://<ip>:10000"
}

# ============================================================================
# VPN & REMOTE ACCESS
# ============================================================================

install_tailscale() {
    if [ "${INSTALL_TAILSCALE:-false}" != "true" ]; then
        return
    fi

    log_section "Installing Tailscale VPN"

    curl -fsSL https://tailscale.com/install.sh | sh

    systemctl enable tailscaled
    systemctl start tailscaled

    log_info "Tailscale installed"
    log_info "Run 'sudo tailscale up' to authenticate"
}

install_zerotier() {
    if [ "${INSTALL_ZEROTIER:-false}" != "true" ]; then
        return
    fi

    log_section "Installing ZeroTier VPN"

    curl -fsSL https://install.zerotier.com | bash

    systemctl enable zerotier-one
    systemctl start zerotier-one

    log_info "ZeroTier installed"
    log_info "Run 'sudo zerotier-cli join <network-id>' to join a network"
}

# ============================================================================
# SECURITY HARDENING
# ============================================================================

install_fail2ban() {
    if [ "${INSTALL_FAIL2BAN:-false}" != "true" ]; then
        return
    fi

    log_section "Installing Fail2ban"

    apt-get install -y fail2ban

    # Create local jail configuration
    cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
banaction = nftables-multiport

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 24h
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban

    log_info "Fail2ban installed and configured"
}

configure_ufw() {
    if [ "${CONFIGURE_UFW:-false}" != "true" ]; then
        return
    fi

    log_section "Configuring UFW Firewall"

    apt-get install -y ufw

    # Default policies
    ufw default deny incoming
    ufw default allow outgoing

    # Allow SSH
    ufw allow ssh

    # Use explicit LAN_CIDR, NFS network, or auto-detect from current IP
    local LAN_CIDR="${LAN_CIDR:-${NFS_ALLOWED_NETWORK:-}}"
    if [ -z "$LAN_CIDR" ]; then
        # Auto-detect LAN CIDR from the primary interface's IP and prefix length
        local auto_ip auto_prefix
        auto_ip=$(ip -o -4 addr show | grep -v '127.0.0.1' | head -1 | awk '{print $4}')
        if [ -n "$auto_ip" ]; then
            auto_prefix=$(echo "$auto_ip" | cut -d/ -f2)
            local ip_base
            # Use bash arithmetic for bitwise ops (POSIX-compatible, works with mawk and gawk)
            local _a _b _c _d
            IFS=. read -r _a _b _c _d <<< "${auto_ip%%/*}"
            if [ -n "$_a" ] && [ -n "$auto_prefix" ]; then
                local _ip=$(( (_a << 24) + (_b << 16) + (_c << 8) + _d ))
                local _mask=$(( 0xFFFFFFFF << (32 - auto_prefix) ))
                local _net=$(( _ip & _mask ))
                ip_base="$(( (_net >> 24) & 0xFF )).$(( (_net >> 16) & 0xFF )).$(( (_net >> 8) & 0xFF )).$(( _net & 0xFF ))"
            fi
            if [ -n "$ip_base" ] && [ -n "$auto_prefix" ]; then
                LAN_CIDR="${ip_base}/${auto_prefix}"
                log_info "Auto-detected LAN CIDR: $LAN_CIDR"
            fi
        fi
        LAN_CIDR="${LAN_CIDR:-192.168.1.0/24}"
    fi
    log_info "Using LAN CIDR for UFW rules: $LAN_CIDR"

    # Allow common services based on what's installed
    [ "${INSTALL_COCKPIT:-false}" = "true" ] && ufw allow from "$LAN_CIDR" to any port 9090 proto tcp comment 'Cockpit (LAN only)'
    # Portainer binds to 127.0.0.1 only - no UFW rule needed
    [ "${INSTALL_SAMBA:-false}" = "true" ] && ufw allow from "$LAN_CIDR" to any app Samba comment 'Samba (LAN only)'
    [ "${INSTALL_NFS:-false}" = "true" ] && ufw allow from "$LAN_CIDR" to any port 2049 proto tcp comment 'NFS (LAN only)'
    # Prometheus and Node Exporter bind to 127.0.0.1 only - no UFW rule needed
    [ "${INSTALL_WEBMIN:-false}" = "true" ] && ufw allow from "$LAN_CIDR" to any port 10000 proto tcp comment 'Webmin (LAN only)'
    # Grafana binds to 127.0.0.1 only - no UFW rule needed
    # SigNoz binds to 127.0.0.1 only - no UFW rule needed
    # OTEL health check binds to 127.0.0.1 only - no UFW rule needed

    # Enable UFW
    echo "y" | ufw enable

    log_info "UFW firewall configured and enabled"
    ufw status verbose
}

configure_unattended_upgrades() {
    if [ "${ENABLE_AUTO_UPDATES:-false}" != "true" ]; then
        return
    fi

    log_section "Configuring Automatic Security Updates"

    apt-get install -y unattended-upgrades apt-listchanges

    # Configure unattended-upgrades
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

Unattended-Upgrade::Package-Blacklist {
};

Unattended-Upgrade::DevRelease "auto";
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF

    # Enable automatic updates
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

    systemctl enable unattended-upgrades
    systemctl start unattended-upgrades

    log_info "Automatic security updates enabled"
}

harden_ssh() {
    if [ "${HARDEN_SSH:-false}" != "true" ]; then
        return
    fi

    log_section "Hardening SSH Configuration"

    # Backup original config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

    # Check if SSH keys are configured before disabling password authentication
    INSTALL_USERNAME="${INSTALL_USERNAME:-admin}"
    USER_HOME=$(getent passwd "$INSTALL_USERNAME" | cut -d: -f6)
    [ -z "$USER_HOME" ] && USER_HOME="/home/$INSTALL_USERNAME"

    local disable_password="no"
    if [ -s "$USER_HOME/.ssh/authorized_keys" ]; then
        disable_password="yes"
        log_info "SSH authorized keys found - disabling password authentication"
    elif [ -n "${SSH_AUTHORIZED_KEYS:-}" ]; then
        disable_password="yes"
        log_info "SSH_AUTHORIZED_KEYS configured - disabling password authentication"
    else
        log_warn "No SSH keys configured - keeping password authentication enabled to prevent lockout"
        log_warn "Run 'ssh-copy-id' to add keys, then set PasswordAuthentication to 'no' in /etc/ssh/sshd_config.d/99-hardening.conf"
    fi

    local password_auth="yes"
    if [ "$disable_password" = "yes" ]; then
        password_auth="no"
    fi

    # Remove the base SSH config drop-in to prevent first-match conflicts
    # (50-ubuntu-installer.conf sets ClientAliveInterval=60 which would override ours)
    rm -f /etc/ssh/sshd_config.d/50-ubuntu-installer.conf

    # Create hardened SSH config
    cat > /etc/ssh/sshd_config.d/99-hardening.conf << EOF
# SSH Hardening Configuration
PermitRootLogin no
MaxAuthTries 3
MaxSessions 5
PubkeyAuthentication yes
PasswordAuthentication $password_auth
PermitEmptyPasswords no
KbdInteractiveAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 60
EOF

    # Restart SSH (Ubuntu uses 'ssh', some distros use 'sshd')
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

    log_info "SSH hardening applied (PasswordAuthentication=$password_auth)"
}

# ============================================================================
# FILE SHARING
# ============================================================================

install_samba() {
    if [ "${INSTALL_SAMBA:-false}" != "true" ]; then
        return
    fi

    log_section "Installing Samba File Sharing"

    apt-get install -y samba samba-common-bin

    # Backup original config
    cp /etc/samba/smb.conf /etc/samba/smb.conf.backup

    # Create default share directory (validate path is safe)
    SHARE_DIR="${SAMBA_SHARE_PATH:-/srv/samba/share}"
    SHARE_DIR=$(realpath -m "$SHARE_DIR" 2>/dev/null || echo "$SHARE_DIR")
    case "$SHARE_DIR" in
        /|/etc|/etc/*|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/boot|/boot/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/var/run|/var/run/*|/run|/run/*|/root|/root/*|/tmp|/tmp/*|/lib|/lib/*|/lib64|/lib64/*|/opt/ubuntu-installer|/opt/ubuntu-installer/*)
            log_error "Refusing to share system directory: $SHARE_DIR"
            track_error
            return
            ;;
    esac
    INSTALL_USERNAME="${INSTALL_USERNAME:-admin}"
    mkdir -p "$SHARE_DIR"
    chmod 775 "$SHARE_DIR"
    chown "$INSTALL_USERNAME:$INSTALL_USERNAME" "$SHARE_DIR" 2>/dev/null || true

    # Configure Samba
    cat > /etc/samba/smb.conf << EOF
[global]
   workgroup = WORKGROUP
   server string = Ubuntu Home Lab Server
   security = user
   dns proxy = no

   # Security
   server min protocol = SMB3
   server signing = mandatory

   # Performance tuning
   read raw = yes
   write raw = yes
   max xmit = 65535
   dead time = 15

[share]
   comment = Shared Files
   path = $SHARE_DIR
   browseable = yes
   read only = no
   guest ok = no
   create mask = 0664
   directory mask = 0775
EOF

    # Samba user setup - password must be set manually for security
    # (INSTALL_PASSWORD is never written to config.env to avoid plaintext credential exposure)
    INSTALL_USERNAME="${INSTALL_USERNAME:-admin}"
    log_info "Samba installed. Set the Samba password with: sudo smbpasswd -a $INSTALL_USERNAME"

    systemctl enable smbd nmbd
    systemctl restart smbd nmbd

    log_info "Samba installed - Share at \\\\<ip>\\share"
}

install_nfs() {
    if [ "${INSTALL_NFS:-false}" != "true" ]; then
        return
    fi

    log_section "Installing NFS Server"

    apt-get install -y nfs-kernel-server

    # Create default export directory (770 = owner+group only, no world access)
    EXPORT_DIR="${NFS_EXPORT_PATH:-/srv/nfs/share}"
    EXPORT_DIR=$(realpath -m "$EXPORT_DIR" 2>/dev/null || echo "$EXPORT_DIR")
    case "$EXPORT_DIR" in
        /|/etc|/etc/*|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/boot|/boot/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/var/run|/var/run/*|/run|/run/*|/root|/root/*|/tmp|/tmp/*|/lib|/lib/*|/lib64|/lib64/*|/opt/ubuntu-installer|/opt/ubuntu-installer/*)
            log_error "Refusing to export system directory: $EXPORT_DIR"
            track_error
            return
            ;;
    esac
    INSTALL_USERNAME="${INSTALL_USERNAME:-admin}"
    mkdir -p "$EXPORT_DIR"
    chmod 770 "$EXPORT_DIR"
    chown "$INSTALL_USERNAME:$INSTALL_USERNAME" "$EXPORT_DIR" 2>/dev/null || true

    # Configure exports (root_squash for security)
    NFS_NETWORK="${NFS_ALLOWED_NETWORK:-192.168.1.0/24}"
    # Validate NFS network value (must be CIDR notation)
    if ! echo "$NFS_NETWORK" | grep -qP '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$'; then
        log_error "NFS_ALLOWED_NETWORK value '$NFS_NETWORK' is not valid CIDR notation - skipping NFS export"
        track_error
        return
    fi
    grep -q "^$EXPORT_DIR " /etc/exports 2>/dev/null || echo "$EXPORT_DIR $NFS_NETWORK(rw,sync,no_subtree_check,root_squash)" >> /etc/exports

    # Export shares
    exportfs -ra

    systemctl enable nfs-kernel-server
    systemctl restart nfs-kernel-server

    log_info "NFS server installed - Export: $EXPORT_DIR"
    log_info "Mount with: mount <ip>:$EXPORT_DIR /mnt/nfs"
}

# ============================================================================
# MONITORING
# ============================================================================

install_prometheus() {
    if [ "${INSTALL_PROMETHEUS:-false}" != "true" ]; then
        return
    fi

    # Detect port 9090 conflict with Cockpit
    if [ "${INSTALL_COCKPIT:-false}" = "true" ] || systemctl is-active cockpit.socket &>/dev/null 2>&1; then
        log_warn "Cockpit is also configured on port 9090. Prometheus will bind to 127.0.0.1:9090 to avoid conflict."
        log_warn "If both need remote access, reconfigure one to a different port."
    fi

    log_section "Installing Prometheus"

    # Create prometheus user
    useradd --no-create-home --shell /bin/false prometheus || true

    # Download and install (with checksum verification)
    PROM_VERSION="2.48.0"
    wget -q -P /tmp "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-amd64.tar.gz"
    wget -q "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/sha256sums.txt" -O "/tmp/prometheus-sha256sums.txt" 2>/dev/null || true
    if [ -f "/tmp/prometheus-sha256sums.txt" ]; then
        if ! verify_checksum "/tmp/prometheus-${PROM_VERSION}.linux-amd64.tar.gz" "/tmp/prometheus-sha256sums.txt"; then
            log_error "Prometheus download integrity check failed - skipping installation"
            track_error
            rm -f "/tmp/prometheus-${PROM_VERSION}.linux-amd64.tar.gz" "/tmp/prometheus-sha256sums.txt"
            return
        fi
        rm -f "/tmp/prometheus-sha256sums.txt"
    else
        log_warn "Prometheus checksums not available - proceeding without verification"
    fi
    tar xzf "/tmp/prometheus-${PROM_VERSION}.linux-amd64.tar.gz" -C /tmp

    cp "/tmp/prometheus-${PROM_VERSION}.linux-amd64/prometheus" /usr/local/bin/
    cp "/tmp/prometheus-${PROM_VERSION}.linux-amd64/promtool" /usr/local/bin/
    chown root:root /usr/local/bin/prometheus /usr/local/bin/promtool
    chmod 755 /usr/local/bin/prometheus /usr/local/bin/promtool

    mkdir -p /etc/prometheus /var/lib/prometheus
    cp -r "/tmp/prometheus-${PROM_VERSION}.linux-amd64/consoles" /etc/prometheus/
    cp -r "/tmp/prometheus-${PROM_VERSION}.linux-amd64/console_libraries" /etc/prometheus/

    # Create config
    cat > /etc/prometheus/prometheus.yml << 'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node'
    static_configs:
      - targets: ['localhost:9100']
EOF

    chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus

    # Create systemd service (bound to localhost for security - use reverse proxy for remote access)
    cat > /etc/systemd/system/prometheus.service << 'EOF'
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \
    --config.file=/etc/prometheus/prometheus.yml \
    --storage.tsdb.path=/var/lib/prometheus/ \
    --storage.tsdb.retention.time=7d \
    --storage.tsdb.retention.size=1GB \
    --web.console.templates=/etc/prometheus/consoles \
    --web.console.libraries=/etc/prometheus/console_libraries \
    --web.listen-address=127.0.0.1:9090
MemoryMax=512M
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable prometheus
    systemctl start prometheus

    rm -rf /tmp/prometheus-*

    log_info "Prometheus installed - Listening on 127.0.0.1:9090 (use reverse proxy for remote access)"
}

install_node_exporter() {
    if [ "${INSTALL_NODE_EXPORTER:-false}" != "true" ]; then
        return
    fi

    log_section "Installing Node Exporter"

    # Create user
    useradd --no-create-home --shell /bin/false node_exporter || true

    # Download and install (with checksum verification)
    NE_VERSION="1.7.0"
    wget -q -P /tmp "https://github.com/prometheus/node_exporter/releases/download/v${NE_VERSION}/node_exporter-${NE_VERSION}.linux-amd64.tar.gz"
    wget -q "https://github.com/prometheus/node_exporter/releases/download/v${NE_VERSION}/sha256sums.txt" -O "/tmp/node_exporter-sha256sums.txt" 2>/dev/null || true
    if [ -f "/tmp/node_exporter-sha256sums.txt" ]; then
        if ! verify_checksum "/tmp/node_exporter-${NE_VERSION}.linux-amd64.tar.gz" "/tmp/node_exporter-sha256sums.txt"; then
            log_error "Node Exporter download integrity check failed - skipping installation"
            track_error
            rm -f "/tmp/node_exporter-${NE_VERSION}.linux-amd64.tar.gz" "/tmp/node_exporter-sha256sums.txt"
            return
        fi
        rm -f "/tmp/node_exporter-sha256sums.txt"
    else
        log_warn "Node Exporter checksums not available - proceeding without verification"
    fi
    tar xzf "/tmp/node_exporter-${NE_VERSION}.linux-amd64.tar.gz" -C /tmp

    cp "/tmp/node_exporter-${NE_VERSION}.linux-amd64/node_exporter" /usr/local/bin/
    chown root:root /usr/local/bin/node_exporter
    chmod 755 /usr/local/bin/node_exporter

    # Create systemd service (bound to localhost for security - use reverse proxy for remote access)
    cat > /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter --web.listen-address=127.0.0.1:9100
Restart=on-failure
RestartSec=5
MemoryMax=128M

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable node_exporter
    systemctl start node_exporter

    rm -rf /tmp/node_exporter-*

    log_info "Node Exporter installed - Metrics at http://127.0.0.1:9100/metrics (localhost only)"
}

install_grafana() {
    if [ "${INSTALL_GRAFANA:-false}" != "true" ]; then
        return
    fi

    log_section "Installing Grafana"

    apt-get install -y apt-transport-https software-properties-common

    # Add Grafana repository
    wget -q -O /usr/share/keyrings/grafana.key https://apt.grafana.com/gpg.key
    echo "deb [signed-by=/usr/share/keyrings/grafana.key] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list

    apt-get update
    apt-get install -y grafana

    # Generate random admin password instead of using default admin/admin
    local grafana_pass
    grafana_pass=$(openssl rand -base64 24 | tr -d '/+=' | head -c 20)
    if [ ${#grafana_pass} -lt 12 ]; then
        log_warn "Failed to generate a strong Grafana admin password (got ${#grafana_pass} chars)"
        grafana_pass=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 20)
        if [ ${#grafana_pass} -lt 12 ]; then
            log_error "Grafana admin password generation failed twice - skipping password randomization"
            track_error
            return
        fi
    fi
    cat > /etc/grafana/grafana-admin-password << EOF
$grafana_pass
EOF
    chmod 600 /etc/grafana/grafana-admin-password
    chown root:root /etc/grafana/grafana-admin-password

    # Set the admin password via Grafana environment override
    # Use EnvironmentFile instead of inline Environment to prevent exposure via systemctl show
    mkdir -p /etc/systemd/system/grafana-server.service.d
    cat > /etc/grafana/grafana-admin-env << EOF
GF_SECURITY_ADMIN_PASSWORD=$grafana_pass
GF_SERVER_HTTP_ADDR=127.0.0.1
EOF
    chmod 600 /etc/grafana/grafana-admin-env
    chown root:root /etc/grafana/grafana-admin-env
    cat > /etc/systemd/system/grafana-server.service.d/admin-password.conf << 'EOF'
[Service]
EnvironmentFile=/etc/grafana/grafana-admin-env
EOF
    chmod 644 /etc/systemd/system/grafana-server.service.d/admin-password.conf

    systemctl daemon-reload
    systemctl enable grafana-server
    systemctl start grafana-server

    # Set admin password via grafana-cli (more secure than EnvironmentFile which leaks to /proc/pid/environ)
    local grafana_cli_ok=false
    sleep 3
    if command -v grafana-cli &>/dev/null; then
        if grafana-cli admin reset-admin-password "$grafana_pass" 2>/dev/null; then
            log_info "Grafana admin password set via grafana-cli"
            grafana_cli_ok=true
            # Remove credential files now that password is set in Grafana DB directly
            rm -f /etc/grafana/grafana-admin-env
            rm -f /etc/grafana/grafana-admin-password
            rm -f /etc/systemd/system/grafana-server.service.d/admin-password.conf
            # Keep only the HTTP bind address override
            mkdir -p /etc/systemd/system/grafana-server.service.d
            cat > /etc/systemd/system/grafana-server.service.d/bind-localhost.conf << 'EOF'
[Service]
Environment=GF_SERVER_HTTP_ADDR=127.0.0.1
EOF
            systemctl daemon-reload
            systemctl restart grafana-server
        else
            log_warn "grafana-cli password set failed (will use EnvironmentFile fallback)"
        fi
    fi

    log_info "Grafana installed - Listening on 127.0.0.1:3000 (use reverse proxy for remote access)"
    if [ "$grafana_cli_ok" = true ]; then
        log_info "Grafana admin password set in DB (credential files removed)"
    else
        log_info "Grafana admin password saved to /etc/grafana/grafana-admin-password (root-only)"
    fi
}

# ============================================================================
# OBSERVABILITY & TELEMETRY
# ============================================================================

install_signoz() {
    if [ "${INSTALL_SIGNOZ:-false}" != "true" ]; then
        return
    fi

    if ! command -v docker &> /dev/null; then
        log_warn "Docker not installed, skipping SigNoz"
        track_error
        return
    fi

    log_section "Installing SigNoz"

    # Create directory for SigNoz and run in subshell to avoid changing cwd
    mkdir -p /opt/signoz

    # Download docker-compose file
    curl -fsSL https://github.com/SigNoz/signoz/releases/latest/download/docker-compose.yaml -o /opt/signoz/docker-compose.yaml

    if [ ! -s /opt/signoz/docker-compose.yaml ]; then
        log_error "SigNoz docker-compose download failed or is empty - skipping"
        track_error
        return
    fi

    # Bind SigNoz frontend to localhost only for security (use reverse proxy for remote access)
    # Check idempotently: only modify if not already bound to localhost
    if grep -q '127.0.0.1:3301:3301' /opt/signoz/docker-compose.yaml; then
        log_info "SigNoz already bound to localhost"
    elif grep -q '3301:3301' /opt/signoz/docker-compose.yaml; then
        sed -i 's/3301:3301/127.0.0.1:3301:3301/' /opt/signoz/docker-compose.yaml
    else
        log_warn "Could not find port 3301 mapping in SigNoz docker-compose.yaml - SigNoz may be exposed on all interfaces"
    fi

    # Start SigNoz
    docker compose -f /opt/signoz/docker-compose.yaml up -d

    log_info "SigNoz installed - Listening on 127.0.0.1:3301 (use reverse proxy for remote access)"
    log_warn "SECURITY: Change SigNoz default credentials on first login"
}

install_otel_collector() {
    if [ "${INSTALL_OTEL_COLLECTOR:-false}" != "true" ]; then
        return
    fi

    log_section "Installing OpenTelemetry Collector"

    OTEL_ENDPOINT="${OTEL_ENDPOINT:-signoz-internal.jeremy.ninja:4317}"

    # Validate endpoint format (host:port required) to prevent YAML injection
    if ! echo "$OTEL_ENDPOINT" | grep -qP '^[a-zA-Z0-9][a-zA-Z0-9._-]*:[0-9]{1,5}$'; then
        log_error "Invalid OTEL_ENDPOINT format: $OTEL_ENDPOINT (expected host:port, e.g., signoz.example.com:4317)"
        track_error
        return
    fi

    # Download and install OpenTelemetry Collector (with size verification)
    OTEL_VERSION="0.92.0"
    wget -q -P /tmp "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/otelcol-contrib_${OTEL_VERSION}_linux_amd64.deb"
    # Verify download is non-empty (OTEL does not publish separate checksum files)
    if [ ! -s "/tmp/otelcol-contrib_${OTEL_VERSION}_linux_amd64.deb" ]; then
        log_error "OTEL Collector download failed or is empty - skipping installation"
        track_error
        rm -f "/tmp/otelcol-contrib_${OTEL_VERSION}_linux_amd64.deb"
        return
    fi
    dpkg -i "/tmp/otelcol-contrib_${OTEL_VERSION}_linux_amd64.deb" || true
    apt-get install -f -y || true

    # Create configuration directory
    mkdir -p /etc/otelcol-contrib

    # Create configuration file for host metrics and logs
    cat > /etc/otelcol-contrib/config.yaml << EOF
receivers:
  hostmetrics:
    collection_interval: 30s
    scrapers:
      cpu:
        metrics:
          system.cpu.utilization:
            enabled: true
      memory:
        metrics:
          system.memory.utilization:
            enabled: true
      disk:
        metrics:
          system.disk.io:
            enabled: true
          system.disk.operations:
            enabled: true
          system.disk.io_time:
            enabled: true
          system.disk.pending_operations:
            enabled: true
      filesystem:
        metrics:
          system.filesystem.utilization:
            enabled: true
      load:
      network:
      processes:
        metrics:
          system.processes.count:
            enabled: true
          system.processes.created:
            enabled: true
      process:
        include:
          match_type: strict
          names: ["dockerd", "containerd", "node_exporter", "prometheus", "grafana-server", "sshd", "nginx", "apache2"]
        metrics:
          process.cpu.utilization:
            enabled: true
          process.memory.utilization:
            enabled: true
          process.disk.io:
            enabled: true

  # System logs from journald
  journald:
    directory: /var/log/journal
    units:
      - ssh
      - docker
      - systemd
      - cron
    priority: info

  # File-based logs from /var/log
  # NOTE: auth.log excluded to prevent leaking authentication data to remote endpoint
  filelog:
    include:
      - /var/log/*.log
      - /var/log/syslog
      - /var/log/kern.log
      - /var/log/apt/*.log
    exclude:
      - /var/log/lastlog
      - /var/log/auth.log
      - /var/log/btmp
      - /var/log/wtmp
    start_at: end
    include_file_path: true
    include_file_name: true
    operators:
      - type: regex_parser
        if: body matches "^(?P<timestamp>\\\\w{3}\\\\s+\\\\d{1,2}\\\\s+\\\\d{2}:\\\\d{2}:\\\\d{2})\\\\s+(?P<hostname>\\\\S+)\\\\s+(?P<program>[^\\\\[]+)(\\\\[(?P<pid>\\\\d+)\\\\])?:\\\\s*(?P<message>.*)\$"
        regex: "^(?P<timestamp>\\\\w{3}\\\\s+\\\\d{1,2}\\\\s+\\\\d{2}:\\\\d{2}:\\\\d{2})\\\\s+(?P<hostname>\\\\S+)\\\\s+(?P<program>[^\\\\[]+)(\\\\[(?P<pid>\\\\d+)\\\\])?:\\\\s*(?P<message>.*)\$"
        on_error: send
      - type: move
        from: attributes.message
        to: body
        if: attributes.message != nil

processors:
  batch:
    timeout: 10s
    send_batch_size: 1000
  resourcedetection:
    detectors: [env, system]
    timeout: 5s
    override: false
  resource:
    attributes:
      - key: host.name
        from_attribute: host.name
        action: upsert
  attributes/logs:
    actions:
      - key: source
        value: "opentelemetry-collector"
        action: upsert

exporters:
  otlp:
    endpoint: "${OTEL_ENDPOINT}"
    tls:
      insecure: false
    headers:
      signoz-access-token: ""
  logging:
    verbosity: normal

extensions:
  health_check:
    endpoint: 127.0.0.1:13133
  zpages:
    endpoint: 127.0.0.1:55679

service:
  extensions: [health_check, zpages]
  pipelines:
    metrics:
      receivers: [hostmetrics]
      processors: [resourcedetection, resource, batch]
      exporters: [otlp, logging]
    logs:
      receivers: [filelog, journald]
      processors: [resourcedetection, resource, attributes/logs, batch]
      exporters: [otlp, logging]
EOF
    chmod 640 /etc/otelcol-contrib/config.yaml
    chown root:otelcol-contrib /etc/otelcol-contrib/config.yaml 2>/dev/null || chmod 600 /etc/otelcol-contrib/config.yaml

    # Create systemd override for custom config
    mkdir -p /etc/systemd/system/otelcol-contrib.service.d
    cat > /etc/systemd/system/otelcol-contrib.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/otelcol-contrib --config=/etc/otelcol-contrib/config.yaml
EOF

    # Reload and start service
    systemctl daemon-reload
    systemctl enable otelcol-contrib
    systemctl restart otelcol-contrib

    rm -f /tmp/otelcol-contrib_*.deb

    log_info "OpenTelemetry Collector installed"
    log_info "Sending telemetry to: ${OTEL_ENDPOINT}"
    log_info "Metrics collected: CPU, Memory, Disk, Filesystem, Network, Processes"
    log_info "Logs collected: /var/log/*.log (excl. auth.log), syslog, kern.log, journald"
}

# ============================================================================
# SYSTEM CONFIGURATION
# ============================================================================

install_ansible() {
    if [ "${INSTALL_ANSIBLE:-false}" != "true" ]; then
        return
    fi

    log_section "Installing Ansible"

    apt-get install -y software-properties-common
    add-apt-repository -y --update ppa:ansible/ansible
    apt-get install -y ansible

    log_info "Ansible installed successfully"
    ansible --version | head -1
}

configure_swap() {
    if [ "${CONFIGURE_SWAP:-false}" != "true" ]; then
        return
    fi

    log_section "Configuring Swap"

    SWAP_SIZE="${SWAP_SIZE_GB:-4}"

    # Validate swap size is a positive integer
    if ! echo "$SWAP_SIZE" | grep -qP '^\d+$' || [ "$SWAP_SIZE" -lt 1 ] || [ "$SWAP_SIZE" -gt 64 ]; then
        log_error "Invalid SWAP_SIZE_GB: $SWAP_SIZE (must be integer 1-64)"
        track_error
        return
    fi

    # Check if swap already exists
    if swapon --show | grep -q "/swapfile"; then
        log_info "Swap already configured"
        return
    fi

    # Create swap file (use dd for btrfs compatibility; fallocate creates sparse files on btrfs)
    if findmnt -n -o FSTYPE / | grep -q btrfs; then
        dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_SIZE * 1024)) status=progress
    else
        fallocate -l "${SWAP_SIZE}G" /swapfile
    fi
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    # Add to fstab
    if ! grep -q "/swapfile" /etc/fstab; then
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi

    # Configure swappiness (use drop-in file instead of appending to sysctl.conf)
    echo "vm.swappiness=10" > /etc/sysctl.d/99-swap.conf
    sysctl -w vm.swappiness=10

    log_info "Swap configured: ${SWAP_SIZE}GB"
}

configure_zram() {
    if [ "${CONFIGURE_ZRAM:-false}" != "true" ]; then
        return
    fi

    log_section "Configuring Zram Swap"

    # Detect total system RAM in GB
    local total_ram_kb
    total_ram_kb=$(LANG=C grep -i '^MemTotal:' /proc/meminfo | awk '{print $2}')
    local total_ram_gb=$(( total_ram_kb / 1024 / 1024 ))

    local zram_size="${ZRAM_SIZE_GB:-auto}"

    if [ "$zram_size" = "auto" ]; then
        # Skip on systems with less than 16GB RAM
        if [ "$total_ram_gb" -lt 16 ]; then
            log_info "System has ${total_ram_gb}GB RAM (< 16GB), skipping zram"
            return
        fi

        # Auto-detect size based on total RAM
        zram_size=4
        log_info "Auto-detected zram size: ${zram_size}GB for ${total_ram_gb}GB RAM"
    else
        # Validate manual size is a positive integer
        if ! echo "$zram_size" | grep -qP '^\d+$' || [ "$zram_size" -lt 1 ] || [ "$zram_size" -gt 32 ]; then
            log_error "Invalid ZRAM_SIZE_GB: $zram_size (must be integer 1-32 or 'auto')"
            track_error
            return
        fi
    fi

    # Check if zram swap is already active
    if swapon --show | grep -q "zram"; then
        log_info "Zram swap already configured"
        return
    fi

    # Disable Ubuntu's default zram-config if present (we manage our own)
    if systemctl is-active --quiet zram-config 2>/dev/null; then
        systemctl stop zram-config
        systemctl disable zram-config
        log_info "Disabled default zram-config service"
    fi

    # Load zram module
    if ! modprobe zram num_devices=1; then
        log_error "Failed to load zram kernel module"
        track_error
        return
    fi

    # Configure zram0 device
    echo "zstd" > /sys/block/zram0/comp_algorithm 2>/dev/null || \
        echo "lz4" > /sys/block/zram0/comp_algorithm 2>/dev/null || \
        log_info "Using default zram compression algorithm"
    echo "${zram_size}G" > /sys/block/zram0/disksize

    # Format and enable as swap (priority 100 so zram is used before disk swap)
    mkswap /dev/zram0
    swapon -p 100 /dev/zram0

    # Persist across reboots via systemd service
    cat > /etc/systemd/system/zram-swap.service << EOF
[Unit]
Description=Configure zram swap device
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'modprobe zram num_devices=1 && echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null || echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null; echo ${zram_size}G > /sys/block/zram0/disksize && mkswap /dev/zram0 && swapon -p 100 /dev/zram0'
ExecStop=/bin/bash -c 'swapoff /dev/zram0 2>/dev/null; echo 1 > /sys/block/zram0/reset 2>/dev/null'

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable zram-swap.service

    log_info "Zram swap configured: ${zram_size}GB (zstd compressed, priority 100)"
}

configure_wakeonlan() {
    if [ "${ENABLE_WAKE_ON_LAN:-false}" != "true" ]; then
        return
    fi

    log_section "Configuring Wake-on-LAN"

    apt-get install -y ethtool

    # Get primary network interface (use 'dev' field from ip route for reliability)
    IFACE=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
    local WOL_MAC
    WOL_MAC=$(ip link show "$IFACE" 2>/dev/null | awk '/ether/ {print $2}')

    if [ -n "$IFACE" ]; then
        log_info "WoL interface: $IFACE (MAC: ${WOL_MAC:-unknown})"
        # Verify NIC supports WoL magic packet before enabling
        local wol_support
        wol_support=$(ethtool "$IFACE" 2>/dev/null | grep "Supports Wake-on:" | awk '{print $3}')
        if ! echo "$wol_support" | grep -q "g"; then
            log_warn "NIC $IFACE does not support Wake-on-LAN magic packet (Supports: ${wol_support:-none})"
            log_warn "Check BIOS: enable 'Wake on LAN' and disable 'Deep Sleep Control'"
            track_error
            return
        fi
        # Enable WoL
        ethtool -s "$IFACE" wol g 2>/dev/null || true

        # Make persistent with systemd
        cat > /etc/systemd/system/wol@.service << 'EOF'
[Unit]
Description=Wake-on-LAN for %i
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -s %i wol g

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable "wol@${IFACE}.service"
        systemctl start "wol@${IFACE}.service"

        log_info "Wake-on-LAN enabled on $IFACE"

        # Platform-specific BIOS reminders (WoL requires both OS + BIOS enablement)
        local sys_vendor
        sys_vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)
        local product_name
        product_name=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
        if echo "$sys_vendor" | grep -qi "HP\|Hewlett"; then
            log_info "HP BIOS: Verify Advanced -> Device Options -> S5 Wake on LAN is ENABLED"
        elif echo "$sys_vendor" | grep -qi "LENOVO"; then
            log_info "Lenovo BIOS: Verify Power -> Wake on LAN: Primary (or Both)"
        elif echo "$sys_vendor" | grep -qi "Dell"; then
            log_info "Dell BIOS: Verify System Setup -> Power Management -> Wake on LAN: LAN Only"
            log_info "Dell BIOS: Verify Deep Sleep Control is DISABLED"
        elif echo "$sys_vendor" | grep -qi "ASUSTeK"; then
            log_info "ASUS BIOS: Verify Advanced -> APM -> Power On By PCI-E/PCI is ENABLED"
        fi
    else
        log_warn "Could not detect network interface for WoL"
    fi
}

configure_rtc_wake() {
    if [ -z "${RTC_WAKE_TIME:-}" ]; then
        return
    fi

    log_section "Configuring RTC Daily Wake"

    # Validate time format (HH:MM, 24h)
    if ! echo "$RTC_WAKE_TIME" | grep -qP '^([01][0-9]|2[0-3]):[0-5][0-9]$'; then
        log_error "Invalid RTC_WAKE_TIME format: $RTC_WAKE_TIME (expected HH:MM in 24h format, e.g. 01:00)"
        track_error
        return
    fi

    # Verify rtcwake is available
    if ! command -v rtcwake &>/dev/null; then
        apt-get install -y util-linux || { track_error; return; }
    fi

    # Test that the RTC supports wake alarms
    if [ ! -f /sys/class/rtc/rtc0/wakealarm ]; then
        log_warn "RTC wake alarm not supported by hardware - skipping RTC wake configuration"
        track_error
        return
    fi

    # Create a script that sets the next wake alarm
    cat > /usr/local/bin/rtc-set-wake << 'EOFRTC'
#!/bin/bash
# Set RTC wake alarm for the next occurrence of the configured time
WAKE_TIME="$1"
if [ -z "$WAKE_TIME" ]; then
    echo "Usage: rtc-set-wake HH:MM" >&2
    exit 1
fi

# Calculate next wake epoch (today or tomorrow if time already passed)
NOW=$(date +%s)
TARGET=$(date -d "today $WAKE_TIME" +%s 2>/dev/null)
if [ -z "$TARGET" ] || [ "$TARGET" -le "$NOW" ]; then
    TARGET=$(date -d "tomorrow $WAKE_TIME" +%s 2>/dev/null)
fi

if [ -n "$TARGET" ]; then
    # Clear existing alarm and set new one
    echo 0 > /sys/class/rtc/rtc0/wakealarm 2>/dev/null
    echo "$TARGET" > /sys/class/rtc/rtc0/wakealarm 2>/dev/null
    echo "RTC wake alarm set for $(date -d @"$TARGET" '+%Y-%m-%d %H:%M')"
else
    echo "Failed to calculate wake time" >&2
    exit 1
fi
EOFRTC
    chmod 755 /usr/local/bin/rtc-set-wake

    # Create systemd service to set the wake alarm
    cat > /etc/systemd/system/rtc-wake.service << EOF
[Unit]
Description=Set RTC wake alarm for ${RTC_WAKE_TIME} daily
After=time-sync.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/rtc-set-wake ${RTC_WAKE_TIME}
EOF

    # Create systemd timer that re-arms the alarm after each wake
    cat > /etc/systemd/system/rtc-wake.timer << 'EOF'
[Unit]
Description=Re-arm RTC wake alarm daily

[Timer]
OnBootSec=1min
OnUnitActiveSec=12h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable rtc-wake.timer
    systemctl start rtc-wake.timer

    # Set the initial wake alarm now
    /usr/local/bin/rtc-set-wake "$RTC_WAKE_TIME" || true

    log_info "RTC daily wake configured for ${RTC_WAKE_TIME}"
    log_info "The system will automatically wake from suspend/poweroff at ${RTC_WAKE_TIME} every day"
}

configure_ntp() {
    if [ "${CONFIGURE_NTP:-true}" != "true" ]; then
        return
    fi

    log_section "Configuring NTP Time Sync"

    apt-get install -y chrony

    # Disable systemd-timesyncd to prevent two NTP daemons competing
    systemctl disable --now systemd-timesyncd 2>/dev/null || true

    # Back up any existing chrony config before overwriting
    if [ -f /etc/chrony/chrony.conf ]; then
        cp /etc/chrony/chrony.conf /etc/chrony/chrony.conf.bak
        log_info "Existing chrony.conf backed up to /etc/chrony/chrony.conf.bak"
    fi

    # Configure chrony
    cat > /etc/chrony/chrony.conf << 'EOF'
# Ubuntu NTP configuration
pool ntp.ubuntu.com iburst maxsources 4
pool 0.ubuntu.pool.ntp.org iburst maxsources 1
pool 1.ubuntu.pool.ntp.org iburst maxsources 1
pool 2.ubuntu.pool.ntp.org iburst maxsources 2

sourcedir /etc/chrony/sources.d

keyfile /etc/chrony/chrony.keys
driftfile /var/lib/chrony/chrony.drift
logdir /var/log/chrony
maxupdateskew 100.0
rtcsync
makestep 1 3
leapsectz right/UTC
EOF
    mkdir -p /etc/chrony/sources.d

    systemctl enable chrony
    systemctl restart chrony

    log_info "NTP time synchronization configured"
}

# ============================================================================
# UTILITIES
# ============================================================================

install_common_tools() {
    if [ "${INSTALL_COMMON_TOOLS:-false}" != "true" ]; then
        return
    fi

    log_section "Installing Common Tools"

    # Note: fastfetch not in Ubuntu 24.04 repos (available in 25.04+)
    # Note: yq from apt is Python v3; mikefarah yq v4 installed in dev_tools
    apt-get install -y \
        btop \
        ncdu \
        tree \
        jq \
        rsync \
        tmux \
        screen \
        byobu \
        mc \
        iperf3 \
        nmap \
        mtr \
        dnsutils \
        whois \
        tcpdump \
        iotop \
        sysstat \
        strace \
        lsof \
        netcat-openbsd \
        traceroute \
        bmon \
        nload

    log_info "Common tools installed"
}

install_dev_tools() {
    if [ "${INSTALL_DEV_TOOLS:-false}" != "true" ]; then
        return
    fi

    log_section "Installing Development Tools"

    INSTALL_USERNAME="${INSTALL_USERNAME:-admin}"
    USER_HOME=$(getent passwd "$INSTALL_USERNAME" | cut -d: -f6)
    [ -z "$USER_HOME" ] && USER_HOME="/home/$INSTALL_USERNAME"

    # Install build essentials and archive tools
    apt-get install -y \
        build-essential \
        git \
        git-lfs \
        curl \
        wget \
        zip \
        unzip \
        unrar-free \
        p7zip-full \
        xz-utils \
        software-properties-common

    # -------------------------------------------------------------------------
    # Python
    # -------------------------------------------------------------------------
    log_info "Installing Python..."
    apt-get install -y \
        python3 \
        python3-pip \
        python3-venv \
        python3-dev

    # Use pipx for user tools (respects PEP 668 externally-managed-environment)
    apt-get install -y pipx || true
    pipx ensurepath || true

    # -------------------------------------------------------------------------
    # Node.js (LTS via NodeSource)
    # -------------------------------------------------------------------------
    log_info "Installing Node.js LTS..."
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
    apt-get install -y nodejs

    # Install common global npm packages
    npm install -g npm@latest
    npm install -g yarn pnpm

    log_info "Node.js $(node --version) installed"

    # -------------------------------------------------------------------------
    # Go
    # -------------------------------------------------------------------------
    log_info "Installing Go..."
    GO_VERSION="${GO_VERSION:-1.22.0}"
    local go_install_ok=true
    wget -q -P /tmp "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
    # Verify Go download checksum
    local go_expected_hash
    go_expected_hash=$(wget -qO- "https://go.dev/dl/?mode=json" 2>/dev/null | grep -A5 "go${GO_VERSION}.linux-amd64.tar.gz" | grep -oP '"sha256":\s*"\K[a-f0-9]+' | head -1) || true
    if [ -n "$go_expected_hash" ]; then
        local go_actual_hash
        go_actual_hash=$(sha256sum "/tmp/go${GO_VERSION}.linux-amd64.tar.gz" | awk '{print $1}')
        if [ "$go_expected_hash" != "$go_actual_hash" ]; then
            log_error "Go download checksum mismatch - skipping Go installation"
            rm -f "/tmp/go${GO_VERSION}.linux-amd64.tar.gz"
            track_error
            go_install_ok=false
        else
            log_info "Go download checksum verified"
        fi
    else
        log_warn "Could not fetch Go checksum - proceeding without verification"
    fi
    if [ "$go_install_ok" = true ]; then
        rm -rf /usr/local/go
        tar -C /usr/local -xzf "/tmp/go${GO_VERSION}.linux-amd64.tar.gz"
        rm -f "/tmp/go${GO_VERSION}.linux-amd64.tar.gz"

        # Add Go to PATH for all users
        cat > /etc/profile.d/go.sh << 'EOF'
export PATH=$PATH:/usr/local/go/bin
export GOPATH=$HOME/go
export PATH=$PATH:$GOPATH/bin
EOF

        # Also add for the install user's bashrc
        if ! grep -q "/usr/local/go/bin" "$USER_HOME/.bashrc" 2>/dev/null; then
            echo 'export PATH=$PATH:/usr/local/go/bin' >> "$USER_HOME/.bashrc"
            echo 'export GOPATH=$HOME/go' >> "$USER_HOME/.bashrc"
            echo 'export PATH=$PATH:$GOPATH/bin' >> "$USER_HOME/.bashrc"
        fi

        log_info "Go $GO_VERSION installed"
    fi

    # -------------------------------------------------------------------------
    # .NET SDK
    # -------------------------------------------------------------------------
    log_info "Installing .NET SDK..."

    # Add Microsoft repository
    wget -q https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb
    dpkg -i /tmp/packages-microsoft-prod.deb
    rm -f /tmp/packages-microsoft-prod.deb

    apt-get update
    apt-get install -y dotnet-sdk-8.0

    log_info ".NET SDK $(dotnet --version) installed"

    # -------------------------------------------------------------------------
    # Rust
    # -------------------------------------------------------------------------
    log_info "Installing Rust..."
    if ! su - "$INSTALL_USERNAME" -c "command -v rustc" &>/dev/null; then
        su - "$INSTALL_USERNAME" -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'
        log_info "Rust installed for $INSTALL_USERNAME"
    else
        log_info "Rust already installed"
    fi

    # -------------------------------------------------------------------------
    # Java (OpenJDK)
    # -------------------------------------------------------------------------
    log_info "Installing Java (OpenJDK)..."
    apt-get install -y openjdk-21-jdk openjdk-21-source

    # Set JAVA_HOME
    cat > /etc/profile.d/java.sh << 'EOF'
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
export PATH=$PATH:$JAVA_HOME/bin
EOF
    log_info "Java $(java --version 2>&1 | head -1) installed"

    # -------------------------------------------------------------------------
    # Modern CLI Tools (Rust-based replacements)
    # -------------------------------------------------------------------------
    log_info "Installing modern CLI tools..."
    apt-get install -y \
        ripgrep \
        fd-find \
        bat \
        fzf \
        zoxide \
        hyperfine \
        tokei

    # Create symlinks for common names
    ln -sf /usr/bin/batcat /usr/local/bin/bat 2>/dev/null || true
    ln -sf /usr/bin/fdfind /usr/local/bin/fd 2>/dev/null || true

    # Install eza (modern ls replacement) - newer than exa
    if ! command -v eza &> /dev/null; then
        apt-get install -y gpg
        mkdir -p /etc/apt/keyrings
        if wget -qO- https://raw.githubusercontent.com/eza-community/eza/main/deb.asc | gpg --dearmor -o /etc/apt/keyrings/gierens.gpg; then
            echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] https://deb.gierens.de stable main" > /etc/apt/sources.list.d/gierens.list
            apt-get update
            apt-get install -y eza || log_warn "eza installation failed"
        else
            log_warn "eza GPG key download failed"
            track_error
        fi
    fi

    # Install delta (better git diff)
    if ! command -v delta &> /dev/null; then
        DELTA_VERSION="0.16.5"
        wget -q "https://github.com/dandavison/delta/releases/download/${DELTA_VERSION}/git-delta_${DELTA_VERSION}_amd64.deb" -O /tmp/delta.deb
        dpkg -i /tmp/delta.deb || apt-get install -f -y
        rm -f /tmp/delta.deb
    fi

    # -------------------------------------------------------------------------
    # Shell Enhancements
    # -------------------------------------------------------------------------
    log_info "Installing shell enhancements..."
    apt-get install -y zsh

    # Install Starship prompt
    if ! command -v starship &> /dev/null; then
        curl -fsSL https://starship.rs/install.sh | sh -s -- -y
    fi

    # Add starship to bashrc if not present
    if ! grep -q "starship init bash" "$USER_HOME/.bashrc" 2>/dev/null; then
        echo 'eval "$(starship init bash)"' >> "$USER_HOME/.bashrc"
    fi

    # Install direnv
    apt-get install -y direnv
    if ! grep -q "direnv hook bash" "$USER_HOME/.bashrc" 2>/dev/null; then
        echo 'eval "$(direnv hook bash)"' >> "$USER_HOME/.bashrc"
    fi

    # -------------------------------------------------------------------------
    # Git Tools
    # -------------------------------------------------------------------------
    log_info "Installing Git tools..."

    # GitHub CLI
    if ! command -v gh &> /dev/null; then
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
        chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
        apt-get update
        apt-get install -y gh
    fi

    # Lazygit (TUI for git)
    if ! command -v lazygit &> /dev/null; then
        LAZYGIT_VERSION=$(github_latest_tag "jesseduffield/lazygit")
        if [ -z "$LAZYGIT_VERSION" ]; then
            log_warn "Could not determine lazygit version - skipping"
        else
        curl -fLo /tmp/lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz"
        tar xf /tmp/lazygit.tar.gz -C /usr/local/bin lazygit
        rm -f /tmp/lazygit.tar.gz
        fi
    fi

    # Configure git to use delta
    git config --system core.pager "delta"
    git config --system interactive.diffFilter "delta --color-only"
    git config --system delta.navigate true
    git config --system delta.light false
    git config --system merge.conflictstyle diff3
    git config --system diff.colorMoved default

    # -------------------------------------------------------------------------
    # Kubernetes Tools
    # -------------------------------------------------------------------------
    log_info "Installing Kubernetes tools..."

    # kubectl
    if ! command -v kubectl &> /dev/null; then
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
        apt-get update
        apt-get install -y kubectl
    fi

    # Helm
    if ! command -v helm &> /dev/null; then
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi

    # k9s (TUI for Kubernetes)
    if ! command -v k9s &> /dev/null; then
        K9S_VERSION=$(github_latest_tag "derailed/k9s")
        if [ -z "$K9S_VERSION" ]; then
            log_warn "Could not determine k9s version - skipping"
        else
            curl -fLo /tmp/k9s.tar.gz "https://github.com/derailed/k9s/releases/download/v${K9S_VERSION}/k9s_Linux_amd64.tar.gz"
            tar xf /tmp/k9s.tar.gz -C /usr/local/bin k9s
            rm -f /tmp/k9s.tar.gz
        fi
    fi

    # kubectx and kubens (pinned to specific version for reproducibility)
    if ! command -v kubectx &> /dev/null; then
        git clone --depth=1 --branch v0.9.5 https://github.com/ahmetb/kubectx /opt/kubectx
        ln -sf /opt/kubectx/kubectx /usr/local/bin/kubectx
        ln -sf /opt/kubectx/kubens /usr/local/bin/kubens
    fi

    # -------------------------------------------------------------------------
    # Cloud CLIs
    # -------------------------------------------------------------------------
    log_info "Installing Cloud CLIs..."

    # AWS CLI v2
    if ! command -v aws &> /dev/null; then
        curl -fSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
        unzip -q /tmp/awscliv2.zip -d /tmp
        /tmp/aws/install
        rm -rf /tmp/aws /tmp/awscliv2.zip
    fi

    # Azure CLI
    if ! command -v az &> /dev/null; then
        curl -fsSL https://aka.ms/InstallAzureCLIDeb | bash
    fi

    # Google Cloud SDK
    if ! command -v gcloud &> /dev/null; then
        echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" > /etc/apt/sources.list.d/google-cloud-sdk.list
        curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
        apt-get update
        apt-get install -y google-cloud-cli
    fi

    # -------------------------------------------------------------------------
    # Infrastructure as Code
    # -------------------------------------------------------------------------
    log_info "Installing IaC tools..."

    # Terraform
    if ! command -v terraform &> /dev/null; then
        if wget -qO- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg; then
            echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" > /etc/apt/sources.list.d/hashicorp.list
            apt-get update
            apt-get install -y terraform
        else
            log_warn "HashiCorp GPG key download failed"
            track_error
        fi
    fi

    # Pulumi
    if ! command -v pulumi &> /dev/null; then
        export PULUMI_HOME="/opt/pulumi" && curl -fsSL https://get.pulumi.com | sh
        ln -sf /opt/pulumi/bin/pulumi /usr/local/bin/pulumi 2>/dev/null || true
    fi

    # -------------------------------------------------------------------------
    # Database Clients
    # -------------------------------------------------------------------------
    log_info "Installing database clients..."
    apt-get install -y \
        postgresql-client \
        default-mysql-client \
        redis-tools \
        sqlite3

    # MongoDB shell (mongosh)
    if ! command -v mongosh &> /dev/null; then
        if wget -qO- https://www.mongodb.org/static/pgp/server-7.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg; then
            echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu $(lsb_release -cs)/mongodb-org/7.0 multiverse" > /etc/apt/sources.list.d/mongodb-org-7.0.list
            apt-get update
            apt-get install -y mongodb-mongosh || log_warn "mongosh installation failed"
        else
            log_warn "MongoDB GPG key download failed"
            track_error
        fi
    fi

    # -------------------------------------------------------------------------
    # HTTP/API Tools
    # -------------------------------------------------------------------------
    log_info "Installing HTTP/API tools..."
    apt-get install -y httpie

    # Install xh (modern HTTPie alternative written in Rust)
    if ! command -v xh &> /dev/null; then
        su - "$INSTALL_USERNAME" -c 'source "$HOME/.cargo/env" && cargo install xh' 2>/dev/null || log_warn "xh installation failed (requires Rust)"
    fi

    # grpcurl
    if ! command -v grpcurl &> /dev/null; then
        GRPCURL_VERSION=$(github_latest_tag "fullstorydev/grpcurl")
        if [ -z "$GRPCURL_VERSION" ]; then
            log_warn "Could not determine grpcurl version - skipping"
        else
            curl -fLo /tmp/grpcurl.tar.gz "https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_linux_x86_64.tar.gz"
            tar xf /tmp/grpcurl.tar.gz -C /usr/local/bin grpcurl
            rm -f /tmp/grpcurl.tar.gz
        fi
    fi

    # -------------------------------------------------------------------------
    # Build & Task Tools
    # -------------------------------------------------------------------------
    log_info "Installing build tools..."
    apt-get install -y \
        cmake \
        ninja-build \
        meson \
        autoconf \
        automake \
        libtool \
        pkg-config

    # Just (command runner like make but better)
    if ! command -v just &> /dev/null; then
        su - "$INSTALL_USERNAME" -c 'source "$HOME/.cargo/env" && cargo install just' 2>/dev/null || log_warn "just installation failed (requires Rust)"
    fi

    # Task (Taskfile runner)
    if ! command -v task &> /dev/null; then
        sh -c "$(curl -fsSL https://taskfile.dev/install.sh)" -- -d -b /usr/local/bin
    fi

    # -------------------------------------------------------------------------
    # Editors
    # -------------------------------------------------------------------------
    log_info "Installing editors..."
    apt-get install -y \
        vim \
        neovim

    # -------------------------------------------------------------------------
    # AI CLI Tools
    # -------------------------------------------------------------------------
    log_info "Installing AI CLI Tools..."

    # Claude Code CLI (Anthropic)
    log_info "Installing Claude Code CLI..."
    npm install -g @anthropic-ai/claude-code || log_warn "Claude Code CLI installation failed"

    # Gemini CLI (Google)
    log_info "Installing Gemini CLI..."
    npm install -g @google/gemini-cli 2>/dev/null || \
    npm install -g gemini-cli 2>/dev/null || \
    log_warn "Gemini CLI not found in npm, may need manual installation"

    # Continue.dev CLI
    log_info "Installing Continue.dev CLI..."
    npm install -g continue-cli 2>/dev/null || \
    log_warn "Continue CLI not found in npm, may need manual installation"

    # Aider (AI pair programming)
    log_info "Installing Aider..."
    pipx install aider-chat || log_warn "Aider installation failed"

    # OpenAI CLI
    log_info "Installing OpenAI CLI..."
    pipx install openai || log_warn "OpenAI CLI installation failed"

    # -------------------------------------------------------------------------
    # Misc Dev Tools
    # -------------------------------------------------------------------------
    log_info "Installing misc dev tools..."
    apt-get install -y \
        shellcheck \
        shfmt \
        pre-commit \
        entr \
        socat \
        || true

    # yq (YAML processor - Go version)
    if ! command -v yq &> /dev/null || ! yq --version 2>&1 | grep -q "mikefarah"; then
        YQ_VERSION=$(github_latest_tag "mikefarah/yq")
        if [ -z "$YQ_VERSION" ]; then
            log_warn "Could not determine yq version - skipping"
        else
            wget -qO /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64"
            chmod +x /usr/local/bin/yq
        fi
    fi

    # glow (markdown renderer)
    if ! command -v glow &> /dev/null; then
        GLOW_VERSION=$(github_latest_tag "charmbracelet/glow")
        if [ -z "$GLOW_VERSION" ]; then
            log_warn "Could not determine glow version - skipping"
        else
            wget -qO /tmp/glow.deb "https://github.com/charmbracelet/glow/releases/download/v${GLOW_VERSION}/glow_${GLOW_VERSION}_amd64.deb"
            dpkg -i /tmp/glow.deb || apt-get install -f -y
            rm -f /tmp/glow.deb
        fi
    fi

    # -------------------------------------------------------------------------
    # Summary
    # -------------------------------------------------------------------------
    log_info "Development tools installation complete!"
    log_info ""
    log_info "Languages installed:"
    log_info "  - Python $(python3 --version 2>&1 | awk '{print $2}')"
    log_info "  - Node.js $(node --version 2>/dev/null)"
    log_info "  - Go $(/usr/local/go/bin/go version 2>/dev/null | awk '{print $3}' | sed 's/go//')"
    log_info "  - .NET SDK $(dotnet --version 2>/dev/null)"
    log_info "  - Rust $(rustc --version 2>/dev/null | awk '{print $2}')"
    log_info "  - Java $(java --version 2>&1 | head -1 | awk '{print $2}')"
    log_info ""
    log_info "CLI tools installed:"
    log_info "  - Modern shell tools: ripgrep, fd, bat, eza, fzf, zoxide, delta"
    log_info "  - Git: gh, lazygit"
    log_info "  - Kubernetes: kubectl, helm, k9s, kubectx/kubens"
    log_info "  - Cloud: aws, az, gcloud"
    log_info "  - IaC: terraform, pulumi"
    log_info "  - Database: psql, mysql, redis-cli, mongosh, sqlite3"
    log_info "  - HTTP: httpie, grpcurl"
    log_info "  - AI: claude, aider, openai"
    log_info "  - Build: cmake, ninja, just, task"
    log_info "  - Shell: starship, direnv, zsh"
    log_info ""
    log_info "Note: Log out and back in for PATH changes to take effect"
}

# ============================================================================
# MAIN MENU (Interactive Mode)
# ============================================================================

show_menu() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}          ${BOLD}Optional Features Installation Menu${NC}                   ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Container & Virtualization:${NC}"
    echo "  1. Docker + Docker Compose"
    echo "  2. Portainer (Docker Web UI)"
    echo ""
    echo -e "${YELLOW}Web Management:${NC}"
    echo "  3. Cockpit (Server Management)"
    echo "  4. Webmin"
    echo ""
    echo -e "${YELLOW}VPN & Remote Access:${NC}"
    echo "  5. Tailscale"
    echo "  6. ZeroTier"
    echo ""
    echo -e "${YELLOW}Security:${NC}"
    echo "  7. Fail2ban (SSH Protection)"
    echo "  8. UFW Firewall"
    echo "  9. SSH Hardening"
    echo " 10. Automatic Security Updates"
    echo ""
    echo -e "${YELLOW}File Sharing:${NC}"
    echo " 11. Samba (Windows Sharing)"
    echo " 12. NFS Server"
    echo ""
    echo -e "${YELLOW}Monitoring:${NC}"
    echo " 13. Prometheus + Node Exporter + Grafana"
    echo " 14. Node Exporter Only"
    echo ""
    echo -e "${YELLOW}Observability & Telemetry:${NC}"
    echo " 15. SigNoz (APM & Observability Platform)"
    echo " 16. OpenTelemetry Collector (Metrics & Logs to SigNoz)"
    echo " 17. SigNoz + OpenTelemetry Collector"
    echo ""
    echo -e "${YELLOW}System:${NC}"
    echo " 18. Ansible (Automation)"
    echo " 19. Configure Swap"
    echo " 20. Configure Zram Swap (compressed RAM swap)"
    echo " 21. Wake-on-LAN"
    echo " 22. Common Tools (btop, ncdu, tmux, etc.)"
    echo ""
    echo -e "${YELLOW}Development:${NC}"
    echo " 23. Dev Tools (Go, Python, Node.js, .NET, AI CLIs)"
    echo ""
    echo " 24. Install ALL recommended for home lab"
    echo " 25. Install ALL recommended for dev workstation"
    echo "  0. Exit"
    echo ""
}

interactive_menu() {
    while true; do
        show_menu
        read -p "Enter choice: " choice

        case $choice in
            1) INSTALL_DOCKER=true; install_docker ;;
            2) INSTALL_DOCKER=true; INSTALL_PORTAINER=true; install_docker; install_portainer ;;
            3) INSTALL_COCKPIT=true; install_cockpit ;;
            4) INSTALL_WEBMIN=true; install_webmin ;;
            5) INSTALL_TAILSCALE=true; install_tailscale ;;
            6) INSTALL_ZEROTIER=true; install_zerotier ;;
            7) INSTALL_FAIL2BAN=true; install_fail2ban ;;
            8) CONFIGURE_UFW=true; configure_ufw ;;
            9) HARDEN_SSH=true; harden_ssh ;;
            10) ENABLE_AUTO_UPDATES=true; configure_unattended_upgrades ;;
            11) INSTALL_SAMBA=true; install_samba ;;
            12) INSTALL_NFS=true; install_nfs ;;
            13) INSTALL_PROMETHEUS=true; INSTALL_NODE_EXPORTER=true; INSTALL_GRAFANA=true
                install_prometheus; install_node_exporter; install_grafana ;;
            14) INSTALL_NODE_EXPORTER=true; install_node_exporter ;;
            15) INSTALL_DOCKER=true; INSTALL_SIGNOZ=true; install_docker; install_signoz ;;
            16) INSTALL_OTEL_COLLECTOR=true; install_otel_collector ;;
            17) INSTALL_DOCKER=true; INSTALL_SIGNOZ=true; INSTALL_OTEL_COLLECTOR=true
                install_docker; install_signoz; install_otel_collector ;;
            18) INSTALL_ANSIBLE=true; install_ansible ;;
            19) CONFIGURE_SWAP=true; configure_swap ;;
            20) CONFIGURE_ZRAM=true; configure_zram ;;
            21) ENABLE_WAKE_ON_LAN=true; configure_wakeonlan ;;
            22) INSTALL_COMMON_TOOLS=true; install_common_tools ;;
            23) INSTALL_DEV_TOOLS=true; install_dev_tools ;;
            24) install_recommended_homelab ;;
            25) install_recommended_dev_workstation ;;
            0)
                echo "Exiting..."
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option${NC}"
                sleep 1
                ;;
        esac

        echo ""
        read -p "Press Enter to continue..."
    done
}

install_recommended_homelab() {
    log_section "Installing Recommended Home Lab Stack"

    INSTALL_DOCKER=true
    INSTALL_PORTAINER=true
    INSTALL_COCKPIT=true
    INSTALL_FAIL2BAN=true
    ENABLE_AUTO_UPDATES=true
    HARDEN_SSH=true
    CONFIGURE_SWAP=true
    CONFIGURE_ZRAM=true
    ENABLE_WAKE_ON_LAN=true
    INSTALL_COMMON_TOOLS=true
    CONFIGURE_NTP=true
    INSTALL_NODE_EXPORTER=true
    INSTALL_ANSIBLE=true

    install_docker
    install_portainer
    install_cockpit
    install_fail2ban
    configure_unattended_upgrades
    harden_ssh
    configure_swap
    configure_zram
    configure_wakeonlan
    configure_rtc_wake
    configure_ntp
    install_node_exporter
    install_ansible
    install_common_tools

    log_info "Recommended home lab stack installed!"
}

install_recommended_dev_workstation() {
    log_section "Installing Recommended Dev Workstation Stack"

    # Include home lab essentials
    INSTALL_DOCKER=true
    INSTALL_PORTAINER=true
    INSTALL_COCKPIT=true
    INSTALL_FAIL2BAN=true
    ENABLE_AUTO_UPDATES=true
    HARDEN_SSH=true
    CONFIGURE_SWAP=true
    CONFIGURE_ZRAM=true
    INSTALL_COMMON_TOOLS=true
    CONFIGURE_NTP=true
    INSTALL_ANSIBLE=true

    # Dev-specific
    INSTALL_DEV_TOOLS=true

    install_docker
    install_portainer
    install_cockpit
    install_fail2ban
    configure_unattended_upgrades
    harden_ssh
    configure_swap
    configure_zram
    configure_ntp
    install_ansible
    install_common_tools
    install_dev_tools

    log_info "Recommended dev workstation stack installed!"
    log_info ""
    log_info "Installed languages & tools:"
    log_info "  - Python 3 with pip and venv"
    log_info "  - Node.js LTS with npm, yarn, pnpm"
    log_info "  - Go"
    log_info "  - .NET SDK 8.0"
    log_info "  - Claude Code CLI"
    log_info "  - Gemini CLI"
    log_info "  - Continue.dev CLI"
    log_info ""
    log_info "Note: Log out and back in for PATH changes to take effect"
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    if [ "$(id -u)" != "0" ]; then
        echo "This script must be run as root"
        exit 1
    fi

    # Check if running interactively
    if [ "$1" = "--interactive" ] || [ "$1" = "-i" ]; then
        interactive_menu
        exit 0
    fi

    # Non-interactive: install based on config
    log_info "Installing optional features based on configuration..."

    # Refresh apt cache if stale (>1 hour) -- needed for standalone runs outside post-install.sh
    local apt_cache="/var/cache/apt/pkgcache.bin"
    if [ ! -f "$apt_cache" ] || [ $(($(date +%s) - $(stat -c %Y "$apt_cache"))) -gt 3600 ]; then
        log_info "Refreshing apt cache (stale or missing)..."
        apt-get update
    fi

    install_docker
    install_portainer
    install_cockpit
    install_webmin
    install_tailscale
    install_zerotier
    install_fail2ban
    configure_ufw
    configure_unattended_upgrades
    harden_ssh
    install_samba
    install_nfs
    install_prometheus
    install_node_exporter
    install_grafana
    install_signoz
    install_otel_collector
    install_ansible
    configure_swap
    configure_zram
    configure_wakeonlan
    configure_rtc_wake
    configure_ntp
    install_common_tools
    install_dev_tools

    # Apply kernel sysctl hardening
    log_section "Applying Kernel Sysctl Hardening"
    cat > /etc/sysctl.d/99-security-hardening.conf << 'EOF'
# IP forwarding: Docker requires ip_forward=1; only disable if Docker is not installed
# (Docker sets this via /etc/sysctl.d/99-docker.conf; we avoid conflicting with it)
# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
# Enable SYN flood protection
net.ipv4.tcp_syncookies = 1
# Log martian packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
# Ignore ICMP broadcast requests
net.ipv4.icmp_echo_ignore_broadcasts = 1
# Enable source address verification (reverse path filtering)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
# Restrict dmesg access
kernel.dmesg_restrict = 1
# Restrict kernel pointer exposure
kernel.kptr_restrict = 1
EOF
    # Only disable ip_forward if Docker is NOT installed (Docker requires it enabled)
    if ! command -v docker &>/dev/null && [ "${INSTALL_DOCKER:-false}" != "true" ]; then
        echo "net.ipv4.ip_forward = 0" >> /etc/sysctl.d/99-security-hardening.conf
        log_info "ip_forward disabled (Docker not installed)"
    else
        log_info "ip_forward left enabled (Docker requires it)"
    fi
    sysctl --system >/dev/null 2>&1 || true
    log_info "Kernel sysctl hardening applied"

    if [ "$ERROR_COUNT" -gt 0 ]; then
        log_warn "Optional features installation complete with $ERROR_COUNT error(s)"
    else
        log_info "Optional features installation complete!"
    fi

    # Cap exit code at 125 to avoid wrapping (values > 125 have special meaning to shells)
    [ "$ERROR_COUNT" -gt 125 ] && ERROR_COUNT=125
    sleep 0.5  # Allow tee process substitution to flush final log lines
    exit $ERROR_COUNT
}

main "$@"
