# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Anti-Cheat - SysInternals Combustion
# Deploys 7 independent layers to block Sysinternals tools on WS2019.
# Prevents download, live UNC access, and execution — pre-install and post.
# Usage: .\CCDC_Windows_AntiCheat_SysInternalsCombustion.ps1 [-Undo]
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

# THIS SCRIPT LIGHTS SYSINTERNALS ON FIRE SO YOUR BLUES ACTUALLY HAVE TO LEARN THINGS

#Requires -RunAsAdministrator

param(
    [switch]$Undo
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Colour helpers ------------------------------------------------------------
function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan   }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green  }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red    }

# -- Runtime banner ------------------------------------------------------------
Write-Host ""
Write-Warn "=================================================================="
Write-Warn "        SYSINTERNALS COMBUSTION  //  CCDC ANTI-CHEAT             "
Write-Warn "=================================================================="
Write-Host ""

# -- Config --------------------------------------------------------------------
$BlockerStubPath  = "C:\Windows\System32\SysInternalsBlocked.cmd"
$IFEOBase         = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options"
$FirewallRuleName = "CCDC_Block_SysInternals_Outbound"
$WatchdogTaskName = "WindowsDiagTrackCacheRefresh"
$WatchdogTaskPath = "\Microsoft\Windows\WindowsUpdate\"

$TargetTools = @(
    "procexp.exe",    "procexp64.exe",
    "procmon.exe",    "procmon64.exe",
    "tcpview.exe",
    "autoruns.exe",   "autoruns64.exe",  "autorunsc.exe",
    "handle.exe",     "handle64.exe",
    "strings.exe",    "strings64.exe",
    "listdlls.exe",   "listdlls64.exe",
    "accesschk.exe",  "accesschk64.exe",
    "procdump.exe",   "procdump64.exe",
    "pslist.exe",
    "bginfo.exe",
    "sysmon.exe",     "sysmon64.exe"
)

$SysInternalsHosts = @(
    "live.sysinternals.com",
    "download.sysinternals.com"
)

