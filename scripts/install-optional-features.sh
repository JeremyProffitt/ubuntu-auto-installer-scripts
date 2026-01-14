#!/bin/bash
# ============================================================================
# Optional Features Installation Script
# Installs optional software and configurations for home lab servers
# ============================================================================

set -e

LOG_FILE="/var/log/optional-features.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo "Optional Features Installation"
echo "Started: $(date)"
echo "=========================================="

CONFIG_FILE="/opt/ubuntu-installer/config.env"

# Load configuration
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo "Loaded configuration from $CONFIG_FILE"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() { echo -e "\n${BLUE}━━━ $1 ━━━${NC}\n"; }

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
    apt-get update
    apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Add repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker
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
        return
    fi

    log_section "Installing Portainer"

    # Create volume for Portainer data
    docker volume create portainer_data

    # Run Portainer
    docker run -d \
        -p 8000:8000 \
        -p 9443:9443 \
        --name portainer \
        --restart=always \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v portainer_data:/data \
        portainer/portainer-ce:latest

    log_info "Portainer installed - Access at https://<ip>:9443"
}

# ============================================================================
# WEB MANAGEMENT INTERFACES
# ============================================================================

install_cockpit() {
    if [ "${INSTALL_COCKPIT:-false}" != "true" ]; then
        return
    fi

    log_section "Installing Cockpit Web Management"

    apt-get update
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

    # Add Webmin repository
    curl -fsSL https://download.webmin.com/jcameron-key.asc | gpg --dearmor -o /usr/share/keyrings/webmin.gpg
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

    curl -s https://install.zerotier.com | bash

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

    apt-get update
    apt-get install -y fail2ban

    # Create local jail configuration
    cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
banaction = iptables-multiport

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

    # Allow common services based on what's installed
    [ "${INSTALL_COCKPIT:-false}" = "true" ] && ufw allow 9090/tcp comment 'Cockpit'
    [ "${INSTALL_WEBMIN:-false}" = "true" ] && ufw allow 10000/tcp comment 'Webmin'
    [ "${INSTALL_PORTAINER:-false}" = "true" ] && ufw allow 9443/tcp comment 'Portainer'
    [ "${INSTALL_SAMBA:-false}" = "true" ] && ufw allow samba comment 'Samba'
    [ "${INSTALL_NFS:-false}" = "true" ] && ufw allow nfs comment 'NFS'
    [ "${INSTALL_PROMETHEUS:-false}" = "true" ] && ufw allow 9090/tcp comment 'Prometheus'
    [ "${INSTALL_NODE_EXPORTER:-false}" = "true" ] && ufw allow 9100/tcp comment 'Node Exporter'
    [ "${INSTALL_GRAFANA:-false}" = "true" ] && ufw allow 3000/tcp comment 'Grafana'
    [ "${INSTALL_SIGNOZ:-false}" = "true" ] && ufw allow 3301/tcp comment 'SigNoz'
    [ "${INSTALL_OTEL_COLLECTOR:-false}" = "true" ] && ufw allow 13133/tcp comment 'OTEL Health Check'

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

    # Create hardened SSH config
    cat > /etc/ssh/sshd_config.d/99-hardening.conf << 'EOF'
# SSH Hardening Configuration
Protocol 2
PermitRootLogin prohibit-password
MaxAuthTries 3
MaxSessions 5
PubkeyAuthentication yes
PasswordAuthentication yes
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 60
EOF

    # Restart SSH
    systemctl restart sshd

    log_info "SSH hardening applied"
}

# ============================================================================
# FILE SHARING
# ============================================================================

