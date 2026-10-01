# Linux Setup Playbook — CCDC Red Team

> **Phase:** Pre-game / initial access
> **Run as:** root (all scripts require `EUID=0`)
> **Target OS:** Ubuntu (Debian-based)

These scripts are run **once you have root access** on a target Linux box before or during the early minutes of the competition. Their job is to establish persistence, create backdoor accounts, and plant services/cron jobs that the blue team must find and remove.

---

## Script Execution Order

Run them in this order — each layer depends on the previous one being in place.

```
1. CCDC_Linux_Users_HomeIntruders.sh          ← accounts first (you need them for fallback access)
2. CCDC_Linux_WebShell_OopsAllWebShells.sh    ← rogue service (visible target for blue team)
3. CCDC_Linux_CronJobs_ImGonnaCron.sh         ← cron persistence (keeps killing legit services)
4. CCDC_Linux_Persistence_PlantsVsZerodays.sh ← multi-location payload (hardest to fully remove)
5. CCDC_Linux_BeeMovie_OopsAllBees.sh         ← Bee Movie PROMPT_COMMAND + watchdog service
```

---

## 1 — Rogue Users (`CCDC_Linux_Users_HomeIntruders.sh`)

**What it does:**
- Creates three backdoor accounts with `sudo` (full `NOPASSWD`) privileges:
  | Username | Password | Disguise level |
  |---|---|---|
  | `landscape` | `Gr0undzer0#` | Medium — Ubuntu Landscape service user |
  | `nagios` | `Bl4ckH4t@2025` | Medium — monitoring agent user |
  | `systemd-oom` | `K3rn3lP4n1c$` | High — looks like a systemd internal account |
- Writes a `/etc/sudoers.d/99-<username>` drop-in for each user (second persistence point)
- Sets `chattr +i` (immutable bit) on `/etc/passwd`, `/etc/shadow`, and all three sudoers drop-ins

**Run it:**
```bash
sudo bash SetupScripts/linux/CCDC_Linux_Users_HomeIntruders.sh
```

**Expected output:** Green `[+]` lines confirming each user created, password set, group added, sudoers written, and `chattr +i` applied.

**Blue team must:**
1. `chattr -i /etc/passwd /etc/shadow` — remove immutable flag before they can delete users
2. `chattr -i /etc/sudoers.d/99-landscape` (and the other two)
3. `userdel -r landscape && userdel -r nagios && userdel -r systemd-oom`
4. `rm /etc/sudoers.d/99-landscape /etc/sudoers.d/99-nagios /etc/sudoers.d/99-systemd-oom`

**Notes:**
- `systemd-oom` is the sneaky one — it impersonates a real systemd internal account name. Blue team may skip it.
- The sudoers drop-ins are a second persistence path: even if they delete the users, a re-add + the drop-in gives full root back.

---

## 2 — Rogue Web Service (`CCDC_Linux_WebShell_OopsAllWebShells.sh`)

**What it does:**
- Installs `php-cli` via apt
- Creates a PHP web app at `/opt/php-session-mgr/www/index.php` that displays **"GET RID OF ME!"**
- Registers and starts a systemd service called `php-session-mgr` listening on **port 8743**, running as root
- Enables the service so it persists across reboots

**Run it:**
```bash
sudo bash SetupScripts/linux/CCDC_Linux_WebShell_OopsAllWebShells.sh
```

**Verify it's live:**
```bash
curl http://localhost:8743
ss -tlnp | grep 8743
```

**Blue team must:**
```bash
systemctl stop php-session-mgr
systemctl disable php-session-mgr
rm /etc/systemd/system/php-session-mgr.service
systemctl daemon-reload
rm -rf /opt/php-session-mgr
```

**Notes:**
- The service description reads `"network session management daemon"` — designed to blend in.
- Running on non-standard port 8743; blue team needs to `ss -tlnp` or `netstat` to find it.

---

## 3 — Malicious Cron Jobs (`CCDC_Linux_CronJobs_ImGonnaCron.sh`)

**What it does:**
- Writes two files to `/etc/cron.d/`:
  | File | Schedule | Disguise |
  |---|---|---|
  | `fwupd-notify` | every 5 min | Looks like a firmware update notifier |
  | `apt-daily-compat` | every 3 min | Looks like an apt maintenance job |
- Both jobs run as root and execute: `systemctl stop` + `systemctl mask` on **dovecot, postfix, apache2, splunk**
- Effect: even if blue team starts their services back up, these jobs kill them again within 3–5 minutes

**Run it:**
```bash
sudo bash SetupScripts/linux/CCDC_Linux_CronJobs_ImGonnaCron.sh
```

**Blue team must:**
```bash
rm /etc/cron.d/fwupd-notify /etc/cron.d/apt-daily-compat
# Also unmask and restart their services:
systemctl unmask dovecot postfix apache2 splunkd
systemctl start dovecot postfix apache2 splunkd
```

**Notes:**
- Both cron file names look plausible — blue team must read each one's content to identify them as malicious.
- Blue team often forgets to check `/etc/cron.d/` — they look at user crontabs first.
- The masking means restarting the service is not enough; they must unmask before the service will come back.

---

## 4 — Multi-Location Persistence (`CCDC_Linux_Persistence_PlantsVsZerodays.sh`)

**What it does:**
Deploys a payload script (`inject_evil_service.sh`, which you provide) into **five separate startup locations**:

