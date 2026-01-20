// Ubuntu Auto Installer USB Creator
// Creates a bootable Ubuntu USB drive with custom autoinstall configuration
package main

import (
	"bufio"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"

	"golang.org/x/crypto/bcrypt"
)

const (
	// Ubuntu ISO URLs
	Ubuntu2404URL = "https://releases.ubuntu.com/24.04/ubuntu-24.04.1-live-server-amd64.iso"
	Ubuntu2204URL = "https://releases.ubuntu.com/22.04/ubuntu-22.04.5-live-server-amd64.iso"

	// Default download directory
	DefaultDownloadDir = "downloads"
)

// DriveInfo represents a USB drive
type DriveInfo struct {
	Number      int
	DeviceID    string
	MediaType   string
	Size        uint64
	SizeDisplay string
	Model       string
	Letters     string
	IsRemovable bool
}

// Config holds the installation configuration
type Config struct {
	Username         string
	Password         string
	Hostname         string
	Timezone         string
	Locale           string
	KeyboardLayout   string
	InstallGUI       bool
	SSHAuthorizedKey string
	StaticIP         bool
	IPAddress        string
	Netmask          string
	Gateway          string
	DNSServers       string
	ExtraPackages    string
	AutoMountDrives  bool
}

func main() {
	fmt.Println("╔════════════════════════════════════════════════════════════╗")
	fmt.Println("║     Ubuntu Auto Installer USB Creator                      ║")
	fmt.Println("║     For: HP Elite 8300, Lenovo M92p/M72, ASUS Z97         ║")
	fmt.Println("╚════════════════════════════════════════════════════════════╝")
	fmt.Println()

	if runtime.GOOS != "windows" {
		fmt.Println("This tool is designed for Windows. Use the shell script version for Linux.")
		os.Exit(1)
	}

	// Check for admin privileges
	if !isAdmin() {
		fmt.Println("⚠️  This program requires Administrator privileges.")
		fmt.Println("   Please run as Administrator.")
		os.Exit(1)
	}

	// Load configuration
	config, err := loadConfig()
	if err != nil {
		fmt.Printf("Error loading configuration: %v\n", err)
		fmt.Println("Please ensure .env file exists (copy from .env.sample)")
		os.Exit(1)
	}

	// Select Ubuntu version
	fmt.Println("\n📦 Select Ubuntu Version:")
	fmt.Println("  1. Ubuntu 24.04 LTS (Noble Numbat) - Recommended")
	fmt.Println("  2. Ubuntu 22.04 LTS (Jammy Jellyfish)")
	fmt.Println()

	ubuntuChoice := promptChoice("Enter choice (1 or 2)", "1")

	var isoURL string
	var isoName string
	switch ubuntuChoice {
	case "2":
		isoURL = Ubuntu2204URL
		isoName = "ubuntu-22.04.5-live-server-amd64.iso"
	default:
		isoURL = Ubuntu2404URL
		isoName = "ubuntu-24.04.1-live-server-amd64.iso"
	}

	// Check for existing ISO or download
	isoPath := filepath.Join(DefaultDownloadDir, isoName)
	if _, err := os.Stat(isoPath); os.IsNotExist(err) {
		fmt.Printf("\n📥 ISO not found. Download %s? (y/n): ", isoName)
		if promptYesNo("", true) {
			if err := downloadISO(isoURL, isoPath); err != nil {
				fmt.Printf("Error downloading ISO: %v\n", err)
				os.Exit(1)
			}
		} else {
			fmt.Print("Enter path to existing Ubuntu ISO: ")
			isoPath = promptString("")
			if _, err := os.Stat(isoPath); os.IsNotExist(err) {
				fmt.Printf("ISO file not found: %s\n", isoPath)
				os.Exit(1)
			}
		}
	} else {
		fmt.Printf("✓ Found existing ISO: %s\n", isoPath)
	}

	// List USB drives
	fmt.Println("\n🔍 Scanning for USB drives...")
	drives, err := listUSBDrives()
	if err != nil {
		fmt.Printf("Error listing drives: %v\n", err)
		os.Exit(1)
	}

	if len(drives) == 0 {
		fmt.Println("❌ No USB drives found. Please insert a USB drive and try again.")
		os.Exit(1)
	}

	// Display drives
	fmt.Println("\n💾 Available USB Drives:")
	fmt.Println("   ────────────────────────────────────────────────────────────")
	for _, d := range drives {
		fmt.Printf("   [%d] %s - %s - %s (%s)\n", d.Number, d.Letters, d.Model, d.SizeDisplay, d.MediaType)
	}
	fmt.Println("   ────────────────────────────────────────────────────────────")

	// Select drive
	fmt.Print("\n⚠️  WARNING: All data on the selected drive will be ERASED!\n")
	fmt.Print("Enter drive number to use: ")
	driveNumStr := promptString("")
	driveNum, err := strconv.Atoi(driveNumStr)
	if err != nil {
		fmt.Println("Invalid drive number")
		os.Exit(1)
	}

	var selectedDrive *DriveInfo
	for _, d := range drives {
		if d.Number == driveNum {
			selectedDrive = &d
			break
		}
	}

	if selectedDrive == nil {
		fmt.Println("Invalid drive selection")
		os.Exit(1)
	}

	// Confirm
	fmt.Printf("\n⚠️  You are about to ERASE all data on:\n")
	fmt.Printf("   Drive: %s\n", selectedDrive.Model)
	fmt.Printf("   Size:  %s\n", selectedDrive.SizeDisplay)
	fmt.Printf("   ID:    %s\n", selectedDrive.DeviceID)
	fmt.Println()
	fmt.Print("Type 'YES' to confirm: ")
	confirmation := promptString("")
	if confirmation != "YES" {
		fmt.Println("Operation cancelled.")
		os.Exit(0)
	}

	// Show configuration summary
	fmt.Println("\n📋 Installation Configuration:")
	fmt.Printf("   Username:     %s\n", config.Username)
	fmt.Printf("   Hostname:     %s\n", config.Hostname)
	fmt.Printf("   Timezone:     %s\n", config.Timezone)
	fmt.Printf("   Install GUI:  %v\n", config.InstallGUI)
	fmt.Printf("   Static IP:    %v\n", config.StaticIP)
	if config.StaticIP {
		fmt.Printf("   IP Address:   %s\n", config.IPAddress)
	}
	fmt.Println()

	// Create USB
	fmt.Println("🔧 Creating bootable USB drive...")

	if err := createBootableUSB(selectedDrive, isoPath, config); err != nil {
		fmt.Printf("\n❌ Error creating USB: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("\n✅ USB drive created successfully!")
	fmt.Println("\n📝 Next steps:")
	fmt.Println("   1. Safely eject the USB drive")
	fmt.Println("   2. Insert into target computer")
	fmt.Println("   3. Boot from USB (usually F12, F2, or Del at startup)")
	fmt.Println("   4. Select the target drive when prompted")
	fmt.Println("   5. Installation will complete automatically")
	fmt.Println()
}

func isAdmin() bool {
	_, err := os.Open("\\\\.\\PHYSICALDRIVE0")
	return err == nil
}

func generateRandomHostname() string {
	b := make([]byte, 3)
	rand.Read(b)
	return fmt.Sprintf("ubuntu-%x", b)
}

func loadConfig() (*Config, error) {
	// Try to load .env file
	envFile := ".env"
	if _, err := os.Stat(envFile); os.IsNotExist(err) {
		// Try parent directory
		envFile = filepath.Join("..", "..", ".env")
		if _, err := os.Stat(envFile); os.IsNotExist(err) {
			return nil, fmt.Errorf(".env file not found. Please copy .env.sample to .env and configure it")
		}
	}

	env, err := parseEnvFile(envFile)
	if err != nil {
		return nil, err
	}

	// Validate required fields
	username := env["INSTALL_USERNAME"]
	if username == "" {
		return nil, fmt.Errorf("INSTALL_USERNAME is not set in .env file")
	}

	password := env["INSTALL_PASSWORD"]
	if password == "" {
		return nil, fmt.Errorf("INSTALL_PASSWORD is not set in .env file")
	}

	// Generate random hostname if set to "random" or empty
	hostname := getEnvOrDefault(env, "INSTALL_HOSTNAME", "random")
	if hostname == "random" || hostname == "" {
		hostname = generateRandomHostname()
	}

	config := &Config{
		Username:         username,
		Password:         password,
		Hostname:         hostname,
		Timezone:         getEnvOrDefault(env, "TIMEZONE", "America/New_York"),
		Locale:           getEnvOrDefault(env, "LOCALE", "en_US.UTF-8"),
		KeyboardLayout:   getEnvOrDefault(env, "KEYBOARD_LAYOUT", "us"),
		InstallGUI:       getEnvOrDefault(env, "INSTALL_GUI", "false") == "true",
		SSHAuthorizedKey: getEnvOrDefault(env, "SSH_AUTHORIZED_KEYS", ""),
		StaticIP:         getEnvOrDefault(env, "STATIC_IP", "false") == "true",
		IPAddress:        getEnvOrDefault(env, "IP_ADDRESS", "192.168.1.100"),
		Netmask:          getEnvOrDefault(env, "NETMASK", "255.255.255.0"),
		Gateway:          getEnvOrDefault(env, "GATEWAY", "192.168.1.1"),
		DNSServers:       getEnvOrDefault(env, "DNS_SERVERS", "8.8.8.8,8.8.4.4"),
		ExtraPackages:    getEnvOrDefault(env, "EXTRA_PACKAGES", "htop,vim,curl,wget,git"),
		AutoMountDrives:  getEnvOrDefault(env, "AUTO_MOUNT_DRIVES", "true") == "true",
	}

	return config, nil
}

func parseEnvFile(filename string) (map[string]string, error) {
	file, err := os.Open(filename)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	env := make(map[string]string)
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) == 2 {
			key := strings.TrimSpace(parts[0])
			value := strings.TrimSpace(parts[1])
			// Remove quotes if present
			value = strings.Trim(value, "\"'")
			env[key] = value
		}
	}
	return env, scanner.Err()
}

