#!/usr/bin/env bash
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Linux Remote Access - Open Door Policy
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# Claude Sonnet 4.6
# "write a script for linux ubuntu fedora centos that will install and
#  configure cockpit with the easiest most permissive settings to test blue
#  team put it in WORK_IN_PROGRESS_setupscripts. I also want this to install
#  and setup other remote services like telnet, ssh, and configure those
#  similarly. can you also think of other lesser known remote management
#  tools for linux we could use?"
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
#
# PURPOSE: Install and misconfigure multiple remote access services with
#          intentionally weak/permissive settings for CCDC blue team training.
#          Every service is configured to allow root access with minimal or
#          no authentication — blue teams must find and remediate all of them.
#
# SERVICES INSTALLED:
#   OpenSSH    port 22    - Root login, empty passwords, no PAM
#   Telnet     port 23    - Cleartext remote shell (inetd/xinetd)
#   Cockpit    port 9090  - Web management, all origins, no timeout
#   Shellinabox port 4200 - Browser terminal, no SSL, runs as root
#   RSH/RLOGIN port 513/514 - BSD r-commands, hosts.equiv "+" bypass
#   TFTP       port 69    - No auth, write-enabled, world-readable root
#
# LESSER-KNOWN TOOLS (not installed here, documented for trainees):
#   Webmin  (port 10000) - Full web admin panel; apt install webmin (after adding repo)
#   ttyd    (port 7681)  - Modern web terminal; single Go binary, easy to hide
#   tmate               - Terminal sharing; outbound relay through tmate.io
#   VNC/TigerVNC (5900) - Graphical remote desktop
#   socat               - socat TCP-LISTEN:4444,fork EXEC:/bin/bash (instant bind shell)
#   netcat              - nc -lvp 4444 -e /bin/bash (classic)
#
# Compatible: Ubuntu 20.04+, Fedora 36+, CentOS/RHEL 8+
# Usage:      sudo bash CCDC_Linux_RemoteAccess_OpenDoorPolicy.sh

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
SSH_PORT=22
COCKPIT_PORT=9090
SHELLINABOX_PORT=4200
TFTP_ROOT="/var/lib/tftpboot"

# ─── Color Helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[*]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
success() { echo -e "${GREEN}[+]${NC} $*"; }
err()     { echo -e "${RED}[-]${NC} $*" >&2; }
die()     { err "$*"; exit 1; }

trap 'err "Error at line $LINENO — check output above"; exit 1' ERR

# ─── Root Check ───────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root: sudo $0"

# ─── Distro Detection ─────────────────────────────────────────────────────────
OS=""
OS_PRETTY=""

detect_distro() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        OS="${ID,,}"
        OS_PRETTY="${PRETTY_NAME:-$ID}"
    elif [[ -f /etc/redhat-release ]]; then
        OS="rhel"
        OS_PRETTY=$(cat /etc/redhat-release)
    else
        die "Cannot detect OS. /etc/os-release not found."
    fi
}

PKG_INSTALL=""
PKG_UPDATE=""
INETD_PKG=""
INETD_CONF=""
INETD_SVC=""
TELNET_PKG=""
RSH_PKG=""
TFTP_PKG=""
SHELLINABOX_PKG="shellinabox"
SHELLINABOX_SVC=""
SHELLINABOX_CONF=""
SSH_SVC=""
SFTP_SERVER=""
EPEL_NEEDED=false

