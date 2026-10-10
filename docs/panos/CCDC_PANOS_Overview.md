# PAN-OS Training Scripts — Overview & Session Handoff

**Project:** Cyber@Stout CCDC Red Team Tools  
**Scope:** PAN-OS 11.1.x misconfiguration suite for blue team hardening exercises  
**Status:** Work-in-progress (lives in `WORK_IN_PROGRESS_setupscripts/`, not yet promoted to `General_Scripts/`)

---

## What This Is

Red team instructors use these scripts to intentionally misconfigure a standalone Palo Alto firewall (PAN-OS 11.1.x) before a CCDC-style training exercise. Blue teams then find and remediate the misconfigurations. After the exercise, the cleanup script restores the firewall to its exact original state using a saved state file.

This is the PAN-OS equivalent of the Linux and Windows setup scripts in the rest of this repo — same concept, different target.

---

## Architecture

```
CCDC_PANOS_Run.py          ← Start here: interactive CLI menu
CCDC_PANOS_WebUI.py        ← Alternative: Flask browser UI (localhost:5000)
  │
  ├── CCDC_PANOS_Setup_DirtyFirewall.py   (12 misconfigs → commit → rogue API key)
  └── CCDC_PANOS_Cleanup.py               (12 reversals → commit → delete state)
        └── panos_lib.py                  (PanosAPI class — all XML API calls)
```

**State file:** `panos_exercise_state.json`  
Written by setup, consumed by cleanup. Contains original values for every setting that gets changed. **Do not delete this file before running cleanup** — without it, exact restoration is impossible.

---

## The 12 Misconfigurations

| # | What Gets Changed | What It Does | Training Value |
|---|---|---|---|
| 1 | Rule logging | Disables `log-start`/`log-end` on every security rule | Blue team loses traffic visibility; must re-enable |
| 2 | Syslog | Creates `ExternalLogging` profile → `172.31.40.6:514 UDP`; redirects system + traffic + threat logs to red team | Log exfiltration; blue team must find and remove |
| 3 | URL filtering | Creates permissive `allow-all` profile; applies to all rules | Removes category blocking; blue team must harden |
| 4 | Security profiles | Strips AV, IPS, anti-spyware profile blocks from all rules | Disables threat prevention; blue team must restore |
| 5 | DNS sinkholing | Deletes sinkhole config from every anti-spyware profile | Removes botnet C2 detection; blue team must restore |
| 6 | App-ID | Sets `application=any` on all security rules | Bypasses application-layer enforcement |
| 7 | SSL decryption | Sets `disabled=yes` on every decryption rule | Blind spot for encrypted traffic |
| 8 | Catch-all rule | Inserts `permit-all-traffic` rule (any→any, all zones, no logging, description `MAINTENANCE-DO-NOT-REMOVE`) | Full bypass at the bottom of the rulebase |
| 9 | Zone flood protection | Deletes flood protection config from all zone protection profiles | Removes DoS mitigation |
| 10 | Management plane | Removes `permitted-ip` list from management interface | Opens admin UI/API to any IP |
| 11 | Rogue admin | Creates superuser `netadmin` / `Winter2024!` | Backdoor account for re-entry |
| 12 | Auth bypass | Creates `LocalBypass` local-DB auth profile; sets it as active management auth | Removes RADIUS/LDAP; blue team must notice auth change |

---

## Key Artifacts Created by Setup

| Item | Value |
|---|---|
| Rogue admin username | `netadmin` |
| Rogue admin password | `Winter2024!` |
| Rogue syslog profile name | `ExternalLogging` |
| Syslog destination | `172.31.40.6:514 UDP` |
| Catch-all rule name | `permit-all-traffic` |
| Auth bypass profile name | `LocalBypass` |
| URL permissive profile name | `allow-all` |
| Rogue API key | Printed to instructor terminal at end of setup; saved in state file |
| State file | `panos_exercise_state.json` (written next to setup script) |
| Web UI PIN | `ccdc2024` (override with `PANOS_UI_PIN` env var) |

---

## File Map

