@echo off
setlocal enabledelayedexpansion

:: ============================================================================
:: Ubuntu Auto Installer USB Creator - Windows Batch Script
:: Creates a bootable Ubuntu USB drive with custom autoinstall configuration
:: ============================================================================

title Ubuntu Auto Installer USB Creator

echo ============================================================
echo     Ubuntu Auto Installer USB Creator
echo     For: HP Elite 8300, Lenovo M92p/M72, ASUS Z97
echo ============================================================
echo.

:: Check for admin privileges
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: This script requires Administrator privileges.
    echo Please right-click and select "Run as administrator"
    pause
    exit /b 1
)

:: Set working directory to script location
cd /d "%~dp0"

:: Load configuration from .env file
if not exist ".env" (
    echo ERROR: .env file not found.
    echo Please copy .env.sample to .env and configure it with your username and password.
    pause
    exit /b 1
)

echo Loading configuration from .env file...
for /f "usebackq tokens=1,* delims==" %%a in (".env") do (
    set "line=%%a"
    if not "!line:~0,1!"=="#" (
        if not "%%a"=="" (
            set "%%a=%%b"
        )
    )
)

:: Validate required fields
if "%INSTALL_USERNAME%"=="" (
    echo ERROR: INSTALL_USERNAME is not set in .env file.
    echo Please configure INSTALL_USERNAME in your .env file.
    pause
    exit /b 1
)

if "%INSTALL_PASSWORD%"=="" (
    echo ERROR: INSTALL_PASSWORD is not set in .env file.
    echo Please configure INSTALL_PASSWORD in your .env file.
    pause
    exit /b 1
)

:: Generate random hostname if set to "random" or empty
if "%INSTALL_HOSTNAME%"=="random" (
    for /f "tokens=*" %%h in ('powershell -Command "[System.Guid]::NewGuid().ToString().Substring(0,6)"') do set INSTALL_HOSTNAME=ubuntu-%%h
)
if "%INSTALL_HOSTNAME%"=="" (
    for /f "tokens=*" %%h in ('powershell -Command "[System.Guid]::NewGuid().ToString().Substring(0,6)"') do set INSTALL_HOSTNAME=ubuntu-%%h
)

echo.
echo Configuration loaded:
echo   Username:    %INSTALL_USERNAME%
echo   Hostname:    %INSTALL_HOSTNAME%
echo   Timezone:    %TIMEZONE%
echo   Install GUI: %INSTALL_GUI%
echo.

:: Check for Ubuntu ISO
set ISO_DIR=downloads
set ISO_NAME=ubuntu-24.04.1-live-server-amd64.iso
set ISO_URL=https://releases.ubuntu.com/24.04/ubuntu-24.04.1-live-server-amd64.iso

if not exist "%ISO_DIR%" mkdir "%ISO_DIR%"

echo Select Ubuntu version:
echo   1. Ubuntu 24.04 LTS (Noble Numbat) - Recommended
echo   2. Ubuntu 22.04 LTS (Jammy Jellyfish)
echo   3. Use existing ISO file
echo.
set /p UBUNTU_CHOICE="Enter choice (1-3): "

if "%UBUNTU_CHOICE%"=="2" (
    set ISO_NAME=ubuntu-22.04.5-live-server-amd64.iso
    set ISO_URL=https://releases.ubuntu.com/22.04/ubuntu-22.04.5-live-server-amd64.iso
)

if "%UBUNTU_CHOICE%"=="3" (
    set /p ISO_PATH="Enter full path to Ubuntu ISO: "
    if not exist "!ISO_PATH!" (
        echo ERROR: ISO file not found: !ISO_PATH!
        pause
        exit /b 1
    )
    goto :select_usb
)

set ISO_PATH=%ISO_DIR%\%ISO_NAME%

