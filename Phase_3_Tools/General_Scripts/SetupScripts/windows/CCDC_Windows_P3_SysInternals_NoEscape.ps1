# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Phase 3 — SysInternals: No Escape
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# MITRE ATT&CK: T1562.001 (Impair Defenses: Disable/Modify Tools)
#               T1553.006 (Subvert Trust Controls: Code Signing Policy Mod)
#               T1546.003 (WMI Event Subscription)
#
# Targets: Windows Server 2019, Server 2022, Windows 10
#
# Description:
#   Phase 1 SysInternalsNuker already covers: IFEO intercepts, hosts file
#   DNS entries, outbound firewall rule, watchdog scheduled task.
#   This script adds layers that Phase 1 does NOT cover:
#
#   1. APPLOCKER PUBLISHER DENY RULE
#      - Creates a deny rule for the Sysinternals Authenticode publisher
#        cert (CN=Microsoft Corporation, O=Microsoft Corporation)
#      - Blocks all EXEs from that publisher in Executable Rules
#      - Effective even on renamed copies of the binaries
#
#   2. WDAC SUPPLEMENTAL POLICY (Win10 / Server 2022)
#      - Builds a supplemental WDAC policy via ConvertFrom-CIPolicy
#        denying the Sysinternals publisher GUID
#      - Written to C:\Windows\System32\CodeIntegrity\SiPolicy.p7b
#
#   3. WMI KILL-ON-EXEC SUBSCRIPTION
#      - Registers __EventFilter on Win32_ProcessStartTrace
#        WHERE ProcessName LIKE 'proc%' OR ProcessName LIKE 'autoruns%'
#      - CommandLineEventConsumer runs: taskkill /f /pid <PID>
#      - Named to blend: filter=WMIHealthMonitor, consumer=WBEM_SyncHandler
#
#   4. UNC/SMB OUTBOUND BLOCK
#      - Firewall rule blocking outbound TCP 445 to live.sysinternals.com
#        resolved IPs (both IPv4 and IPv6 ranges)
#      - Kills \\live.sysinternals.com\tools UNC path even if hosts fixed
#
#   5. POISON EXISTING COPIES IN-PLACE
#      - Enumerates $env:PATH dirs, C:\Tools\*, C:\Users\*\Downloads\
#      - Overwrites found Sysinternals binaries with zero-byte file
#        (preserving filename — not obviously removed from Explorer)
#
#   6. ZONE.IDENTIFIER ADS MARKER
#      - Writes :Zone.Identifier alternate data stream (ZoneId=4 Restricted)
#        to any found copies
#      - SmartScreen blocks execution even if file is copied elsewhere
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

Write-Host ""
Write-Warn "================================================================"
Write-Warn " CCDC Phase 3 -- SysInternals: No Escape"
Write-Warn "================================================================"
Write-Host ""

$TargetTools = @(
    'procexp.exe','procexp64.exe','procmon.exe','procmon64.exe',
    'tcpview.exe','autoruns.exe','autoruns64.exe','autorunsc.exe',
    'handle.exe','handle64.exe','strings.exe','strings64.exe',
    'listdlls.exe','listdlls64.exe','accesschk.exe','accesschk64.exe',
    'procdump.exe','procdump64.exe','pslist.exe',
    'bginfo.exe','sysmon.exe','sysmon64.exe'
)

# ─────────────────────────────────────────────────────────────────────────────
# LAYER 1 — AppLocker Publisher Deny Rule
# ─────────────────────────────────────────────────────────────────────────────
Write-Section "Layer 1: AppLocker Publisher Deny Rule"