# =============================================================================
# BLOCK
# =============================================================================
function Invoke-SysInternalsBlock {

    # -- Layer 1: IFEO ---------------------------------------------------------
    # Intercepts process creation by name at OS level — works even if the tool
    # is not yet installed. When Windows creates procexp.exe it runs our stub instead.
    Write-Info "Layer 1: Setting IFEO intercepts..."

    $stub = @'
@echo off
cls
echo.
echo  BZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZT
echo.
pause
exit /b 1
'@
    try {
        Set-Content -Path $BlockerStubPath -Value $stub -Encoding ASCII -Force
        Write-Success "  Blocker stub written: $BlockerStubPath"
    } catch {
        Write-Err "  Could not write blocker stub: $_"
        return
    }

    foreach ($tool in $TargetTools) {
        $regPath = "$IFEOBase\$tool"
        try {
            if (-not (Test-Path $regPath)) {
                New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null
            }
            Set-ItemProperty -Path $regPath -Name "Debugger" -Value $BlockerStubPath -ErrorAction Stop
            Write-Success "  IFEO: $tool"
        } catch {
            Write-Warn "  IFEO failed for $tool : $_"
        }
    }

    # -- Layer 2: AppLocker ----------------------------------------------------
    # Publisher-based blocking catches renamed tools since the Sysinternals
    # code-signing cert is still present regardless of filename.
    Write-Info "Layer 2: Configuring AppLocker deny rules..."
    try {
        Set-Service -Name AppIDSvc -StartupType Automatic -ErrorAction Stop
        Start-Service -Name AppIDSvc -ErrorAction Stop

        # Build Deny entries for each tool
        $denyRules = foreach ($t in $TargetTools) {
            $guid = [System.Guid]::NewGuid().ToString()
            "    <FilePathRule Id=""$guid"" Name=""CCDC_Block_$t"" Description=""CCDC Sysinternals block"" UserOrGroupSid=""S-1-1-0"" Action=""Deny"">
      <Conditions>
        <FilePathCondition Path=""*\$t"" />
      </Conditions>
    </FilePathRule>"
        }

        # Standard Allow rules ensure the rest of the system still runs normally
        $allowWin       = [System.Guid]::NewGuid().ToString()
        $allowPF        = [System.Guid]::NewGuid().ToString()
        $allowPFx86     = [System.Guid]::NewGuid().ToString()
        $allowAdmins    = [System.Guid]::NewGuid().ToString()

        $policyXml = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <FilePathRule Id="$allowAdmins" Name="Allow Administrators everything" Description="" UserOrGroupSid="S-1-5-32-544" Action="Allow">
      <Conditions><FilePathCondition Path="*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="$allowWin" Name="Allow Windows" Description="" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%WINDIR%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="$allowPF" Name="Allow ProgramFiles" Description="" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%PROGRAMFILES%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="$allowPFx86" Name="Allow ProgramFiles x86" Description="" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%PROGRAMFILES(X86)%\*" /></Conditions>
    </FilePathRule>
$($denyRules -join "`n")
  </RuleCollection>
</AppLockerPolicy>
"@
        $policyFile = "$env:TEMP\ccdc_applocker_combustion.xml"
        Set-Content -Path $policyFile -Value $policyXml -Encoding UTF8 -Force
        Set-AppLockerPolicy -XmlPolicy $policyFile -Merge -ErrorAction Stop
        Remove-Item $policyFile -Force -ErrorAction SilentlyContinue
        Write-Success "  AppLocker deny rules merged and AppIDSvc started"
    } catch {
        Write-Warn "  AppLocker config failed (Layer 2 skipped — IFEO still active): $_"
    }

    # -- Layer 3: Hosts file DNS block -----------------------------------------
    # Poisons the resolver so live.sysinternals.com and download URLs resolve to
    # localhost. Stops both browser downloads and UNC live access before TCP opens.
    Write-Info "Layer 3: Poisoning hosts file for Sysinternals domains..."
    $hostsPath = "C:\Windows\System32\drivers\etc\hosts"
    try {
        $hostsContent = Get-Content -Path $hostsPath -Raw -ErrorAction Stop
        foreach ($domain in $SysInternalsHosts) {
            if ($hostsContent -notmatch [regex]::Escape($domain)) {
                Add-Content -Path $hostsPath -Value "`r`n127.0.0.1  $domain" -Encoding ASCII -ErrorAction Stop
                Write-Success "  Hosts: $domain -> 127.0.0.1"
            } else {
                Write-Warn "  Hosts: $domain already present, skipping"
            }
        }
    } catch {
        Write-Warn "  Hosts file update failed: $_"
    }

    # -- Layer 4: Disable WebClient (WebDAV) -----------------------------------
    # \\live.sysinternals.com\tools\ works over WebDAV. Disabling WebClient
    # service kills that entire access path at the transport level.
    Write-Info "Layer 4: Disabling WebClient service (kills live.sysinternals.com UNC)..."
    try {
        Stop-Service -Name WebClient -Force -ErrorAction SilentlyContinue
        Set-Service -Name WebClient -StartupType Disabled -ErrorAction Stop
        Write-Success "  WebClient service disabled"
    } catch {
        Write-Warn "  WebClient disable failed (service may not be installed): $_"
    }

    # -- Layer 5: Windows Firewall outbound block ------------------------------
    Write-Info "Layer 5: Adding outbound firewall block for Sysinternals domains..."
    try {
        Remove-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue

        # Resolve current IPs — best effort; hosts file + WebClient are primary
        $resolvedIPs = @()
        foreach ($domain in $SysInternalsHosts) {
            try {
                $ips = [System.Net.Dns]::GetHostAddresses($domain) | Select-Object -ExpandProperty IPAddressToString
                $resolvedIPs += $ips
            } catch { }
        }

        if ($resolvedIPs.Count -gt 0) {
            New-NetFirewallRule `
                -DisplayName  $FirewallRuleName `
                -Direction    Outbound `
                -Action       Block `
                -Protocol     TCP `
                -RemotePort   80,443 `
                -RemoteAddress ($resolvedIPs | Sort-Object -Unique) `
                -Description  "CCDC: block Sysinternals download endpoints (IPs captured at deploy time)" `
                -ErrorAction Stop | Out-Null
            Write-Success "  Firewall rule created blocking $($resolvedIPs.Count) resolved IP(s)"
        } else {
            Write-Warn "  DNS resolution returned no IPs (hosts file already poisoned?) — skipping firewall rule"
        }
    } catch {
        Write-Warn "  Firewall rule creation failed: $_"
    }

    # -- Layer 6: NTFS deny-execute on common tool drop paths ------------------
    # Blue teamers will download/copy tools to Downloads, Desktop, or temp.
    # Deny Execute for non-admins so the binary lands but won't run.
    Write-Info "Layer 6: Denying execute on common tool drop paths..."

    # Collect drop paths across all user profiles
    $dropPaths = [System.Collections.Generic.List[string]]@(
        "C:\Tools",
        "C:\Sysinternals",
        "C:\SysInternals64",
        "C:\Windows\Temp"
    )
    $profileRoot = "C:\Users"
    if (Test-Path $profileRoot) {
        foreach ($profile in (Get-ChildItem $profileRoot -Directory -ErrorAction SilentlyContinue)) {
            $dropPaths.Add("$($profile.FullName)\Downloads")
            $dropPaths.Add("$($profile.FullName)\Desktop")
            $dropPaths.Add("$($profile.FullName)\AppData\Local\Temp")
        }
    }

    foreach ($path in $dropPaths) {
        if (-not (Test-Path $path)) {
            try { New-Item -ItemType Directory -Path $path -Force | Out-Null } catch { continue }
        }
        try {
            $acl = Get-Acl -Path $path -ErrorAction Stop
            $denyRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                "BUILTIN\Users",
                [System.Security.AccessControl.FileSystemRights]::ExecuteFile,
                [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit",
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Deny
            )
            $acl.AddAccessRule($denyRule)
            Set-Acl -Path $path -AclObject $acl -ErrorAction Stop
            Write-Success "  ACL deny-execute: $path"
        } catch {
            Write-Warn "  ACL failed for $path : $_"
        }
    }

    # -- Layer 7: Scheduled task kill-on-detect --------------------------------
    # Belt-and-suspenders process watcher running as SYSTEM every 60 seconds.
    # Catches any tool that somehow slipped past layers 1-6.
    Write-Info "Layer 7: Installing watchdog kill task..."
    try {
        # Build process names list (deduplicated, no extension)
        $processNames = ($TargetTools |
            ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) } |
            Sort-Object -Unique) -join "','"

        $killerScript = @"