if not exist "%ISO_PATH%" (
    echo.
    echo ISO not found. Download %ISO_NAME%?
    set /p DOWNLOAD_CHOICE="Download? (Y/N): "
    if /i "!DOWNLOAD_CHOICE!"=="Y" (
        echo.
        echo Downloading Ubuntu ISO...
        echo This may take a while depending on your internet speed.
        echo URL: %ISO_URL%
        echo.

        :: Try PowerShell download
        powershell -Command "& { $ProgressPreference = 'SilentlyContinue'; Invoke-WebRequest -Uri '%ISO_URL%' -OutFile '%ISO_PATH%' }"

        if not exist "%ISO_PATH%" (
            echo ERROR: Download failed.
            echo Please download manually from: %ISO_URL%
            echo And place it in: %ISO_DIR%\
            pause
            exit /b 1
        )
        echo Download complete!
    ) else (
        echo Please provide the ISO path or download it first.
        pause
        exit /b 1
    )
) else (
    echo Found existing ISO: %ISO_PATH%
)

:select_usb
echo.
echo ============================================================
echo Scanning for USB drives...
echo ============================================================
echo.

:: List available USB drives using PowerShell (with drive letters)
powershell -Command "Get-Disk | Where-Object { $_.BusType -eq 'USB' -or ($_.Size -lt 256GB -and $_.BusType -ne 'NVMe' -and $_.OperationalStatus -eq 'Online') } | ForEach-Object { $disk = $_; $letters = (Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue | Get-Volume -ErrorAction SilentlyContinue | Where-Object DriveLetter | ForEach-Object { $_.DriveLetter + ':' }) -join ','; [PSCustomObject]@{ Number = $disk.Number; Letters = if($letters){$letters}else{'(none)'}; FriendlyName = $disk.FriendlyName; 'Size(GB)' = [math]::Round($disk.Size/1GB,2); BusType = $disk.BusType } } | Format-Table Number, Letters, FriendlyName, 'Size(GB)', BusType -AutoSize"

echo.
echo WARNING: All data on the selected drive will be ERASED!
echo.
set /p DISK_NUMBER="Enter disk number to use (or 'q' to quit): "

if /i "%DISK_NUMBER%"=="q" (
    echo Operation cancelled.
    exit /b 0
)

:: Confirm selection
echo.
echo You selected Disk %DISK_NUMBER%.
echo.
powershell -Command "Get-Disk -Number %DISK_NUMBER% | Format-List FriendlyName, Size, BusType"

echo.
echo WARNING: ALL DATA ON THIS DISK WILL BE PERMANENTLY ERASED!
set /p CONFIRM="Type YES to confirm: "

if not "%CONFIRM%"=="YES" (
    echo Operation cancelled.
    exit /b 0
)

echo.
echo ============================================================
echo Creating bootable USB drive...
echo ============================================================

:: Step 1: Clean and partition the disk
echo.
echo Step 1/5: Cleaning disk...

:: Create diskpart script - use MBR with single FAT32 partition for USB compatibility
:: Note: GPT EFI partitions are not supported on removable media in Windows
(
    echo select disk %DISK_NUMBER%
    echo clean
    echo convert mbr
    echo create partition primary
    echo select partition 1
    echo active
    echo format quick fs=fat32 label="UBUNTU"
    echo assign letter=U
    echo exit
) > "%TEMP%\diskpart_script.txt"

diskpart /s "%TEMP%\diskpart_script.txt"

if %errorlevel% neq 0 (
    echo ERROR: Failed to partition disk.
    del "%TEMP%\diskpart_script.txt"
    pause
    exit /b 1
)
del "%TEMP%\diskpart_script.txt"

:: Step 2: Mount ISO and copy contents
echo.
echo Step 2/5: Mounting ISO and extracting contents...

:: Convert relative ISO path to absolute (Mount-DiskImage requires absolute path)
for %%i in ("%ISO_PATH%") do set ISO_FULLPATH=%%~fi

