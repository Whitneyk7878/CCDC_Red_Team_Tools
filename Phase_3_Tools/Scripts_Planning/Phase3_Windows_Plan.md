# OS Support

**Windows Server 2019 (MSSQL), Windows Server 2022 (AD/DC), Windows 10 Workstation.**

- All scripts require elevation (`#Requires -RunAsAdministrator`).
- Role detection at runtime: check installed Windows Features / services before applying role-specific layers.
- Naming convention: `CCDC_Windows_P3_<Category>_<FunName>.ps1`

---

# Context

Phase 3 Windows-only advanced training module for CCDC blue team. Targets two Windows servers (2019 MSSQL, 2022 AD/DC) and one Windows 10 workstation. Blue team has already worked through Phase 1 and Phase 2, so Phase 3 introduces techniques and difficulty layers not covered in prior phases.

Phase 3 focuses on four new dimensions:
1. **Breaking defender tools** — not just disabling, but structurally corrupting so restoration is non-trivial
2. **Analyst tooling denial** — blocking SysInternals via vectors Phase 1 didn't cover (AppLocker, WDAC, WMI kill subscription)
3. **3-layer service misconfigs** (DNS, AD/Kerberos, MSSQL) — each layer independently blocks service scoring; fixing one easy visible thing leaves two hidden layers still blocking
4. **LOTL-only stealthy persistence** — native Windows mechanisms only; no external binaries touch disk

All MITRE ATT&CK–mapped. No live malware payloads — mechanics + misconfiguration only.

---

## Phase 1 & 2 Coverage (do not duplicate)

| Area | Phase 1 | Phase 2 |
|---|---|---|
| Defender | `DefenderNeuter.ps1`: Set-MpPreference, service stop, policy registry, ACL lock | — |
| SysInternals | `SysInternalsNuker.ps1`: IFEO, hosts, outbound FW rule, watchdog task | — |
| Persistence | Task Scheduler, DLL hijack, cluster shells, Sliver C2 | BITS, ShadowStrike, port-knock TrafficSignal, process hollowing |
| Service Sabotage | — | ServiceSmasher: DNS/FTP/IIS/LDAP 3-layer stop+config+FW |
| Anti-Forensics | — | MemoryHole |

---

## Phase 3 Scripts — 8 Total

All scripts go under `Phase_3_Tools/General_Scripts/SetupScripts/windows/`.

| # | Script Filename | MITRE IDs | Targets |
|---|---|---|---|
| 1 | `CCDC_Windows_P3_Defender_BreakingBad.ps1` | T1562.001, T1490, T1222 | All |
| 2 | `CCDC_Windows_P3_SysInternals_NoEscape.ps1` | T1562.001, T1553.006, T1546.003 | All |
| 3 | `CCDC_Windows_P3_DNS_ConditionalSurrender.ps1` | T1565.001, T1584.002, T1562.004 | DC + optional MSSQL server |
| 4 | `CCDC_Windows_P3_AD_KerberosKhaos.ps1` | T1484.001, T1484.002, T1222, T1531 | DC only |
| 5 | `CCDC_Windows_P3_MSSQL_DeadInTheWater.ps1` | T1489, T1565.001, T1562.004, T1222 | MSSQL server only |
| 6 | `CCDC_Windows_P3_Persist_GhostInTheWMI.ps1` | T1546.003, T1546.015, T1547.010 | All |
| 7 | `CCDC_Windows_P3_Evasion_BlindSpot.ps1` | T1562.002, T1562.006, T1070.001, T1059.001 | All |
| 8 | `CCDC_Windows_P3_COMBINED.ps1` | (orchestrator, all IDs above) | Role-detected |

---

## Per-Machine Deployment Matrix

| Script | Server 2019 (MSSQL) | Server 2022 (AD/DC) | Win10 Workstation |
|---|---|---|---|
| Defender_BreakingBad | ✓ | ✓ | ✓ (skip Server DISM step) |
| SysInternals_NoEscape | ✓ | ✓ | ✓ |
| DNS_ConditionalSurrender | optional | ✓ | — |
| AD_KerberosKhaos | — | ✓ | — |
| MSSQL_DeadInTheWater | ✓ | — | — |
| Persist_GhostInTheWMI | ✓ | ✓ | ✓ |
| Evasion_BlindSpot | ✓ | ✓ | ✓ |

---

## Script Design Details

### 1 — `Defender_BreakingBad.ps1`

Phase 1 already handles basic neuter (Set-MpPreference, service stop, policy registry, ACL lock).
Phase 3 goes structural:

