#!/bin/bash
################################################################################
# CCDC_Linux_PAM_Cleanup.sh
#
# Blue Team Cleanup Script - Remove PAM Training Backdoors
# Compatible with: Ubuntu, Debian, CentOS, RHEL, Fedora
#
# This script removes all training PAM modules and restores system to baseline.
# Run this AFTER the CCDC_Linux_ExWifeNamedPAM.sh training scenario.
################################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Detect PAM library path
detect_pam_lib_path() {
    local pam_paths=(
        "/usr/lib64/security"      # CentOS/RHEL/Fedora
        "/lib64/security"          # Some RHEL variants
        "/usr/lib/x86_64-linux-gnu/security"  # Debian/Ubuntu 64-bit
        "/lib/x86_64-linux-gnu/security"      # Debian/Ubuntu 64-bit alt
        "/usr/lib/security"        # Generic fallback
        "/lib/security"            # Generic fallback
    )

    for path in "${pam_paths[@]}"; do
        if [ -d "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    echo "/usr/lib64/security"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}"
   exit 1
fi

# Detect PAM library path
PAM_LIB_PATH=$(detect_pam_lib_path)

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}CCDC PAM Training Module Cleanup${NC}"
echo -e "${BLUE}Detected PAM Path: $PAM_LIB_PATH${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Step 1: Restore PAM configurations
echo -e "${YELLOW}[*] Step 1: Restoring PAM configurations...${NC}"

PAM_DIR="/etc/pam.d"
for backup_file in "$PAM_DIR"/*.backup.ccdc_training; do
    if [ -f "$backup_file" ]; then
        original_file="${backup_file%.backup.ccdc_training}"
        mv "$backup_file" "$original_file"
        echo -e "${GREEN}[+] Restored $(basename "$original_file")${NC}"
    fi
done

# Step 2: Remove compiled PAM modules
echo -e "${YELLOW}[*] Step 2: Removing malicious PAM modules...${NC}"

# Remove from detected location
pam_locations=(
    "$PAM_LIB_PATH/pam_capture.so"
    "/lib/x86_64-linux-gnu/security/pam_capture.so"
    "/lib64/security/pam_capture.so"
    "/usr/lib/x86_64-linux-gnu/security/pam_capture.so"
    "/usr/lib64/security/pam_capture.so"
    "/lib/security/pam_capture.so"
    "/usr/lib/security/pam_capture.so"
)

for module in "${pam_locations[@]}"; do
    if [ -f "$module" ]; then
        rm -f "$module"
        echo -e "${GREEN}[+] Removed $module${NC}"
    fi
done

# Step 3: Remove training scripts
echo -e "${YELLOW}[*] Step 3: Removing training scripts...${NC}"

if [ -d "/opt/ccdc_training" ]; then
    rm -rf "/opt/ccdc_training"
    echo -e "${GREEN}[+] Removed /opt/ccdc_training directory${NC}"
fi

# Step 4: Remove PAM temporary source files
echo -e "${YELLOW}[*] Step 4: Cleaning up temporary files...${NC}"

if [ -d "/tmp/pam_capture_src" ]; then
    rm -rf "/tmp/pam_capture_src"
    echo -e "${GREEN}[+] Removed temporary PAM source files${NC}"
fi

# Step 5: Clean sudoers
echo -e "${YELLOW}[*] Step 5: Cleaning sudoers configuration...${NC}"

# Remove CCDC_Training entries from sudoers
if grep -q "CCDC_Training" /etc/sudoers; then
    sed -i '/CCDC_Training/d' /etc/sudoers
    echo -e "${GREEN}[+] Removed CCDC_Training entries from sudoers${NC}"
fi

# Step 6: Restore SSH configuration
echo -e "${YELLOW}[*] Step 6: Restoring SSH configuration...${NC}"

SSH_CONFIG_D="/etc/ssh/sshd_config.d"
if [ -f "$SSH_CONFIG_D/ccdc_training.conf" ]; then
    rm "$SSH_CONFIG_D/ccdc_training.conf"
    echo -e "${GREEN}[+] Removed SSH training configuration${NC}"
fi

# Restore main SSH config if backup exists
SSH_CONFIG="/etc/ssh/sshd_config"
if [ -f "${SSH_CONFIG}.backup.ccdc_training" ]; then
    mv "${SSH_CONFIG}.backup.ccdc_training" "$SSH_CONFIG"
    echo -e "${GREEN}[+] Restored sshd_config from backup${NC}"
fi

# Restart SSH
if command -v systemctl &> /dev/null; then
    if systemctl is-active --quiet ssh 2>/dev/null; then
        systemctl restart ssh 2>/dev/null && echo -e "${GREEN}[+] SSH service restarted${NC}" || \
        echo -e "${YELLOW}[!] Could not restart SSH service${NC}"
    elif systemctl is-active --quiet sshd 2>/dev/null; then
        systemctl restart sshd 2>/dev/null && echo -e "${GREEN}[+] SSH service restarted${NC}" || \
        echo -e "${YELLOW}[!] Could not restart SSH service${NC}"
    else
        echo -e "${YELLOW}[!] SSH service not found or not active${NC}"
    fi
fi

# Step 7: Remove capture logs
echo -e "${YELLOW}[*] Step 7: Removing capture logs from user directories...${NC}"

find /home -name "LOOK_WHAT_PAM_CAPTURED_FLAG.txt" -delete 2>/dev/null && \
    echo -e "${GREEN}[+] Removed capture logs from user directories${NC}"

# Also check root's home
if [ -f "/root/LOOK_WHAT_PAM_CAPTURED_FLAG.txt" ]; then
    rm "/root/LOOK_WHAT_PAM_CAPTURED_FLAG.txt"
    echo -e "${GREEN}[+] Removed capture log from /root${NC}"
fi

# Step 8: Verify cleanup
echo -e "${YELLOW}[*] Step 8: Verifying cleanup...${NC}"

cleanup_verified=true

# Check for remaining PAM modules
for module in "${pam_locations[@]}"; do
    if [ -f "$module" ]; then
        echo -e "${RED}[!] WARNING: $module still exists${NC}"
        cleanup_verified=false
    fi
done

# Also check with find for any remaining pam_capture.so files
if find / -name "pam_capture.so" 2>/dev/null | grep -q .; then
    echo -e "${RED}[!] WARNING: pam_capture.so files still found in system${NC}"
    cleanup_verified=false
fi

# Check for training directory
if [ -d "/opt/ccdc_training" ]; then
    echo -e "${RED}[!] WARNING: /opt/ccdc_training still exists${NC}"
    cleanup_verified=false
fi

# Check for CCDC_Training entries
if grep -q "CCDC_Training" /etc/sudoers 2>/dev/null; then
    echo -e "${RED}[!] WARNING: CCDC_Training entries still in sudoers${NC}"
    cleanup_verified=false
fi

echo ""
if [ "$cleanup_verified" = true ]; then
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Cleanup Complete and Verified!${NC}"
    echo -e "${GREEN}========================================${NC}"
else
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}Cleanup Complete (with warnings)${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}Please review the warnings above${NC}"
fi

echo ""