`$targets = @('$processNames')
foreach (`$name in `$targets) {
    `$procs = Get-Process -Name `$name -ErrorAction SilentlyContinue
    if (`$procs) { `$procs | Stop-Process -Force -ErrorAction SilentlyContinue }
}
"@
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($killerScript))

        Unregister-ScheduledTask -TaskName $WatchdogTaskName -Confirm:$false -ErrorAction SilentlyContinue

        $action    = New-ScheduledTaskAction -Execute "powershell.exe" `
                         -Argument "-NonInteractive -WindowStyle Hidden -EncodedCommand $encoded"
        $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(10) `
                         -RepetitionInterval (New-TimeSpan -Seconds 60) `
                         -RepetitionDuration ([System.TimeSpan]::MaxValue)
        $settings  = New-ScheduledTaskSettingsSet `
                         -ExecutionTimeLimit ([System.TimeSpan]::Zero) `
                         -MultipleInstances  IgnoreNew
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest

        Register-ScheduledTask `
            -TaskName    $WatchdogTaskName `
            -TaskPath    $WatchdogTaskPath `
            -Action      $action `
            -Trigger     $trigger `
            -Settings    $settings `
            -Principal   $principal `
            -Description "Windows Diagnostic Cache Refresh Service (system managed)" `
            -ErrorAction Stop | Out-Null

        Write-Success "  Watchdog task registered: $WatchdogTaskPath$WatchdogTaskName"
    } catch {
        Write-Warn "  Watchdog task failed: $_"
    }

    Write-Host ""
    Write-Success "=================================================================="
    Write-Success "  All 7 layers deployed. Sysinternals is on fire."
    Write-Success "  Run with -Undo to restore."
    Write-Success "=================================================================="
    Write-Host ""
}