| Layer | What | Detail |
|---|---|---|
| WMI corruption | Remove `Root\SecurityCenter2` AntiVirusProduct class instances; break MOF auto-recovery | Defender reports no AV registered; WMI repair is non-trivial |
| Signature store ACL | Delete `C:\ProgramData\Microsoft\Windows Defender\Definition Updates\*`; deny `NT SERVICE\WinDefend` all access to path | Defender starts but can't update or use signatures |
| Catalog trust break | Remove Defender entries from `catroot2`; corrupt SFC/CBS catalog | DISM repair fails silently |
| Feature uninstall (Server) | `Uninstall-WindowsFeature -Name Windows-Defender` | Requires WinSxS source media to restore |
| Task folder lock | Delete `\Microsoft\Windows\Windows Defender\*` scheduled tasks; deny ACE on task folder path | Defender update schedule can't be recreated |
| Registry trap | `DisableAntiSpyware=1` + `TamperProtection=0` then ACL-lock the key | Admin must take ownership before any fix |

---

### 2 — `SysInternals_NoEscape.ps1`

Phase 1 already handles IFEO, hosts file, outbound FW rule, watchdog task.
Phase 3 adds:

| Layer | What | Detail |
|---|---|---|
| AppLocker publisher deny | Deny all EXEs from `CN=Microsoft Corporation` Sysinternals publisher cert | Blocks even renamed copies |
| WDAC supplemental policy | `ConvertFrom-CIPolicy` → `SiPolicy.p7b` denying Sysinternals publisher GUID | Win10 + Server 2022 |
| WMI kill-on-exec | `__EventFilter` on `Win32_ProcessStartTrace WHERE ProcessName LIKE 'proc%'` → consumer `taskkill /f /pid` | Disguised as `WMIHealthMonitor` |
| UNC/SMB block | FW rule blocking outbound TCP 445 to `live.sysinternals.com` resolved IPs | Kills `\\live.sysinternals.com\tools` UNC access |
| Poison existing copies | Enumerate PATH + `C:\Tools\*` + `C:\Users\*\Downloads\` for known SysInternals names; overwrite with zero-byte | Breaks in-place without obvious removal |
| Zone.Identifier ADS | Write `:Zone.Identifier` stream to any found copies (ZoneId=4 — Restricted) | SmartScreen blocks execution |

---

### 3 — `DNS_ConditionalSurrender.ps1`

Phase 2 ServiceSmasher already stops DNS + corrupts zone files + blocks port 53.
Phase 3 uses different angles that persist even after service restart and zone file repair:

| Layer | What | Detail |
|---|---|---|
| L1 — Conditional forwarder poisoning | Add conditional forwarders for competition domain(s) → `192.0.2.1` | Survives zone file repair; all domain queries black-holed |
| L2 — TTL/scavenging destruction | `dnscmd /Config /DefaultTTL 1`; scavenging every 1h with 1h refresh/no-refresh | Dynamic records age out; 1s TTL prevents any caching |
| L3 — Recursion trap + console ACL | `dnscmd /Config /NoRecursion 1`; root hints → `192.0.2.1`; deny MMC snap-in access | Must use CLI to fix; MMC access denied |

---

### 4 — `AD_KerberosKhaos.ps1`

Phase 2 ServiceSmasher covered LDAP firewall + LDAP policy max connections.
Phase 3 attacks authentication and directory access:

| Layer | What | Detail |
|---|---|---|
| L1 — Kerberos ticket TTL | `Set-ADDefaultDomainPasswordPolicy -MaxTicketAge 00:01:00 -MaxClockSkew 00:00:00` | Tickets expire in 60s; zero clock skew tolerance breaks auth on any time drift |
| L2 — Account lockout weaponization | `LockoutThreshold=1`, `LockoutDuration=-1`, `LockoutObservationWindow=99999`; trigger one failed auth on service accounts | Accounts locked on first bad attempt, never auto-unlock |
| L3 — SYSVOL/NETLOGON ACL destruction | Remove `Authenticated Users:Read` from SYSVOL and Policies; `DisablePasswordChange=1` in Netlogon | GPOs don't apply, logon scripts fail, machine accounts can't renew |

---

### 5 — `MSSQL_DeadInTheWater.ps1`

No Phase 1 or Phase 2 MSSQL coverage — entirely new territory:

| Layer | What | Detail |
|---|---|---|
| L1 — Service account + startup params | Change SQL Server service account to nonexistent local user via WMI Config Manager API; add invalid `-e C:\NonExistent\sql.log` startup parameter | Service fails to start even after basic troubleshooting |
| L2 — Database-level sabotage | `ALTER DATABASE master SET RESTRICTED_USER WITH ROLLBACK IMMEDIATE`; `msdb` OFFLINE; `model` READ_ONLY; disable TCP/IP in registry (`SuperSocketNetLib\Tcp\Enabled=0`) | SQL Server only accepts named-pipe connections (blocked by FW) |
| L3 — Port/discovery sabotage | Change TCP port from 1433 to 14334 via `IPAll\TcpPort` registry; stop+disable SQL Browser; FW block TCP 1433 AND 14334 | Three separate things must be found and fixed before 1433 returns |

Key registry base: `HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL<ver>\MSSQLServer`

---

### 6 — `Persist_GhostInTheWMI.ps1`

Phase 1 covers Task Scheduler, DLL hijack, cluster shells. Phase 2 covers BITS, port-knock, process hollowing.
Phase 3 uses mechanisms with no visible autorun artifact:

| Mechanism | What | Detail |
|---|---|---|
| WMI Event Subscription | `__EventFilter` on `Win32_ProcessStartTrace WHERE ProcessName='svchost.exe'`; `CommandLineEventConsumer` runs encoded PS reverse shell | Filter: `WMIProviderHostCompatibility`; consumer: `WBEM_SyncHandler`; binding: `WMIPerfCounterMaintenance` |
| COM Hijacking | HKCU CLSID override for a CLSID loaded by `mmc.exe`/`taskschd.exe`; DLL at `C:\Windows\Temp\wbemperf.dll` | Fires in admin context when any admin opens MMC/Task Scheduler |
| Print Monitor DLL | `HKLM:\...\Control\Print\Monitors\<name>\Driver = localspl_ext.dll`; loaded by spoolsv.exe as SYSTEM at startup | No Run key, no task, no obvious trail; DLL is inline `Add-Type` compiled PS launcher |

LOTL only — all payloads are PowerShell compiled via `Add-Type` at runtime, no EXE/DLL written from external source.

---

### 7 — `Evasion_BlindSpot.ps1`

Destroys visibility so blue team can't use Windows' own investigation capabilities:

| What | Detail |
|---|---|
| Event log size destruction | `wevtutil set-log` → `maxSize=65536` on Security/System/Application/PowerShell-Operational/Sysmon channels; `/overwrite:true` — rolls over in seconds |
| Audit policy wipe | `auditpol /clear /y`; `auditpol /set /subcategory:* /success:disable /failure:disable` |
| PS logging destruction | Registry keys: ScriptBlockLogging, ModuleLogging, Transcription all disabled under `HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell` |
| Sysmon removal | Detect `SysmonDrv`/`Sysmon64` service; `sc stop`; delete driver + binary; IFEO intercept on `sysmon.exe` and `sysmon64.exe` |
| EVTX journal corruption | Stop EventLog service; overwrite Security/System/Application `.evtx` with corrupted 4-byte EVTX magic header — forensic tools report "invalid log file"; EventLog recreates empty logs on next start |
| WER disable | `HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\Disabled=1`; stop `WerSvc` — no crash dumps |

---

## Naming & Style Rules (same as Phase 1/2)

- `#Requires -RunAsAdministrator`
- `Set-StrictMode -Version Latest`
- `$ErrorActionPreference = "Continue"`
- Color helpers: `Write-Info` (Cyan), `Write-Warn` (Yellow), `Write-Success` (Green), `Write-Err` (Red)
- ASCII banner: `///////...\\\\\\` border style
- Idempotent: check before applying each change

