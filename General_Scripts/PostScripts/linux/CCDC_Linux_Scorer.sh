#!/usr/bin/env bash
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Linux Target Scorer
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# Grades the DEFENDER (blue team) across 5 categories. Higher = better defense.
#   1. Scored Services           (100) – scored services still running
#   2. Persistence Removed       (100) – planted persistence found & cleaned
#   3. Rogue Users Removed       (100) – backdoor accounts found & deleted
#   4. Remote Access Hardened    (100) – insecure remote access locked down
#   5. Malicious Modules Removed (100) – LD_PRELOAD / PAM backdoors cleaned
# Total: /500
#
# Run:    sudo bash CCDC_Linux_Scorer.sh
# Report: /tmp/ccdc_score_report.html  (written at end of run)
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

if [[ $(id -u) -ne 0 ]]; then
    echo "ERROR: must run as root (sudo bash $0)"
    exit 1
fi

# -- ANSI colors ---------------------------------------------------------------
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
WHITE='\033[1;37m'
RESET='\033[0m'

# -- Score accumulators -------------------------------------------------------
S1=0; S2=0; S3=0; S4=0; S5=0

# -- Report data arrays -------------------------------------------------------
declare -a R_SVAR=()
declare -a R_PTS=()
declare -a R_LABEL=()
declare -a R_PASS=()
declare -a R_HINT=()

# -- Helpers ------------------------------------------------------------------
section() { echo -e "\n${CYAN}==[ $1 ]==${RESET}\n"; }
subtotal() { echo -e "\n${YELLOW}  Subtotal: $1 / $2${RESET}"; }

# check <score_var> <points> <label> <1=pass|0=fail> [hint]
check() {
    local svar="$1" pts="$2" label="$3" pass="$4" hint="${5:-}"
    R_SVAR+=("$svar"); R_PTS+=("$pts"); R_LABEL+=("$label")
    R_PASS+=("$pass"); R_HINT+=("$hint")
    if [[ "$pass" == "1" ]]; then
        printf "${GREEN}[PASS +%2d] %s${RESET}\n" "$pts" "$label"
        case "$svar" in
            S1) S1=$((S1+pts)) ;; S2) S2=$((S2+pts)) ;; S3) S3=$((S3+pts)) ;;
            S4) S4=$((S4+pts)) ;; S5) S5=$((S5+pts)) ;;
        esac
    else
        printf "${RED}[FAIL  +0] %s${RESET}\n" "$label"
    fi
}

svc_active()   { systemctl is-active --quiet "$1" 2>/dev/null && echo 1 || echo 0; }
svc_enabled()  { systemctl is-enabled --quiet "$1" 2>/dev/null && echo 1 || echo 0; }

port_listening() { ss -tlnp 2>/dev/null | awk '{print $4}' | grep -qE ":${1}$" && echo 1 || echo 0; }
udp_listening()  { ss -ulnp 2>/dev/null | awk '{print $4}' | grep -qE ":${1}$" && echo 1 || echo 0; }
port_gone()      { [[ "$(port_listening "$1")" == "0" ]] && echo 1 || echo 0; }
udp_gone()       { [[ "$(udp_listening "$1")" == "0" ]] && echo 1 || echo 0; }

http_ok() {
    local code
    code=$(curl -sk --max-time 5 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null)
    [[ "$code" =~ ^[23] ]] && echo 1 || echo 0
}

file_gone()   { [[ ! -e "$1" ]] && echo 1 || echo 0; }
dir_gone()    { [[ ! -d "$1" ]] && echo 1 || echo 0; }
file_no_str() { grep -qF "$2" "$1" 2>/dev/null && echo 0 || echo 1; }

not_immutable() {
    lsattr "$1" 2>/dev/null | awk 'NR==1{print $1}' | grep -qF 'i' && echo 0 || echo 1
}
user_gone()   { getent passwd "$1" &>/dev/null && echo 0 || echo 1; }
not_in_sudo() { id -nG "$1" 2>/dev/null | grep -qE '\b(sudo|wheel)\b' && echo 0 || echo 1; }

html_esc() {
    local s="$1"
    s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"
    printf '%s' "$s"
}

# =============================================================================
# BANNER
# =============================================================================
echo -e ""
echo -e "${CYAN}========================================================${RESET}"
echo -e "${CYAN}  CCDC Blue Team Training - Linux Defender Scorer${RESET}"
echo -e "${CYAN}========================================================${RESET}"
echo -e ""

# =============================================================================
# CATEGORY 1 – SCORED SERVICES (100 pts)
# Blue team gets points for keeping legitimate services UP.
# =============================================================================
section "CATEGORY 1 – SCORED SERVICES (100 pts)"

check S1 15 "apache2 service active" \
    "$(svc_active apache2)" \
    "systemctl status apache2  →  systemctl start apache2"
check S1 15 "HTTP GET http://localhost returns 2xx/3xx" \
    "$(http_ok http://localhost)" \
    "curl -v http://localhost  →  check apache2 logs"
check S1 15 "postfix service active" \
    "$(svc_active postfix)" \
    "systemctl status postfix  →  systemctl start postfix"
check S1 10 "SMTP port 25 listening" \
    "$(port_listening 25)" \
    "ss -tlnp | grep :25"