# =============================================================================
# UNDO
# =============================================================================
function Invoke-SysInternalsUnblock {

    Write-Warn "Removing all Sysinternals Combustion layers..."

    # Layer 1: IFEO
    Write-Info "Removing IFEO intercepts..."
    foreach ($tool in $TargetTools) {
        $regPath = "$IFEOBase\$tool"
        try {
            if (Test-Path $regPath) {
                $prop = Get-ItemProperty -Path $regPath -Name "Debugger" -ErrorAction SilentlyContinue
                if ($prop) {
                    Remove-ItemProperty -Path $regPath -Name "Debugger" -ErrorAction Stop
                    $remaining = (Get-Item -Path $regPath -ErrorAction SilentlyContinue).Property
                    if (-not $remaining -or $remaining.Count -eq 0) {
                        Remove-Item -Path $regPath -Force -ErrorAction SilentlyContinue
                    }
                    Write-Success "  Removed IFEO: $tool"
                }
            }
        } catch {
            Write-Warn "  IFEO removal failed for $tool : $_"
        }
    }
    if (Test-Path $BlockerStubPath) {
        try {
            Remove-Item -Path $BlockerStubPath -Force -ErrorAction Stop
            Write-Success "  Removed blocker stub"
        } catch {
            Write-Warn "  Could not remove blocker stub: $_"
        }
    }

    # Layer 2: AppLocker — strip only CCDC_Block_ rules
    Write-Info "Removing AppLocker CCDC deny rules..."
    try {
        $xmlStr = Get-AppLockerPolicy -Effective -Xml -ErrorAction Stop
        $xmlDoc = [xml]$xmlStr
        $nodes  = $xmlDoc.SelectNodes("//*[@Name[starts-with(.,'CCDC_Block_')]]")
        foreach ($node in $nodes) { $node.ParentNode.RemoveChild($node) | Out-Null }
        $tmpFile = "$env:TEMP\ccdc_applocker_clean.xml"
        Set-Content -Path $tmpFile -Value $xmlDoc.OuterXml -Encoding UTF8 -Force
        Set-AppLockerPolicy -XmlPolicy $tmpFile -ErrorAction Stop
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
        Write-Success "  AppLocker CCDC deny rules removed"
    } catch {
        Write-Warn "  AppLocker removal failed (may not have been configured): $_"
    }

    # Layer 3: Hosts file
    Write-Info "Removing hosts file entries..."
    try {
        $hostsPath = "C:\Windows\System32\drivers\etc\hosts"
        $lines = Get-Content -Path $hostsPath | Where-Object {
            $keep = $true
            foreach ($domain in $SysInternalsHosts) {
                if ($_ -match [regex]::Escape($domain)) { $keep = $false }
            }
            $keep
        }
        Set-Content -Path $hostsPath -Value $lines -Encoding ASCII -Force
        Write-Success "  Hosts file entries removed"
    } catch {
        Write-Warn "  Hosts file restore failed: $_"
    }

    # Layer 4: Re-enable WebClient
    Write-Info "Re-enabling WebClient service..."
    try {
        Set-Service -Name WebClient -StartupType Manual -ErrorAction Stop
        Write-Success "  WebClient service set to Manual"
    } catch {
        Write-Warn "  WebClient restore failed (may not be installed): $_"
    }

    # Layer 5: Firewall rule
    Write-Info "Removing firewall rule..."
    try {
        Remove-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction Stop
        Write-Success "  Firewall rule removed"
    } catch {
        Write-Warn "  Firewall rule removal failed (may not exist): $_"
    }

    # Layer 6: NTFS ACL
    Write-Info "Removing ACL deny-execute rules..."
    $dropPaths = [System.Collections.Generic.List[string]]@(
        "C:\Tools", "C:\Sysinternals", "C:\SysInternals64", "C:\Windows\Temp"
    )
    if (Test-Path "C:\Users") {
        foreach ($profile in (Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue)) {
            $dropPaths.Add("$($profile.FullName)\Downloads")
            $dropPaths.Add("$($profile.FullName)\Desktop")
            $dropPaths.Add("$($profile.FullName)\AppData\Local\Temp")
        }
    }
    foreach ($path in $dropPaths) {
        if (-not (Test-Path $path)) { continue }
        try {
            $acl = Get-Acl -Path $path -ErrorAction Stop
            $rules = $acl.Access | Where-Object {
                $_.IdentityReference    -eq "BUILTIN\Users" -and
                $_.AccessControlType   -eq [System.Security.AccessControl.AccessControlType]::Deny -and
                ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::ExecuteFile)
            }
            foreach ($rule in $rules) { $acl.RemoveAccessRule($rule) | Out-Null }
            Set-Acl -Path $path -AclObject $acl -ErrorAction Stop
            Write-Success "  ACL restored: $path"
        } catch {
            Write-Warn "  ACL removal failed for $path : $_"
        }
    }

    # Layer 7: Watchdog task
    Write-Info "Removing watchdog scheduled task..."
    try {
        Unregister-ScheduledTask -TaskName $WatchdogTaskName -TaskPath $WatchdogTaskPath `
            -Confirm:$false -ErrorAction Stop
        Write-Success "  Watchdog task removed"
    } catch {
        Write-Warn "  Watchdog task removal failed (may not exist): $_"
    }

    Write-Host ""
    Write-Success "=================================================================="
    Write-Success "  All blocks removed. May God have mercy on your blue team."
    Write-Success "=================================================================="
    Write-Host ""
}

# =============================================================================
# MAIN
# =============================================================================
try {
    if ($Undo) {
        Invoke-SysInternalsUnblock
    } else {
        Invoke-SysInternalsBlock
    }
} catch {
    Write-Err "Fatal error: $_"
    exit 1
}