---

## File Destinations

```
Phase_3_Tools/General_Scripts/SetupScripts/windows/
├── CCDC_Windows_P3_COMBINED.ps1
├── CCDC_Windows_P3_Defender_BreakingBad.ps1
├── CCDC_Windows_P3_SysInternals_NoEscape.ps1
├── CCDC_Windows_P3_DNS_ConditionalSurrender.ps1
├── CCDC_Windows_P3_AD_KerberosKhaos.ps1
├── CCDC_Windows_P3_MSSQL_DeadInTheWater.ps1
├── CCDC_Windows_P3_Persist_GhostInTheWMI.ps1
└── CCDC_Windows_P3_Evasion_BlindSpot.ps1

Phase_3_Tools/Scripts_Planning/
└── Phase3_Windows_Plan.md  ← this file
```

---

## Verification

```powershell
# List all Phase 3 scripts
Get-ChildItem Phase_3_Tools\General_Scripts\SetupScripts\windows\*.ps1 | Select Name

# Syntax check stubs
Get-ChildItem Phase_3_Tools\General_Scripts\SetupScripts\windows\*.ps1 |
    ForEach-Object {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errors)
        if ($errors) { "ERRORS in $($_.Name): $($errors -join '; ')" } else { "OK: $($_.Name)" }
    }
```