| # | Location | Trigger |
|---|---|---|
| 1 | `/etc/rc.local` → `/usr/local/lib/.sysinit-helper` | Every boot (SysV shim) |
| 2 | `/etc/profile.d/99-sysenv-init.sh` → `/usr/local/lib/.sysenv-init` | Every root login shell |
| 3 | `/etc/systemd/system/sys-khelper-init.service` → `/usr/local/lib/.khelper-init` | Every boot (systemd oneshot) |
| 4 | `/etc/cron.d/syslogd-helper` → `/usr/local/lib/.syslogd-helper` | `@reboot` via cron |
| 5 | `/root/.bashrc` → `/usr/local/lib/.sysnet-diag` | Every interactive root bash session |

All payload copies are hidden with dot-prefix names inside `/usr/local/lib/`.

**Run it:**
```bash
sudo bash SetupScripts/linux/CCDC_Linux_Persistence_PlantsVsZerodays.sh /path/to/inject_evil_service.sh
```

**Blue team must find and remove ALL of:**
```
/etc/rc.local                              (or clear the payload call from it)
/usr/local/lib/.sysinit-helper
/etc/profile.d/99-sysenv-init.sh
/usr/local/lib/.sysenv-init
/etc/systemd/system/sys-khelper-init.service
/usr/local/lib/.khelper-init
/etc/cron.d/syslogd-helper
/usr/local/lib/.syslogd-helper
/root/.bashrc                              (remove the __sysnet_diag_hook__ block)
/usr/local/lib/.sysnet-diag
```
```bash
systemctl disable sys-khelper-init.service
systemctl daemon-reload
```

**Notes:**
- Script header says "UNTESTED" — dry-run on a VM before competition day.
- The payload copies all have inconspicuous dot-prefix names — blue team must `ls -la /usr/local/lib/` to see them.
- If blue team only finds 3 of 5, the payload keeps coming back on every reboot/login. This is the point.
- Systemd unit description: `"Kernel subsystem helper initialisation"` — looks legitimate.

---

## 5 — Bee Movie Prompt Hook (`CCDC_Linux_BeeMovie_OopsAllBees.sh`)

**What it does:**
- Creates a library at `/usr/local/lib/systemd-pipewire-multithread-runner/` containing an enforcement script and a backup copy of the hook
- Installs `/etc/profile.d/99-pipewire-session-env.sh` — a profile hook that installs a `PROMPT_COMMAND` function into every interactive bash session:
  | Function | Output before each prompt |
  |---|---|
  | `_pipewire_session_env_check` | "According to all known laws of aviation…" (Bee Movie opening) |
- Appends a source line to `/etc/bash.bashrc` so non-login interactive shells also pick up the hook
- Installs `systemd-pipewire-multithread-runner.service` (oneshot) and `systemd-pipewire-multithread-runner.timer` (fires every 60 s); the timer runs the enforcement script which restores the hook from backup if it has been removed or tampered with

**Run it:**
```bash
sudo bash SetupScripts/linux/CCDC_Linux_BeeMovie_OopsAllBees.sh
```

**Expected output:** Blue `[*]` and green `[+]` lines for each installed component; final status shows the timer as `active`.

**Verify it's running:**
```bash
systemctl status systemd-pipewire-multithread-runner.timer
# Then open a new shell — the Bee Movie text should appear before every prompt
```

**Blue team must:**
```bash
# Stop and disable the watchdog
systemctl stop systemd-pipewire-multithread-runner.timer \
               systemd-pipewire-multithread-runner.service
systemctl disable systemd-pipewire-multithread-runner.timer
rm /etc/systemd/system/systemd-pipewire-multithread-runner.service \
   /etc/systemd/system/systemd-pipewire-multithread-runner.timer
systemctl daemon-reload

# Remove the hook and its backup
rm /etc/profile.d/99-pipewire-session-env.sh
rm -rf /usr/local/lib/systemd-pipewire-multithread-runner/

# Remove the source line from /etc/bash.bashrc
# (look for the "systemd-pipewire-multithread-runner" comment block near the bottom)
nano /etc/bash.bashrc

# Open a new shell to confirm the hook is gone
```

**Notes:**
- The service is disguised as "PipeWire Multithread Session Runner" with a real freedesktop.org documentation URL — it blends in with actual PipeWire services on a desktop/audio-capable system.
- The timer fires 30 s after boot and then every 60 s, so removing the hook file buys blue team at most 60 s of clean prompts before it comes back.
- `Persistent=true` on the timer means a missed tick (host was powered off) fires immediately on the next boot.
- The hook is idempotent — it checks `$PROMPT_COMMAND` for the function name before appending, so re-sourcing the file in the same session won't double-install the hook.
- Blue team must also find and remove the `/etc/bash.bashrc` source line, or a new non-login shell will re-source the hook even after the profile.d file is deleted.

---

## Quick Reference — What Blue Team Must Check

```
/etc/cron.d/
/etc/profile.d/              ← includes 99-pipewire-session-env.sh (Bee Movie hook)
/etc/rc.local
/etc/systemd/system/         ← includes systemd-pipewire-multithread-runner.service + .timer
/etc/sudoers.d/
/usr/local/lib/              ← dot-prefix files AND systemd-pipewire-multithread-runner/ library (use ls -la)
/root/.bashrc
/etc/bash.bashrc             ← check for systemd-pipewire-multithread-runner source line near bottom
/opt/php-session-mgr/
/etc/passwd + /etc/shadow    ← check immutable bit with lsattr
```

Check immutable bits:
```bash
lsattr /etc/passwd /etc/shadow
lsattr /etc/sudoers.d/
```
