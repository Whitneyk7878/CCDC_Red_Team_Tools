# OS Support

**Windows Server 2019 and 2022 (primary targets). Windows Server 2016 supported where APIs match.**

- Service names: `DNS`, `FTPSVC`/`MSFTPSVC`, `W3SVC`, `NTDS` (AD DS).
- IIS configuration lives in `%windir%\system32\inetsrv\config\applicationHost.config` (XML).
- `appcmd.exe` at `%windir%\system32\inetsrv\appcmd.exe` for IIS/FTP site management.
- DNS zone files at `C:\Windows\System32\dns\`.
- Firewall rules via `New-NetFirewallRule` (WMI-based, survives reboot).

---

# Context

Runtime service-sabotage script for CCDC Windows targets. Deploys directly onto a scored machine
and applies three independent layers of disruption per service. Blue team must identify and
remediate all three layers to restore scoring. Script detects each service before acting and
skips services that are not installed.

A `-WhatIf` switch performs a dry run (no changes, logs intended actions only).

---

## Script

| Filename | OS | Privilege |
|---|---|---|
| `CCDC_Windows_ServiceSabotage_ServiceSmasher.ps1` | Windows Server 2016/2019/2022 | SYSTEM or Domain Admin |

---

## MITRE ATT&CK Coverage

| ID | Technique | Usage |
|---|---|---|
| T1489 | Service Stop | Layer 1 — `Stop-Service` + `Set-Service -StartupType Disabled` |
| T1565.001 | Stored Data Manipulation | Layer 2 — zone file / applicationHost.config corruption |
| T1562.004 | Disable or Modify System Firewall | Layer 1/3 — `New-NetFirewallRule` blocking service ports |
| T1222 | File and Directory Permissions Modification | Layer 3 — `icacls /deny` on service directories |
| T1053.005 | Scheduled Task/Job | Layer 3 — recurring task re-applies disable |

---

## 3-Layer Strategy

| Layer | Category | Description |
|---|---|---|
| 1 | **Service Kill** | `Stop-Service -Force` + `Set-Service -StartupType Disabled` — service is down |
| 2 | **Config Corruption** | Edit XML config / registry so service errors on startup even when re-enabled |
| 3 | **Hidden Blocker** | `New-NetFirewallRule` DROP + `icacls /deny` on content dir + scheduled task re-applies disable |

---

## Per-Service Design

### DNS Server (UDP/TCP 53)

| Layer | Technique | Detail |
|---|---|---|
| L1 | Stop + disable + bad listen addr | `Stop-Service DNS -Force`; `Set-Service DNS -StartupType Disabled`; set `HKLM:\…\DNS\Parameters\ListenAddresses = 127.0.0.99` (service binds to nonexistent NIC address) |
| L2 | Zone file corruption + root hints | Prepend malformed SOA to each `.dns` zone file in `C:\Windows\System32\dns\`; clear `cache.dns` (root hints) |
| L3 | FW block + ACL deny + re-disable task | `New-NetFirewallRule` DROP UDP/TCP 53 (in + out); `icacls dns\ /deny "NETWORK SERVICE:(OI)(CI)F"`; scheduled task re-disables DNS every 5 min |

### FTP — IIS FTPSVC (TCP 21, passive 50000–50100)

| Layer | Technique | Detail |
|---|---|---|
| L1 | Stop + disable FTP service | `Stop-Service FTPSVC/MSFTPSVC -Force`; `Set-Service -StartupType Disabled`; `appcmd stop site` |
| L2 | Bind to dead IP + disable auth | `appcmd set site` binding → `192.0.2.1:21:` (RFC 5737 nonroutable); `appcmd clear config` removes all FTP auth rules; edit `applicationHost.config` to disable basicAuthentication |
| L3 | FW block + FTP root ACL + re-stop task | `New-NetFirewallRule` DROP TCP 21; `icacls ftproot /deny "Everyone:(OI)(CI)F"`; scheduled task re-stops FTPSVC every 5 min |

### IIS Web Server — W3SVC (TCP 80, 443)

| Layer | Technique | Detail |
|---|---|---|
| L1 | Stop + disable W3SVC + iisreset | `Stop-Service W3SVC -Force`; `Set-Service -StartupType Disabled`; `iisreset /stop` |
| L2 | Bind to dead IP + invalid pool identity + broken web.config | Edit `applicationHost.config`: Default Web Site binding → `192.0.2.1:80:`; DefaultAppPool processModel userName → random invalid user; plant broken `web.config` in `wwwroot` referencing a nonexistent HTTP module |
| L3 | FW block + wwwroot ACL + re-stop task | `New-NetFirewallRule` DROP TCP 80/443; `icacls wwwroot /deny "IIS_IUSRS:(OI)(CI)R"` + IUSR deny; scheduled task re-stops W3SVC every 5 min |

### LDAP — Active Directory DS (TCP/UDP 389, TCP 636, TCP 3268/3269)

NTDS cannot be safely stopped (risks AD corruption). Layers target network, policy, and auth:

| Layer | Technique | Detail |
|---|---|---|
| L1 | Firewall block all LDAP ports | `New-NetFirewallRule` DROP TCP/UDP 389, TCP 636, TCP 3268/3269 — immediate connectivity loss |
| L2 | LDAP policy degradation via registry | `HKLM:\…\NTDS\Parameters`: `MaxConnections=1`, `MaxConnIdleTime=1`, `MaxPageSize=1`, `MaxQueryDuration=1` — breaks concurrent connections and most LDAP queries |
| L3 | Require signing + channel binding + fake SRV | `LDAPServerIntegrity=2` (require signing); `LdapEnforceChannelBinding=2` (require TLS channel binding — plain LDAP clients rejected); add fake `_ldap._tcp.dc._msdcs` SRV record pointing to `192.0.2.99` |

---

## Key Implementation Notes

- **`appcmd.exe` path**: always validate `Test-Path "$env:windir\system32\inetsrv\appcmd.exe"` before use.
- **`applicationHost.config` edits**: use `[xml]` typed variable, save with `.Save()`. Always back up to `.orig` first.
- **NTDS registry keys**: the `LDAPServerIntegrity` and `LdapEnforceChannelBinding` changes take effect after NTDS restarts or a reboot. They are persistent even after firewall rules are cleared.
- **Scheduled tasks**: all tasks named with `CCDC-*` prefix for easy identification. Use `-Force` on `Register-ScheduledTask` to overwrite if re-run.
- **RFC 5737 IPs**: `192.0.2.x` is the IANA documentation/test block — guaranteed non-routable, will never accidentally reach a real server.

---

## File Destinations

```
Phase_2_Tools/General_Scripts/SetupScripts/windows/
└── CCDC_Windows_ServiceSabotage_ServiceSmasher.ps1
```

---

## Verification

```powershell
# After running on test Server 2022 VM with DNS + IIS + FTP roles:

# Confirm firewall rules
Get-NetFirewallRule -DisplayName "*Red*" | Select DisplayName, Enabled, Action

# Confirm services disabled
Get-Service DNS, W3SVC, FTPSVC | Select Name, Status, StartType

# Confirm scheduled re-disable tasks
Get-ScheduledTask | Where-Object TaskName -like "CCDC-*" | Select TaskName, State

# Confirm IIS won't start (binding to dead IP)
Start-Service W3SVC -ErrorAction SilentlyContinue
Start-Sleep 2
curl.exe http://localhost -v   # Should fail (connection refused or timeout)

# Confirm LDAP unreachable
Test-NetConnection -ComputerName localhost -Port 389   # TcpTestSucceeded should be False

# Confirm DNS zone file corruption
Get-Content "C:\Windows\System32\dns\*.dns" | Select -First 5
```