:: Mount the ISO
for /f "tokens=*" %%i in ('powershell -Command "(Mount-DiskImage -ImagePath '!ISO_FULLPATH!' -PassThru | Get-Volume).DriveLetter"') do set ISO_DRIVE=%%i

if "%ISO_DRIVE%"=="" (
    echo ERROR: Failed to mount ISO.
    pause
    exit /b 1
)

echo ISO mounted on drive %ISO_DRIVE%:

:: Step 3: Copy ISO contents
echo.
echo Step 3/5: Copying ISO contents to USB (this may take several minutes)...

:: Copy all ISO contents to USB (single partition handles both UEFI and legacy boot)
robocopy %ISO_DRIVE%:\ U:\ /E /NFL /NDL /NJH /NJS /R:3 /W:5

:: Unmount ISO
powershell -Command "Dismount-DiskImage -ImagePath '!ISO_FULLPATH!'"

:: Step 4: Create autoinstall configuration
echo.
echo Step 4/5: Creating autoinstall configuration...

if not exist "U:\autoinstall" mkdir "U:\autoinstall"

:: Generate password hash using PowerShell
for /f "tokens=*" %%h in ('powershell -Command "$password = '%INSTALL_PASSWORD%'; $bytes = [System.Text.Encoding]::UTF8.GetBytes($password); $sha512 = [System.Security.Cryptography.SHA512]::Create(); $hash = $sha512.ComputeHash($bytes); '$6$rounds=4096$randomsalt$' + [Convert]::ToBase64String($hash)"') do set PASSWORD_HASH=%%h

:: Create user-data file by copying template and substituting variables
:: Copy the template from autoinstall directory
if exist "autoinstall\user-data" (
    copy "autoinstall\user-data" "U:\autoinstall\user-data" >nul

    :: Substitute variables in user-data using PowerShell
    powershell -Command "$content = Get-Content 'U:\autoinstall\user-data' -Raw; $content = $content -replace '\$\{LOCALE:-[^}]+\}', '%LOCALE%'; $content = $content -replace '\$\{KEYBOARD_LAYOUT:-[^}]+\}', '%KEYBOARD_LAYOUT%'; $content = $content -replace '\$\{INSTALL_HOSTNAME:-[^}]+\}', '%INSTALL_HOSTNAME%'; $content = $content -replace '\$\{INSTALL_USERNAME:-[^}]+\}', '%INSTALL_USERNAME%'; $content = $content -replace '\$\{PASSWORD_HASH\}', '%PASSWORD_HASH%'; $content = $content -replace '\$\{TIMEZONE:-[^}]+\}', '%TIMEZONE%'; [System.IO.File]::WriteAllText('U:\autoinstall\user-data', $content)"

    echo User-data template copied and configured.
) else (
    echo ERROR: autoinstall\user-data template not found!
    echo Please ensure the autoinstall directory exists with user-data file.
    pause
    exit /b 1
)

:: Create meta-data file
if exist "autoinstall\meta-data" (
    copy "autoinstall\meta-data" "U:\autoinstall\meta-data" >nul
    powershell -Command "$content = Get-Content 'U:\autoinstall\meta-data' -Raw; $content = $content -replace 'local-hostname:.*', 'local-hostname: %INSTALL_HOSTNAME%'; [System.IO.File]::WriteAllText('U:\autoinstall\meta-data', $content)"
) else (
    echo instance-id: ubuntu-autoinstall> "U:\autoinstall\meta-data"
    echo local-hostname: %INSTALL_HOSTNAME%>> "U:\autoinstall\meta-data"
)

:: Step 5: Copy scripts
echo.
echo Step 5/5: Copying installation scripts...

if not exist "U:\scripts" mkdir "U:\scripts"