set_distro_vars() {
    case "$OS" in
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive
            PKG_INSTALL="apt-get install -y"
            PKG_UPDATE="apt-get update -y"
            INETD_PKG="openbsd-inetd"
            INETD_CONF="/etc/inetd.conf"
            INETD_SVC="inetd"
            TELNET_PKG="inetutils-telnetd"
            RSH_PKG="rsh-server"
            TFTP_PKG="tftpd-hpa"
            SHELLINABOX_SVC="shellinabox"
            SHELLINABOX_CONF="/etc/default/shellinabox"
            SSH_SVC="ssh"
            SFTP_SERVER="/usr/lib/openssh/sftp-server"
            EPEL_NEEDED=false
            ;;
        fedora)
            PKG_INSTALL="dnf install -y"
            PKG_UPDATE="dnf check-update -y || true"
            INETD_PKG="xinetd"
            INETD_CONF="/etc/xinetd.d"
            INETD_SVC="xinetd"
            TELNET_PKG="telnet-server"
            RSH_PKG="rsh-server"
            TFTP_PKG="tftp-server"
            SHELLINABOX_SVC="shellinaboxd"
            SHELLINABOX_CONF="/etc/sysconfig/shellinaboxd"
            SSH_SVC="sshd"
            SFTP_SERVER="/usr/libexec/openssh/sftp-server"
            EPEL_NEEDED=false
            ;;
        centos|rhel|rocky|almalinux)
            # prefer dnf but fall back to yum for older RHEL 7
            if command -v dnf &>/dev/null; then
                PKG_INSTALL="dnf install -y"
                PKG_UPDATE="dnf check-update -y || true"
            else
                PKG_INSTALL="yum install -y"
                PKG_UPDATE="yum check-update -y || true"
            fi
            INETD_PKG="xinetd"
            INETD_CONF="/etc/xinetd.d"
            INETD_SVC="xinetd"
            TELNET_PKG="telnet-server"
            RSH_PKG="rsh-server"
            TFTP_PKG="tftp-server"
            SHELLINABOX_SVC="shellinaboxd"
            SHELLINABOX_CONF="/etc/sysconfig/shellinaboxd"
            SSH_SVC="sshd"
            SFTP_SERVER="/usr/libexec/openssh/sftp-server"
            EPEL_NEEDED=true
            ;;
        *)
            die "Unsupported distro: $OS. Tested on ubuntu, fedora, centos, rhel."
            ;;
    esac
}

# ─── Helper: Install EPEL if needed ───────────────────────────────────────────
ensure_epel() {
    if $EPEL_NEEDED && ! rpm -q epel-release &>/dev/null; then
        info "Installing EPEL repository..."
        $PKG_INSTALL epel-release || true
        success "EPEL installed"
    fi
}

# ─── Helper: Restart inetd/xinetd ─────────────────────────────────────────────
restart_inetd() {
    systemctl enable --now "$INETD_SVC" 2>/dev/null || true
    systemctl restart "$INETD_SVC"
}

# ─── Section 1: OpenSSH ───────────────────────────────────────────────────────
setup_ssh() {
    info "Configuring OpenSSH with permissive settings..."

    $PKG_INSTALL openssh-server || true

    # Backup original config once
    [[ -f /etc/ssh/sshd_config.bak ]] || cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

    cat > /etc/ssh/sshd_config <<'EOF'
# CCDC Training Config — intentionally permissive
Port 22
AddressFamily any
ListenAddress 0.0.0.0

# Authentication
PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords yes
ChallengeResponseAuthentication no
UsePAM no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys

# Brute-force friendly
MaxAuthTries 100
LoginGraceTime 120
MaxSessions 50

# Features
X11Forwarding yes
AllowTcpForwarding yes
GatewayPorts yes
PermitTunnel yes

# Logging (low — harder to detect attacks in logs)
LogLevel QUIET

PrintLastLog no
PrintMotd no
AcceptEnv LANG LC_*
EOF
    # Subsystem path differs by distro; append it after the heredoc
    echo "Subsystem sftp $SFTP_SERVER" >> /etc/ssh/sshd_config

    systemctl enable --now "$SSH_SVC"
    systemctl restart "$SSH_SVC"

    if systemctl is-active --quiet "$SSH_SVC"; then
        success "SSH running on port $SSH_PORT (root login enabled, empty passwords allowed)"
    else
        warn "SSH may not have started — check: journalctl -u $SSH_SVC -n 30"
    fi
}

