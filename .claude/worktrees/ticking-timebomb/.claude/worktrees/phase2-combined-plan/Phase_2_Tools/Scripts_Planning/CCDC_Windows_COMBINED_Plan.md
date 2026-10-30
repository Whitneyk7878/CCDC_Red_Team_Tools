# CCDC Windows Phase 2 Combined Script — Design Plan

**Status:** PLANNED — script not yet built  
**Target file:** `Phase_2_Tools/General_Scripts/SetupScripts/windows/CCDC_Windows_P2_COMBINED.ps1`  
**MITRE coverage:** T1014, T1055.012, T1070, T1072, T1197, T1205.001, T1489

---

## Overview

The 7 individual Phase 2 Windows scripts each have to be transferred and run separately. `CCDC_Windows_P2_COMBINED.ps1` mirrors the Phase 1 pattern (`CCDC_Windows_COMBINED.ps1`) — one file, numbered modules, interactive menu or CLI flags, state tracking per session.

This is a **separate file** from the Phase 1 combined script. Phase 1 covers setup/persistence/exploitation. Phase 2 covers advanced techniques (rootkits, process injection, anti-forensics). They are not merged.

**What it solves:**
- One transfer instead of seven
- State CSV survives disconnect — operator can see what ran before reconnecting
- `-All` fires in the correct order (rootkit/AMSI patch first, antiforensics last) automatically
- A failed module is caught in try/catch, logged, and the next module continues

---

## Architecture

```
CCDC_Windows_P2_COMBINED.ps1
├── #region OPERATOR CONFIG          ← single region, all vars here
├── #Requires -RunAsAdministrator
├── Shared helpers
│   ├── Write-P2Info/Success/Warn/Error/Section
│   ├── Set-P2State()
│   ├── Get-P2State()
│   └── Show-P2StateTable()
├── Module functions (7)
│   ├── Invoke-Rootkit()             ← WhoAmIAnyway body
│   ├── Invoke-BITS()                ← BackgroundBeef body
│   ├── Invoke-ProcessInject()       ← Hollowman body
│   ├── Invoke-ServiceSabotage()     ← ServiceSmasher body
│   ├── Invoke-SoftwareDeploy()      ← ChocolateFactory body
│   ├── Invoke-TrafficSignal()       ← WhosThere body
│   └── Invoke-AntiForensics()       ← MemoryHole body (run LAST)
└── Main block                       ← param binding, menu, dispatch
```

**Error isolation:** `$ErrorActionPreference = "Continue"` at script level. Each module dispatch uses try/catch:

```powershell
function Invoke-Module {
    param([string]$Name, [scriptblock]$Fn)
    if ((Get-P2State $Name) -eq 'Success' -and -not $Force) {
        Write-P2Info "[$Name] already ran — skipping (use -Force to re-run)"
        return
    }
    try {
        & $Fn
        Set-P2State $Name 'Success'
    } catch {
        Write-P2Error "[$Name] FAILED: $_"
        Set-P2State $Name 'Failed'
    }
}
```

---

## Modules

| # | Key | Origin Script | MITRE | Short Description |
|---|-----|---------------|-------|-------------------|
| 1 | `Rootkit` | `CCDC_Windows_Rootkit_WhoAmIAnyway.ps1` | T1014 | AMSI/ETW patch + process-enum filter + persistence |
| 2 | `BITS` | `CCDC_Windows_BITS_BackgroundBeef.ps1` | T1197 | BITS self-healing C2 download loop |
| 3 | `ProcessInject` | `CCDC_Windows_ProcessInject_Hollowman.ps1` | T1055.012 | Process hollowing into svchost.exe |
| 4 | `ServiceSabotage` | `CCDC_Windows_ServiceSabotage_ServiceSmasher.ps1` | T1489 | Three-layer attack on DNS/FTP/IIS/LDAP |
| 5 | `SoftwareDeploy` | `CCDC_Windows_SoftwareDeploy_ChocolateFactory.ps1` | T1072 | Weaponized Chocolatey package source |
| 6 | `TrafficSignal` | `CCDC_Windows_TrafficSignal_WhosThere.ps1` | T1205.001 | UDP magic-packet backdoor service |
| 7 | `AntiForensics` | `CCDC_Windows_AntiForensics_MemoryHole.ps1` | T1070 | Event log wipe, timestomp, VSS destroy (run LAST) |