:: Copy all scripts if they exist
if exist "scripts\install-drivers.sh" copy "scripts\install-drivers.sh" "U:\scripts\" >nul
if exist "scripts\post-install.sh" copy "scripts\post-install.sh" "U:\scripts\" >nul
if exist "scripts\mount-drives.sh" copy "scripts\mount-drives.sh" "U:\scripts\" >nul
if exist "scripts\install-gui.sh" copy "scripts\install-gui.sh" "U:\scripts\" >nul
if exist "scripts\configure-drives.sh" copy "scripts\configure-drives.sh" "U:\scripts\" >nul
if exist "scripts\install-optional-features.sh" copy "scripts\install-optional-features.sh" "U:\scripts\" >nul

:: Create config.env with all settings for unattended operation
(
    echo INSTALL_USERNAME=%INSTALL_USERNAME%
    echo INSTALL_HOSTNAME=%INSTALL_HOSTNAME%
    echo TIMEZONE=%TIMEZONE%
    echo LOCALE=%LOCALE%
    echo KEYBOARD_LAYOUT=%KEYBOARD_LAYOUT%
    echo INSTALL_GUI=%INSTALL_GUI%
    echo SSH_AUTHORIZED_KEYS=%SSH_AUTHORIZED_KEYS%
    echo STATIC_IP=%STATIC_IP%
    echo IP_ADDRESS=%IP_ADDRESS%
    echo NETMASK=%NETMASK%
    echo GATEWAY=%GATEWAY%
    echo DNS_SERVERS=%DNS_SERVERS%
    echo EXTRA_PACKAGES=%EXTRA_PACKAGES%
    echo AUTO_MOUNT_DRIVES=%AUTO_MOUNT_DRIVES%
    echo INTERACTIVE_DRIVE_CONFIG=false
    echo SHOW_OPTIONAL_MENU=false
    echo UNATTENDED=true
    echo # Optional features
    echo INSTALL_DOCKER=%INSTALL_DOCKER%
    echo INSTALL_PORTAINER=%INSTALL_PORTAINER%
    echo INSTALL_COCKPIT=%INSTALL_COCKPIT%
    echo INSTALL_WEBMIN=%INSTALL_WEBMIN%
    echo INSTALL_TAILSCALE=%INSTALL_TAILSCALE%
    echo INSTALL_ZEROTIER=%INSTALL_ZEROTIER%
    echo ENABLE_WAKE_ON_LAN=%ENABLE_WAKE_ON_LAN%
    echo INSTALL_FAIL2BAN=%INSTALL_FAIL2BAN%
    echo CONFIGURE_UFW=%CONFIGURE_UFW%
    echo HARDEN_SSH=%HARDEN_SSH%
    echo ENABLE_AUTO_UPDATES=%ENABLE_AUTO_UPDATES%
    echo INSTALL_SAMBA=%INSTALL_SAMBA%
    echo SAMBA_SHARE_PATH=%SAMBA_SHARE_PATH%
    echo INSTALL_NFS=%INSTALL_NFS%
    echo NFS_EXPORT_PATH=%NFS_EXPORT_PATH%
    echo NFS_ALLOWED_NETWORK=%NFS_ALLOWED_NETWORK%
    echo INSTALL_PROMETHEUS=%INSTALL_PROMETHEUS%
    echo INSTALL_NODE_EXPORTER=%INSTALL_NODE_EXPORTER%
    echo INSTALL_GRAFANA=%INSTALL_GRAFANA%
    echo INSTALL_SIGNOZ=%INSTALL_SIGNOZ%
    echo INSTALL_OTEL_COLLECTOR=%INSTALL_OTEL_COLLECTOR%
    echo OTEL_ENDPOINT=%OTEL_ENDPOINT%
    echo INSTALL_ANSIBLE=%INSTALL_ANSIBLE%
    echo CONFIGURE_SWAP=%CONFIGURE_SWAP%
    echo SWAP_SIZE_GB=%SWAP_SIZE_GB%
    echo CONFIGURE_NTP=%CONFIGURE_NTP%
    echo INSTALL_COMMON_TOOLS=%INSTALL_COMMON_TOOLS%
    echo INSTALL_DEV_TOOLS=%INSTALL_DEV_TOOLS%
    echo GO_VERSION=%GO_VERSION%
    echo # Notifications
    echo WEBHOOK_URL=%WEBHOOK_URL%
) > "U:\scripts\config.env"