# ─── Section 2: Telnet ────────────────────────────────────────────────────────
setup_telnet() {
    info "Installing Telnet server (cleartext remote shell)..."

    $PKG_INSTALL "$INETD_PKG" "$TELNET_PKG" || true

    case "$OS" in
        ubuntu|debian)
            # Append to inetd.conf if not already present
            grep -q "telnetd" "$INETD_CONF" 2>/dev/null || \
                echo "telnet stream tcp  nowait root /usr/sbin/in.telnetd in.telnetd" >> "$INETD_CONF"
            grep -q "telnet6" "$INETD_CONF" 2>/dev/null || \
                echo "telnet stream tcp6 nowait root /usr/sbin/in.telnetd in.telnetd" >> "$INETD_CONF"
            ;;
        fedora|centos|rhel|rocky|almalinux)
            cat > /etc/xinetd.d/telnet <<'EOF'
service telnet
{
    flags           = REUSE
    socket_type     = stream
    wait            = no
    user            = root
    server          = /usr/sbin/in.telnetd
    log_on_failure  += USERID
    disable         = no
}
EOF
            ;;
    esac

    restart_inetd

    if ss -tlnp 2>/dev/null | grep -q ":23 " || \
       ss -tlnp 2>/dev/null | grep -q ":23$"; then
        success "Telnet listening on port 23"
    else
        warn "Telnet port 23 not yet visible in ss — inetd may open it on first connection"
    fi
}

# ─── Section 3: Cockpit ───────────────────────────────────────────────────────
setup_cockpit() {
    info "Installing Cockpit web management interface..."

    case "$OS" in
        ubuntu|debian)
            $PKG_INSTALL cockpit || true
            ;;
        fedora|centos|rhel|rocky|almalinux)
            $PKG_INSTALL cockpit cockpit-dashboard cockpit-packagekit || true
            ;;
    esac

    mkdir -p /etc/cockpit

    # Permissive cockpit config: allow all origins, no login restrictions, no timeout
    cat > /etc/cockpit/cockpit.conf <<EOF
[WebService]
Origins = *
LoginTo = false
ProtocolHeader = X-Forwarded-Proto
AllowUnencrypted = true

[Session]
IdleTimeout = 0
Banner =
EOF

    # Write an explicit empty disallowed-users so root is never blocked on any distro
    echo "" > /etc/cockpit/disallowed-users

    systemctl enable --now cockpit.socket
    systemctl enable cockpit 2>/dev/null || true
    systemctl start cockpit 2>/dev/null || true

    # Wait up to 10 seconds for cockpit to respond
    local attempt=0
    while (( attempt < 10 )); do
        if curl -sk "https://localhost:${COCKPIT_PORT}/" -o /dev/null 2>/dev/null; then
            break
        fi
        sleep 1
        (( attempt++ )) || true
    done

    if systemctl is-active --quiet cockpit.socket || systemctl is-active --quiet cockpit; then
        success "Cockpit running on https://localhost:${COCKPIT_PORT} (root login allowed, no timeout)"
    else
        warn "Cockpit socket not active — check: journalctl -u cockpit.socket -n 30"
    fi
}

# ─── Section 4: Shellinabox ───────────────────────────────────────────────────
setup_shellinabox() {
    info "Installing Shellinabox (browser-accessible terminal)..."

    ensure_epel
    $PKG_INSTALL "$SHELLINABOX_PKG" || true

    if ! command -v shellinaboxd &>/dev/null; then
        warn "Shellinabox binary not found — package may not be available on this distro. Skipping."
        return
    fi

    # Configure: plain HTTP (no SSL), run as root, custom port
    cat > "$SHELLINABOX_CONF" <<EOF
SHELLINABOX_DAEMON_START=1
SHELLINABOX_PORT=${SHELLINABOX_PORT}
SHELLINABOX_ARGS="--no-beep --disable-ssl --port=${SHELLINABOX_PORT} --user=root --group=root"
EOF

    systemctl enable --now "$SHELLINABOX_SVC" || true
    systemctl restart "$SHELLINABOX_SVC" || true

    sleep 1
    if systemctl is-active --quiet "$SHELLINABOX_SVC" 2>/dev/null; then
        success "Shellinabox running on http://localhost:${SHELLINABOX_PORT} (no SSL, root access)"
    else
        warn "Shellinabox not active — may need manual start: shellinaboxd --no-beep --disable-ssl --port=${SHELLINABOX_PORT}"
    fi
}