func getEnvOrDefault(env map[string]string, key, defaultValue string) string {
	if value, ok := env[key]; ok && value != "" {
		return value
	}
	return defaultValue
}

func listUSBDrives() ([]DriveInfo, error) {
	// Use PowerShell to get disk information with drive letters
	cmd := exec.Command("powershell", "-Command", `
		Get-Disk | Where-Object { $_.BusType -eq 'USB' -or ($_.Size -lt 256GB -and $_.BusType -ne 'NVMe' -and $_.OperationalStatus -eq 'Online') } |
		ForEach-Object {
			$disk = $_
			$letters = (Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue | Get-Volume -ErrorAction SilentlyContinue | Where-Object DriveLetter | ForEach-Object { $_.DriveLetter + ':' }) -join ','
			if (-not $letters) { $letters = '(none)' }
			$size = [math]::Round($disk.Size / 1GB, 2)
			"$($disk.Number)|$($letters)|$($disk.FriendlyName)|$($size)GB|$($disk.BusType)"
		}
	`)

	output, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("failed to list drives: %v", err)
	}

	var drives []DriveInfo
	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.Split(line, "|")
		if len(parts) >= 5 {
			num, _ := strconv.Atoi(parts[0])
			drives = append(drives, DriveInfo{
				Number:      num,
				Letters:     parts[1],
				Model:       parts[2],
				SizeDisplay: parts[3],
				MediaType:   parts[4],
				DeviceID:    fmt.Sprintf("\\\\.\\PhysicalDrive%d", num),
				IsRemovable: parts[4] == "USB",
			})
		}
	}

	return drives, nil
}

