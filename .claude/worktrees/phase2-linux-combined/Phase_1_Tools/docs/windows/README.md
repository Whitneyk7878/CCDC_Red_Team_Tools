# Windows Playbooks — CCDC Tryout

Operational playbooks for the Windows track.

## Playbooks

| File | Phase | Scripts covered |
|---|---|---|
| [target-setup-playbook.md](target-setup-playbook.md) | Pre-game / provisioning | `CCDC_Windows_TargetSetup_HTTP_FTP_DNS.ps1` |
| [setup-playbook.md](setup-playbook.md) | Pre-game / initial access | The four attack SetupScripts |

> Windows RuntimeScripts are not yet written. The Linux escalation ladder (`00` → `40`) is the model to follow when they are.

## High-Level Flow

```
BEFORE competition
  1. On each Windows target: run target setup script (provisions IIS, FTP, DNS)
  2. Once you have Administrator access: run attack setup scripts
     (users → web shell → scheduled tasks → persistence)

DURING competition
  3. Attack services using runtime scripts (TBD) or manual techniques
```

## Scripts at a Glance

### SetupScripts/windows/ — target provisioning

| Script | Phase | What it does |
|---|---|---|
| `CCDC_Windows_TargetSetup_HTTP_FTP_DNS.ps1` | Pre-game | Installs and configures IIS (HTTP), IIS FTP, and DNS Server |

### SetupScripts/windows/ — red team attack

| Script | What it plants |
|---|---|
| `CCDC_Windows_Users_UsersAreInYourWalls.ps1` | 3 backdoor accounts: local Admins always, + AD Domain Admins if domain is available |
| `CCDC_Windows_WebShell_SheWebShellOnMyIIS.ps1` | Rogue IIS site on port 8080 |
| `CCDC_Windows__ScheduledTasks_ScheduledTaskinator.ps1` | 2 scheduled tasks: Notepad alert + service killer |
| `CCDC_Windows_Persistence_ClusterBombShells.ps1` | Payload in 5 startup locations |