check S1 15 "dovecot service active" \
    "$(svc_active dovecot)" \
    "systemctl status dovecot  →  systemctl start dovecot"
check S1 10 "IMAP port 143 listening" \
    "$(port_listening 143)" \
    "ss -tlnp | grep :143"
check S1  5 "POP3 port 110 listening" \
    "$(port_listening 110)" \
    "ss -tlnp | grep :110"

SPLUNK_ACTIVE=0
if systemctl is-active --quiet Splunkd 2>/dev/null || \
   systemctl is-active --quiet splunk  2>/dev/null; then
    SPLUNK_ACTIVE=1
fi
check S1 10 "Splunk service (Splunkd/splunk) active" \
    "$SPLUNK_ACTIVE" \
    "systemctl status Splunkd || systemctl status splunk"
check S1  5 "Splunk web port 8000 responding" \
    "$(http_ok http://localhost:8000)" \
    "curl -v http://localhost:8000"

subtotal "$S1" 100

# =============================================================================
# CATEGORY 2 – PERSISTENCE REMOVED (100 pts)
# Blue team gets points for each planted artifact that has been cleaned up.
# Covers: ImGonnaCron, PlantsVsZerodays, OopsAllWebShells, OopsAllBees, ATD
# =============================================================================
section "CATEGORY 2 – PERSISTENCE REMOVED (100 pts)"

# -- Cron jobs (ImGonnaCron) --------------------------------------------------
check S2  8 "/etc/cron.d/grub-service removed (5-min service killer)" \
    "$(file_gone /etc/cron.d/grub-service)" \
    "cat /etc/cron.d/grub-service  →  rm /etc/cron.d/grub-service"

check S2  8 "/etc/cron.d/sillyevilcronjob removed (3-min service killer)" \
    "$(file_gone /etc/cron.d/sillyevilcronjob)" \
    "cat /etc/cron.d/sillyevilcronjob  →  rm /etc/cron.d/sillyevilcronjob"

# -- Persistence location 1: rc.local (PlantsVsZerodays) ---------------------
check S2  7 '/etc/rc.local no longer contains "sysinit-helper"' \
    "$(file_no_str /etc/rc.local 'sysinit-helper')" \
    "cat /etc/rc.local  →  remove the sysinit-helper line; restore original rc.local"

check S2  2 "/usr/local/lib/.sysinit-helper payload removed" \
    "$(file_gone /usr/local/lib/.sysinit-helper)" \
    "ls -la /usr/local/lib/.sysinit-helper  →  rm /usr/local/lib/.sysinit-helper"

# -- Persistence location 2: profile.d ----------------------------------------
check S2  6 "/etc/profile.d/99-sysenv-init.sh removed" \
    "$(file_gone /etc/profile.d/99-sysenv-init.sh)" \
    "cat /etc/profile.d/99-sysenv-init.sh  →  rm /etc/profile.d/99-sysenv-init.sh"

check S2  2 "/usr/local/lib/.sysenv-init payload removed" \
    "$(file_gone /usr/local/lib/.sysenv-init)" \
    "ls /usr/local/lib/.sysenv-init  →  rm /usr/local/lib/.sysenv-init"

# -- Persistence location 3: systemd service ----------------------------------
check S2  6 "/etc/systemd/system/sys-khelper-init.service removed" \
    "$(file_gone /etc/systemd/system/sys-khelper-init.service)" \
    "ls /etc/systemd/system/sys-khelper-init.service  →  systemctl disable --now sys-khelper-init; rm /etc/systemd/system/sys-khelper-init.service; systemctl daemon-reload"

KHELPER_DISABLED=1
systemctl is-enabled --quiet sys-khelper-init.service 2>/dev/null && KHELPER_DISABLED=0
check S2  3 "sys-khelper-init.service disabled/removed" "$KHELPER_DISABLED" \
    "systemctl is-enabled sys-khelper-init  →  systemctl disable sys-khelper-init"

check S2  2 "/usr/local/lib/.khelper-init payload removed" \
    "$(file_gone /usr/local/lib/.khelper-init)" \
    "ls /usr/local/lib/.khelper-init  →  rm /usr/local/lib/.khelper-init"

# -- Persistence location 4: cron.d syslogd-helper ---------------------------
check S2  3 "/etc/cron.d/syslogd-helper removed (@reboot persistence)" \
    "$(file_gone /etc/cron.d/syslogd-helper)" \
    "cat /etc/cron.d/syslogd-helper  →  rm /etc/cron.d/syslogd-helper"

check S2  2 "/usr/local/lib/.syslogd-helper payload removed" \
    "$(file_gone /usr/local/lib/.syslogd-helper)" \
    "ls /usr/local/lib/.syslogd-helper  →  rm /usr/local/lib/.syslogd-helper"

# -- Persistence location 5: .bashrc -----------------------------------------
check S2  7 '/root/.bashrc no longer contains "__sysnet_diag_hook__"' \
    "$(file_no_str /root/.bashrc '__sysnet_diag_hook__')" \
    "grep -n '__sysnet_diag_hook__' /root/.bashrc  →  remove the injected block from /root/.bashrc"

