@echo off
setlocal enabledelayedexpansion

:: ============================================================================
:: Ubuntu Auto Installer USB Creator - Windows Batch Script
:: Creates a bootable Ubuntu USB drive with custom autoinstall configuration
:: ============================================================================

title Ubuntu Auto Installer USB Creator

echo ============================================================
echo     Ubuntu Auto Installer USB Creator
echo     For: HP Elite 8300, HP 800 G1, Lenovo M92p/M72, ASUS Z97, Dell T7910, ASUS ROG Strix
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
:: Temporarily disable delayed expansion to preserve ! in values (e.g. passwords)
:: eol=# skips comment lines without needing delayed expansion for the check
endlocal
for /f "usebackq eol=# tokens=1,* delims==" %%a in (".env") do (
    if not "%%a"=="" set "%%a=%%b"
)
setlocal enabledelayedexpansion

:: Validate required fields
if "%INSTALL_USERNAME%"=="" (
    echo ERROR: INSTALL_USERNAME is not set in .env file.
    echo Please configure INSTALL_USERNAME in your .env file.
    pause
    exit /b 1
)

:: Validate username matches Linux username rules (lowercase, start with letter/underscore, max 32 chars)
:: Use $env: to avoid command injection from untrusted .env values
powershell -Command "if ($env:INSTALL_USERNAME -notmatch '^[a-z_][a-z0-9_-]{0,31}$') { Write-Host 'ERROR: INSTALL_USERNAME must be a valid Linux username (lowercase, letters/digits/hyphens/underscores, max 32 chars)'; exit 1 }"
if errorlevel 1 (
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

:: Validate hostname (RFC 1123: alphanumeric and hyphens, max 63 chars, no leading/trailing hyphen)
:: Use $env: to avoid command injection from untrusted .env values
powershell -Command "if ($env:INSTALL_HOSTNAME -notmatch '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$') { Write-Host 'ERROR: INSTALL_HOSTNAME contains invalid characters (RFC 1123: letters, digits, hyphens only)'; exit 1 }"
if errorlevel 1 (
    pause
    exit /b 1
)

:: Validate LOCALE format (e.g., en_US.UTF-8)
powershell -Command "if ($env:LOCALE -and $env:LOCALE -notmatch '^[a-zA-Z_]+(\.[a-zA-Z0-9_-]+)?$') { Write-Host 'ERROR: LOCALE contains invalid characters'; exit 1 }"
if errorlevel 1 (
    pause
    exit /b 1
)

:: Validate KEYBOARD_LAYOUT format (e.g., us, gb, de)
powershell -Command "if ($env:KEYBOARD_LAYOUT -and $env:KEYBOARD_LAYOUT -notmatch '^[a-z]{2,10}$') { Write-Host 'ERROR: KEYBOARD_LAYOUT must be a lowercase keyboard layout code'; exit 1 }"
if errorlevel 1 (
    pause
    exit /b 1
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

        :: Verify ISO integrity (SHA256 checksum + GPG signature if available)
        echo Verifying ISO integrity...
        :: Download SHA256SUMS checksum file
        set "CHECKSUM_DIR_URL=%ISO_URL%"
        for %%F in ("%ISO_URL%") do set "CHECKSUM_DIR_URL=%%~dpF"
        set "CHECKSUM_DIR_URL=!CHECKSUM_DIR_URL:\=/!"
        powershell -Command "& { $ProgressPreference = 'SilentlyContinue'; try { Invoke-WebRequest -Uri '%ISO_URL%.sha256' -OutFile '%ISO_DIR%\SHA256SUMS' } catch { $base = '%ISO_URL%' -replace '/[^/]+$', '/SHA256SUMS'; Invoke-WebRequest -Uri $base -OutFile '%ISO_DIR%\SHA256SUMS' } }" 2>nul
        if exist "%ISO_DIR%\SHA256SUMS" (
            :: Attempt GPG signature verification (best-effort: warns if GPG unavailable)
            powershell -Command "& { $ProgressPreference = 'SilentlyContinue'; $base = '%ISO_URL%' -replace '/[^/]+$', '/SHA256SUMS.gpg'; try { Invoke-WebRequest -Uri $base -OutFile '%ISO_DIR%\SHA256SUMS.gpg' } catch {} }" 2>nul
            if exist "%ISO_DIR%\SHA256SUMS.gpg" (
                echo Verifying GPG signature on SHA256SUMS...
                :: Check if gpg is available (e.g. via Git for Windows or Gpg4win)
                where gpg >nul 2>&1
                if not errorlevel 1 (
                    :: Import Canonical's Ubuntu CD Image signing key
                    gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 843938DF228D22F7B3742BC0D94AA3F0EFE21092 2>nul
                    gpg --verify "%ISO_DIR%\SHA256SUMS.gpg" "%ISO_DIR%\SHA256SUMS" 2>nul
                    if errorlevel 1 (
                        echo WARNING: GPG signature verification FAILED! SHA256SUMS may have been tampered with.
                        set /p CONTINUE_GPG="Continue anyway? (Y/N): "
                        if /i not "!CONTINUE_GPG!"=="Y" (
                            del "%ISO_PATH%" 2>nul
                            del "%ISO_DIR%\SHA256SUMS" 2>nul
                            del "%ISO_DIR%\SHA256SUMS.gpg" 2>nul
                            pause
                            exit /b 1
                        )
                    ) else (
                        echo GPG signature verified OK - SHA256SUMS is authentic.
                    )
                ) else (
                    echo NOTE: GPG not found - cannot verify SHA256SUMS signature.
                    echo       Install Gpg4win or Git for Windows for full supply chain verification.
                )
                del "%ISO_DIR%\SHA256SUMS.gpg" 2>nul
            ) else (
                echo NOTE: SHA256SUMS.gpg not available - skipping GPG verification.
            )

            :: Verify ISO hash against SHA256SUMS (Trim handles BOM/whitespace from Windows downloads)
            powershell -Command "& { $expected = (Get-Content '%ISO_DIR%\SHA256SUMS' | Select-String '%ISO_NAME%').Line.Split(' ')[0].Trim(); $actual = (Get-FileHash '%ISO_PATH%' -Algorithm SHA256).Hash.Trim(); if ($expected -ieq $actual) { Write-Host 'ISO checksum verified OK' } else { Write-Host ('WARNING: ISO checksum mismatch! Expected: ' + $expected + ' Got: ' + $actual); exit 1 } }"
            if errorlevel 1 (
                echo WARNING: ISO checksum verification failed. The download may be corrupt.
                set /p CONTINUE_ANYWAY="Continue anyway? (Y/N): "
                if /i not "!CONTINUE_ANYWAY!"=="Y" (
                    del "%ISO_PATH%" 2>nul
                    pause
                    exit /b 1
                )
            )
            del "%ISO_DIR%\SHA256SUMS" 2>nul
        ) else (
            echo NOTE: Could not download checksum file - skipping verification.
        )
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
powershell -Command "Get-Disk | Where-Object { $_.BusType -eq 'USB' -or $_.BusType -eq 'SD' } | ForEach-Object { $disk = $_; $letters = (Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue | Get-Volume -ErrorAction SilentlyContinue | Where-Object DriveLetter | ForEach-Object { $_.DriveLetter + ':' }) -join ','; [PSCustomObject]@{ Number = $disk.Number; Letters = if($letters){$letters}else{'(none)'}; FriendlyName = $disk.FriendlyName; 'Size(GB)' = [math]::Round($disk.Size/1GB,2); BusType = $disk.BusType } } | Format-Table Number, Letters, FriendlyName, 'Size(GB)', BusType -AutoSize"

echo.
echo WARNING: All data on the selected drive will be ERASED!
echo.
set /p DISK_NUMBER="Enter disk number to use (or 'q' to quit): "

if /i "%DISK_NUMBER%"=="q" (
    echo Operation cancelled.
    exit /b 0
)

:: Validate disk number is a positive integer
echo !DISK_NUMBER!| findstr /r "^[0-9][0-9]*$" >nul 2>&1
if errorlevel 1 (
    echo ERROR: Invalid disk number. Must be a number.
    goto :select_usb
)

:: Reject disk 0 (typically the system drive)
if "!DISK_NUMBER!"=="0" (
    echo ERROR: Disk 0 is typically the Windows system disk. Cannot continue.
    echo Select a USB drive with a different disk number.
    goto :select_usb
)

:: Validate the selected disk is actually a USB/SD device
for /f "tokens=*" %%b in ('powershell -Command "(Get-Disk -Number %DISK_NUMBER%).BusType"') do set DISK_BUS=%%b
if /i not "!DISK_BUS!"=="USB" if /i not "!DISK_BUS!"=="SD" (
    echo ERROR: Disk %DISK_NUMBER% is not a USB or SD device ^(detected: !DISK_BUS!^).
    echo Only USB and SD drives can be used. Please select a different disk.
    goto :select_usb
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
echo Step 1/6: Cleaning disk and erasing old boot structures...

:: First, release any existing drive letters on this disk to avoid conflicts
powershell -Command "Get-Partition -DiskNumber %DISK_NUMBER% -ErrorAction SilentlyContinue | ForEach-Object { $_ | Remove-PartitionAccessPath -AccessPath \"$($_.DriveLetter):\" -ErrorAction SilentlyContinue }"

:: Find a free drive letter (prefer U, fallback to others)
set USB_LETTER=
for %%L in (U V W X Y Z T S R Q P) do (
    if "!USB_LETTER!"=="" (
        if not exist "%%L:\" (
            set USB_LETTER=%%L
        )
    )
)
if "!USB_LETTER!"=="" (
    echo ERROR: No free drive letters available.
    pause
    exit /b 1
)
echo Using drive letter !USB_LETTER!: for USB

:: Zero out the first 1MB to obliterate any residual boot structures
:: (EFI bootloaders, Windows Boot Manager remnants, old GPT headers)
echo Wiping residual boot sectors...
powershell -Command "& { $drive = '\\.\PhysicalDrive%DISK_NUMBER%'; $fs = [IO.File]::Open($drive, 'Open', 'ReadWrite', 'ReadWrite'); $zeros = New-Object byte[] (1MB); $fs.Write($zeros, 0, $zeros.Length); $fs.Flush(); $fs.Close(); Write-Host 'Boot sectors wiped' }" 2>nul

:: Create diskpart script - use MBR with single FAT32 partition for USB compatibility
:: Note: GPT EFI partitions are not supported on removable media in Windows
(
    echo select disk %DISK_NUMBER%
    echo clean
    echo convert mbr
    echo create partition primary
    echo select partition 1
    echo active
    echo format fs=fat32 label="UBUNTU" quick
    echo assign letter=!USB_LETTER!
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

:: Verify the drive letter was actually assigned
if not exist "!USB_LETTER!:\" (
    echo ERROR: Drive letter !USB_LETTER!: was not assigned. The disk may not have been formatted properly.
    pause
    exit /b 1
)
echo Disk cleaned and formatted successfully.

:: Step 2: Mount ISO and copy contents
echo.
echo Step 2/6: Mounting ISO and extracting contents...

:: Convert relative ISO path to absolute (Mount-DiskImage requires absolute path)
for %%i in ("%ISO_PATH%") do set ISO_FULLPATH=%%~fi

:: Mount the ISO (use $env: to safely handle paths with spaces or special characters)
set "ISO_FULLPATH_ENV=!ISO_FULLPATH!"
for /f "tokens=*" %%i in ('powershell -Command "(Mount-DiskImage -ImagePath $env:ISO_FULLPATH_ENV -PassThru | Get-Volume).DriveLetter"') do set ISO_DRIVE=%%i

if "%ISO_DRIVE%"=="" (
    echo ERROR: Failed to mount ISO.
    powershell -Command "Dismount-DiskImage -ImagePath $env:ISO_FULLPATH_ENV" 2>nul
    pause
    exit /b 1
)

echo ISO mounted on drive %ISO_DRIVE%:

:: Step 3: Copy ISO contents
echo.
echo Step 3/6: Copying ISO contents to USB (this may take several minutes)...

:: Copy all ISO contents to USB (single partition handles both UEFI and legacy boot)
robocopy %ISO_DRIVE%:\ !USB_LETTER!:\ /E /NFL /NDL /NJH /NJS /R:3 /W:5

:: Check robocopy exit code (0-7 = success/warning, 8+ = error)
set ROBO_RC=%errorlevel%
if %ROBO_RC% geq 8 (
    echo ERROR: Robocopy failed with exit code %ROBO_RC%. ISO contents may not have copied correctly.
    powershell -Command "Dismount-DiskImage -ImagePath $env:ISO_FULLPATH_ENV" 2>nul
    pause
    exit /b 1
)

:: Check for files that exceeded FAT32 4GB limit (would have been silently skipped by robocopy)
powershell -Command "& { $big = Get-ChildItem '%ISO_DRIVE%:\' -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 4GB }; if ($big) { $big | ForEach-Object { Write-Host ('WARNING: File exceeds FAT32 4GB limit: ' + $_.FullName + ' (' + [math]::Round($_.Length/1GB,2) + ' GB)') }; exit 1 } }"
if errorlevel 1 (
    echo ERROR: Ubuntu ISO contains files larger than 4GB that cannot be stored on FAT32.
    echo Consider using a tool like Rufus with NTFS support or a newer Ubuntu ISO.
    powershell -Command "Dismount-DiskImage -ImagePath $env:ISO_FULLPATH_ENV" 2>nul
    pause
    exit /b 1
)

:: Unmount ISO
powershell -Command "Dismount-DiskImage -ImagePath $env:ISO_FULLPATH_ENV"

:: Step 4: Create autoinstall configuration
echo.
echo Step 4/6: Creating autoinstall configuration...

if not exist "!USB_LETTER!:\autoinstall" mkdir "!USB_LETTER!:\autoinstall"

:: Generate proper crypt(3) SHA-512 password hash
:: Password is read directly via $env:INSTALL_PASSWORD to avoid delayed expansion
:: stripping ! characters from the password value
:: Note: output is captured via temp file instead of for /f, because for /f strips
:: ; and = from the command string (CMD treats them as token delimiters)
set PASSWORD_HASH=
:: Try Python with passlib first (most reliable, works on all Python versions)
powershell -Command "$pw = $env:INSTALL_PASSWORD; $pw | python -c \"import sys; pw=sys.stdin.readline^(^).strip^(^); from passlib.hash import sha512_crypt; print^(sha512_crypt.using^(rounds=656000^).hash^(pw^)^)\"" > "%TEMP%\pwhash.tmp" 2>nul
if exist "%TEMP%\pwhash.tmp" (
    set /p PASSWORD_HASH=<"%TEMP%\pwhash.tmp"
    del "%TEMP%\pwhash.tmp" 2>nul
)
:: Try Python crypt module (available in Python 3.12 and below, removed in 3.13)
if "!PASSWORD_HASH!"=="" (
    powershell -Command "$pw = $env:INSTALL_PASSWORD; $pw | python -c \"import sys,crypt; pw=sys.stdin.readline^(^).strip^(^); print^(crypt.crypt^(pw,crypt.mksalt^(crypt.METHOD_SHA512^)^)^)\"" > "%TEMP%\pwhash.tmp" 2>nul
    if exist "%TEMP%\pwhash.tmp" (
        set /p PASSWORD_HASH=<"%TEMP%\pwhash.tmp"
        del "%TEMP%\pwhash.tmp" 2>nul
    )
)
:: Fallback to WSL openssl (password via stdin, tr -d \r strips Windows CRLF)
if "!PASSWORD_HASH!"=="" (
    powershell -Command "$pw = $env:INSTALL_PASSWORD; $pw | wsl bash -c \"tr -d \\r ^| openssl passwd -6 -stdin\"" > "%TEMP%\pwhash.tmp" 2>nul
    if exist "%TEMP%\pwhash.tmp" (
        set /p PASSWORD_HASH=<"%TEMP%\pwhash.tmp"
        del "%TEMP%\pwhash.tmp" 2>nul
    )
)
:: Fallback to WSL mkpasswd
if "!PASSWORD_HASH!"=="" (
    powershell -Command "$pw = $env:INSTALL_PASSWORD; $pw | wsl bash -c \"tr -d \\r ^| mkpasswd --method=SHA-512 --stdin\"" > "%TEMP%\pwhash.tmp" 2>nul
    if exist "%TEMP%\pwhash.tmp" (
        set /p PASSWORD_HASH=<"%TEMP%\pwhash.tmp"
        del "%TEMP%\pwhash.tmp" 2>nul
    )
)
:: Error if none worked
if "!PASSWORD_HASH!"=="" (
    echo ERROR: Could not generate password hash.
    echo Please install Python 3 with passlib, or enable WSL with openssl.
    pause
    exit /b 1
)
:: Clear plaintext password from environment (hash is the only value needed from here)
set "INSTALL_PASSWORD="

:: Apply defaults for optional template variables not defined in .env
if "!LOCALE!"=="" set "LOCALE=en_US.UTF-8"
if "!KEYBOARD_LAYOUT!"=="" set "KEYBOARD_LAYOUT=us"
if "!TIMEZONE!"=="" set "TIMEZONE=America/New_York"

:: Create user-data file by copying template and substituting variables
if not exist "autoinstall\user-data" (
    echo ERROR: autoinstall\user-data template not found!
    echo Please ensure the autoinstall directory exists with user-data file.
    pause
    exit /b 1
)
:: Copy the template from autoinstall directory
copy "autoinstall\user-data" "!USB_LETTER!:\autoinstall\user-data" >nul

:: Substitute variables in user-data using a temporary PowerShell script
:: Script file avoids cmd.exe command-line parsing issues with long inline PowerShell
:: All values read via $env: to avoid delayed expansion corrupting ! and $ characters
>"%TEMP%\subst-vars.ps1" echo $ErrorActionPreference = 'Stop'
>>"%TEMP%\subst-vars.ps1" echo $file = $args[0]
>>"%TEMP%\subst-vars.ps1" echo $c = Get-Content $file -Raw
>>"%TEMP%\subst-vars.ps1" echo $c = $c -replace '\$\{LOCALE:-[^^}]+\}', $env:LOCALE
>>"%TEMP%\subst-vars.ps1" echo $c = $c -replace '\$\{KEYBOARD_LAYOUT:-[^^}]+\}', $env:KEYBOARD_LAYOUT
>>"%TEMP%\subst-vars.ps1" echo $c = $c -replace '\$\{INSTALL_HOSTNAME:-[^^}]+\}', $env:INSTALL_HOSTNAME
>>"%TEMP%\subst-vars.ps1" echo $c = $c -replace '\$\{INSTALL_USERNAME:-[^^}]+\}', $env:INSTALL_USERNAME
>>"%TEMP%\subst-vars.ps1" echo $c = $c.Replace('${PASSWORD_HASH}', $env:PASSWORD_HASH)
>>"%TEMP%\subst-vars.ps1" echo $c = $c -replace '\$\{TIMEZONE:-[^^}]+\}', $env:TIMEZONE
>>"%TEMP%\subst-vars.ps1" echo [System.IO.File]::WriteAllText($file, $c)
>>"%TEMP%\subst-vars.ps1" echo $verify = [System.IO.File]::ReadAllText($file)
>>"%TEMP%\subst-vars.ps1" echo if ($verify -match '\$\{[A-Z_]+') { $m = [regex]::Matches($verify, '\$\{[A-Z_]+[^^}]*\}'); foreach ($x in $m) { Write-Host ('  Unsubstituted: ' + $x.Value) }; exit 1 }
powershell -ExecutionPolicy Bypass -File "%TEMP%\subst-vars.ps1" "!USB_LETTER!:\autoinstall\user-data"
if errorlevel 1 (
    echo ERROR: user-data still contains unsubstituted template variables.
    echo Please verify your .env file contains all required settings.
    del "%TEMP%\subst-vars.ps1" 2>nul
    pause
    exit /b 1
)
del "%TEMP%\subst-vars.ps1" 2>nul
echo User-data template copied and configured.

:: Generate unique instance-id per USB creation
for /f "tokens=*" %%i in ('powershell -Command "[System.Guid]::NewGuid().ToString()"') do set INSTANCE_ID=%%i

:: Create meta-data file
if exist "autoinstall\meta-data" (
    copy "autoinstall\meta-data" "!USB_LETTER!:\autoinstall\meta-data" >nul
    powershell -Command "$content = Get-Content '!USB_LETTER!:\autoinstall\meta-data' -Raw; $content = $content -replace 'instance-id:.*', 'instance-id: %INSTANCE_ID%'; $content = $content -replace 'local-hostname:.*', 'local-hostname: %INSTALL_HOSTNAME%'; [System.IO.File]::WriteAllText('!USB_LETTER!:\autoinstall\meta-data', $content)"
) else (
    echo instance-id: %INSTANCE_ID%> "!USB_LETTER!:\autoinstall\meta-data"
    echo local-hostname: %INSTALL_HOSTNAME%>> "!USB_LETTER!:\autoinstall\meta-data"
)

:: Step 5: Copy scripts
echo.
echo Step 5/6: Copying installation scripts...

if not exist "!USB_LETTER!:\scripts" mkdir "!USB_LETTER!:\scripts"

:: Copy all scripts if they exist
if exist "scripts\install-drivers.sh" copy "scripts\install-drivers.sh" "!USB_LETTER!:\scripts\" >nul
if exist "scripts\post-install.sh" copy "scripts\post-install.sh" "!USB_LETTER!:\scripts\" >nul
if exist "scripts\mount-drives.sh" copy "scripts\mount-drives.sh" "!USB_LETTER!:\scripts\" >nul
if exist "scripts\install-gui.sh" copy "scripts\install-gui.sh" "!USB_LETTER!:\scripts\" >nul
if exist "scripts\configure-drives.sh" copy "scripts\configure-drives.sh" "!USB_LETTER!:\scripts\" >nul
if exist "scripts\install-optional-features.sh" copy "scripts\install-optional-features.sh" "!USB_LETTER!:\scripts\" >nul
if exist "scripts\early-setup.sh" copy "scripts\early-setup.sh" "!USB_LETTER!:\scripts\" >nul

:: Convert Windows CRLF line endings to Unix LF for all shell scripts and YAML files
:: This is critical - CRLF causes "bad interpreter" errors on Linux
echo Converting line endings to Unix format...
powershell -Command "Get-ChildItem '!USB_LETTER!:\scripts\*.sh' -ErrorAction SilentlyContinue | ForEach-Object { $c = [System.IO.File]::ReadAllText($_.FullName); $c = $c -replace \"`r`n\", \"`n\"; [System.IO.File]::WriteAllText($_.FullName, $c, (New-Object System.Text.UTF8Encoding $false)) }"
powershell -Command "if (Test-Path '!USB_LETTER!:\autoinstall\user-data') { $c = [System.IO.File]::ReadAllText('!USB_LETTER!:\autoinstall\user-data'); $c = $c -replace \"`r`n\", \"`n\"; [System.IO.File]::WriteAllText('!USB_LETTER!:\autoinstall\user-data', $c, (New-Object System.Text.UTF8Encoding $false)) }"
if exist "!USB_LETTER!:\autoinstall\meta-data" (
    powershell -Command "$c = [System.IO.File]::ReadAllText('!USB_LETTER!:\autoinstall\meta-data'); $c = $c -replace \"`r`n\", \"`n\"; [System.IO.File]::WriteAllText('!USB_LETTER!:\autoinstall\meta-data', $c, (New-Object System.Text.UTF8Encoding $false))"
)

:: Create config.env with all settings for unattended operation
:: NOTE: config.env is generated below by Windows echo commands which produce CRLF.
:: It MUST be converted to LF after creation (see conversion step below).
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
    echo NETMASK=%CIDR_PREFIX%
    echo GATEWAY=%GATEWAY%
    echo DNS_SERVERS=%DNS_SERVERS%
    echo EXTRA_PACKAGES=%EXTRA_PACKAGES%
    echo LAN_CIDR=%LAN_CIDR%
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
    echo RTC_WAKE_TIME=%RTC_WAKE_TIME%
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
) > "!USB_LETTER!:\scripts\config.env"

:: Convert config.env CRLF to LF (critical: CRLF causes trailing \r in values,
:: breaking all config checks like [ "$VAR" = "true" ] on Linux)
powershell -Command "$c = [System.IO.File]::ReadAllText('!USB_LETTER!:\scripts\config.env'); $c = $c -replace \"`r`n\", \"`n\"; [System.IO.File]::WriteAllText('!USB_LETTER!:\scripts\config.env', $c, (New-Object System.Text.UTF8Encoding $false))"

:: Modify grub.cfg to add autoinstall and set timeout for automatic boot
echo Configuring boot loader for automatic installation...
if exist "!USB_LETTER!:\boot\grub\grub.cfg" (
    attrib -r "!USB_LETTER!:\boot\grub\grub.cfg" 2>nul

    :: Use PowerShell to modify grub.cfg with proper escaping
    :: Add autoinstall parameters and console output for debugging
    :: Parameters: autoinstall, console=tty0 only (serial console configured per-platform by install-drivers.sh)
    powershell -Command "$grub = Get-Content '!USB_LETTER!:\boot\grub\grub.cfg' -Raw; if ($grub -notmatch 'autoinstall') { $grub = $grub -replace '(linux\s+/casper/vmlinuz[^\r\n]*)', '$1 autoinstall ds=nocloud\;s=/cdrom/autoinstall/ console=tty0 fsck.repair=preen' }; $grub = $grub -replace 'set timeout=\d+', 'set timeout=10'; if ($grub -notmatch 'timeout_style') { $grub = $grub -replace '(set timeout=\d+)', \"`$1`nset timeout_style=menu\" }; [System.IO.File]::WriteAllText('!USB_LETTER!:\boot\grub\grub.cfg', $grub)"

    :: Add a fallback safe mode menu entry with nomodeset for problematic graphics
    powershell -Command "$grub = Get-Content '!USB_LETTER!:\boot\grub\grub.cfg' -Raw; if ($grub -notmatch 'Safe Mode') { $safeEntry = [char]10 + 'menuentry ''Ubuntu Server - Safe Mode - nomodeset'' {' + [char]10 + [char]9 + 'linux /casper/vmlinuz autoinstall ds=nocloud\;s=/cdrom/autoinstall/ console=tty0 nomodeset fsck.repair=preen ---' + [char]10 + [char]9 + 'initrd /casper/initrd' + [char]10 + '}' + [char]10; $grub = $grub + $safeEntry }; [System.IO.File]::WriteAllText('!USB_LETTER!:\boot\grub\grub.cfg', $grub)"

    :: Verify autoinstall was injected into grub.cfg
    powershell -Command "if ((Get-Content '!USB_LETTER!:\boot\grub\grub.cfg' -Raw) -notmatch 'autoinstall') { Write-Host 'ERROR: autoinstall not found in grub.cfg - GRUB patching failed!'; exit 1 }"
    if errorlevel 1 (
        echo ERROR: Failed to inject autoinstall into GRUB configuration.
        pause
        exit /b 1
    )

    echo GRUB configuration updated for autoinstall with console logging.
) else (
    echo WARNING: grub.cfg not found on USB - ISO contents may not have copied correctly!
)

:: Also check for loopback.cfg which some Ubuntu ISOs use
if exist "!USB_LETTER!:\boot\grub\loopback.cfg" (
    attrib -r "!USB_LETTER!:\boot\grub\loopback.cfg" 2>nul
    powershell -Command "$grub = Get-Content '!USB_LETTER!:\boot\grub\loopback.cfg' -Raw; if ($grub -notmatch 'autoinstall') { $grub = $grub -replace '(linux\s+/casper/vmlinuz[^\r\n]*)', '$1 autoinstall ds=nocloud\;s=/cdrom/autoinstall/ console=tty0' }; [System.IO.File]::WriteAllText('!USB_LETTER!:\boot\grub\loopback.cfg', $grub)"
)

:: Convert grub.cfg line endings to Unix LF (GRUB can have issues with mixed CRLF/LF)
if exist "!USB_LETTER!:\boot\grub\grub.cfg" (
    powershell -Command "$c = [System.IO.File]::ReadAllText('!USB_LETTER!:\boot\grub\grub.cfg'); $c = $c -replace \"`r`n\", \"`n\"; [System.IO.File]::WriteAllText('!USB_LETTER!:\boot\grub\grub.cfg', $c, (New-Object System.Text.UTF8Encoding $false))"
)
if exist "!USB_LETTER!:\boot\grub\loopback.cfg" (
    powershell -Command "$c = [System.IO.File]::ReadAllText('!USB_LETTER!:\boot\grub\loopback.cfg'); $c = $c -replace \"`r`n\", \"`n\"; [System.IO.File]::WriteAllText('!USB_LETTER!:\boot\grub\loopback.cfg', $c, (New-Object System.Text.UTF8Encoding $false))"
)

:: Step 6: Verify USB contents
echo.
echo Step 6/6: Verifying USB boot files...

set VERIFY_PASS=true

:: Check for critical Ubuntu boot files
if not exist "!USB_LETTER!:\EFI\BOOT\BOOTx64.EFI" (
    echo WARNING: EFI bootloader not found - UEFI boot may not work!
    set VERIFY_PASS=false
)
if not exist "!USB_LETTER!:\boot\grub\grub.cfg" (
    echo WARNING: GRUB config not found - boot may not work!
    set VERIFY_PASS=false
)
if not exist "!USB_LETTER!:\casper\vmlinuz" (
    echo WARNING: Linux kernel not found - ISO may not have copied correctly!
    set VERIFY_PASS=false
)
if not exist "!USB_LETTER!:\casper\initrd" (
    echo WARNING: initrd not found - ISO may not have copied correctly!
    set VERIFY_PASS=false
)
if not exist "!USB_LETTER!:\autoinstall\user-data" (
    echo WARNING: autoinstall user-data not found!
    set VERIFY_PASS=false
)

:: Check that NO Windows boot files exist (should have been wiped)
if exist "!USB_LETTER!:\EFI\Microsoft" (
    echo WARNING: Windows EFI boot files detected on USB - removing...
    rmdir /s /q "!USB_LETTER!:\EFI\Microsoft" 2>nul
)
if exist "!USB_LETTER!:\sources\install.wim" (
    echo ERROR: Windows installation files found on USB! The drive was not properly wiped.
    echo Please try again with a different USB drive.
    set VERIFY_PASS=false
)

if "!VERIFY_PASS!"=="true" (
    echo All boot files verified successfully.
) else (
    echo.
    echo WARNING: Some verification checks failed. The USB may not boot correctly.
    echo Consider trying again or using a different USB drive.
)

echo.
echo ============================================================
echo USB drive created on !USB_LETTER!:
echo ============================================================
echo.
echo FULLY AUTOMATED INSTALLATION - No user interaction required!
echo.
echo IMPORTANT - Before installing, verify BIOS settings:
echo   - Boot mode must be set to UEFI (not Legacy/CSM)
echo   - Secure Boot must be DISABLED
echo   - HP: F10, Lenovo: F1, Dell: F2, ASUS: Del for BIOS setup
echo.
echo Next steps:
echo   1. Safely eject the USB drive
echo   2. Insert into target computer
echo   3. Boot from USB (usually F12, F2, or Del at startup)
echo   4. Installation will proceed automatically on the smallest SSD
echo   5. System will reboot and complete post-installation setup
echo.
echo The installation will:
echo   - Auto-select the smallest SSD (ignores HDDs)
echo   - Install Ubuntu with your configured settings
echo   - Run post-install scripts on first boot
echo   - Install configured optional features
echo.
echo NOTE: FAT32 USB drives are limited to 32GB by Windows formatting.
echo   For larger drives, use a third-party tool to format as FAT32 first.
echo.
echo Supported hardware:
echo   - HP Elite 8300
echo   - HP EliteDesk 800 G1 SFF
echo   - Lenovo ThinkCentre M92p
echo   - Lenovo ThinkCentre M72
echo   - ASUS Z97 motherboards
echo   - Dell Precision T7910
echo   - ASUS Hyper M.2 x16 Card V2
echo   - ASUS ROG Strix laptops (G733QS, etc.)
echo.

pause
