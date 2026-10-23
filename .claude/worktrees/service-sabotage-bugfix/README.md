# CCDC Tryout — Red Team Scripts

Scripts for the Cyber@Stout CCDC tryout, split into **target setup** (provision competition machines before the match), **attack setup** (plant persistence once you have access), and **runtime** (degrade blue team services during the match).

> **Platform coverage:** Linux ✅ · Windows ✅

---

## Repository Layout

```
.
├── SetupScripts/
│   ├── linux/       ← Target provisioning + attack setup (Bash)
│   └── windows/     ← Target provisioning + attack setup (PowerShell)
├── RuntimeScripts/
│   ├── linux/       ← Escalating service disruption (Bash)
│   └── windows/     ← (not yet written)
└── docs/
    ├── linux/
    │   ├── README.md                ← Linux scripts quick-reference
    │   ├── target-setup-playbook.md ← How to provision the Linux target machine
    │   ├── setup-playbook.md        ← How/when to run Linux attack setup scripts
    │   └── runtime-playbook.md      ← Linux runtime escalation ladder
    └── windows/
        ├── README.md                ← Windows scripts quick-reference
        ├── target-setup-playbook.md ← How to provision the Windows target machine
        └── setup-playbook.md        ← How/when to run Windows attack setup scripts
```

---

## Linux Scripts

### SetupScripts/linux/ — target provisioning (run before competition)

| Script | What it sets up |
|---|---|
| `CCDC_Linux_TargetSetup_HTTP_Mail_Splunk.sh` | Apache2 (port 80), Postfix+Dovecot (25/110/143), Splunk Enterprise (8000) |

### SetupScripts/linux/ — run once on initial access

| Script | What it plants |
|---|---|
| `CCDC_Linux_Users_HomeIntruders.sh` | 3 backdoor sudo accounts + `chattr +i` on `/etc/passwd` and `/etc/shadow` |
| `CCDC_Linux_WebShell_OopsAllWebShells.sh` | Rogue PHP service (`php-session-mgr`) on port 8743 running as root |
| `CCDC_Linux_CronJobs_ImGonnaCron.sh` | 2 cron jobs in `/etc/cron.d/` that stop+mask scored services every 3–5 min |
| `CCDC_Linux_Persistence_PlantsVsZerodays.sh` | Payload dropped in 5 separate startup locations |
| `CCDC_Linux_BeeMovie_OopsAllBees.sh` | Disguised `systemd-pipewire-multithread-runner` service + timer that re-plants a `PROMPT_COMMAND` printing the Bee Movie opening before every bash prompt |

### RuntimeScripts/linux/ — run during the competition

| Script | Impact | Reversible? |
|---|---|---|
| `00_drop_service.sh` | Stop + disable apache2, dovecot, postfix, splunkd | ✅ Yes |
| `10_mask_service.sh` | Mask the same services (requires unmask to recover) | ✅ Yes |
| `20_block_with_firewall.sh` | Drop inbound on ports 25/80/110/143/443/8000 (rules persisted across reboots) | ✅ Yes |
| `30_delete_services.sh` | Purge packages + delete all config/data/logs | ⚠️ No |
| `40_nyan_hell.sh` | Replace UEFI bootloader — host bricks on reboot | 💀 No |

Run 00 → 40 to escalate. See [`docs/linux/runtime-playbook.md`](docs/linux/runtime-playbook.md).

---

## Windows Scripts

### SetupScripts/windows/ — target provisioning (run before competition)

| Script | What it sets up |
|---|---|
| `CCDC_Windows_TargetSetup_HTTP_FTP_DNS.ps1` | IIS HTTP (port 80), IIS FTP (port 21, anonymous), DNS Server (`ccdc.local`) |

### SetupScripts/windows/ — run once on initial access

| Script | What it plants |
|---|---|
| `CCDC_Windows_Users_UsersAreInYourWalls.ps1` | 3 backdoor Domain Admin accounts (one disguised as a service account) |
| `CCDC_Windows_WebShell_SheWebShellOnMyIIS.ps1` | Rogue IIS site on port 8080 with Classic ASP page |
| `CCDC_Windows__ScheduledTasks_ScheduledTaskinator.ps1` | 2 tasks: Notepad alert every 3 min + DNS/IIS/FTP service killer every 3 min |
| `CCDC_Windows_Persistence_ClusterBombShells.ps1` | Payload in 5 startup locations (registry, Winlogon, scheduled task, service, Active Setup) |

---

## Playbooks

Full operational detail — prerequisites, execution order, what blue team must do to remediate — lives in `docs/`:

| Playbook | Covers |
|---|---|
| [`docs/linux/target-setup-playbook.md`](docs/linux/target-setup-playbook.md) | Provisioning the Linux target (Apache2, mail, Splunk) |
| [`docs/linux/setup-playbook.md`](docs/linux/setup-playbook.md) | Linux attack setup scripts (order, how to run, recovery steps) |
| [`docs/linux/runtime-playbook.md`](docs/linux/runtime-playbook.md) | Linux runtime scripts (escalation ladder, timing, caveats) |
| [`docs/windows/target-setup-playbook.md`](docs/windows/target-setup-playbook.md) | Provisioning the Windows target (IIS, FTP, DNS) |
| [`docs/windows/setup-playbook.md`](docs/windows/setup-playbook.md) | Windows attack setup scripts (order, how to run, recovery steps) |

---

## Requirements

| Platform | Privilege | OS |
|---|---|---|
| Linux scripts | `root` (`sudo`) | Ubuntu 24.04 LTS (x86_64) |
| Windows scripts | Administrator | Windows Server 2022 |

**Special cases:**
- `40_nyan_hell.sh` requires the target to be in **UEFI boot mode** with internet access (clones and builds an EFI binary from GitHub).
- `CCDC_Linux_TargetSetup_HTTP_Mail_Splunk.sh` downloads Splunk from the internet — the build hash in the script may be stale; see the [target setup playbook](docs/linux/target-setup-playbook.md) if the download fails.
- `CCDC_Windows_Users_UsersAreInYourWalls.ps1` requires the **ActiveDirectory** PowerShell module — run on a DC or a machine with AD RSAT installed.