check S2  2 "/usr/local/lib/.sysnet-diag payload removed" \
    "$(file_gone /usr/local/lib/.sysnet-diag)" \
    "ls /usr/local/lib/.sysnet-diag  →  rm /usr/local/lib/.sysnet-diag"

# -- Rogue web shell service (OopsAllWebShells) --------------------------------
SILLYEVIL_GONE=1
[[ -e "/etc/systemd/system/sillyevilservice.service" ]] && SILLYEVIL_GONE=0
systemctl is-active --quiet sillyevilservice 2>/dev/null && SILLYEVIL_GONE=0
check S2  8 "sillyevilservice (rogue PHP web shell) service stopped and unit removed" \
    "$SILLYEVIL_GONE" \
    "systemctl status sillyevilservice  →  systemctl disable --now sillyevilservice; rm /etc/systemd/system/sillyevilservice.service; systemctl daemon-reload"

check S2  3 "/opt/sillyevilservice/www/index.php removed" \
    "$(file_gone /opt/sillyevilservice/www/index.php)" \
    "ls /opt/sillyevilservice/  →  rm -rf /opt/sillyevilservice"

check S2  4 "/opt/sillyevilservice directory removed" \
    "$(dir_gone /opt/sillyevilservice)" \
    "ls -la /opt/sillyevilservice  →  rm -rf /opt/sillyevilservice"

# -- BeeMovie (OopsAllBees) ---------------------------------------------------
PIPEWIRE_TIMER_GONE=1
[[ -e "/etc/systemd/system/systemd-pipewire-multithread-runner.timer" ]] && PIPEWIRE_TIMER_GONE=0
systemctl is-active --quiet systemd-pipewire-multithread-runner.timer 2>/dev/null && PIPEWIRE_TIMER_GONE=0
check S2  5 "systemd-pipewire-multithread-runner.timer stopped and unit removed" \
    "$PIPEWIRE_TIMER_GONE" \
    "systemctl status systemd-pipewire-multithread-runner.timer  →  systemctl disable --now systemd-pipewire-multithread-runner.timer; rm /etc/systemd/system/systemd-pipewire-multithread-runner.timer"

check S2  3 "/etc/systemd/system/systemd-pipewire-multithread-runner.service unit file removed" \
    "$(file_gone /etc/systemd/system/systemd-pipewire-multithread-runner.service)" \
    "ls /etc/systemd/system/systemd-pipewire-multithread-runner.service  →  rm it; systemctl daemon-reload"

check S2  5 "/etc/profile.d/99-pipewire-session-env.sh (Bee Movie PROMPT_COMMAND hook) removed" \
    "$(file_gone /etc/profile.d/99-pipewire-session-env.sh)" \
    "cat /etc/profile.d/99-pipewire-session-env.sh  →  rm /etc/profile.d/99-pipewire-session-env.sh"

check S2  3 "/usr/local/lib/systemd-pipewire-multithread-runner/ enforcer directory removed" \
    "$(dir_gone /usr/local/lib/systemd-pipewire-multithread-runner)" \
    "ls /usr/local/lib/systemd-pipewire-multithread-runner/  →  rm -rf /usr/local/lib/systemd-pipewire-multithread-runner"

check S2  3 '/etc/bash.bashrc no longer sources 99-pipewire-session-env.sh' \
    "$(file_no_str /etc/bash.bashrc '99-pipewire-session-env.sh')" \
    "grep -n 'pipewire-session-env' /etc/bash.bashrc  →  remove that source line from /etc/bash.bashrc"

# -- ATD (ComeATmeBro) --------------------------------------------------------
ATD_CLEAN=1
systemctl is-active --quiet atd 2>/dev/null && ATD_CLEAN=0
pgrep -x atd &>/dev/null && ATD_CLEAN=0
check S2  5 "atd (at daemon) service stopped — no self-rescheduling at jobs" \
    "$ATD_CLEAN" \
    "systemctl is-active atd; atq  →  atrm \$(atq | awk '{print \$1}'); systemctl disable --now atd"

check S2  3 "/usr/local/lib/systemd-compat-helper.sh (ATD payload) removed" \
    "$(file_gone /usr/local/lib/systemd-compat-helper.sh)" \
    "ls /usr/local/lib/systemd-compat-helper.sh  →  rm /usr/local/lib/systemd-compat-helper.sh"

subtotal "$S2" 100

# =============================================================================
# CATEGORY 3 – ROGUE USERS REMOVED (100 pts)
# Blue team gets points for each backdoor account that has been cleaned up.
# Includes immutable flag removal on /etc/passwd, /etc/shadow, sudoers.d files.
# =============================================================================
section "CATEGORY 3 – ROGUE USERS REMOVED (100 pts)"

