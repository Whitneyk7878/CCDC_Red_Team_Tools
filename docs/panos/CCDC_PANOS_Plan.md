# CCDC PAN-OS Blue Team Training — Plan & Context

## Overview

Three Python scripts that push intentional misconfigurations to a standalone
PAN-OS 11.1.x firewall (via XML API) for blue team hardening exercises, then
clean everything up afterward. Designed for NCCDC-style competition training.

---

## Files

```
General_Scripts/SetupScripts/panos/
├── panos_lib.py                      # Shared XML API helpers (PanosAPI class)
├── CCDC_PANOS_Setup_DirtyFirewall.py # Applies all misconfigs + commits
├── CCDC_PANOS_Cleanup.py             # Reverses all misconfigs + commits
└── CCDC_PANOS_Run.py                 # Interactive orchestrator (main entry point)
```

State is written to `panos_exercise_state.json` in the same directory
after setup runs. Cleanup reads that file and removes it when done.

---

## Misconfigurations Applied by Setup Script

### Visibility / Logging
- Disables `log-end` and `log-start` on all existing security rules
- Creates a syslog server profile (`ExternalLogging`) pointing to `172.31.40.6:514 UDP`
- Redirects system logs to that profile
- Creates a log forwarding profile and applies it to all security rules,
  sending all traffic and threat logs to the red team syslog receiver

### URL Filtering
- Creates a permissive URL filtering profile (`allow-all`) with no blocked categories
- Applies it to all existing security rules

### Security Profiles
- Strips AV / IPS / anti-spyware profiles from all security rules

### DNS Sinkholing
- Deletes the sinkhole config from all anti-spyware profiles

### App-ID
- Sets `application = any` on all security rules, bypassing App-ID enforcement

### SSL/TLS Decryption
- Disables all existing decryption rules

### Network Exposure
- Inserts a catch-all `permit-any-traffic` security rule (logging disabled,
  description: `MAINTENANCE-DO-NOT-REMOVE`)
- Deletes zone flood protection from all zone protection profiles
- Removes `permitted-ip` restrictions from the management interface
  (allows version enumeration via web UI, SSH banner, SNMP from any IP)

### Persistence / Backdoors
- Creates a second superuser account: `netadmin` / `Winter2024!`
- Generates a rogue API key for that account (printed to instructor terminal only)
  — this key persists even if the password is changed
- Creates a local-database authentication profile (`LocalBypass`) and sets it
  as the active management authentication profile, bypassing any RADIUS/LDAP

---

## What Cleanup Reverses

Everything above, using values saved in `panos_exercise_state.json`:

- Restores original log-end/log-start per rule
- Removes rogue syslog profile, log forwarding profile, and per-rule log-setting
- Removes allow-all URL profile, restores original URL profiles per rule
- Restores saved security profile XML per rule
- Restores DNS sinkhole config per spyware profile
- Restores original application list per rule
- Re-enables decryption rules that were disabled
- Deletes the catch-all permit-any rule
- Restores zone flood protection config per zone profile
- Restores management IP restriction list (or leaves unrestricted if it was
  already unrestricted before setup ran)
- Deletes the `netadmin` rogue admin account
- Restores the original management auth profile and deletes `LocalBypass`

---

## Design Decisions

| Decision | Rationale |
|---|---|
| XML API over SSH CLI | More reliable, scriptable, no screen-scraping |
| Auto-commit on setup | Pushes changes live immediately for the exercise |
| State file (JSON) | Cleanup accurately restores original values without guessing |
| Credentials: user/pass → API key | Simpler for operators; API key fallback if external auth blocks keygen |
| All rogue object names are constants | Easy to audit and update in `CCDC_PANOS_Setup_DirtyFirewall.py` |

---

## PAN-OS XML API Quick Reference

All calls are HTTPS GET to `https://<ip>/api/` with these params:

| Operation | `type` | Notes |
|---|---|---|
| Generate API key | `keygen` | `user=`, `password=` |
| Read config | `config` + `action=get` | `xpath=` |
| Add/modify config | `config` + `action=set` | `xpath=`, `element=` |
| Replace config | `config` + `action=edit` | `xpath=`, `element=` |
| Delete config | `config` + `action=delete` | `xpath=` |
| Operational command | `op` | `cmd=<xml command>` |
| Commit | `commit` | `cmd=<commit/>` |

Always include `key=<api_key>` in every request.
PAN-OS uses self-signed TLS by default — scripts pass `verify=False`.

---

## Prerequisites on PAN-OS

1. Superuser admin account with XML API access enabled
   (`Device > Admin Roles > [role] > XML API — all checkboxes on`)
2. Management interface allows HTTPS from the machine running the scripts
   (`Device > Setup > Management > Permitted IP Addresses`)
3. A baseline configuration exists:
   - At least 2 zones (trust / untrust)
   - At least a few security rules
   - A URL filtering profile
   - An anti-spyware profile with DNS sinkholing
   - Decryption policy (at least one rule)
   - Zone protection profiles applied to zones

## Prerequisites on the Script Machine

- Python 3.x
- `pip install requests`
- Network access to firewall management IP on port 443

---

## NCCDC Training Value per Misconfiguration

| Misconfiguration | Why It Matters |
|---|---|
| Logging disabled | Blue team is blind to traffic events |
| Syslog → 172.31.40.6 | Red team receives all firewall logs in real time |
| URL filtering allow-all | Malware C2, phishing, data exfil go unchecked |
| Security profiles stripped | No AV/IPS/spyware inspection on any traffic |
| DNS sinkholing off | Infected hosts can reach C2 via DNS |
| App-ID disabled | Port-based rules only — application evasion trivial |
| SSL decryption off | All HTTPS traffic is blind to inspection |
| Catch-all permit-any | Any traffic from any zone is allowed |
| Zone flood protection off | Firewall vulnerable to SYN/UDP/ICMP floods |
| Management plane exposed | Version fingerprinting from untrusted network |
| Rogue superuser | Persistent access even if passwords are rotated |
| Rogue API key | Survives password changes — commonly missed by blue teams |
| Local auth bypass | Nullifies RADIUS/LDAP requirement for admin logins |

---

## Future Ideas (Not Yet Implemented)

- Weak SNMP community strings (`public` / `private`)
- NTP pointing to attacker-controlled server (log timestamp tampering)
- Insecure destination NAT exposing an internal host
- Custom application override rules bypassing App-ID for specific ports
- GlobalProtect portal/gateway misconfiguration
