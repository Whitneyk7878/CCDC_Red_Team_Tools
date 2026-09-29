#!/bin/bash
################################################################################
# CCDC_Linux_LoadsOfIssues_Cleanup.sh
#
# Blue Team Cleanup Script - Remove LD_PRELOAD Hijacking Training Backdoors
# Compatible with: Ubuntu, Debian, CentOS, RHEL, Fedora
#
# This script removes all training LD_PRELOAD hijacking components and
# restores the system to its original state.
################################################################################
# Claude Haiku 4.5
#  "Now I want to make another script to train them for LD_PRELOAD hijacking.
# Same folder as the last script and create the same read me and blue team
#  cleanup script. I want it so that every time a binary is ran systemctl
#   stop and mask dovecot and systemctl stop and mask http happen. again
#    remember its for all those operating systems. I also want one to look
#     for any processes called FLAG.py running and purposefully hide them
#      from showing up if they run binaries like top, ps. and then finally
#       I will hide a flag service running on port 8888 so I want it to
#        also hide that from them so that they will only see that network
#         connection when they have remvoed the preload. and then lastly
#          I want it this to all be system wide with /etc/ld.so.preload.
#           call the file CCDC_Linux_LoadsOfIssues.sh"




RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Detect library path
detect_lib_path() {
    if [ -d "/usr/lib64" ]; then
        echo "/usr/lib64"
    elif [ -d "/usr/lib/x86_64-linux-gnu" ]; then
        echo "/usr/lib/x86_64-linux-gnu"
    else
        echo "/usr/lib"
    fi
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}"
   exit 1
fi

LIB_PATH=$(detect_lib_path)

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}CCDC LD_PRELOAD Training Module Cleanup${NC}"
echo -e "${BLUE}Library Path: $LIB_PATH${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Step 1: Remove /etc/ld.so.preload
echo -e "${YELLOW}[*] Step 1: Removing /etc/ld.so.preload...${NC}"

LD_PRELOAD_FILE="/etc/ld.so.preload"

if [ -f "$LD_PRELOAD_FILE" ]; then
    rm -f "$LD_PRELOAD_FILE"
    echo -e "${GREEN}[+] Removed /etc/ld.so.preload${NC}"
fi

# Restore backup if it exists
if [ -f "${LD_PRELOAD_FILE}.backup.ccdc_training" ]; then
    mv "${LD_PRELOAD_FILE}.backup.ccdc_training" "$LD_PRELOAD_FILE"
    echo -e "${GREEN}[+] Restored original /etc/ld.so.preload${NC}"
fi

# Step 2: Remove malicious library
echo -e "${YELLOW}[*] Step 2: Removing malicious library...${NC}"

preload_locations=(
    "$LIB_PATH/libccdc_hijack.so"
    "/usr/lib64/libccdc_hijack.so"
    "/usr/lib/x86_64-linux-gnu/libccdc_hijack.so"
    "/usr/lib/libccdc_hijack.so"
    "/lib64/libccdc_hijack.so"
    "/lib/libccdc_hijack.so"
)

for lib in "${preload_locations[@]}"; do
    if [ -f "$lib" ]; then
        rm -f "$lib"
        echo -e "${GREEN}[+] Removed $lib${NC}"
    fi
done

# Step 3: Stop and disable flag service
echo -e "${YELLOW}[*] Step 3: Stopping flag service...${NC}"

if systemctl is-active --quiet ccdc-flag 2>/dev/null; then
    systemctl stop ccdc-flag 2>/dev/null
    echo -e "${GREEN}[+] Stopped ccdc-flag service${NC}"
fi

if systemctl is-enabled --quiet ccdc-flag 2>/dev/null; then
    systemctl disable ccdc-flag 2>/dev/null
    echo -e "${GREEN}[+] Disabled ccdc-flag service${NC}"
fi

# Remove service file
if [ -f "/etc/systemd/system/ccdc-flag.service" ]; then
    rm -f "/etc/systemd/system/ccdc-flag.service"
    echo -e "${GREEN}[+] Removed ccdc-flag service file${NC}"
fi

# Reload systemd
systemctl daemon-reload 2>/dev/null || true

# Step 4: Kill any remaining hidden processes
echo -e "${YELLOW}[*] Step 4: Killing hidden processes...${NC}"

# Kill FLAG.py processes
pkill -f "FLAG.py" 2>/dev/null || true
echo -e "${GREEN}[+] Killed FLAG.py processes${NC}"

# Kill flag_service processes
pkill -f "flag_service.py" 2>/dev/null || true
echo -e "${GREEN}[+] Killed flag_service.py processes${NC}"

# Step 5: Remove training directory
echo -e "${YELLOW}[*] Step 5: Removing training directory...${NC}"

if [ -d "/opt/ccdc_training" ]; then
    rm -rf "/opt/ccdc_training"
    echo -e "${GREEN}[+] Removed /opt/ccdc_training directory${NC}"
fi

# Step 6: Remove compilation artifacts
echo -e "${YELLOW}[*] Step 6: Cleaning up compilation artifacts...${NC}"

if [ -d "/tmp/preload_src" ]; then
    rm -rf "/tmp/preload_src"
    echo -e "${GREEN}[+] Removed /tmp/preload_src directory${NC}"
fi

# Step 7: Restore services if masked
echo -e "${YELLOW}[*] Step 7: Restoring masked services...${NC}"

services=("dovecot" "httpd" "apache2")

for service in "${services[@]}"; do
    # Try to unmask service (unmask is idempotent - safe even if not masked)
    if systemctl unmask "$service" 2>/dev/null; then
        echo -e "${GREEN}[+] Unmasked $service${NC}"
    fi
done

# Step 8: Verify cleanup
echo -e "${YELLOW}[*] Step 8: Verifying cleanup...${NC}"

cleanup_verified=true

# Check for remaining preload file
if [ -f "$LD_PRELOAD_FILE" ] && [ -s "$LD_PRELOAD_FILE" ]; then
    echo -e "${RED}[!] WARNING: /etc/ld.so.preload still exists${NC}"
    cleanup_verified=false
fi

# Check for remaining library
if [ -f "$LIB_PATH/libccdc_hijack.so" ]; then
    echo -e "${RED}[!] WARNING: libccdc_hijack.so still exists${NC}"
    cleanup_verified=false
fi

# Check for remaining service file
if [ -f "/etc/systemd/system/ccdc-flag.service" ]; then
    echo -e "${RED}[!] WARNING: ccdc-flag service file still exists${NC}"
    cleanup_verified=false
fi

# Check for remaining training directory
if [ -d "/opt/ccdc_training" ]; then
    echo -e "${RED}[!] WARNING: /opt/ccdc_training directory still exists${NC}"
    cleanup_verified=false
fi

# Check for hidden processes
if pgrep -f "FLAG.py" >/dev/null 2>&1; then
    echo -e "${RED}[!] WARNING: FLAG.py processes still running${NC}"
    cleanup_verified=false
fi

if pgrep -f "flag_service.py" >/dev/null 2>&1; then
    echo -e "${RED}[!] WARNING: flag_service.py processes still running${NC}"
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
