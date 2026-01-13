# Ubuntu Auto Installer Scripts

Automated Ubuntu installation USB creator for home lab computers with full driver support and customizable configuration.

## Supported Hardware

This installer is specifically designed and tested for:

| System | Chipset | CPU Generation |
|--------|---------|----------------|
| HP Elite 8300 | Intel Q77 | 3rd Gen Intel (Ivy Bridge) |
| Lenovo ThinkCentre M92p | Intel Q77 | 3rd Gen Intel (Ivy Bridge) |
| Lenovo ThinkCentre M72 | Intel H61 | 3rd Gen Intel (Ivy Bridge) |
| ASUS Z97 Motherboards | Intel Z97 | 4th/5th Gen Intel (Haswell/Broadwell) |
| ASUS Hyper M.2 x16 Card V2 | PCIe NVMe Adapter | - |

## Features

- **Docker pre-installed** - Container runtime ready out of the box
- **Automatic driver installation** for all supported hardware
- **Interactive disk selection** during installation
- **Interactive drive configuration** - format, partition, and name mount points
- **SSH enabled by default** with password authentication
- **Auto-mount all drives** after installation
- **Optional GUI installation** (Ubuntu Desktop or headless server)
- **RAID array creation** with mdadm
- **System utilities included** - swap, NTP, btop, ncdu, jq, and more
- **Configurable via `.env` file**
- **Works with USB 2.0/3.0 drives**

## Quick Start

### 1. Configure Settings

```bash
# Copy sample configuration
copy .env.sample .env

# Edit .env with your preferences
notepad .env
```

### 2. Create USB Drive

**Option A: Windows Batch Script (Recommended for simplicity)**
```cmd
# Run as Administrator
create-usb.bat
```

**Option B: Go Program**
```cmd
# Build and run
go build -o usb-creator.exe ./cmd/usb-creator
usb-creator.exe
```

### 3. Boot Target Computer

1. Insert USB drive into target computer
2. Boot from USB (F12, F2, or Del at startup for boot menu)
3. Select the target drive when prompted
4. Installation completes automatically

## Configuration Options

Edit `.env` to customize your installation:

```ini
# User Configuration
INSTALL_USERNAME=admin          # Default user account
INSTALL_PASSWORD=changeme123    # User password (change this!)
INSTALL_HOSTNAME=ubuntu-server  # System hostname

# SSH Configuration
SSH_AUTHORIZED_KEYS=            # Optional SSH public key

# Network Configuration
STATIC_IP=false                 # Set to true for static IP
IP_ADDRESS=192.168.1.100       # Static IP address
NETMASK=255.255.255.0          # Network mask
GATEWAY=192.168.1.1            # Default gateway
DNS_SERVERS=8.8.8.8,8.8.4.4    # DNS servers

# Installation Options
INSTALL_GUI=false               # true = Ubuntu Desktop, false = server
TIMEZONE=America/New_York       # System timezone
LOCALE=en_US.UTF-8             # System locale
KEYBOARD_LAYOUT=us              # Keyboard layout

# Drive Configuration
INTERACTIVE_DRIVE_CONFIG=true  # Prompt for interactive drive setup on first boot
AUTO_MOUNT_DRIVES=true         # Auto-mount drives if interactive config skipped

# Enabled by Default
INSTALL_DOCKER=true            # Docker container runtime
CONFIGURE_SWAP=true            # 4GB swap file
CONFIGURE_NTP=true             # Time synchronization
INSTALL_COMMON_TOOLS=true      # btop, ncdu, jq, rsync, etc.
```

## Project Structure

```
ubuntu-auto-installer-scripts/
├── .env.sample              # Sample configuration file
├── .gitignore               # Git ignore rules
├── go.mod                   # Go module definition
├── create-usb.bat           # Windows batch script
├── README.md                # This file
├── autoinstall/
│   ├── user-data            # Cloud-init autoinstall config
│   └── meta-data            # Cloud-init metadata
├── cmd/
│   └── usb-creator/
│       └── main.go          # Go USB creator program
└── scripts/
    ├── install-drivers.sh          # Driver installation script
    ├── post-install.sh             # First-boot setup script
    ├── mount-drives.sh             # Auto-mount drives script
    ├── install-gui.sh              # GUI installation script
    ├── configure-drives.sh         # Interactive drive configuration
    └── install-optional-features.sh # Optional software installer
```

## Driver Support

### All Systems
- Linux firmware package
- Intel/AMD microcode updates
- DKMS build tools
- NVMe storage drivers
- USB 2.0/3.0 support

### HP Elite 8300 / Lenovo M92p
- Intel Q77 chipset support
- Intel HD Graphics 2500/4000 (i915)
- Intel 82579LM Gigabit Ethernet (e1000e)
- Realtek ALC audio (snd-hda-intel)
- Intel MEI (Management Engine)
- TPM 1.2 support

### Lenovo ThinkCentre M72
- Intel H61 chipset support
- Intel HD Graphics 2500 (i915)
- Realtek RTL8111E Ethernet (r8169)
- Realtek ALC662 audio
- Hardware monitoring (NCT6775)

### ASUS Z97 Motherboards
- Intel Z97 chipset support
- Intel HD Graphics 4600 (i915)
- Intel I218-V/I211-AT Ethernet (e1000e/igb)
- Broadcom BCM4352 WiFi (bcmwl)
- Realtek ALC1150 audio
- Nuvoton NCT6791D monitoring (nct6775)

### ASUS Hyper M.2 x16 Card V2
- NVMe driver configuration
- PCIe bifurcation support
- Multiple NVMe drive detection
- Optimized I/O scheduler settings