install_samba() {
    if [ "${INSTALL_SAMBA:-false}" != "true" ]; then
        return
    fi

    log_section "Installing Samba File Sharing"

    apt-get update
    apt-get install -y samba samba-common-bin

    # Backup original config
    cp /etc/samba/smb.conf /etc/samba/smb.conf.backup

    # Create default share directory
    SHARE_DIR="${SAMBA_SHARE_PATH:-/srv/samba/share}"
    mkdir -p "$SHARE_DIR"
    chmod 777 "$SHARE_DIR"

    # Configure Samba
    cat > /etc/samba/smb.conf << EOF
[global]
   workgroup = WORKGROUP
   server string = Ubuntu Home Lab Server
   security = user
   map to guest = Bad User
   dns proxy = no

   # Performance tuning
   socket options = TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=131072 SO_SNDBUF=131072
   read raw = yes
   write raw = yes
   max xmit = 65535
   dead time = 15
   getwd cache = yes

[share]
   comment = Shared Files
   path = $SHARE_DIR
   browseable = yes
   read only = no
   guest ok = yes
   create mask = 0664
   directory mask = 0775

[homes]
   comment = Home Directories
   browseable = no
   read only = no
   create mask = 0700
   directory mask = 0700
   valid users = %S
EOF

    # Set Samba password for user
    INSTALL_USERNAME="${INSTALL_USERNAME:-admin}"
    echo -e "${INSTALL_PASSWORD:-changeme123}\n${INSTALL_PASSWORD:-changeme123}" | smbpasswd -a "$INSTALL_USERNAME" -s || true

    systemctl enable smbd nmbd
    systemctl restart smbd nmbd

    log_info "Samba installed - Share at \\\\<ip>\\share"
}

install_nfs() {
    if [ "${INSTALL_NFS:-false}" != "true" ]; then
        return
    fi

    log_section "Installing NFS Server"

    apt-get update
    apt-get install -y nfs-kernel-server

    # Create default export directory
    EXPORT_DIR="${NFS_EXPORT_PATH:-/srv/nfs/share}"
    mkdir -p "$EXPORT_DIR"
    chmod 777 "$EXPORT_DIR"

    # Configure exports
    NFS_NETWORK="${NFS_ALLOWED_NETWORK:-192.168.1.0/24}"
    echo "$EXPORT_DIR $NFS_NETWORK(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports

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

    log_section "Installing Prometheus"

    # Create prometheus user
    useradd --no-create-home --shell /bin/false prometheus || true

    # Download and install
    PROM_VERSION="2.48.0"
    cd /tmp
    wget -q "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-amd64.tar.gz"
    tar xzf "prometheus-${PROM_VERSION}.linux-amd64.tar.gz"

    cp "prometheus-${PROM_VERSION}.linux-amd64/prometheus" /usr/local/bin/
    cp "prometheus-${PROM_VERSION}.linux-amd64/promtool" /usr/local/bin/

    mkdir -p /etc/prometheus /var/lib/prometheus
    cp -r "prometheus-${PROM_VERSION}.linux-amd64/consoles" /etc/prometheus/
    cp -r "prometheus-${PROM_VERSION}.linux-amd64/console_libraries" /etc/prometheus/

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

    # Create systemd service
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
    --web.console.templates=/etc/prometheus/consoles \
    --web.console.libraries=/etc/prometheus/console_libraries

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable prometheus
    systemctl start prometheus

    rm -rf /tmp/prometheus-*

    log_info "Prometheus installed - Access at http://<ip>:9090"
}

install_node_exporter() {
    if [ "${INSTALL_NODE_EXPORTER:-false}" != "true" ]; then
        return
    fi

    log_section "Installing Node Exporter"

    # Create user
    useradd --no-create-home --shell /bin/false node_exporter || true

    # Download and install
    NE_VERSION="1.7.0"
    cd /tmp
    wget -q "https://github.com/prometheus/node_exporter/releases/download/v${NE_VERSION}/node_exporter-${NE_VERSION}.linux-amd64.tar.gz"
    tar xzf "node_exporter-${NE_VERSION}.linux-amd64.tar.gz"

    cp "node_exporter-${NE_VERSION}.linux-amd64/node_exporter" /usr/local/bin/
    chown node_exporter:node_exporter /usr/local/bin/node_exporter

    # Create systemd service
    cat > /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable node_exporter
    systemctl start node_exporter

    rm -rf /tmp/node_exporter-*

    log_info "Node Exporter installed - Metrics at http://<ip>:9100/metrics"
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

    systemctl enable grafana-server
    systemctl start grafana-server

    log_info "Grafana installed - Access at http://<ip>:3000 (admin/admin)"
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
        return
    fi

    log_section "Installing SigNoz"

    # Create directory for SigNoz
    mkdir -p /opt/signoz
    cd /opt/signoz

    # Download docker-compose file
    curl -sL https://github.com/SigNoz/signoz/releases/latest/download/docker-compose.yaml -o docker-compose.yaml

    # Start SigNoz
    docker compose up -d

    log_info "SigNoz installed - Access at http://<ip>:3301"
    log_info "Default credentials: admin@signoz.io / changeit"
}

