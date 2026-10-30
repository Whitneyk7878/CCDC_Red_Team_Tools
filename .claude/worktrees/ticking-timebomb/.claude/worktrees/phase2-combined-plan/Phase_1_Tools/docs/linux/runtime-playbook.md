# Linux Runtime Playbook — CCDC Red Team

> **Phase:** In-game / active competition
> **Run as:** root on compromised target(s)
> **Target OS:** Ubuntu / Debian-based Linux

These scripts are run **during the competition** once you have shell access on a target. They are designed to degrade or destroy blue team services, lock them out, and ultimately destroy the host. Scripts are numbered in order of escalating impact — **run them in sequence** or selectively based on your objective at that moment.

---

## Escalation Ladder

```
00_drop_service.sh      ← Services down (reversible)
        ↓
10_mask_service.sh      ← Services masked (requires extra step to reverse)
        ↓
20_block_with_firewall.sh ← Ports blocked (network-level denial)
        ↓
30_delete_services.sh   ← Packages and data GONE (destructive, slow to recover)
        ↓
40_nyan_hell.sh         ← Bootloader replaced — host will not boot (nuclear)
```

Start low and escalate as the situation demands. Scripts 30 and 40 are irreversible during competition time.

---

## 00 — Stop & Disable Services (`00_drop_service.sh`)

**Impact:** Low — blue team can recover within seconds if they're watching.
**Reversible:** Yes — `systemctl enable --now <service>`

**What it does:**
- `systemctl stop` + `systemctl disable` on: `apache2`, `dovecot`, `postfix`, `splunkd`
- Services go down immediately; they won't restart on next boot
- Does NOT mask — blue team can bring them back with one command

**Run it:**
```bash
sudo bash RuntimeScripts/linux/00_drop_service.sh
```

**Use when:** You want to briefly knock services down and see if blue team is paying attention. Good opening move or a probe to gauge their monitoring responsiveness.

**Pair with:** The cron jobs from setup (which mask on a 3–5 min cycle) to make recovery painful even after they restart.

---

## 10 — Mask Services (`10_mask_service.sh`)

**Impact:** Medium — requires blue team to explicitly unmask before services can start.
**Reversible:** Yes — `systemctl unmask <service>` then `systemctl start <service>`

**What it does:**
- `systemctl mask` on: `apache2`, `dovecot`, `postfix`, `splunkd`
- Masking symlinks the unit to `/dev/null` — `systemctl start` will hard-fail
- Sends a `wall` broadcast: `"meow meow meow meow we are in your walls meow meow meow meow"`

**Run it:**
```bash
sudo bash RuntimeScripts/linux/10_mask_service.sh
```

**Use when:** Blue team keeps restarting services and you need to add friction. Masked services look broken — less obvious than just stopped. Many blue teamers will try `systemctl start apache2`, see it fail, and not immediately know to check if it's masked.

**Note:** The `wall` broadcast is a fun taunt but also a giveaway that something is happening. Use it knowingly.

**Blue team recovery:**
```bash
systemctl unmask apache2 dovecot postfix splunkd
systemctl start apache2 dovecot postfix splunkd
```

---

## 20 — Firewall Block (`20_block_with_firewall.sh`)

**Impact:** Medium-High — services may be running but unreachable from the network.
**Reversible:** Yes — `iptables -D` or `iptables -F` to flush rules

**What it does:**
Appends `DROP` rules to the `INPUT` chain for:
| Service | Ports |
|---|---|
| HTTP/HTTPS | 80, 443 |
| Splunk web UI | 8000 |
| Dovecot (POP3/IMAP) | 110, 143 |
| Postfix (SMTP) | 25 |

**Run it:**
```bash
sudo bash RuntimeScripts/linux/20_block_with_firewall.sh
```

**Use when:** Blue team has services running and you want to cut them off at the network level without touching the services themselves. Trickier to diagnose — the service is "up" but traffic never arrives.

**Notes:**
- Rules use `-A` (append) not `-I` (insert) — they go to the end of the chain. If blue team has ACCEPT rules earlier in the chain, those may take priority. Check with `iptables -L -n --line-numbers` first.
- Rules are **persisted** across reboots via `netfilter-persistent save` (falls back to writing `/etc/iptables/rules.v4` directly). Blue team must flush the runtime rules AND purge the saved rules or they reload on next boot.
- HTTPS (443) is blocked — if blue team is checking from the browser and gets a connection refused, they'll look at the service first, not the firewall. Buys time.

**Blue team recovery:**
```bash
iptables -F INPUT    # flush all INPUT rules (nuclear option for them)
# or selectively: iptables -D INPUT -p tcp --dport 80 -j DROP  etc.

# Also clear the saved rules so they don't reload on reboot:
netfilter-persistent flush   # if netfilter-persistent is installed
# or:
> /etc/iptables/rules.v4     # truncate the saved ruleset
```

---

## 30 — Purge Services (`30_delete_services.sh`)