# ─── Section 5: RSH / RLOGIN ──────────────────────────────────────────────────
setup_rsh() {
    info "Installing RSH/RLOGIN (BSD r-commands with hosts.equiv bypass)..."

    $PKG_INSTALL "$INETD_PKG" "$RSH_PKG" || true

    case "$OS" in
        ubuntu|debian)
            # Shell (rsh) and login (rlogin) via inetd
            grep -q "in.rshd" "$INETD_CONF" 2>/dev/null || \
                echo "shell  stream tcp  nowait root /usr/sbin/in.rshd  in.rshd"  >> "$INETD_CONF"
            grep -q "in.rlogind" "$INETD_CONF" 2>/dev/null || \
                echo "login  stream tcp  nowait root /usr/sbin/in.rlogind in.rlogind" >> "$INETD_CONF"
            ;;
        fedora|centos|rhel|rocky|almalinux)
            cat > /etc/xinetd.d/rsh <<'EOF'
service shell
{
    socket_type     = stream
    wait            = no
    user            = root
    log_on_success  -= PID HOST DURATION
    log_on_failure  -= HOST
    server          = /usr/sbin/in.rshd
    disable         = no
}
EOF
            cat > /etc/xinetd.d/rlogin <<'EOF'
service login
{
    socket_type     = stream
    wait            = no
    user            = root
    log_on_success  -= PID HOST DURATION
    log_on_failure  -= HOST
    server          = /usr/sbin/in.rlogind
    disable         = no
}
EOF
            ;;
    esac

    # hosts.equiv "+" trusts ALL hosts — no password needed for any user
    echo "+" > /etc/hosts.equiv
    chmod 644 /etc/hosts.equiv

    # /root/.rhosts "+ +" allows any user from any host to log in as root
    mkdir -p /root
    echo "+ +" > /root/.rhosts
    chmod 600 /root/.rhosts

    restart_inetd
    success "RSH/RLOGIN configured — /etc/hosts.equiv='+', /root/.rhosts='+ +' (trust all hosts)"
}

# ─── Section 6: TFTP ──────────────────────────────────────────────────────────
setup_tftp() {
    info "Installing TFTP server (no authentication, write-enabled)..."

    $PKG_INSTALL "$TFTP_PKG" || true

    mkdir -p "$TFTP_ROOT"
    chmod 777 "$TFTP_ROOT"

    # Drop a marker file blue team should find
    echo "CCDC TFTP server — unauthenticated file read/write enabled" > "$TFTP_ROOT/README_CCDC.txt"
    chmod 644 "$TFTP_ROOT/README_CCDC.txt"

    case "$OS" in
        ubuntu|debian)
            # tftpd-hpa uses a config file
            cat > /etc/default/tftpd-hpa <<EOF
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="${TFTP_ROOT}"
TFTP_ADDRESS="0.0.0.0:69"
TFTP_OPTIONS="--secure --create --verbose"
EOF
            systemctl enable --now tftpd-hpa
            systemctl restart tftpd-hpa

            if systemctl is-active --quiet tftpd-hpa; then
                success "TFTP (tftpd-hpa) running on UDP 69 — write-enabled at $TFTP_ROOT"
            else
                warn "TFTP not active — check: journalctl -u tftpd-hpa -n 20"
            fi
            ;;
        fedora|centos|rhel|rocky|almalinux)
            # tftp-server uses xinetd
            cat > /etc/xinetd.d/tftp <<EOF