install_otel_collector() {
    if [ "${INSTALL_OTEL_COLLECTOR:-false}" != "true" ]; then
        return
    fi

    log_section "Installing OpenTelemetry Collector"

    OTEL_ENDPOINT="${OTEL_ENDPOINT:-signoz-internal.jeremy.ninja:4317}"

    # Download and install OpenTelemetry Collector
    OTEL_VERSION="0.92.0"
    cd /tmp
    wget -q "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/otelcol-contrib_${OTEL_VERSION}_linux_amd64.deb"
    dpkg -i "otelcol-contrib_${OTEL_VERSION}_linux_amd64.deb"

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
          match_type: regexp
          names: [".*"]
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
  filelog:
    include:
      - /var/log/*.log
      - /var/log/syslog
      - /var/log/auth.log
      - /var/log/kern.log
      - /var/log/apt/*.log
    exclude:
      - /var/log/lastlog
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
      insecure: true
    headers:
      signoz-access-token: ""
  logging:
    loglevel: info

extensions:
  health_check:
    endpoint: 0.0.0.0:13133
  zpages:
    endpoint: 0.0.0.0:55679

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
    log_info "Logs collected: /var/log/*.log, syslog, auth.log, kern.log, journald"
}

# ============================================================================
# SYSTEM CONFIGURATION
# ============================================================================

install_ansible() {
    if [ "${INSTALL_ANSIBLE:-true}" != "true" ]; then
        return
    fi

    log_section "Installing Ansible"

    apt-get update
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

    # Check if swap already exists
    if swapon --show | grep -q "/swapfile"; then
        log_info "Swap already configured"
        return
    fi

    # Create swap file
    fallocate -l "${SWAP_SIZE}G" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    # Add to fstab
    if ! grep -q "/swapfile" /etc/fstab; then
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi

    # Configure swappiness
    echo "vm.swappiness=10" >> /etc/sysctl.conf
    sysctl -p

    log_info "Swap configured: ${SWAP_SIZE}GB"
}

configure_wakeonlan() {
    if [ "${ENABLE_WAKE_ON_LAN:-false}" != "true" ]; then
        return
    fi

    log_section "Configuring Wake-on-LAN"

    apt-get install -y ethtool

    # Get primary network interface
    IFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')

    if [ -n "$IFACE" ]; then
        # Enable WoL
        ethtool -s "$IFACE" wol g 2>/dev/null || true

        # Make persistent with systemd
        cat > /etc/systemd/system/wol@.service << 'EOF'
[Unit]
Description=Wake-on-LAN for %i
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/ethtool -s %i wol g

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable "wol@${IFACE}.service"
        systemctl start "wol@${IFACE}.service"

        log_info "Wake-on-LAN enabled on $IFACE"
    else
        log_warn "Could not detect network interface for WoL"
    fi
}

configure_ntp() {
    if [ "${CONFIGURE_NTP:-true}" != "true" ]; then
        return
    fi

    log_section "Configuring NTP Time Sync"

    apt-get install -y chrony

    # Configure chrony
    cat > /etc/chrony/chrony.conf << 'EOF'
# Ubuntu NTP configuration
pool ntp.ubuntu.com iburst maxsources 4
pool 0.ubuntu.pool.ntp.org iburst maxsources 1
pool 1.ubuntu.pool.ntp.org iburst maxsources 1
pool 2.ubuntu.pool.ntp.org iburst maxsources 2

keyfile /etc/chrony/chrony.keys
driftfile /var/lib/chrony/chrony.drift
logdir /var/log/chrony
maxupdateskew 100.0
rtcsync
makestep 1 3
EOF

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

    apt-get update
    apt-get install -y \
        neofetch \
        btop \
        ncdu \
        tree \
        jq \
        yq \
        rsync \
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
    echo " 20. Wake-on-LAN"
    echo " 21. Common Tools (btop, ncdu, etc.)"
    echo ""
    echo " 22. Install ALL recommended for home lab"
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
            20) ENABLE_WAKE_ON_LAN=true; configure_wakeonlan ;;
            21) INSTALL_COMMON_TOOLS=true; install_common_tools ;;
            22) install_recommended_homelab ;;
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
    configure_wakeonlan
    configure_ntp
    install_node_exporter
    install_ansible
    install_common_tools

    log_info "Recommended home lab stack installed!"
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

    apt-get update

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
    configure_wakeonlan
    configure_ntp
    install_common_tools

    log_info "Optional features installation complete!"
}

main "$@"