func downloadISO(url, destPath string) error {
	// Create downloads directory
	dir := filepath.Dir(destPath)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}

	fmt.Printf("Downloading from: %s\n", url)
	fmt.Printf("Saving to: %s\n", destPath)

	// Create the file
	out, err := os.Create(destPath + ".tmp")
	if err != nil {
		return err
	}
	defer out.Close()

	// Get the data
	resp, err := http.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	// Get file size
	size := resp.ContentLength
	fmt.Printf("File size: %.2f GB\n", float64(size)/(1024*1024*1024))

	// Create progress wrapper
	counter := &writeCounter{Total: size}
	_, err = io.Copy(out, io.TeeReader(resp.Body, counter))
	if err != nil {
		return err
	}

	fmt.Println("\n✓ Download complete")

	// Rename temp file
	return os.Rename(destPath+".tmp", destPath)
}

type writeCounter struct {
	Total      int64
	Downloaded int64
}

func (wc *writeCounter) Write(p []byte) (int, error) {
	n := len(p)
	wc.Downloaded += int64(n)
	percentage := float64(wc.Downloaded) / float64(wc.Total) * 100
	fmt.Printf("\r   Progress: %.1f%% (%.2f GB / %.2f GB)",
		percentage,
		float64(wc.Downloaded)/(1024*1024*1024),
		float64(wc.Total)/(1024*1024*1024))
	return n, nil
}