for USERNAME in ubuntu johnredteam "systemd-bus-proxy"; do
    check S3 13 "User \"${USERNAME}\" removed" \
        "$(user_gone "$USERNAME")" \
        "getent passwd $USERNAME  →  chattr -i /etc/passwd /etc/shadow; userdel -r $USERNAME"

    if getent passwd "$USERNAME" &>/dev/null; then
        check S3 8 "\"${USERNAME}\" removed from sudo/wheel group" \
            "$(not_in_sudo "$USERNAME")" \
            "id -nG $USERNAME | grep -E 'sudo|wheel'  →  gpasswd -d $USERNAME sudo"
    else
        check S3 8 "\"${USERNAME}\" removed from sudo/wheel group (user gone)" 1 ""
    fi

    check S3 5 "/etc/sudoers.d/99-${USERNAME} removed" \
        "$(file_gone "/etc/sudoers.d/99-${USERNAME}")" \
        "lsattr /etc/sudoers.d/99-${USERNAME}  →  chattr -i /etc/sudoers.d/99-${USERNAME}; rm /etc/sudoers.d/99-${USERNAME}"

    SUDOERS_FILE="/etc/sudoers.d/99-${USERNAME}"
    if [[ ! -e "$SUDOERS_FILE" ]]; then
        check S3 3 "/etc/sudoers.d/99-${USERNAME} immutable flag cleared (file gone)" 1 ""
    else
        check S3 3 "/etc/sudoers.d/99-${USERNAME} immutable (chattr +i) flag cleared" \
            "$(not_immutable "$SUDOERS_FILE")" \
            "lsattr /etc/sudoers.d/99-${USERNAME}  →  chattr -i /etc/sudoers.d/99-${USERNAME}"
    fi
done

check S3 5 "/etc/passwd immutable (chattr +i) flag cleared" \
    "$(not_immutable /etc/passwd)" \
    "lsattr /etc/passwd  →  chattr -i /etc/passwd"

check S3 5 "/etc/shadow immutable (chattr +i) flag cleared" \
    "$(not_immutable /etc/shadow)" \
    "lsattr /etc/shadow  →  chattr -i /etc/shadow"

ALL_GONE=1
for u in ubuntu johnredteam "systemd-bus-proxy"; do
    [[ -e "/etc/sudoers.d/99-${u}" ]] && ALL_GONE=0 && break
done
check S3 3 "All /etc/sudoers.d drop-ins removed (all three gone — bonus)" "$ALL_GONE" \
    "ls /etc/sudoers.d/  →  remove all 99-ubuntu, 99-johnredteam, 99-systemd-bus-proxy files"

subtotal "$S3" 100

# =============================================================================
# CATEGORY 4 – REMOTE ACCESS HARDENED (100 pts)
# Blue team gets points for locking down the intentionally permissive remote
# access services installed by RemoteAccess_OpenDoorPolicy.
# =============================================================================
section "CATEGORY 4 – REMOTE ACCESS HARDENED (100 pts)"