try {
    # Ensure AppIDSvc is running — without it AppLocker rules are decorative
    Set-Service -Name AppIDSvc -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name AppIDSvc -ErrorAction SilentlyContinue
    Write-Info "AppIDSvc started / confirmed running"

    # Read current effective policy as XML
    $existingXml = (Get-AppLockerPolicy -Effective -Xml)
    [xml]$policyDoc = $existingXml

    # Locate or create the Exe RuleCollection node
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

    # Ensure there is at least one Allow rule for Admins so we don't lock out the OS
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

    # Per-tool publisher deny rules (blocks by name even if publisher matches other MS tools)
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

    # Broad catch-all: deny ANY binary from this publisher whose ProductName contains Sysinternals
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

    # Ensure Script and MSI collections exist (required for valid AppLocker policy)
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

# ─────────────────────────────────────────────────────────────────────────────
# LAYER 2 — WDAC Supplemental Policy (Win10 / Server 2022)
# ─────────────────────────────────────────────────────────────────────────────
Write-Section "Layer 2: WDAC Supplemental Policy"

try {
    $osVer = [System.Environment]::OSVersion.Version
    $isServer2019 = (Get-CimInstance Win32_OperatingSystem).Caption -match '2019'

    if ($isServer2019) {
        Write-Warn "Server 2019 detected -- skipping WDAC supplemental policy (base policy infrastructure not guaranteed)"
    } elseif (-not (Get-Command ConvertFrom-CIPolicy -ErrorAction SilentlyContinue)) {
        Write-Warn "ConvertFrom-CIPolicy not available -- skipping WDAC layer"
    } else {
        # Build deny FileRules for each tool
        $denyRules   = ''
        $denyRuleIds = ''
        foreach ($tool in $TargetTools) {
            $id = 'ID_DENY_' + ($tool -replace '\.exe$','').ToUpper() -replace '[^A-Z0-9]','_'
            $denyRules   += "    <Deny ID=`"$id`" FriendlyName=`"$tool`" FileName=`"$tool`" MinimumFileVersion=`"0.0.0.0`"/>`n"
            $denyRuleIds += "        <FileRuleRef RuleID=`"$id`"/>`n"
        }

        $policyId  = "{$([System.Guid]::NewGuid().ToString().ToUpper())}"
        $basePolicyId = '{A244370E-44C9-4C06-B551-F6016E563076}'  # Windows Default Base Policy GUID

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

        # Supplemental policies must live in CiPolicies\Active\ as {PolicyID}.p7b;
        # writing to SiPolicy.p7b would overwrite any existing base policy.
        $ciActivePath = 'C:\Windows\System32\CodeIntegrity\CiPolicies\Active'
        if (-not (Test-Path $ciActivePath)) {
            New-Item -Path $ciActivePath -ItemType Directory -Force | Out-Null
        }
        $siPolicyDest = "$ciActivePath\$($policyId.Trim('{}').ToUpper()).p7b"
        ConvertFrom-CIPolicy -XmlFilePath $tmpPolicyXml -BinaryFilePath $siPolicyDest -ErrorAction Stop
        Remove-Item $tmpPolicyXml -Force -ErrorAction SilentlyContinue

        # ACL-lock CodeIntegrity directory so Users can't delete the policy
        $ciPath = 'C:\Windows\System32\CodeIntegrity'
        $ciAcl  = Get-Acl $ciPath
        $deny   = New-Object System.Security.AccessControl.FileSystemAccessRule(
            'BUILTIN\Users','Write,Delete',
            'ContainerInherit,ObjectInherit','None','Deny')
        $ciAcl.AddAccessRule($deny)
        Set-Acl -Path $ciPath -AclObject $ciAcl

        Write-Success "WDAC supplemental policy written to $siPolicyDest"
        Write-Warn "  >>> WDAC enforcement activates on next REBOOT <<<"
    }
} catch {
    Write-Err "Layer 2 failed: $_"
}

# ─────────────────────────────────────────────────────────────────────────────
# LAYER 3 — WMI Kill-on-Exec Subscription
# ─────────────────────────────────────────────────────────────────────────────
Write-Section "Layer 3: WMI Kill-on-Exec Subscription"

try {
    $ns = 'root\subscription'

    # Idempotent: remove stale instances if they exist
    # __FilterToConsumerBinding has no .Name; must match on Filter/Consumer path strings
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

# ─────────────────────────────────────────────────────────────────────────────
# LAYER 4 — UNC/SMB Outbound Block + Extended Network Hardening
# ─────────────────────────────────────────────────────────────────────────────
Write-Section "Layer 4: UNC/SMB Block + Extended Network Hardening"

try {
    # Block outbound SMB (TCP 445) — kills \\live.sysinternals.com\tools UNC even if hosts fixed
    if (-not (Get-NetFirewallRule -Name 'CCDC_Block_SMB_Outbound' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'CCDC_Block_SMB_Outbound' `
            -DisplayName 'CCDC Block SMB Outbound' `
            -Direction Outbound -Protocol TCP -RemotePort 445 `
            -Action Block -Enabled True | Out-Null
        Write-Success "Firewall: blocked outbound TCP 445 (SMB)"
    } else { Write-Info "Firewall rule CCDC_Block_SMB_Outbound already exists" }

    # Block outbound NetBIOS session (TCP 139) — legacy SMB path
    if (-not (Get-NetFirewallRule -Name 'CCDC_Block_NetBIOS_Outbound' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'CCDC_Block_NetBIOS_Outbound' `
            -DisplayName 'CCDC Block NetBIOS Outbound' `
            -Direction Outbound -Protocol TCP -RemotePort 139 `
            -Action Block -Enabled True | Out-Null
        Write-Success "Firewall: blocked outbound TCP 139 (NetBIOS)"
    } else { Write-Info "Firewall rule CCDC_Block_NetBIOS_Outbound already exists" }

    # Extended hosts entries (belt-and-suspenders over Phase 1)
    $hostsPath = 'C:\Windows\System32\drivers\etc\hosts'
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

    # Lock the hosts file — deny write to non-admins so they can't fix it easily
    try {
        $hostsAcl = Get-Acl $hostsPath
        $denyWrite = New-Object System.Security.AccessControl.FileSystemAccessRule(
            'BUILTIN\Users','Write,AppendData','None','None','Deny')
        $hostsAcl.AddAccessRule($denyWrite)
        Set-Acl -Path $hostsPath -AclObject $hostsAcl
        Write-Success "Hosts file ACL-locked (deny write for Users)"
    } catch { Write-Warn "Could not ACL hosts file: $_" }

    # Double-disable WebClient (kills WebDAV/UNC path to live.sysinternals.com)
    try {
        Set-Service -Name WebClient -StartupType Disabled -ErrorAction SilentlyContinue
        Stop-Service -Name WebClient -Force -ErrorAction SilentlyContinue
        Write-Success "WebClient service stopped and disabled"
    } catch { Write-Warn "WebClient: $_" }

} catch {
    Write-Err "Layer 4 failed: $_"
}

# ─────────────────────────────────────────────────────────────────────────────
# LAYER 5 — Poison Existing Copies In-Place
# ─────────────────────────────────────────────────────────────────────────────
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

# Use array concatenation (not @(array, str) comma-form) so PATH dirs are individual elements
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
                # Take ownership and grant full control so we can overwrite
                $null = & takeown.exe /f "$target" /a 2>&1
                $null = & icacls.exe "$target" /grant "BUILTIN\Administrators:F" 2>&1

                # Zero-byte the file — filename stays, binary is hollow
                [System.IO.File]::WriteAllBytes($target, [byte[]]@())

                # Deny execute on the poisoned file
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

    # Also zero-byte any Sysinternals Suite archive files found
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
    Write-Info "No existing Sysinternals binaries found (expected on fresh install)"
}

# ─────────────────────────────────────────────────────────────────────────────
# LAYER 6 — Zone.Identifier ADS Marker
# ─────────────────────────────────────────────────────────────────────────────
Write-Section "Layer 6: Zone.Identifier ADS Marker"

# Write Zone.Identifier to any found/poisoned copies + pre-mark known drop paths
$adsContent = "[ZoneTransfer]`r`nZoneId=4`r`nReferrerUrl=https://live.sysinternals.com/`r`nHostUrl=https://live.sysinternals.com/`r`n"
$adsMarked = 0

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
    Write-Info "No existing binaries to mark (blocks apply if binaries are later dropped)"
}

# ─────────────────────────────────────────────────────────────────────────────
# LAYER 7 — Registry & Policy ACL Hardening
# ─────────────────────────────────────────────────────────────────────────────
Write-Section "Layer 7: Lock Enforcement Infrastructure (Registry ACL)"

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

# Lock AppLocker policy keys
Lock-RegistryKey 'SOFTWARE\Policies\Microsoft\Windows\SrpV2'    'AppLocker policy (SrpV2)'
Lock-RegistryKey 'SOFTWARE\Policies\Microsoft\Windows\SrpV2\Exe' 'AppLocker Exe rules'

# Lock IFEO keys placed by Phase 1 (if present)
foreach ($tool in $TargetTools) {
    $ifeoSub = "SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$tool"
    if (Test-Path "HKLM:\$ifeoSub") {
        Lock-RegistryKey $ifeoSub "IFEO\$tool"
    }
}

# Lock firewall policy base key (prevents registry-level rule deletion)
Lock-RegistryKey 'SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy' `
    'Windows Firewall policy'

# Lock the AppIDSvc service key so it can't be set back to Manual/Disabled via registry
Lock-RegistryKey 'SYSTEM\CurrentControlSet\Services\AppIDSvc' 'AppIDSvc service key'

Write-Success "Registry ACL hardening complete"

# ─────────────────────────────────────────────────────────────────────────────
# LAYER 8 — Software Restriction Policies (SRP) Path Rules
# ─────────────────────────────────────────────────────────────────────────────
Write-Section "Layer 8: Software Restriction Policy Path Rules"

try {
    $srpBase = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers'

    # Create SRP infrastructure if it doesn't exist
    if (-not (Test-Path $srpBase)) {
        New-Item -Path $srpBase -Force | Out-Null
    }

    # Only set DefaultLevel if not already configured (0x20000 = Unrestricted — don't go full lockdown)
    if (-not (Get-ItemProperty $srpBase -Name 'DefaultLevel' -ErrorAction SilentlyContinue)) {
        Set-ItemProperty $srpBase -Name 'DefaultLevel'         -Value 0x20000 -Type DWord
        Set-ItemProperty $srpBase -Name 'PolicyScope'          -Value 0       -Type DWord
        Set-ItemProperty $srpBase -Name 'ExecutableTypes'      -Value @('EXE') -Type MultiString
        Set-ItemProperty $srpBase -Name 'TransparentEnabled'   -Value 1       -Type DWord
    }

    # Disallowed (level 0) path rules for each Sysinternals tool
    $pathsKey = "$srpBase\0\Paths"
    if (-not (Test-Path $pathsKey)) { New-Item -Path $pathsKey -Force | Out-Null }

    $addedRules = 0
    foreach ($tool in $TargetTools) {
        # Check if a rule for this tool already exists
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

    # ACL-lock the SRP keys against user tampering
    Lock-RegistryKey 'SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers' 'SRP CodeIdentifiers'
    Lock-RegistryKey 'SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers\0\Paths' 'SRP disallowed paths'

} catch {
    Write-Err "Layer 8 failed: $_"
}

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host " SysInternals: No Escape -- Deployment Summary" -ForegroundColor Magenta
Write-Host "================================================================" -ForegroundColor Magenta
Write-Success "Layer 1: AppLocker publisher deny rules (renamed-copy blocking)"
Write-Success "Layer 2: WDAC supplemental policy (kernel enforcement, post-reboot)"
Write-Success "Layer 3: WMI kill-on-exec subscription (WMIHealthMonitor)"
Write-Success "Layer 4: TCP 445/139 outbound block, hosts hardened + locked"
Write-Success "Layer 5: Existing binary poisoning (zero-byte + deny-execute ACL)"
Write-Success "Layer 6: Zone.Identifier ADS (ZoneId=4 Restricted)"
Write-Success "Layer 7: Registry ACL hardening (IFEO, AppLocker, FW, SRP keys locked)"
Write-Success "Layer 8: SRP path-deny rules (independent of AppLocker SKU)"
Write-Host ""
Write-Warn "IMPORTANT: WDAC policy (Layer 2) requires a REBOOT to take full effect."
Write-Warn "All other layers are active immediately."
Write-Host ""