func hashPassword(password string) (string, error) {
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return "", err
	}
	return string(hash), nil
}

func createBootableUSB(drive *DriveInfo, isoPath string, config *Config) error {
	fmt.Println("\n   Step 1/5: Cleaning disk...")
	// Clean the disk
	cleanScript := fmt.Sprintf(`
		$disk = Get-Disk -Number %d
		$disk | Clear-Disk -RemoveData -RemoveOEM -Confirm:$false -ErrorAction SilentlyContinue
	`, drive.Number)
	cmd := exec.Command("powershell", "-Command", cleanScript)
	cmd.Run() // Ignore error as disk might already be clean

	fmt.Println("   Step 2/5: Creating partitions...")
	// Create partitions using diskpart
	diskpartScript := fmt.Sprintf(`
select disk %d
clean
convert gpt
create partition efi size=512
format quick fs=fat32 label="ESP"
assign letter=S
create partition primary
format quick fs=ntfs label="Ubuntu"
assign letter=U
exit
`, drive.Number)

	// Write diskpart script to temp file
	tmpFile, err := os.CreateTemp("", "diskpart*.txt")
	if err != nil {
		return err
	}
	defer os.Remove(tmpFile.Name())

	if _, err := tmpFile.WriteString(diskpartScript); err != nil {
		return err
	}
	tmpFile.Close()

	cmd = exec.Command("diskpart", "/s", tmpFile.Name())
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("diskpart failed: %v\nOutput: %s", err, output)
	}

	fmt.Println("   Step 3/5: Extracting ISO contents...")
	// Mount ISO and copy contents
	mountScript := `
		$iso = Mount-DiskImage -ImagePath "` + isoPath + `" -PassThru
		$driveLetter = ($iso | Get-Volume).DriveLetter
		Write-Output $driveLetter
	`
	cmd = exec.Command("powershell", "-Command", mountScript)
	output, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("failed to mount ISO: %v", err)
	}
	isoDrive := strings.TrimSpace(string(output)) + ":"

	// Copy ISO contents to USB
	copyScript := fmt.Sprintf(`
		$source = "%s\"
		$destUSB = "U:\"
		$destESP = "S:\"

		# Copy all ISO contents to USB data partition
		robocopy $source $destUSB /E /NFL /NDL /NJH /NJS

		# Copy EFI boot files to ESP
		if (Test-Path "$source\EFI") {
			robocopy "$source\EFI" "$destESP\EFI" /E /NFL /NDL /NJH /NJS
		}

		# Copy boot folder to ESP
		if (Test-Path "$source\boot") {
			robocopy "$source\boot" "$destESP\boot" /E /NFL /NDL /NJH /NJS
		}
	`, isoDrive)

	cmd = exec.Command("powershell", "-Command", copyScript)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		// Unmount ISO on error
		exec.Command("powershell", "-Command", `Dismount-DiskImage -ImagePath "`+isoPath+`"`).Run()
		return fmt.Errorf("failed to copy ISO contents: %v", err)
	}

	// Unmount ISO
	exec.Command("powershell", "-Command", `Dismount-DiskImage -ImagePath "`+isoPath+`"`).Run()

	fmt.Println("   Step 4/5: Creating autoinstall configuration...")
	// Create autoinstall directory structure
	if err := os.MkdirAll("U:\\autoinstall", 0755); err != nil {
		// Try alternative approach
		exec.Command("cmd", "/c", "mkdir", "U:\\autoinstall").Run()
	}

	// Generate password hash
	passwordHash, err := hashPassword(config.Password)
	if err != nil {
		return fmt.Errorf("failed to hash password: %v", err)
	}

	// Create user-data file
	userData := generateUserData(config, passwordHash)
	if err := os.WriteFile("U:\\autoinstall\\user-data", []byte(userData), 0644); err != nil {
		return fmt.Errorf("failed to write user-data: %v", err)
	}

	// Create meta-data file
	metaData := fmt.Sprintf("instance-id: ubuntu-autoinstall\nlocal-hostname: %s\n", config.Hostname)
	if err := os.WriteFile("U:\\autoinstall\\meta-data", []byte(metaData), 0644); err != nil {
		return fmt.Errorf("failed to write meta-data: %v", err)
	}

	fmt.Println("   Step 5/5: Copying installation scripts...")
	// Copy scripts
	scriptsDir := "U:\\scripts"
	if err := os.MkdirAll(scriptsDir, 0755); err != nil {
		exec.Command("cmd", "/c", "mkdir", scriptsDir).Run()
	}

	// Copy scripts from local scripts directory
	scriptFiles := []string{"install-drivers.sh", "post-install.sh", "mount-drives.sh", "install-gui.sh"}
	scriptsSrcDir := filepath.Join(filepath.Dir(os.Args[0]), "..", "..", "scripts")
	if _, err := os.Stat(scriptsSrcDir); os.IsNotExist(err) {
		scriptsSrcDir = "scripts"
	}

	for _, script := range scriptFiles {
		srcPath := filepath.Join(scriptsSrcDir, script)
		dstPath := filepath.Join(scriptsDir, script)
		if _, err := os.Stat(srcPath); err == nil {
			copyFile(srcPath, dstPath)
		}
	}

	// Create config.env for the scripts
	configEnv := generateConfigEnv(config)
	if err := os.WriteFile(filepath.Join(scriptsDir, "config.env"), []byte(configEnv), 0644); err != nil {
		return fmt.Errorf("failed to write config.env: %v", err)
	}

	// Modify grub.cfg to enable autoinstall
	fmt.Println("   Configuring boot loader...")
	modifyGrubConfig("U:\\boot\\grub\\grub.cfg")
	modifyGrubConfig("S:\\boot\\grub\\grub.cfg")

	return nil
}

