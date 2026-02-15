#!/bin/bash
# Early setup script - runs in the Ubuntu live installer environment before installation
# Called from autoinstall early-commands to avoid YAML multi-line block parsing issues
set -e

# Log installation start time
echo "=== Ubuntu Auto-Install Started: $(date) ===" | tee /run/install-start.log

# Check Secure Boot status (informational - warns if enabled)
if command -v mokutil >/dev/null 2>&1; then
    SB_STATE=$(mokutil --sb-state 2>/dev/null || echo "unknown")
    echo "Secure Boot: $SB_STATE" | tee -a /run/install-start.log
    if echo "$SB_STATE" | grep -qi "enabled"; then
        echo "WARNING: Secure Boot is enabled. NVIDIA proprietary drivers may not load." | tee -a /run/install-start.log
        echo "WARNING: Disable Secure Boot in BIOS for full driver support." | tee -a /run/install-start.log
    fi
fi

# Check SMART health and NVMe wear - abort if an SSD install target is failing or exhausted
echo "=== Disk Health Check ===" | tee /run/disk-health.log
for disk in /dev/sd[a-z] /dev/sd[a-z][a-z] /dev/nvme*n1; do
    if [ -e "$disk" ]; then
        echo "Checking $disk..." | tee -a /run/disk-health.log
        smartctl -H "$disk" 2>/dev/null | tee -a /run/disk-health.log || echo "SMART not supported on $disk" | tee -a /run/disk-health.log
        # Determine if disk is an SSD (potential install target)
        is_ssd=false
        if echo "$disk" | grep -q nvme; then
            is_ssd=true
        elif [ "$(cat /sys/block/$(basename "$disk")/queue/rotational 2>/dev/null)" = "0" ]; then
            is_ssd=true
        fi
        # Check SMART overall health
        health=$(smartctl -H "$disk" 2>/dev/null | grep -iE "SMART overall-health|Critical Warning" || true)
        if echo "$health" | grep -qiE "FAILED|0x[0-9a-fA-F]*[1-9a-fA-F][0-9a-fA-F]*"; then
            if [ "$is_ssd" = true ]; then
                echo "CRITICAL: SSD $disk reports SMART FAILURE - aborting installation!" | tee -a /run/install-start.log
                echo "Replace the failing disk before installing." | tee -a /run/install-start.log
                sleep 30
                exit 1
            else
                echo "WARNING: HDD $disk reports SMART issue (not an install target, continuing)" | tee -a /run/install-start.log
            fi
        fi
        # Check NVMe write endurance (percentage used)
        if [ "$is_ssd" = true ] && echo "$disk" | grep -q nvme; then
            pct_used=$(nvme smart-log "$disk" 2>/dev/null | grep -iE "percentage.used" | awk -F: '{print $2}' | tr -d '% ' || true)
            # Truncate to integer (some drives report decimals like "1.5%")
            pct_used=$(echo "$pct_used" | cut -d. -f1)
            if [ -n "$pct_used" ] && [ "$pct_used" -ge 95 ] 2>/dev/null; then
                echo "WARNING: NVMe $disk has ${pct_used}% write endurance consumed" | tee -a /run/install-start.log
                if [ "$pct_used" -ge 100 ] 2>/dev/null; then
                    echo "CRITICAL: NVMe $disk endurance EXHAUSTED - aborting installation!" | tee -a /run/install-start.log
                    sleep 30
                    exit 1
                fi
            fi
        fi
    fi
done
echo "=== Health Check Complete ===" | tee -a /run/disk-health.log

# Ensure network is available (ping + DNS check)
echo "Waiting for network..."
NETWORK_READY=false
for i in $(seq 1 30); do
    if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        echo "Network connectivity available"
        # Also verify DNS is working (needed for apt)
        if host archive.ubuntu.com >/dev/null 2>&1 || nslookup archive.ubuntu.com >/dev/null 2>&1; then
            echo "DNS resolution working"
            NETWORK_READY=true
            break
        else
            echo "DNS not yet working, retrying..."
        fi
    fi
    sleep 2
done
if [ "$NETWORK_READY" = "false" ]; then
    echo "WARNING: Network not available after 60s. Package installation may fail." | tee -a /run/install-start.log
fi