# -- SSH hardening ------------------------------------------------------------
SSH_NO_ROOT=1
grep -qiE '^\s*PermitRootLogin\s+yes' /etc/ssh/sshd_config 2>/dev/null && SSH_NO_ROOT=0
for _f in /etc/ssh/sshd_config.d/*.conf; do
    [[ -f "$_f" ]] && grep -qiE '^\s*PermitRootLogin\s+yes' "$_f" 2>/dev/null && SSH_NO_ROOT=0
done
check S4 15 "SSH: PermitRootLogin is not 'yes' in sshd_config" \
    "$SSH_NO_ROOT" \
    "grep -ri PermitRootLogin /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null  →  set PermitRootLogin no; systemctl restart sshd"

SSH_NO_EMPTY=1
grep -qiE '^\s*PermitEmptyPasswords\s+yes' /etc/ssh/sshd_config 2>/dev/null && SSH_NO_EMPTY=0
for _f in /etc/ssh/sshd_config.d/*.conf; do
    [[ -f "$_f" ]] && grep -qiE '^\s*PermitEmptyPasswords\s+yes' "$_f" 2>/dev/null && SSH_NO_EMPTY=0
done
check S4 15 "SSH: PermitEmptyPasswords is not 'yes' in sshd_config" \
    "$SSH_NO_EMPTY" \
    "grep -ri PermitEmptyPasswords /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null  →  set PermitEmptyPasswords no; systemctl restart sshd"

# -- Telnet -------------------------------------------------------------------
check S4 12 "Telnet port 23/TCP not listening (cleartext shell disabled)" \
    "$(port_gone 23)" \
    "ss -tlnp | grep :23  →  systemctl disable --now inetd (or xinetd); remove telnet entry from /etc/inetd.conf or /etc/xinetd.d/telnet"

# -- Cockpit ------------------------------------------------------------------
COCKPIT_DOWN=0
systemctl is-active --quiet cockpit.socket 2>/dev/null || COCKPIT_DOWN=1
check S4 10 "Cockpit web management (cockpit.socket) stopped" \
    "$COCKPIT_DOWN" \
    "systemctl is-active cockpit.socket  →  systemctl disable --now --mask cockpit.socket"

COCKPIT_ORIGINS_OK=1
if [[ -f "/etc/cockpit/cockpit.conf" ]]; then
    grep -qF 'Origins = *' /etc/cockpit/cockpit.conf 2>/dev/null && COCKPIT_ORIGINS_OK=0
fi
check S4  5 "Cockpit config: wildcard Origins removed or config file gone" \
    "$COCKPIT_ORIGINS_OK" \
    "cat /etc/cockpit/cockpit.conf | grep Origins  →  remove 'Origins = *' line or rm /etc/cockpit/cockpit.conf"

# -- Shellinabox --------------------------------------------------------------
check S4 10 "Shellinabox browser terminal (port 4200) not listening" \
    "$(port_gone 4200)" \
    "ss -tlnp | grep :4200  →  systemctl disable --now shellinabox (or shellinaboxd)"

# -- RSH / RLOGIN trust files -------------------------------------------------
HOSTS_EQUIV_OK=1
if [[ -f "/etc/hosts.equiv" ]]; then
    grep -qE '^\+\s*$' /etc/hosts.equiv 2>/dev/null && HOSTS_EQUIV_OK=0
fi
check S4 10 "/etc/hosts.equiv does not trust all hosts (no bare '+' line)" \
    "$HOSTS_EQUIV_OK" \
    "cat /etc/hosts.equiv  →  rm /etc/hosts.equiv  (or remove the '+' wildcard entry)"

RHOSTS_OK=1
if [[ -f "/root/.rhosts" ]]; then
    grep -qE '^\+\s+\+\s*$' /root/.rhosts 2>/dev/null && RHOSTS_OK=0
fi
check S4 10 "/root/.rhosts does not trust all hosts (no '+ +' entry)" \
    "$RHOSTS_OK" \
    "cat /root/.rhosts  →  rm /root/.rhosts"

# -- TFTP ---------------------------------------------------------------------
check S4 13 "TFTP port 69/UDP not listening (unauthenticated file transfer disabled)" \
    "$(udp_gone 69)" \
    "ss -ulnp | grep :69  →  systemctl disable --now tftpd-hpa; or remove /etc/xinetd.d/tftp and restart xinetd"

subtotal "$S4" 100

# =============================================================================
# CATEGORY 5 – MALICIOUS MODULES REMOVED (100 pts)
# Blue team gets points for cleaning LD_PRELOAD hijacking and PAM backdoors
# installed by LoadsOfIssues and ExWifeNamedPAM.
# =============================================================================
section "CATEGORY 5 – MALICIOUS MODULES REMOVED (100 pts)"

# -- LD_PRELOAD hijack --------------------------------------------------------
LD_PRELOAD_CLEAN=0
if [[ ! -e "/etc/ld.so.preload" ]] || [[ ! -s "/etc/ld.so.preload" ]]; then
    LD_PRELOAD_CLEAN=1
fi
check S5 15 "/etc/ld.so.preload empty or removed (LD_PRELOAD system-wide hijack cleared)" \
    "$LD_PRELOAD_CLEAN" \
    "cat /etc/ld.so.preload  →  rm /etc/ld.so.preload  (file should be absent or empty)"

LIB_GONE=1
for _lib in /usr/lib/x86_64-linux-gnu/libccdc_hijack.so \
            /usr/lib64/libccdc_hijack.so \
            /usr/lib/libccdc_hijack.so; do
    [[ -e "$_lib" ]] && LIB_GONE=0 && break
done
check S5 12 "libccdc_hijack.so malicious shared library removed from system library path" \
    "$LIB_GONE" \
    "find /usr/lib /usr/lib64 -name 'libccdc_hijack.so' 2>/dev/null  →  rm that file"

# -- ccdc-flag hidden service -------------------------------------------------
CCDCFLAG_GONE=1
[[ -e "/etc/systemd/system/ccdc-flag.service" ]] && CCDCFLAG_GONE=0
systemctl is-active --quiet ccdc-flag 2>/dev/null && CCDCFLAG_GONE=0
check S5 12 "ccdc-flag service (hidden port-8888 flag server) stopped and unit removed" \
    "$CCDCFLAG_GONE" \
    "systemctl status ccdc-flag; ls /etc/systemd/system/ccdc-flag.service  →  systemctl disable --now ccdc-flag; rm /etc/systemd/system/ccdc-flag.service; systemctl daemon-reload"

# -- Training payload directory -----------------------------------------------
check S5 12 "/opt/ccdc_training directory (LD_PRELOAD + PAM payloads) removed" \
    "$(dir_gone /opt/ccdc_training)" \
    "ls -la /opt/ccdc_training/  →  rm -rf /opt/ccdc_training/  (contains FLAG.py, flag_service.py, pam scripts)"

# -- PAM backdoors ------------------------------------------------------------
PAM_NO_PERMIT=1
for _f in /etc/pam.d/common-auth /etc/pam.d/system-auth /etc/pam.d/password-auth; do
    [[ -f "$_f" ]] && grep -qF "pam_permit_all" "$_f" 2>/dev/null && PAM_NO_PERMIT=0 && break
done
check S5 15 "PAM config: pam_permit_all.sh always-succeed auth bypass removed" \
    "$PAM_NO_PERMIT" \
    "grep -r 'pam_permit_all' /etc/pam.d/  →  restore from /etc/pam.d/common-auth.backup.ccdc_training (or system-auth)"

PAM_NO_CAPTURE=1
for _f in /etc/pam.d/common-auth /etc/pam.d/system-auth /etc/pam.d/password-auth; do
    [[ -f "$_f" ]] && grep -qF "pam_capture" "$_f" 2>/dev/null && PAM_NO_CAPTURE=0 && break
done
check S5  8 "PAM config: pam_capture.so credential harvester module removed" \
    "$PAM_NO_CAPTURE" \
    "grep -r 'pam_capture' /etc/pam.d/  →  restore from /etc/pam.d/common-auth.backup.ccdc_training"

# -- Sudoers bypass entries ---------------------------------------------------
SUDOERS_CLEAN=1
grep -qF 'CCDC_Training' /etc/sudoers 2>/dev/null && SUDOERS_CLEAN=0
check S5 15 "/etc/sudoers: CCDC_Training NOPASSWD:ALL bypass entries removed" \
    "$SUDOERS_CLEAN" \
    "grep -n 'CCDC_Training' /etc/sudoers  →  visudo and delete lines containing '# CCDC_Training'"

# -- SSH drop-in backdoor config ----------------------------------------------
check S5 11 "/etc/ssh/sshd_config.d/ccdc_training.conf (PAM script SSH backdoor) removed" \
    "$(file_gone /etc/ssh/sshd_config.d/ccdc_training.conf)" \
    "cat /etc/ssh/sshd_config.d/ccdc_training.conf  →  rm /etc/ssh/sshd_config.d/ccdc_training.conf; systemctl restart sshd"

subtotal "$S5" 100

# =============================================================================
# TERMINAL SUMMARY TABLE
# =============================================================================
TOTAL=$((S1+S2+S3+S4+S5))

score_color() {
    local s=$1
    if   [[ $s -ge 70 ]]; then echo -e "$GREEN"
    elif [[ $s -ge 40 ]]; then echo -e "$YELLOW"
    else echo -e "$RED"; fi
}

echo -e ""
echo -e "${CYAN}========================================================${RESET}"
echo -e "${CYAN}  CCDC LINUX DEFENDER SCORE${RESET}"
echo -e "${CYAN}========================================================${RESET}"
printf "${WHITE}  %-30s${RESET} $(score_color $S1)%3d / 100${RESET}\n" "Scored Services:"           "$S1"
printf "${WHITE}  %-30s${RESET} $(score_color $S2)%3d / 100${RESET}\n" "Persistence Removed:"       "$S2"
printf "${WHITE}  %-30s${RESET} $(score_color $S3)%3d / 100${RESET}\n" "Rogue Users Removed:"       "$S3"
printf "${WHITE}  %-30s${RESET} $(score_color $S4)%3d / 100${RESET}\n" "Remote Access Hardened:"    "$S4"
printf "${WHITE}  %-30s${RESET} $(score_color $S5)%3d / 100${RESET}\n" "Malicious Modules Removed:" "$S5"
echo -e "${CYAN}--------------------------------------------------------${RESET}"
printf "${WHITE}  %-30s %3d / 500${RESET}\n" "TOTAL:" "$TOTAL"
echo -e "${CYAN}========================================================${RESET}"
echo -e ""

# =============================================================================
# HTML REPORT GENERATION
# =============================================================================
generate_html_report() {
    local report_path="/tmp/ccdc_score_report.html"
    local _host; _host=$(hostname 2>/dev/null || echo "unknown")
    local _ts;   _ts=$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)
    local _user; _user=$(logname 2>/dev/null || echo "root")

    local _total=$((S1+S2+S3+S4+S5))
    local _pct=$(( _total * 100 / 500 ))

    local _score_color="#f85149"
    local _grade="FAILING"
    local _grade_cls="grade-red"
    [[ $_total -ge 200 ]] && _score_color="#d29922" && _grade="NEEDS WORK" && _grade_cls="grade-yellow"
    [[ $_total -ge 350 ]] && _score_color="#3fb950" && _grade="PASSING"    && _grade_cls="grade-green"

    local -a _cnames=("Scored Services" "Persistence Removed" "Rogue Users Removed" "Remote Access Hardened" "Malicious Modules Removed")
    local -a _cscores=("$S1" "$S2" "$S3" "$S4" "$S5")
    local -a _cicons=("⚡" "🪲" "👤" "🌐" "☣️")

    local _total_pass=0 _total_fail=0
    for _p in "${R_PASS[@]}"; do [[ "$_p" == "1" ]] && ((_total_pass++)) || ((_total_fail++)); done

    {
        # ── Head & CSS ────────────────────────────────────────────────────────
        cat << 'CSSEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CCDC Linux Defender Report</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#0d1117;color:#c9d1d9;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;font-size:14px;line-height:1.5}
.page-hdr{background:linear-gradient(160deg,#0d1117 0%,#161b22 100%);border-bottom:1px solid #30363d;padding:2rem 2rem 1.5rem;text-align:center}
.page-hdr h1{font-size:1.65rem;color:#58a6ff;letter-spacing:.07em;text-transform:uppercase;margin-bottom:.35rem}
.page-hdr .meta{color:#6e7681;font-family:'Courier New',monospace;font-size:.78rem}
.score-hero{display:flex;align-items:center;justify-content:center;gap:3rem;padding:2rem 1rem 1.5rem;background:#161b22;border-bottom:1px solid #30363d;flex-wrap:wrap}
.score-dial{text-align:center}
.score-dial .pts{font-size:4.5rem;font-weight:700;line-height:1;letter-spacing:-.02em}
.score-dial .of{font-size:.95rem;color:#6e7681;margin-top:.2rem}
.score-dial .grade{display:inline-block;margin-top:.6rem;padding:.25rem .9rem;border-radius:20px;font-size:.78rem;font-weight:700;letter-spacing:.12em;text-transform:uppercase}
.grade-green{background:#0d2318;color:#3fb950;border:1px solid #3fb950}
.grade-yellow{background:#2d1f00;color:#d29922;border:1px solid #d29922}
.grade-red{background:#2d1217;color:#f85149;border:1px solid #f85149}
.score-breakdown{min-width:260px}
.bk-row{display:flex;align-items:center;gap:.5rem;margin-bottom:.45rem;font-size:.82rem}
.bk-name{width:185px;color:#8b949e;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.bk-bar-wrap{flex:1;background:#21262d;border-radius:3px;height:7px}
.bk-bar{height:7px;border-radius:3px}
.bk-pts{width:48px;text-align:right;font-family:'Courier New',monospace;font-size:.78rem;color:#8b949e}
.stat-row{display:flex;justify-content:center;gap:2.5rem;padding:1rem 1rem 1.2rem;background:#0d1117;border-bottom:1px solid #30363d;flex-wrap:wrap}
.stat-box{text-align:center}
.stat-box .stat-num{font-size:1.65rem;font-weight:700;line-height:1}
.stat-box .stat-lbl{font-size:.7rem;color:#6e7681;text-transform:uppercase;letter-spacing:.06em;margin-top:.2rem}
.sn-blue{color:#58a6ff}.sn-green{color:#3fb950}.sn-red{color:#f85149}.sn-yellow{color:#d29922}
.content{max-width:980px;margin:0 auto;padding:1.5rem 1rem 3rem}
.cat-card{background:#161b22;border:1px solid #30363d;border-radius:8px;margin-bottom:1.5rem;overflow:hidden}
.cat-hdr{display:flex;align-items:center;padding:.85rem 1rem;background:#0d1117;border-bottom:1px solid #30363d;gap:.7rem}
.cat-hdr .icon{font-size:1.1rem;flex:0 0 1.4rem;text-align:center}
.cat-hdr .title{flex:1;font-weight:600;font-size:.95rem;color:#e6edf3}
.cat-hdr .cat-pts{font-family:'Courier New',monospace;font-size:.88rem;color:#8b949e;margin-right:.75rem;white-space:nowrap}
.cat-hdr .prog-wrap{width:90px;background:#21262d;border-radius:4px;height:8px;flex-shrink:0}
.cat-hdr .prog-fill{height:8px;border-radius:4px}
table{width:100%;border-collapse:collapse}
th{background:#0d1117;color:#6e7681;font-size:.7rem;text-transform:uppercase;letter-spacing:.06em;padding:.45rem .75rem;text-align:left;border-bottom:1px solid #30363d;white-space:nowrap}
td{padding:.5rem .75rem;border-bottom:1px solid #1c2129;vertical-align:top;font-size:.82rem}
tr:last-child td{border-bottom:none}
.r-pass td{background:#0d2318}.r-fail td{background:#2d1217}
.badge{display:inline-block;padding:.1rem .45rem;border-radius:4px;font-size:.68rem;font-weight:700;font-family:'Courier New',monospace;white-space:nowrap}
.badge-pass{background:#3fb950;color:#000}.badge-fail{background:#f85149;color:#fff}
.pts-pass{color:#3fb950;font-family:'Courier New',monospace;font-size:.82rem;white-space:nowrap;text-align:right}
.pts-fail{color:#484f58;font-family:'Courier New',monospace;font-size:.82rem;white-space:nowrap;text-align:right}
.hint-box{margin-top:.35rem;background:#0d1117;border-left:3px solid #f85149;padding:.3rem .6rem;border-radius:0 4px 4px 0;font-family:'Courier New',monospace;font-size:.75rem;color:#8b949e;word-break:break-all}
.hint-lbl{color:#f85149;font-weight:700;margin-right:.4rem}
.footer{text-align:center;padding:1.5rem;border-top:1px solid #30363d;color:#484f58;font-size:.77rem;margin-top:1.5rem}
@media(max-width:600px){.score-hero{flex-direction:column}.score-breakdown{width:100%}.bk-name{width:140px}}
</style>
</head>
<body>
CSSEOF

        # ── Page header ───────────────────────────────────────────────────────
        echo "<div class='page-hdr'>"
        echo "  <h1>⚔ CCDC Linux Defender Report</h1>"
        echo "  <div class='meta'>Host: <strong>$(html_esc "$_host")</strong> &nbsp;·&nbsp; $(html_esc "$_ts") &nbsp;·&nbsp; Run by: $(html_esc "$_user")</div>"
        echo "</div>"

        # ── Score hero ────────────────────────────────────────────────────────
        echo "<div class='score-hero'>"
        echo "  <div class='score-dial'>"
        echo "    <div class='pts' style='color:${_score_color}'>${_total}</div>"
        echo "    <div class='of'>out of 500 pts &nbsp;(${_pct}%)</div>"
        echo "    <div class='grade ${_grade_cls}'>${_grade}</div>"
        echo "  </div>"
        echo "  <div class='score-breakdown'>"
        for _ci in 0 1 2 3 4; do
            local _sc="${_cscores[$_ci]}"
            local _bpct=$(( _sc * 100 / 100 ))
            local _bcol="#58a6ff"
            [[ $_sc -ge 70 ]] && _bcol="#3fb950"
            [[ $_sc -lt 40 ]] && _bcol="#f85149"
            echo "    <div class='bk-row'>"
            echo "      <div class='bk-name'>${_cicons[$_ci]} ${_cnames[$_ci]}</div>"
            echo "      <div class='bk-bar-wrap'><div class='bk-bar' style='width:${_bpct}%;background:${_bcol}'></div></div>"
            echo "      <div class='bk-pts'>${_sc}/100</div>"
            echo "    </div>"
        done
        echo "  </div>"
        echo "</div>"

        # ── Stat row ─────────────────────────────────────────────────────────
        echo "<div class='stat-row'>"
        echo "  <div class='stat-box'><div class='stat-num sn-blue'>${_total}</div><div class='stat-lbl'>Total Score</div></div>"
        echo "  <div class='stat-box'><div class='stat-num sn-green'>${_total_pass}</div><div class='stat-lbl'>Checks Passed</div></div>"
        echo "  <div class='stat-box'><div class='stat-num sn-red'>${_total_fail}</div><div class='stat-lbl'>Checks Failed</div></div>"
        echo "  <div class='stat-box'><div class='stat-num sn-yellow'>${_pct}%</div><div class='stat-lbl'>Score Rate</div></div>"
        echo "</div>"

        # ── Category cards ────────────────────────────────────────────────────
        echo "<div class='content'>"

        for _ci in 0 1 2 3 4; do
            local _svar="S$((_ci+1))"
            local _cname="${_cnames[$_ci]}"
            local _cscore="${_cscores[$_ci]}"
            local _cicon="${_cicons[$_ci]}"
            local _bpct=$_cscore
            local _bcol="#58a6ff"
            [[ $_cscore -ge 70 ]] && _bcol="#3fb950"
            [[ $_cscore -lt 40 ]] && _bcol="#f85149"
            local _cat_pass=0 _cat_fail=0
            for _i in "${!R_SVAR[@]}"; do
                [[ "${R_SVAR[$_i]}" != "$_svar" ]] && continue
                [[ "${R_PASS[$_i]}" == "1" ]] && ((_cat_pass++)) || ((_cat_fail++))
            done

            echo "<div class='cat-card'>"
            echo "  <div class='cat-hdr'>"
            echo "    <span class='icon'>${_cicon}</span>"
            echo "    <span class='title'>Cat $((_ci+1)): $(html_esc "$_cname")</span>"
            echo "    <span class='cat-pts'>${_cscore}/100 &nbsp;·&nbsp; <span style='color:#3fb950'>${_cat_pass}✓</span> <span style='color:#f85149'>${_cat_fail}✗</span></span>"
            echo "    <div class='prog-wrap'><div class='prog-fill' style='width:${_bpct}%;background:${_bcol}'></div></div>"
            echo "  </div>"
            echo "  <table>"
            echo "    <thead><tr><th>Status</th><th style='width:100%'>Check Description</th><th>Pts</th></tr></thead>"
            echo "    <tbody>"

            for _i in "${!R_SVAR[@]}"; do
                [[ "${R_SVAR[$_i]}" != "$_svar" ]] && continue
                local _lbl="${R_LABEL[$_i]}"
                local _pts="${R_PTS[$_i]}"
                local _pass="${R_PASS[$_i]}"
                local _hint="${R_HINT[$_i]}"

                if [[ "$_pass" == "1" ]]; then
                    echo "      <tr class='r-pass'>"
                    echo "        <td><span class='badge badge-pass'>PASS</span></td>"
                    echo "        <td>$(html_esc "$_lbl")</td>"
                    echo "        <td class='pts-pass'>+${_pts}</td>"
                else
                    echo "      <tr class='r-fail'>"
                    echo "        <td><span class='badge badge-fail'>FAIL</span></td>"
                    echo "        <td>$(html_esc "$_lbl")"
                    if [[ -n "$_hint" ]]; then
                        echo "          <div class='hint-box'><span class='hint-lbl'>WHERE TO LOOK →</span>$(html_esc "$_hint")</div>"
                    fi
                    echo "        </td>"
                    echo "        <td class='pts-fail'>+0</td>"
                fi
                echo "      </tr>"
            done

            echo "    </tbody>"
            echo "  </table>"
            echo "</div>"
        done

        echo "</div>" # /content

        # ── Footer ────────────────────────────────────────────────────────────
        echo "<div class='footer'>CCDC Linux Defender Scorer &nbsp;·&nbsp; $(html_esc "$_host") &nbsp;·&nbsp; $(html_esc "$_ts") &nbsp;·&nbsp; Score: ${_total}/500</div>"
        echo "</body></html>"

    } > "$report_path"

    echo -e "${CYAN}========================================================${RESET}"
    echo -e "${CYAN}  HTML REPORT GENERATED${RESET}"
    echo -e "${CYAN}========================================================${RESET}"
    echo -e "${WHITE}  Saved to:${RESET}  ${GREEN}${report_path}${RESET}"
    echo -e "${WHITE}  Open:${RESET}      xdg-open ${report_path}  (if desktop available)"
    echo -e "            or copy to your machine and open in a browser"
    echo -e "${CYAN}========================================================${RESET}"
    echo -e ""
}

generate_html_report
