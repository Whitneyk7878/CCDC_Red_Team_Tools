# Distro Support (All Phase 2 Linux Scripts)

**All Phase 2 Linux scripts must support Ubuntu, Fedora, and Oracle Linux 9.**

- Distro detection via `/etc/os-release` (`ID` field): `ubuntu`/`debian` → apt, `fedora` → dnf + Docker CE fedora repo, `ol`/`rhel`/`centos` → dnf + Docker CE rhel repo.
- Service names differ: `apache2` (Ubuntu/Debian) vs `httpd` (RHEL-family/Fedora/Oracle). Include both in any `systemctl` commands.
- Shell/package manager differences: use `apt-get` for Ubuntu, `dnf` for Fedora/Oracle Linux 9.
- When installing packages, check if already present before installing to keep scripts idempotent.

---

# Context

Phase 2 of the CCDC Red Team exercise. New setup scripts that challenge the blue team with MITRE ATT&CK techniques not yet properly covered in Phase 1. Scripts follow the same naming convention, header style, and helper-function patterns established in Phase 1 (`CCDC_<OS>_<Category>_<FunName>.<ext>`).

After building this plan, the MD file is copied to `Phase_2_Tools/Scripts_Planning/` so future sessions can reference it when developing each script one by one.

---

## Phase 1 Coverage Notes

| Technique | ID | Status | Note |
|---|---|---|---|
| BITS Jobs | T1197 | Phase 1 exists but interactive | `CCDC_Windows_BITS_BitsAndPieces.ps1` loops in PowerShell — Phase 2 replaces it with a true background/fire-and-forget version |
| Pre-OS Boot: Bootkit (destructive) | T1542.003 | Phase 1 has it | `40_nyan_hell.sh` bricks the host — not useful for active CCDC red teaming; Phase 2 does a stealthy *strategic* variant instead |

---

## New Phase 2 Scripts — 11 Total

All go under `Phase_2_Tools/General_Scripts/SetupScripts/<os>/`.

| # | Script Filename | MITRE ID | Sub-Technique | OS | Strategic Value |
|---|---|---|---|---|---|
| 1 | `CCDC_Linux_Rootkit_KernelSneak.sh` | T1014 | Rootkit | Linux | Compiles + installs an LKM that hides named processes, files with a magic prefix, and TCP connections from `/proc`; persists via `/etc/modules-load.d/` so it reloads on boot |
| 2 | `CCDC_Windows_Rootkit_WhoAmIAnyway.ps1` | T1014 | Rootkit | Windows | User-mode rootkit: patches AMSI + ETW in-memory in the current session, installs a global WH_CBT hook DLL that strips named processes from `EnumProcesses` / WMI queries, hides payload registry keys |
| 3 | `CCDC_Linux_TrafficSignal_KnockKnock.sh` | T1205.001 | Port Knocking | Linux | Configures iptables `recent`-module 3-port knock sequence; correct knock opens a reverse-shell listener for 30 s then re-closes it; disguised as a `ufw-compat` systemd unit |
| 4 | `CCDC_Windows_TrafficSignal_WhosThere.ps1` | T1205 | Traffic Signaling | Windows | Deploys a WinPcap/Npcap BPF listener as a service; a magic crafted UDP packet to any port triggers a waiting reverse shell; service registered as `NdisFilterHelper` |
| 5 | `CCDC_Linux_SoftwareDeploy_ChefMischief.sh` | T1072 | Software Deployment Tools | Linux | Installs Chef Infra Client silently; drops a malicious cookbook (`base_config`) that kills scored services and plants SSH authorized keys; registers a recurring `chef-client` daemon so payloads redeploy on schedule |
| 6 | `CCDC_Windows_SoftwareDeploy_ChocolateFactory.ps1` | T1072 | Software Deployment Tools | Windows | Installs Chocolatey silently; registers a rogue local package source; creates a "scheduled maintenance" task (SYSTEM) that installs a malicious `.nupkg` payload; also hooks PDQ Deploy if found |
| 7 | `CCDC_Linux_PreOSBoot_BootStrap.sh` | T1542.001 | Pre-OS Boot (strategic) | Linux | Injects an initramfs hook (`/etc/initramfs-tools/scripts/init-bottom/`) that runs *before userspace starts* on every boot; hook silently re-plants SSH keys, re-creates rogue users, and restores masked services — blue team can clean everything, but the next reboot re-installs it all; **CCDC gold**: survives full persistence wipe as long as blue team doesn't rebuild the initramfs |
| 8 | `CCDC_Linux_ProcessInject_PTraced.sh` | T1055.008 | ptrace Injection | Linux | C helper binary + wrapper script; attaches to a target PID via `ptrace`, writes shellcode into an RWX mapping, hijacks `RIP` to execute, then restores the process; defaults to targeting first `apache2` or `sshd` PID found |
| 9 | `CCDC_Windows_ProcessInject_Hollowman.ps1` | T1055.012 | Process Hollowing | Windows | Spawns `svchost.exe -k netsvcs` suspended, unmaps its image via `NtUnmapViewOfSection`, maps payload PE in its place, patches PEB image base, resumes thread; falls back to APC injection into `spoolsv.exe` |
| 10 | `CCDC_Linux_ImplantImage_DockerPoisoner.sh` | T1525 | Implant Internal Image | Linux | Enumerates all local Docker images; builds a poisoned layer that adds a reverse-shell cron entry + SSH authorized key; re-tags it as the original `name:tag`; pushes back to any configured local registry; cleans layer history |
| 11 | `CCDC_Windows_BITS_BackgroundBeef.ps1` | T1197 | BITS Jobs (non-interactive) | Windows | Registers a BITS job via `Start-BitsTransfer -Asynchronous` or `bitsadmin /create` then **exits immediately** — Windows manages the job in the background with no resident PowerShell process; job is disguised as Windows Update telemetry, set to `RESUME_ON_RESTART` for persistence |