> ⚠️ **DESTRUCTIVE AND IRREVERSIBLE** during competition time. Use deliberately.

**Impact:** Critical — packages uninstalled, all config and data deleted, service users removed.
**Reversible:** No — data is gone. Blue team must reinstall from scratch.

**What it does:**
1. Stops and disables: `apache2`, `dovecot`, `postfix`, `splunk`
2. `apt-get purge` on all related packages (apache2, dovecot, postfix and their variants)
3. `rm -rf` on all config, data, log, and spool directories:
   - `/etc/apache2`, `/var/www`, `/var/log/apache2`
   - `/etc/dovecot`, `/var/lib/dovecot`, `/var/mail`, `/var/vmail`
   - `/etc/postfix`, `/var/spool/postfix`, `/var/lib/postfix`
   - `/opt/splunk`, `/opt/splunkforwarder`
4. Deletes service OS users: `postfix`, `dovecot`, `dovenull`, `splunk`

**Run it:**
```bash
sudo bash RuntimeScripts/linux/30_delete_services.sh
```

**Use when:** You have a window where blue team is distracted or understaffed and you want to cause maximum scoring damage. Purging means re-installation and reconfiguration — that takes 10–30+ minutes depending on the service.

**Note:** Script requires `EUID=0` and will exit if not root. It uses `set -euo pipefail` but catches errors with `|| true` where appropriate, so it won't abort mid-run.

**Blue team recovery time estimate:**
| Service | Reinstall + reconfig time |
|---|---|
| apache2 | ~5 min |
| postfix | ~15–20 min |
| dovecot | ~15–20 min |
| Splunk | ~20–30 min |

---

## 40 — Nyan Hell / Bootloader Brick (`40_nyan_hell.sh`)

> 💀 **NUCLEAR OPTION — HOST WILL NOT BOOT NORMALLY AFTER THIS.** Only run on a host you're done with or want to take fully out of scoring.

**Impact:** Total — replaces the UEFI boot entry with a Nyan Cat animation. Host reboots and never returns.
**Reversible:** Only with physical access or out-of-band boot (rescue USB, iLO, IPMI).

**Requirements:**
- Host must be booted in **UEFI mode** (checks `/sys/firmware/efi` — exits if not present)
- ESP must be mounted at `/boot/efi`
- Requires internet access from the target (clones from GitHub)
- Requires `apt` to install: `build-essential`, `gnu-efi`, `git`, `efibootmgr`

**What it does:**
1. Installs build dependencies via apt
2. Clones `https://github.com/ohnx/nyan-load` from GitHub
3. Builds the EFI application (`nyan-load.efi`)
4. Copies it to `<ESP>/EFI/nyanload/nyan-load.efi`
5. Registers a new UEFI boot entry called `"nyan-load"` via `efibootmgr`
6. Sets it as the **first and only** boot order entry
7. Reboots the host

**Run it:**
```bash
sudo bash RuntimeScripts/linux/40_nyan_hell.sh
```

**Timing:** The build step takes ~1–3 minutes. The host goes dark after the final `reboot`.

**Use when:** Scoring is irrelevant for this host, you want it gone, or it's the last action on a box you're done with. Once it reboots, the blue team gets a Nyan Cat screen and no OS.

**Notes:**
- Network access is required to clone the repo — if the target has no internet, this will fail at the `git clone` step.
- BIOS/legacy boot systems will exit early with a clear error message.
- Blue team recovery requires booting from a rescue medium, using `efibootmgr` to delete the `nyan-load` entry and restore their original boot order, then rebooting. This is non-trivial under competition pressure.

---

## Recommended Timing / Sequencing

| Time into competition | Action |
|---|---|
| T+0 (initial access) | Run `00_drop_service.sh` immediately — fast and visible signal |
| T+1 min | Run `10_mask_service.sh` — makes recovery harder |
| T+2 min | Run `20_block_with_firewall.sh` — network-level denial |
| Opportunistic | Run `30_delete_services.sh` if blue team is losing the battle |
| End game | Run `40_nyan_hell.sh` when you want the host fully bricked |

If you've also run the **setup scripts**, the cron jobs will keep masking services every 3–5 minutes — so even if blue team runs their recovery, they need to find the cron jobs too or the services go back down.

---

## Quick Reference — What Services Each Script Targets

| Service | 00 | 10 | 20 | 30 |
|---|---|---|---|---|
| apache2 | stop/disable | mask | block 80/443 | purge+rm |
| dovecot | stop/disable | mask | block 110/143 | purge+rm |
| postfix | stop/disable | mask | block 25 | purge+rm |
| splunkd | stop/disable | mask | block 8000 | purge+rm |

---

## Pre-Run Checklist

```
[ ] Confirmed root access on target
[ ] Target is Debian/Ubuntu based
[ ] Know which scripts apply to this host's role (web server? mail server? log server?)
[ ] Scripts are on target (scp, curl, etc.) or cloned repo is accessible
[ ] 40_nyan_hell.sh: confirmed UEFI boot + internet access if planning to use it
```