---

## State Tracking

**State file:** `$env:SystemRoot\System32\spool\drivers\color\.p2_state.csv`  
Same hidden directory used by other Phase 2 scripts. CSV format; survives PowerShell session restarts.

**Format:**
```csv
Module,Status,Timestamp,ExitCode
Rootkit,Success,2026-10-04T14:32:11,0
BITS,Failed,2026-10-04T14:33:05,1
ProcessInject,Pending,,
```

**State values:**
| Status | Meaning |
|--------|---------|
| `Pending` | Not yet attempted |
| `Success` | Module completed without terminating exception |
| `Failed` | Module threw a terminating error |
| `Skipped` | Explicitly skipped by user |

**Helper functions:**
```powershell
Set-P2State      # Set-P2State -Module <name> -Status <value>
Get-P2State      # Returns current status string for a module
Show-P2StateTable  # Prints formatted table of all module statuses
```

---

## Invocation

```powershell
# Interactive numbered menu (default when no args)
.\CCDC_Windows_P2_COMBINED.ps1

# Run specific modules
.\CCDC_Windows_P2_COMBINED.ps1 -Modules Rootkit,ServiceSabotage

# Run all in recommended order
.\CCDC_Windows_P2_COMBINED.ps1 -All

# Show current run state without executing anything
.\CCDC_Windows_P2_COMBINED.ps1 -Status

# Force re-run even if previously succeeded
.\CCDC_Windows_P2_COMBINED.ps1 -Modules AntiForensics -Force

# Run all, skip modules that already succeeded
.\CCDC_Windows_P2_COMBINED.ps1 -All -Resume
```

**`-All` execution order:**
```
1. Rootkit         (patches AMSI + ETW, hides red team processes)
2. BITS            (C2 persistence loop)
3. ProcessInject   (shell inside svchost)
4. ServiceSabotage (breaks DNS/FTP/IIS/LDAP)
5. SoftwareDeploy  (weaponizes Chocolatey)
6. TrafficSignal   (UDP magic-packet backdoor)
7. AntiForensics   (wipes all traces of modules 1–6)
```

Rootkit runs first because it patches AMSI (prevents Defender script scanning) and ETW (kills behavioral telemetry) before the other modules fire. AntiForensics runs last because it destroys evidence left by all prior modules.

---

## Operator Config Block

All variables consolidated in a single `#region`:

```powershell
#region OPERATOR CONFIG — CHANGE ALL OF THESE BEFORE DEPLOYING

$RedTeamIP        = "CHANGEME"    # C2 / listener IP
$RevShellPort     = 4449          # TrafficSignal reverse shell port
$BITSPort         = 4450          # BITS reverse shell port
$InjectPort       = 4451          # ProcessInject reverse shell port
$ChocolateyPort   = 4452          # SoftwareDeploy reverse shell port
$C2Url            = "CHANGEME"    # BITS download URL (http://IP:8080/wu-telemetry.ps1)
$MagicBytes       = @(0xDE,0xAD,0xBE,0xEF)   # TrafficSignal trigger bytes
$Passphrase       = "CHANGEME"    # AntiForensics gate passphrase
$OperatorUser     = "CHANGEME"    # Operator username for log scrubbing

#endregion OPERATOR CONFIG
```

Script validates none are still `"CHANGEME"` before running any module and aborts with a clear error if they are.

---

## Module Inlining Approach

When building the combined script from the 7 individual scripts:

1. Each individual script's body becomes an `Invoke-<Name>()` function
2. Remove `#Requires -RunAsAdministrator` from inlined bodies (hoisted to script top)
3. Remove `Set-StrictMode` / `$ErrorActionPreference` from inlined bodies (handled at script level)
4. Remove duplicate `Write-Info/Success/Warn/Error` helper definitions (hoisted to shared helpers)
5. Replace per-script `$RedTeamIP`, `$RevShellPort`, etc. with the combined script's `OPERATOR CONFIG` vars
6. Keep all C# compilation, file drops, service/task registration, and firewall rule logic exactly intact