## Interactive Drive Configuration

On first boot, you'll be prompted to run the interactive drive configuration utility. This allows you to:

### Features
- **View all drives** - See all detected storage devices with details
- **Format partitions** - Format with ext4, xfs, btrfs, ntfs, exfat, or fat32
- **Partition drives** - Use fdisk, parted, cfdisk, or gdisk
- **Custom mount points** - Name mounts like `/mnt/data`, `/mnt/backup`, etc.
- **Configure fstab** - Set up auto-mount on boot
- **Create RAID arrays** - Build RAID 0/1/5/6/10 with mdadm
- **Check disk health** - View SMART status for all drives

### Running Later
You can run the interactive configuration anytime:
```bash
sudo /opt/ubuntu-installer-scripts/configure-drives.sh
```

### Menu Options
```
┌─────────────────────────────────────────────────────────────────┐
│  Main Menu                                                      │
├─────────────────────────────────────────────────────────────────┤
│  1. View all drives and partitions                              │
│  2. View current mount points                                   │
│  3. Format a drive/partition                                    │
│  4. Partition a drive (fdisk/parted)                            │
│  5. Mount a partition with custom name                          │
│  6. Unmount a partition                                         │
│  7. Configure auto-mount (fstab)                                │
│  8. Create RAID array (mdadm)                                   │
│  9. View SMART disk health                                      │
│  0. Exit and save configuration                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Optional Features

The installer includes many optional features that can be enabled in `.env` or installed via interactive menu.

### Available Optional Features

| Category | Feature | Description | Default | Port |
|----------|---------|-------------|---------|------|
| **Containers** | Docker | Container runtime | ✅ ON | - |
| | Portainer | Docker web UI | OFF | 9443 |
| **Web Management** | Cockpit | Server management UI | OFF | 9090 |
| | Webmin | Classic admin panel | OFF | 10000 |
| **VPN/Remote** | Tailscale | Mesh VPN | OFF | - |
| | ZeroTier | Software-defined network | OFF | - |
| | Wake-on-LAN | Remote power on | OFF | - |
| **Security** | Fail2ban | SSH brute-force protection | OFF | - |
| | UFW | Firewall configuration | OFF | - |
| | SSH Hardening | Secure SSH config | OFF | - |
| | Auto Updates | Unattended security updates | OFF | - |
| **File Sharing** | Samba | Windows file sharing (SMB) | OFF | 445 |
| | NFS | Linux/Unix file sharing | OFF | 2049 |
| **Monitoring** | Prometheus | Metrics database | OFF | 9090 |
| | Node Exporter | System metrics | OFF | 9100 |
| | Grafana | Visualization | OFF | 3000 |
| **System** | Swap (4GB) | Configure swap space | ✅ ON | - |
| | NTP | Time synchronization | ✅ ON | - |
| | Common Tools | btop, ncdu, jq, etc. | ✅ ON | - |

### Quick Presets in .env

```ini
# --- HOME LAB SERVER (Recommended) ---
INSTALL_DOCKER=true
INSTALL_PORTAINER=true
INSTALL_COCKPIT=true
INSTALL_FAIL2BAN=true
HARDEN_SSH=true
ENABLE_AUTO_UPDATES=true
CONFIGURE_SWAP=true
ENABLE_WAKE_ON_LAN=true
INSTALL_COMMON_TOOLS=true
INSTALL_NODE_EXPORTER=true
```

### Interactive Menu

Run the optional features menu anytime:
```bash
sudo /opt/ubuntu-installer-scripts/install-optional-features.sh -i
```

## Post-Installation

After installation completes and the system reboots:

1. **Interactive Drive Setup** (if enabled): Configure drives, partitions, and mount points

2. **SSH Access**: Connect via SSH using the configured credentials
   ```bash
   ssh admin@<ip-address>
   ```

3. **Check Driver Status**:
   ```bash
   # View installed drivers
   lspci -k

   # Check hardware sensors
   sensors

   # View mounted drives
   lsblk
   ```

4. **Install GUI** (if not installed during setup):
   ```bash
   sudo /opt/ubuntu-installer-scripts/install-gui.sh
   ```

5. **Reconfigure Drives** (anytime):
   ```bash
   sudo /opt/ubuntu-installer-scripts/configure-drives.sh
   ```

6. **Install Optional Features** (anytime):
   ```bash
   sudo /opt/ubuntu-installer-scripts/install-optional-features.sh -i
   ```

## Troubleshooting

### USB Boot Issues
- Ensure Secure Boot is disabled in BIOS
- Try Legacy Boot mode if UEFI doesn't work
- Use a different USB port (try USB 2.0 ports)

### Network Not Working
- Check ethernet cable connection
- Run: `sudo systemctl restart NetworkManager`
- For Realtek issues: `sudo apt install r8168-dkms`

### No Sound
- Run: `alsamixer` and unmute channels
- Check: `aplay -l` for detected audio devices

### NVMe Drives Not Detected
- Verify PCIe bifurcation is enabled in BIOS
- Check: `lspci | grep -i nvme`
- Run: `sudo nvme list`

## Requirements

### For USB Creation (Windows)
- Windows 10/11
- Administrator privileges
- 8GB+ USB drive
- Internet connection (for ISO download)
- Go 1.21+ (optional, for Go program)

### Target Computer
- 64-bit x86 processor
- 4GB+ RAM (8GB recommended for GUI)
- 20GB+ storage (50GB recommended)
- UEFI or Legacy BIOS boot support

## License

This project is provided as-is for personal and educational use.

## Contributing

Feel free to submit issues and pull requests for additional hardware support or improvements.