service tftp
{
    socket_type     = dgram
    protocol        = udp
    wait            = yes
    user            = root
    server          = /usr/sbin/in.tftpd
    server_args     = -s ${TFTP_ROOT} -c
    disable         = no
    per_source      = 11
    cps             = 100 2
    flags           = IPv4
}
EOF
            restart_inetd
            success "TFTP configured via xinetd on UDP 69 — write-enabled at $TFTP_ROOT"
            ;;
    esac
}

# ─── Summary ──────────────────────────────────────────────────────────────────
print_summary() {
    local IP
    IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -n "$IP" ]] || IP="127.0.0.1"

    echo
    echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║     INTENTIONAL MISCONFIGURATIONS INSTALLED — CCDC TRAINING  ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${YELLOW}  Target IP:${NC} ${IP}"
    echo
    echo -e "${CYAN}  Service         Port     Protocol    Weakness${NC}"
    echo    "  ─────────────────────────────────────────────────────────────"
    echo -e "  OpenSSH          22       TCP         Root login, empty passwords, no PAM"
    echo -e "  Telnet           23       TCP         Cleartext, root shell, no encryption"
    echo -e "  Cockpit          9090     HTTPS       All origins, root login, no timeout"
    echo -e "  Shellinabox      4200     HTTP        Browser terminal, no SSL, root access"
    echo -e "  RSH/RLOGIN       513/514  TCP         hosts.equiv '+', .rhosts '+ +'"
    echo -e "  TFTP             69       UDP         No auth, file write enabled"
    echo
    echo -e "${YELLOW}  Access URLs:${NC}"
    echo    "    Cockpit:     https://${IP}:9090"
    echo    "    Shellinabox: http://${IP}:4200"
    echo    "    SSH:         ssh root@${IP}  (any password, including empty)"
    echo    "    Telnet:      telnet ${IP}"
    echo    "    RSH:         rsh -l root ${IP}"
    echo
    echo -e "${YELLOW}  Other Remote Management Tools to Consider:${NC}"
    echo    "    Webmin    port 10000  - apt install webmin (after adding Webmin apt repo)"
    echo    "    ttyd      port 7681   - modern web terminal; single Go binary"
    echo    "    tmate               - terminal sharing via tmate.io relay (outbound)"
    echo    "    VNC       port 5900  - tigervnc-server (requires desktop environment)"
    echo    "    socat               - socat TCP-LISTEN:4444,fork EXEC:/bin/bash"
    echo    "    netcat              - nc -lvp 4444 -e /bin/bash"
    echo
    echo -e "${GREEN}  ── Blue Team Remediation Checklist ──────────────────────────${NC}"
    echo    "  1. Disable inetd/xinetd: systemctl disable --now inetd  (or xinetd)"
    echo    "     - Remove /etc/inetd.conf lines or /etc/xinetd.d/telnet, rsh, rlogin, tftp"
    echo    "  2. Harden SSH: PermitRootLogin no, PasswordAuthentication no"
    echo    "     - Restore backup: cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config"
    echo    "  3. Remove trust files: rm /etc/hosts.equiv /root/.rhosts"
    echo    "  4. Stop Cockpit: systemctl disable --now --mask cockpit.socket"
    echo    "  5. Stop Shellinabox: systemctl disable --now shellinabox (or shellinaboxd)"
    echo    "  6. Stop TFTP and restrict root: chmod 755 ${TFTP_ROOT}"
    echo    "  7. Audit open ports: ss -tlnp && ss -ulnp"
    echo    "  8. Audit extra repos: apt list --installed 2>/dev/null | grep -i epel"
    echo    "     or: yum repolist"
    echo
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    detect_distro
    set_distro_vars

    echo
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  CCDC Linux Remote Access — Open Door Policy${NC}"
    echo -e "${CYAN}  Target: ${OS_PRETTY}${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo

    info "Updating package lists..."
    eval "$PKG_UPDATE" || true

    setup_ssh
    echo
    setup_telnet
    echo
    setup_cockpit
    echo
    setup_shellinabox
    echo
    setup_rsh
    echo
    setup_tftp

    print_summary
}

main "$@"