---

## Known Constraints

| Module | Constraint |
|--------|-----------|
| `Rootkit` | x64 Windows only; AMSI/ETW patches are x64-specific byte sequences |
| `ProcessInject` | x64 Windows only; process hollowing shellcode is x64 |
| `ProcessInject` | Requires a live listener on `$RedTeamIP:$InjectPort` before module runs |
| `BITS` | `$C2Url` must be reachable from target; C2 must serve payload on port 8080 |
| `SoftwareDeploy` | Internet access required for Chocolatey install if not present |
| `TrafficSignal` | Npcap download requires internet; raw socket fallback works without it |
| `ServiceSabotage` | LDAP layer requires Domain Admin privileges |
| `AntiForensics` | Must run LAST; running earlier destroys evidence of unrun modules |
| `AntiForensics` | `$Passphrase` must match the value hardcoded in the original script |

---

## Relationship to Phase 1 Combined

| | Phase 1 `CCDC_Windows_COMBINED.ps1` | Phase 2 `CCDC_Windows_P2_COMBINED.ps1` |
|--|--------------------------------------|----------------------------------------|
| Modules | Users, WebShells, ScheduledTasks, Persistence, Defender, RemoteAccess, LSA, DLL, BITS (basic), StickyKeys | Rootkit, BITS (advanced), ProcessInject, ServiceSabotage, SoftwareDeploy, TrafficSignal, AntiForensics |
| State file | None (Phase 1 has no state tracking) | `.p2_state.csv` in color spool dir |
| Run order | Any | Rootkit-first, AntiForensics-last enforced |
| Purpose | Initial foothold, visibility | Advanced persistence, stealth, disruption |

Phase 1 and Phase 2 combined scripts remain separate files. Do not merge them.

---

## Interactive Menu Mockup

```
╔══════════════════════════════════════════════════════════╗
║    CCDC Windows Phase 2 Combined — Module Launcher      ║
╠══════════════════════════════════════════════════════════╣
║  #  Module              Status     MITRE                 ║
║  ─  ──────────────────  ─────────  ──────────────────    ║
║  1  Rootkit             Success    T1014                 ║
║  2  BITS                Pending    T1197                 ║
║  3  ProcessInject       Pending    T1055.012             ║
║  4  ServiceSabotage     Pending    T1489                 ║
║  5  SoftwareDeploy      Failed     T1072                 ║
║  6  TrafficSignal       Pending    T1205.001             ║
║  7  AntiForensics       Pending    T1070                 ║
╠══════════════════════════════════════════════════════════╣
║  A  Run ALL (recommended order)                         ║
║  R  Resume (skip Success, retry Failed)                 ║
║  S  Status only                                         ║
║  Q  Quit                                                ║
╚══════════════════════════════════════════════════════════╝
Select module(s) [1-7, A, R, S, Q]:
```

---

## Implementation Checklist

- [ ] Write `CCDC_Windows_P2_COMBINED.ps1` skeleton: `param()` block, `#Requires`, shared helpers
- [ ] Inline all 7 module functions from individual scripts
- [ ] Wire `#region OPERATOR CONFIG` — replace per-script vars with combined vars
- [ ] Implement state CSV read/write helpers (`Set-P2State`, `Get-P2State`, `Show-P2StateTable`)
- [ ] Implement `-All` dispatch with correct ordering
- [ ] Implement `-Modules` comma-separated dispatch
- [ ] Implement `-Status` read-only display
- [ ] Implement `-Force` flag
- [ ] Add config validation (abort if any var is still `"CHANGEME"`)
- [ ] Test: run `-Status` before any modules (shows all Pending)
- [ ] Test: run `-Modules Rootkit` alone, confirm state CSV written
- [ ] Test: run `-All`, confirm Rootkit-first and AntiForensics-last order
- [ ] Test: deliberately fail a module (wrong IP), confirm others continue