---

## Naming & Style Rules (Phase 1 conventions)

- **Linux**: `#!/usr/bin/env bash` + `set -euo pipefail`; color helpers `info()` `warn()` `success()` `err()`; root check via `$EUID`
- **Windows**: `#Requires -RunAsAdministrator` + `Set-StrictMode -Version Latest`; color helpers `Write-Info` `Write-Warn` `Write-Success` `Write-Err`
- **ASCII banner**: `///////...\\\\\\` border style matching Phase 1
- Attribution comment + original prompt quote in every header

---

## File Destinations

```
Phase_2_Tools/General_Scripts/SetupScripts/
├── linux/
│   ├── CCDC_Linux_Rootkit_KernelSneak.sh
│   ├── CCDC_Linux_TrafficSignal_KnockKnock.sh
│   ├── CCDC_Linux_SoftwareDeploy_ChefMischief.sh
│   ├── CCDC_Linux_PreOSBoot_BootStrap.sh
│   ├── CCDC_Linux_ProcessInject_PTraced.sh
│   └── CCDC_Linux_ImplantImage_DockerPoisoner.sh
└── windows/
    ├── CCDC_Windows_Rootkit_WhoAmIAnyway.ps1
    ├── CCDC_Windows_TrafficSignal_WhosThere.ps1
    ├── CCDC_Windows_SoftwareDeploy_ChocolateFactory.ps1
    ├── CCDC_Windows_ProcessInject_Hollowman.ps1
    └── CCDC_Windows_BITS_BackgroundBeef.ps1
```

Also copy this plan to:
```
Phase_2_Tools/Scripts_Planning/Phase2_Scripts_Plan.md
```

---

## Stub File Format

Each script file will be created as a stub (empty except for a header comment block) so future sessions can develop them individually. The comment block in each file will contain:
- Script filename + plan reference path
- MITRE ATT&CK ID and technique name
- OS and privilege requirements
- Full description of what the script will do and be capable of
- Key implementation notes from this plan

---

## Verification

After creation:
```bash
find Phase_2_Tools/General_Scripts/SetupScripts -name "*.sh" -o -name "*.ps1" | sort
# Should list all 11 scripts

ls Phase_2_Tools/Scripts_Planning/Phase2_Scripts_Plan.md
# Should exist

# Syntax check Linux stubs:
for f in Phase_2_Tools/General_Scripts/SetupScripts/linux/*.sh; do bash -n "$f" && echo "OK: $f"; done
```