| File | Role |
|---|---|
| `WORK_IN_PROGRESS_setupscripts/CCDC_PANOS_Run.py` | CLI orchestrator — main entry point |
| `WORK_IN_PROGRESS_setupscripts/CCDC_PANOS_WebUI.py` | Flask web UI alternative |
| `WORK_IN_PROGRESS_setupscripts/CCDC_PANOS_Setup_DirtyFirewall.py` | 12-step misconfiguration engine |
| `WORK_IN_PROGRESS_setupscripts/CCDC_PANOS_Cleanup.py` | 12-step reversal engine |
| `General_Scripts/SetupScripts/panos/panos_lib.py` | `PanosAPI` shared library (all XML API calls) |
| `docs/panos/CCDC_PANOS_Plan.md` | Full design doc with API reference and future ideas |
| `docs/panos/panos-guide.html` | Styled HTML reference guide |
| `Injects/42 - PAN-OS Rulebase Assessment.pdf` | Blue team inject |
| `Injects/43 - PAN-OS Log Forwarding Plan.pdf` | Blue team inject |
| `Injects/48 - PAN-OS Version Assessment.pdf` | Blue team inject |
| `Injects/49 - PAN-OS Management Access Audit.pdf` | Blue team inject |

---

## How to Run

### Prerequisites

- Python 3.x with `requests` installed (`pip install requests`)
- Flask installed for web UI (`pip install flask`)
- PAN-OS device reachable over HTTPS from the script machine
- A superuser account with XML API access enabled on the firewall
- Baseline config with at least: security rules, URL filtering profile, anti-spyware profile with DNS sinkholing, decryption policy, zone protection profiles

### Option A — CLI (recommended)

```bash
cd WORK_IN_PROGRESS_setupscripts/
python CCDC_PANOS_Run.py
```

1. Enter firewall IP
2. Enter admin username + password (auto-generates API key) — or paste an API key directly
3. Menu appears:
   - `[1]` Apply dirty state — type `yes` to confirm → runs all 12 misconfigs → commits → prints rogue API key
   - `[2]` Run cleanup → type `yes` to confirm → reads `panos_exercise_state.json` → reverses all 12 → commits → deletes state file
   - `[3]` Exit

### Option B — Web UI

```bash
cd WORK_IN_PROGRESS_setupscripts/
python CCDC_PANOS_WebUI.py
# Browse to http://localhost:5000
# PIN: ccdc2024
```

Same workflow as CLI but in a browser with live streaming log output via Server-Sent Events.

---

## panos_lib.py Quick Reference

`PanosAPI` wraps the PAN-OS XML API (`https://<ip>/api/`). TLS verification is disabled (self-signed certs expected).

```python
from panos_lib import PanosAPI

# From credentials
api = PanosAPI.from_credentials("192.168.1.1", "admin", "password")

# From existing API key
api = PanosAPI("192.168.1.1", "LUFRPT1...")

# Common calls
api.config_get(xpath)
api.config_set(xpath, element_xml)
api.config_edit(xpath, element_xml)
api.config_delete(xpath)
api.op("show system info")
api.commit("description")

# Helpers
api.security_rules()       # list of rule names
api.decryption_rules()     # list of rule names
api.spyware_profiles()     # list of profile names
api.zone_protection_profiles()
api.get_password_hash("plaintext")  # returns phash for admin creation
```

---

## Warnings

- **State file is sacred.** If `panos_exercise_state.json` is deleted before cleanup, the firewall cannot be precisely restored — you'll need to manually reconfigure it.
- **Rogue API key is ephemeral.** It's printed once to the instructor's terminal at setup time and stored in the state file. If both are lost, you can still log in as `netadmin` / `Winter2024!` while the dirty state is active.
- **Commit is part of setup and cleanup.** Both scripts call `api.commit()` at the end — changes take effect immediately on the live device.
- **Scripts are in WORK_IN_PROGRESS.** They haven't been promoted to `General_Scripts/` yet. Don't assume the path is stable.

---

## Future Ideas (not yet implemented)

From `CCDC_PANOS_Plan.md`:
- Weak SNMP community strings
- NTP pointing to attacker-controlled server
- Insecure destination NAT exposure
- Custom App-ID override rules to bypass application enforcement
- GlobalProtect misconfiguration
