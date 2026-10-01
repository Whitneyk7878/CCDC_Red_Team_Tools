# Linux Playbooks — CCDC Tryout

Operational playbooks for the Linux track.

## Playbooks

| File | Phase | Scripts covered |
|---|---|---|
| [target-setup-playbook.md](target-setup-playbook.md) | Pre-game / provisioning | `CCDC_Linux_TargetSetup_HTTP_Mail_Splunk.sh` |
| [setup-playbook.md](setup-playbook.md) | Pre-game / initial access | The four attack SetupScripts |
| [runtime-playbook.md](runtime-playbook.md) | In-game / active attack | `RuntimeScripts/linux/` |

## High-Level Flow

```
BEFORE competition
  1. Run CCDC_Linux_TargetSetup_HTTP_Mail_Splunk.sh to provision scored services
     (Apache2, Postfix+Dovecot, Splunk)

ONCE YOU HAVE ROOT ACCESS
  2. Run attack setup scripts:
     users → web service → cron jobs → persistence

DURING competition
  3. Escalate through runtime scripts: 00 → 10 → 20 → 30 → 40
```

## Scripts at a Glance

### SetupScripts/linux/ — target provisioning

| Script | Phase | What it sets up |
|---|---|---|
| `CCDC_Linux_TargetSetup_HTTP_Mail_Splunk.sh` | Pre-game | Apache2 (port 80), Postfix+Dovecot (25/110/143), Splunk (8000) |

### SetupScripts/linux/ — red team attack

| Script | What it plants |
|---|---|
| `CCDC_Linux_Users_HomeIntruders.sh` | 3 sudo backdoor accounts + immutable `/etc/passwd` and `/etc/shadow` |
| `CCDC_Linux_WebShell_OopsAllWebShells.sh` | Rogue PHP service (`php-session-mgr`) on port 8743 |
| `CCDC_Linux_CronJobs_ImGonnaCron.sh` | 2 cron jobs that keep killing legit services |
| `CCDC_Linux_Persistence_PlantsVsZerodays.sh` | Payload in 5 startup locations |
| `CCDC_Linux_BeeMovie_OopsAllBees.sh` | `systemd-pipewire-multithread-runner` service + timer; re-plants Bee Movie `PROMPT_COMMAND` every 60 s |

### RuntimeScripts/linux/

| Script | Impact |
|---|---|
| `00_drop_service.sh` | Stop + disable apache2/dovecot/postfix/splunk |
| `10_mask_service.sh` | Mask services (harder to start back up) |
| `20_block_with_firewall.sh` | Drop ports 25/80/110/143/443/8000 (persisted across reboots) |
| `30_delete_services.sh` | Purge packages + delete all data ⚠️ irreversible |
| `40_nyan_hell.sh` | Replace UEFI bootloader → host bricks on reboot 💀 |