func generateUserData(config *Config, passwordHash string) string {
	// Build network section
	networkSection := `  network:
    version: 2
    ethernets:
      id0:
        match:
          driver: "*"
        dhcp4: true
        dhcp6: true`

	if config.StaticIP {
		networkSection = fmt.Sprintf(`  network:
    version: 2
    ethernets:
      id0:
        match:
          driver: "*"
        dhcp4: false
        addresses:
          - %s/24
        routes:
          - to: default
            via: %s
        nameservers:
          addresses: [%s]`, config.IPAddress, config.Gateway, config.DNSServers)
	}

	userData := fmt.Sprintf(`#cloud-config
autoinstall:
  version: 1
  storage:
    layout:
      name: lvm
      match:
        size: largest
  locale: %s
  keyboard:
    layout: %s
  identity:
    hostname: %s
    username: %s
    password: %s
  ssh:
    install-server: true
    allow-pw: true
    authorized-keys: []
%s
  timezone: %s
  apt:
    primary:
      - arches: [default]
        uri: http://archive.ubuntu.com/ubuntu
    geoip: true
  packages:
    - linux-firmware
    - intel-microcode
    - amd64-microcode
    - build-essential
    - dkms
    - linux-headers-generic
    - network-manager
    - wpasupplicant
    - ethtool
    - net-tools
    - nvme-cli
    - smartmontools
    - hdparm
    - mdadm
    - lvm2
    - openssh-server
    - curl
    - wget
    - git
    - htop
    - vim
    - tmux
    - unzip
    - lm-sensors
    - i2c-tools
    - thermald
    - powertop
    - alsa-utils
    - alsa-base
    - usbutils
    - pciutils
    - fwupd
  late-commands:
    - cp -r /cdrom/scripts /target/opt/ubuntu-installer-scripts || true
    - chmod +x /target/opt/ubuntu-installer-scripts/*.sh 2>/dev/null || true
    - cp /cdrom/scripts/config.env /target/opt/ubuntu-installer/ 2>/dev/null || true
    - |
      cat > /target/etc/systemd/system/first-boot-setup.service << 'EOFSERVICE'
      [Unit]
      Description=First Boot Setup
      After=network-online.target
      Wants=network-online.target
      ConditionPathExists=/opt/ubuntu-installer-scripts/post-install.sh

      [Service]
      Type=oneshot
      ExecStart=/opt/ubuntu-installer-scripts/post-install.sh
      ExecStartPost=/bin/rm -f /opt/ubuntu-installer-scripts/post-install.sh
      ExecStartPost=/bin/systemctl disable first-boot-setup.service
      RemainAfterExit=yes
      StandardOutput=journal+console
      StandardError=journal+console

      [Install]
      WantedBy=multi-user.target
      EOFSERVICE
    - curtin in-target --target=/target -- systemctl enable first-boot-setup.service
    - curtin in-target --target=/target -- systemctl enable ssh
    - curtin in-target --target=/target -- update-initramfs -u -k all
`,
		config.Locale,
		config.KeyboardLayout,
		config.Hostname,
		config.Username,
		passwordHash,
		networkSection,
		config.Timezone,
	)

	return userData
}