:: Modify grub.cfg to add autoinstall and set timeout for automatic boot
echo Configuring boot loader for automatic installation...
if exist "U:\boot\grub\grub.cfg" (
    attrib -r "U:\boot\grub\grub.cfg"

    :: Use PowerShell to modify grub.cfg with proper escaping
    :: Add autoinstall parameters and console output for debugging
    :: Parameters: autoinstall, console logging (tty + serial), fsck repair
    powershell -Command "$grub = Get-Content 'U:\boot\grub\grub.cfg' -Raw; if ($grub -notmatch 'autoinstall') { $grub = $grub -replace '(linux\s+/casper/vmlinuz[^\r\n]*)', '$1 autoinstall ds=nocloud\;s=/cdrom/autoinstall/ console=tty0 console=ttyS0,115200n8 fsck.mode=force fsck.repair=yes' }; $grub = $grub -replace 'set timeout=\d+', 'set timeout=10'; if ($grub -notmatch 'timeout_style') { $grub = $grub -replace '(set timeout=\d+)', \"`$1`nset timeout_style=menu\" }; [System.IO.File]::WriteAllText('U:\boot\grub\grub.cfg', $grub)"

    :: Add a fallback safe mode menu entry with nomodeset for problematic graphics
    powershell -Command "$grub = Get-Content 'U:\boot\grub\grub.cfg' -Raw; if ($grub -notmatch 'Safe Mode') { $safeEntry = \"`nmenuentry 'Ubuntu Server (Safe Mode - nomodeset)' {`n`tlinux /casper/vmlinuz autoinstall ds=nocloud;s=/cdrom/autoinstall/ console=tty0 nomodeset fsck.mode=force fsck.repair=yes ---`n`tinitrd /casper/initrd`n}`n\"; $grub = $grub + $safeEntry }; [System.IO.File]::WriteAllText('U:\boot\grub\grub.cfg', $grub)"

    echo GRUB configuration updated for autoinstall with console logging.
)

:: Also check for loopback.cfg which some Ubuntu ISOs use
if exist "U:\boot\grub\loopback.cfg" (
    attrib -r "U:\boot\grub\loopback.cfg"
    powershell -Command "$grub = Get-Content 'U:\boot\grub\loopback.cfg' -Raw; if ($grub -notmatch 'autoinstall') { $grub = $grub -replace '(linux\s+/casper/vmlinuz[^\r\n]*)', '$1 autoinstall ds=nocloud\;s=/cdrom/autoinstall/ console=tty0 console=ttyS0,115200n8' }; [System.IO.File]::WriteAllText('U:\boot\grub\loopback.cfg', $grub)"
)

echo.
echo ============================================================
echo USB drive created successfully!
echo ============================================================
echo.
echo FULLY AUTOMATED INSTALLATION - No user interaction required!
echo.
echo Next steps:
echo   1. Safely eject the USB drive
echo   2. Insert into target computer
echo   3. Boot from USB (usually F12, F2, or Del at startup)
echo   4. Installation will proceed automatically on the largest disk
echo   5. System will reboot and complete post-installation setup
echo.
echo The installation will:
echo   - Auto-select the smallest SSD (ignores HDDs)
echo   - Install Ubuntu with your configured settings
echo   - Run post-install scripts on first boot
echo   - Install configured optional features
echo.
echo Supported hardware:
echo   - HP Elite 8300
echo   - Lenovo ThinkCentre M92p
echo   - Lenovo ThinkCentre M72
echo   - ASUS Z97 motherboards
echo   - ASUS Hyper M.2 x16 Card V2
echo.

pause