func generateConfigEnv(config *Config) string {
	return fmt.Sprintf(`# Auto-generated configuration
INSTALL_USERNAME=%s
INSTALL_HOSTNAME=%s
TIMEZONE=%s
LOCALE=%s
KEYBOARD_LAYOUT=%s
INSTALL_GUI=%v
SSH_AUTHORIZED_KEYS=%s
STATIC_IP=%v
IP_ADDRESS=%s
NETMASK=%s
GATEWAY=%s
DNS_SERVERS=%s
EXTRA_PACKAGES=%s
AUTO_MOUNT_DRIVES=%v
`,
		config.Username,
		config.Hostname,
		config.Timezone,
		config.Locale,
		config.KeyboardLayout,
		config.InstallGUI,
		config.SSHAuthorizedKey,
		config.StaticIP,
		config.IPAddress,
		config.Netmask,
		config.Gateway,
		config.DNSServers,
		config.ExtraPackages,
		config.AutoMountDrives,
	)
}

func modifyGrubConfig(grubPath string) error {
	content, err := os.ReadFile(grubPath)
	if err != nil {
		return nil // File might not exist
	}

	modified := string(content)

	// Add autoinstall parameter to linux boot line
	re := regexp.MustCompile(`(linux\s+[^\n]+)`)
	modified = re.ReplaceAllStringFunc(modified, func(match string) string {
		if !strings.Contains(match, "autoinstall") {
			return match + " autoinstall ds=nocloud;s=/cdrom/autoinstall/"
		}
		return match
	})

	// Set timeout to 5 seconds for automatic boot
	timeoutRe := regexp.MustCompile(`set timeout=\d+`)
	if timeoutRe.MatchString(modified) {
		modified = timeoutRe.ReplaceAllString(modified, "set timeout=5")
	}

	// Add timeout_style for countdown display
	if !strings.Contains(modified, "timeout_style") {
		modified = strings.Replace(modified, "set timeout=5", "set timeout=5\nset timeout_style=countdown", 1)
	}

	return os.WriteFile(grubPath, []byte(modified), 0644)
}

func copyFile(src, dst string) error {
	sourceFile, err := os.Open(src)
	if err != nil {
		return err
	}
	defer sourceFile.Close()

	destFile, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer destFile.Close()

	_, err = io.Copy(destFile, sourceFile)
	return err
}

func promptChoice(prompt, defaultVal string) string {
	fmt.Print(prompt + " [" + defaultVal + "]: ")
	reader := bufio.NewReader(os.Stdin)
	input, _ := reader.ReadString('\n')
	input = strings.TrimSpace(input)
	if input == "" {
		return defaultVal
	}
	return input
}

func promptString(defaultVal string) string {
	reader := bufio.NewReader(os.Stdin)
	input, _ := reader.ReadString('\n')
	input = strings.TrimSpace(input)
	if input == "" {
		return defaultVal
	}
	return input
}

func promptYesNo(prompt string, defaultYes bool) bool {
	reader := bufio.NewReader(os.Stdin)
	input, _ := reader.ReadString('\n')
	input = strings.ToLower(strings.TrimSpace(input))
	if input == "" {
		return defaultYes
	}
	return input == "y" || input == "yes"
}

func sha256Hash(filepath string) (string, error) {
	f, err := os.Open(filepath)
	if err != nil {
		return "", err
	}
	defer f.Close()

	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}

	return hex.EncodeToString(h.Sum(nil)), nil
}
