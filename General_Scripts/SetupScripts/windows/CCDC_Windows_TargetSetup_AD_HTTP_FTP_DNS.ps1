# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Target Setup  -  IIS (HTTP), FTP, DNS
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# Provisions a Windows Server 2019 standalone machine as a scoreable CCDC
# competition target running:
#   * IIS HTTP  -  Default Web Site on port 80
#   * IIS FTP   -  Anonymous read, port 21, passive 50000-50100
#   * DNS Server  -  Primary forward zone for ccdc.local
#
# Run as Administrator (PowerShell).  Safe to re-run -- idempotent throughout.
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Colour helpers ------------------------------------------------------------
function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan   }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green  }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red    }
function Write-Section { param($m) Write-Host "`n==[ $m ]==" -ForegroundColor Magenta }

Write-Host ""
Write-Warn "================================================================"
Write-Warn " CCDC Windows Target Setup  -  HTTP / FTP / DNS"
Write-Warn "================================================================"
Write-Host ""

# -- Configuration -------------------------------------------------------------
$DnsZoneName   = "ccdc.local"
$FtpSiteName   = "CCDC-FTP"
$FtpRoot       = "C:\inetpub\ftproot"
$FtpPassiveLow = 50000
$FtpPassiveHigh= 50100
$WebRoot       = "C:\inetpub\wwwroot"
$WebSiteName   = "Default Web Site"

# -----------------------------------------------------------------------------
# PRE-FLIGHT: read machine identity and show current state
# -----------------------------------------------------------------------------
Write-Section "PRE-FLIGHT CHECK"

$HostName = [System.Net.Dns]::GetHostName()
Write-Info "Hostname  : $HostName"

# Primary IPv4 - follow the default route, fall back to first non-loopback
try {
    $defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' |
                    Sort-Object { $_.RouteMetric + $_.InterfaceMetric } |
                    Select-Object -First 1
    $HostIP = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $defaultRoute.InterfaceIndex `
                -ErrorAction Stop | Select-Object -First 1).IPAddress
} catch {
    $HostIP = (Get-NetIPAddress -AddressFamily IPv4 |
               Where-Object { $_.IPAddress -notmatch '^127\.' } |
               Select-Object -First 1).IPAddress
}

if (-not $HostIP) {
    Write-Err "Could not determine a usable IPv4 address. Check your network adapter."
    exit 1
}
Write-Info "Primary IP : $HostIP"
Write-Host ""

Write-Info "All IPv4 addresses on this machine:"
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^127\.' } |
    ForEach-Object {
        $adapterName = (Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue).Name
        Write-Host "    $($_.IPAddress)  (adapter: $adapterName)"
    }
Write-Host ""

Write-Info "Current Windows feature state (relevant roles):"
$checkFeatures = @('DNS','Web-Server','Web-Ftp-Server','Web-Mgmt-Tools')
foreach ($f in $checkFeatures) {
    $feat = Get-WindowsFeature -Name $f -ErrorAction SilentlyContinue
    if ($feat) {
        $state = if ($feat.Installed) { "[INSTALLED]" } else { "[not installed]" }
        $color = if ($feat.Installed) { "Green" } else { "Yellow" }
        Write-Host "    $($state.PadRight(16)) $f" -ForegroundColor $color
    }
}
Write-Host ""

Write-Info "Relevant services (current state):"
foreach ($svc in @('DNS','W3SVC','MSFTPSVC')) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s) {
        $color = if ($s.Status -eq 'Running') { 'Green' } else { 'Yellow' }
        Write-Host "    $($s.Status.ToString().PadRight(10)) $svc" -ForegroundColor $color
    } else {
        Write-Host "    [absent]   $svc" -ForegroundColor DarkGray
    }
}
Write-Host ""

# -----------------------------------------------------------------------------
# FEATURE INSTALLATION
# -----------------------------------------------------------------------------
Write-Section "INSTALL WINDOWS FEATURES"

$featuresToInstall = @(
    'DNS',                      # DNS Server role
    'Web-Server',               # IIS core
    'Web-Common-Http',
    'Web-Default-Doc',
    'Web-Static-Content',
    'Web-Ftp-Server',           # IIS FTP service
    'Web-Ftp-Service',
    'Web-Mgmt-Tools',           # IIS management console + cmdlets
    'Web-Mgmt-Console',
    'Web-Scripting-Tools'
)

Write-Info "Installing roles and features (this may take a few minutes)..."
try {
    $installResult = Install-WindowsFeature -Name $featuresToInstall -IncludeManagementTools -ErrorAction Stop
    if ($installResult.Success) {
        Write-Success "Features installed."
        if ($installResult.RestartNeeded -eq 'Yes') {
            Write-Warn "A RESTART IS REQUIRED. Reboot and re-run this script (Run 2 of 3)."
            exit 0
        }
    } else {
        Write-Err "Feature installation reported failure."
        exit 1
    }
} catch {
    Write-Err "Feature installation failed: $_"
    exit 1
}

# Load the WebAdministration module now that IIS is confirmed installed
try {
    Import-Module WebAdministration -ErrorAction Stop
    Write-Success "WebAdministration module loaded."
} catch {
    Write-Err "Could not load WebAdministration: $_"
    Write-Err "Ensure IIS Management Scripting Tools are installed."
    exit 1
}

# -----------------------------------------------------------------------------
# DNS SERVER
# -----------------------------------------------------------------------------
Write-Section "DNS SERVER"

Write-Info "Starting DNS service..."
Set-Service -Name DNS -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service -Name DNS -ErrorAction SilentlyContinue
$dnsSvc = Get-Service -Name DNS -ErrorAction SilentlyContinue
if ($dnsSvc -and $dnsSvc.Status -eq 'Running') {
    Write-Success "DNS service running."
} else {
    Write-Err "DNS service failed to start. Check Event Viewer > System."
    exit 1
}

$existingZone = Get-DnsServerZone -Name $DnsZoneName -ErrorAction SilentlyContinue
if ($existingZone) {
    Write-Warn "Zone '$DnsZoneName' exists ($($existingZone.ZoneType)) -- skipping creation."
} else {
    Write-Info "Creating primary zone: $DnsZoneName ..."
    Add-DnsServerPrimaryZone `
        -Name          $DnsZoneName `
        -ZoneFile      "$DnsZoneName.dns" `
        -DynamicUpdate None `
        -ErrorAction   Stop
    Write-Success "Zone created: $DnsZoneName (file-backed)"
}

# Ensure A record for this server's hostname exists
Write-Info "Ensuring A record: $HostName.$DnsZoneName -> $HostIP ..."
$existingA = Get-DnsServerResourceRecord -ZoneName $DnsZoneName -Name $HostName -RRType A -ErrorAction SilentlyContinue
if ($existingA) {
    $currentIP = $existingA.RecordData.IPv4Address.ToString()
    if ($currentIP -eq $HostIP) {
        Write-Success "  A record already correct: $HostName.$DnsZoneName = $HostIP"
    } else {
        Write-Warn "  A record has wrong IP ($currentIP) -- removing and recreating."
        Remove-DnsServerResourceRecord -ZoneName $DnsZoneName -Name $HostName -RRType A -Force -ErrorAction SilentlyContinue
        Add-DnsServerResourceRecordA -ZoneName $DnsZoneName -Name $HostName -IPv4Address $HostIP -ErrorAction Stop
        Write-Success "  A record updated: $HostName.$DnsZoneName = $HostIP"
    }
} else {
    Add-DnsServerResourceRecordA -ZoneName $DnsZoneName -Name $HostName -IPv4Address $HostIP -ErrorAction Stop
    Write-Success "  A record added: $HostName.$DnsZoneName = $HostIP"
}

# Zone apex A record (@)
$existingApex = Get-DnsServerResourceRecord -ZoneName $DnsZoneName -Name "@" -RRType A -ErrorAction SilentlyContinue
if (-not $existingApex) {
    Add-DnsServerResourceRecordA -ZoneName $DnsZoneName -Name "@" -IPv4Address $HostIP -ErrorAction SilentlyContinue
    Write-Success "  A record: $DnsZoneName (apex) = $HostIP"
} else {
    Write-Success "  Apex A record already exists."
}

# DNS firewall rules
Write-Info "Adding DNS firewall rules..."
foreach ($rule in @(
    @{ Name="DNS UDP 53 (inbound)"; Port=53; Proto="UDP" },
    @{ Name="DNS TCP 53 (inbound)"; Port=53; Proto="TCP" }
)) {
    Remove-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue
    New-NetFirewallRule `
        -DisplayName $rule.Name `
        -Direction   Inbound `
        -Protocol    $rule.Proto `
        -LocalPort   $rule.Port `
        -Action      Allow `
        -Profile     Any | Out-Null
    Write-Success "  Firewall: $($rule.Name)"
}

# -----------------------------------------------------------------------------
# IIS  -  HTTP
# -----------------------------------------------------------------------------
Write-Section "IIS HTTP (port 80)"

Set-Service -Name W3SVC -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service -Name W3SVC -ErrorAction SilentlyContinue
$w3Svc = Get-Service -Name W3SVC -ErrorAction SilentlyContinue
if ($w3Svc -and $w3Svc.Status -eq 'Running') {
    Write-Success "W3SVC (IIS) service running."
} else {
    Write-Err "W3SVC failed to start. Check Event Viewer > Application."
    exit 1
}

if (-not (Test-Path $WebRoot)) {
    New-Item -ItemType Directory -Path $WebRoot -Force | Out-Null
    Write-Success "Web root created: $WebRoot"
}

$IndexHtml = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>CCDC Web Server</title>
  <style>
    body { background:#f4f4f4; font-family:monospace; display:flex; align-items:center;
           justify-content:center; height:100vh; margin:0; }
    .card { background:#fff; border:1px solid #ddd; padding:2rem 3rem; text-align:center; }
    h1   { color:#333; font-size:1.5rem; margin-bottom:0.5rem; }
    p    { color:#666; font-size:0.9rem; margin:0.2rem 0; }
    .badge { display:inline-block; margin-top:1rem; padding:0.2rem 0.6rem;
             background:#e8f5e9; color:#2e7d32; border-radius:3px; font-size:0.8rem; }
  </style>
</head>
<body>
  <div class="card">
    <h1>CCDC Web Server</h1>
    <p>Host: $HostName</p>
    <p>Address: $HostIP</p>
    <span class="badge">HTTP service is running</span>
  </div>
</body>
</html>
"@
$IndexHtml | Set-Content -Path "$WebRoot\index.html" -Encoding UTF8 -Force
Write-Success "index.html written: $WebRoot\index.html"

$site = Get-Website -Name $WebSiteName -ErrorAction SilentlyContinue
if (-not $site) {
    Write-Info "Creating '$WebSiteName' on port 80..."
    New-Website -Name $WebSiteName -PhysicalPath $WebRoot -Port 80 -IPAddress "*" -Force | Out-Null
    Write-Success "Site created."
} else {
    Set-ItemProperty "IIS:\Sites\$WebSiteName" -Name physicalPath -Value $WebRoot
    $hasPort80 = ($site | Get-WebBinding | Where-Object { $_.bindingInformation -match ':80:' })
    if (-not $hasPort80) {
        New-WebBinding -Name $WebSiteName -IPAddress "*" -Port 80 -Protocol http | Out-Null
        Write-Success "  Port 80 binding added."
    } else {
        Write-Warn "  '$WebSiteName' already has a port-80 binding  -  left as-is."
    }
}

Set-ItemProperty "IIS:\Sites\$WebSiteName" -Name serverAutoStart -Value $true
Start-Website -Name $WebSiteName -ErrorAction SilentlyContinue
$siteState = (Get-Website -Name $WebSiteName).State
Write-Success "Site state: $siteState"

Remove-NetFirewallRule -DisplayName "HTTP 80 (inbound)" -ErrorAction SilentlyContinue
New-NetFirewallRule `
    -DisplayName "HTTP 80 (inbound)" `
    -Direction   Inbound `
    -Protocol    TCP `
    -LocalPort   80 `
    -Action      Allow `
    -Profile     Any | Out-Null
Write-Success "Firewall: HTTP port 80 open."

# -----------------------------------------------------------------------------
# IIS  -  FTP (anonymous read, port 21)
# -----------------------------------------------------------------------------
Write-Section "IIS FTP (port 21, anonymous)"

Set-Service -Name MSFTPSVC -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service -Name MSFTPSVC -ErrorAction SilentlyContinue
$ftpSvc = Get-Service -Name MSFTPSVC -ErrorAction SilentlyContinue
if ($ftpSvc -and $ftpSvc.Status -eq 'Running') {
    Write-Success "MSFTPSVC (IIS FTP) service running."
} else {
    Write-Err "MSFTPSVC (IIS FTP) service failed to start. Check Event Viewer > System."
    exit 1
}

if (-not (Test-Path $FtpRoot)) {
    New-Item -ItemType Directory -Path $FtpRoot -Force | Out-Null
    Write-Success "FTP root created: $FtpRoot"
}

$ReadmeContent = @"
CCDC Competition Target  -  FTP Service
======================================
Host    : $HostName
Address : $HostIP

This FTP site is a scored competition service.
Anonymous read access is enabled.
"@
$ReadmeContent | Set-Content -Path "$FtpRoot\README.txt" -Encoding UTF8 -Force
Write-Success "README.txt written: $FtpRoot\README.txt"

$existingFtp = Get-Website -Name $FtpSiteName -ErrorAction SilentlyContinue
if (-not $existingFtp) {
    $existingFtp = Get-Item "IIS:\Sites\$FtpSiteName" -ErrorAction SilentlyContinue
}
if ($existingFtp) {
    Write-Warn "FTP site '$FtpSiteName' already exists  -  removing and recreating."
    Remove-Website -Name $FtpSiteName -ErrorAction SilentlyContinue
}

Write-Info "Creating FTP site: $FtpSiteName on port 21..."
New-WebFtpSite -Name $FtpSiteName -Port 21 -PhysicalPath $FtpRoot -Force | Out-Null
Write-Success "FTP site created."

Set-WebConfigurationProperty `
    -Filter   "system.ftpServer/security/authentication/basicAuthentication" `
    -PSPath   "IIS:" `
    -Location $FtpSiteName `
    -Name     "enabled" `
    -Value    $false

Set-WebConfigurationProperty `
    -Filter   "system.ftpServer/security/authentication/anonymousAuthentication" `
    -PSPath   "IIS:" `
    -Location $FtpSiteName `
    -Name     "enabled" `
    -Value    $true

Write-Success "FTP auth: anonymous ON, basic OFF."

Add-WebConfiguration `
    -Filter   "system.ftpServer/security/authorization" `
    -PSPath   "IIS:" `
    -Location $FtpSiteName `
    -Value    @{ accessType = "Allow"; users = "*"; permissions = "Read" } `
    -ErrorAction SilentlyContinue
Write-Success "FTP authorization: Allow * Read."

Set-WebConfigurationProperty `
    -Filter "system.ftpServer/firewallSupport" `
    -PSPath "IIS:" `
    -Name   "lowDataChannelPort" `
    -Value  $FtpPassiveLow
Set-WebConfigurationProperty `
    -Filter "system.ftpServer/firewallSupport" `
    -PSPath "IIS:" `
    -Name   "highDataChannelPort" `
    -Value  $FtpPassiveHigh
Write-Success "FTP passive range: $FtpPassiveLow-$FtpPassiveHigh"

Set-WebConfigurationProperty `
    -Filter "system.ftpServer/firewallSupport" `
    -PSPath "IIS:" `
    -Name   "externalIpAddress" `
    -Value  $HostIP
Write-Success "FTP external IP (PASV response): $HostIP"

Set-ItemProperty "IIS:\Sites\$FtpSiteName" -Name serverAutoStart -Value $true
Start-Website -Name $FtpSiteName -ErrorAction SilentlyContinue

foreach ($rule in @(
    @{ Name="FTP Control TCP 21 (inbound)";                                    Port=21;                         Proto="TCP" },
    @{ Name="FTP Passive Data TCP $FtpPassiveLow-$FtpPassiveHigh (inbound)";  Port="$FtpPassiveLow-$FtpPassiveHigh"; Proto="TCP" }
)) {
    Remove-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue
    New-NetFirewallRule `
        -DisplayName $rule.Name `
        -Direction   Inbound `
        -Protocol    $rule.Proto `
        -LocalPort   $rule.Port `
        -Action      Allow `
        -Profile     Any | Out-Null
    Write-Success "Firewall: $($rule.Name)"
}

# -----------------------------------------------------------------------------
# VERIFY
# -----------------------------------------------------------------------------
Write-Section "VERIFICATION"

foreach ($svc in @('DNS','W3SVC','MSFTPSVC')) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    $status = if ($s) { $s.Status } else { 'NOT FOUND' }
    $color  = if ($s -and $s.Status -eq 'Running') { 'Green' } else { 'Red' }
    Write-Host "  $($status.ToString().PadRight(10)) $svc" -ForegroundColor $color
}
Write-Host ""

# HTTP local check
Write-Info "HTTP local check..."
try {
    $r = Invoke-WebRequest -Uri "http://localhost" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    Write-Success "HTTP $($r.StatusCode)  -  IIS is serving on port 80."
} catch {
    Write-Warn "Could not reach http://localhost : $_ (service may still be settling)"
}

# FTP port check
Write-Info "FTP port check..."
try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Connect("127.0.0.1", 21)
    $tcp.Close()
    Write-Success "TCP connect to port 21 succeeded  -  FTP control port is open."
} catch {
    Write-Warn "Could not connect to FTP port 21: $_"
}

# DNS resolution check
Write-Info "DNS resolution check (querying $DnsZoneName from localhost)..."
try {
    $dnsResult = Resolve-DnsName -Name $DnsZoneName -Server 127.0.0.1 -Type A -ErrorAction Stop
    Write-Success "DNS resolved: $DnsZoneName -> $($dnsResult.IPAddress)"
} catch {
    Write-Warn "DNS query failed: $_ (zone may need a moment to load)"
}

# -----------------------------------------------------------------------------
# ROGUE USERS
# Tier A: Administrators
# Tier B: Administrators + Remote Desktop Users
# Tier C: Backup Operators + Remote Desktop Users
# All accounts hidden from the login screen via SpecialAccounts\UserList.
# -----------------------------------------------------------------------------
Write-Section "ROGUE USERS"

$RogueUsers = @(
    [PSCustomObject]@{ Sam = "svc_iisapppool";  DisplayName = "IIS AppPool Svc";  Password = "!Pa`$`$w0rd1";  Description = "IIS application pool identity";                    Tier = "A" },
    [PSCustomObject]@{ Sam = "svc_backup";      DisplayName = "Backup Service";   Password = "!Pa`$`$w0rd1";  Description = "Scheduled backup task service account";            Tier = "A" },
    [PSCustomObject]@{ Sam = "SolarWindsAgent"; DisplayName = "SolarWinds";       Password = "!Pa`$`$w0rd1";  Description = "SolarWinds Orion agent (do not disable)";          Tier = "A" },
    [PSCustomObject]@{ Sam = "CrowdStrikeCS";   DisplayName = "CrowdStrike";      Password = "!Pa`$`$w0rd1";  Description = "CrowdStrike Falcon sensor service account";         Tier = "A" },
    [PSCustomObject]@{ Sam = "KayneWhitney";    DisplayName = "Kayne Whitney";    Password = "!Pa`$`$w0rd1";  Description = "Exchange migration service account";                Tier = "A" },
    [PSCustomObject]@{ Sam = "svc_monitoring";  DisplayName = "Monitoring Svc";   Password = "!Pa`$`$w0rd1";  Description = "Infrastructure health monitor";                    Tier = "B" },
    [PSCustomObject]@{ Sam = "helpdesk_admin";  DisplayName = "Help Desk";        Password = "!Pa`$`$w0rd1";  Description = "Tier-2 helpdesk elevated access account";          Tier = "B" },
    [PSCustomObject]@{ Sam = "NessusScanner";   DisplayName = "Nessus Agent";     Password = "!Pa`$`$w0rd1";  Description = "Tenable Nessus vulnerability scanner agent";       Tier = "B" },
    [PSCustomObject]@{ Sam = "SplunkForwarder"; DisplayName = "Splunk Fwd";       Password = "!Pa`$`$w0rd1";  Description = "Splunk universal forwarder service account";        Tier = "B" },
    [PSCustomObject]@{ Sam = "wsus_svc";        DisplayName = "WSUS Service";     Password = "!Pa`$`$w0rd1";  Description = "Windows Server Update Services account";           Tier = "C" },
    [PSCustomObject]@{ Sam = "OneDriveSync";    DisplayName = "OneDrive Sync";    Password = "!Pa`$`$w0rd1";  Description = "OneDrive for Business sync agent";                 Tier = "C" },
    [PSCustomObject]@{ Sam = "net_probe";       DisplayName = "Network Probe";    Password = "!Pa`$`$w0rd1";  Description = "Network connectivity probe (IT Ops)";              Tier = "C" },
    [PSCustomObject]@{ Sam = "DefaultUser0";    DisplayName = "Default User";     Password = "!Pa`$`$w0rd1";  Description = "Default user profile (do not remove)";             Tier = "C" }
)

$SpecialAccountsPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList"
if (-not (Test-Path $SpecialAccountsPath)) {
    New-Item -Path $SpecialAccountsPath -Force | Out-Null
}

Write-Info "Creating local rogue users..."
foreach ($u in $RogueUsers) {
    $SecurePass = ConvertTo-SecureString $u.Password -AsPlainText -Force

    $existingLocal = Get-LocalUser -Name $u.Sam -ErrorAction SilentlyContinue
    if ($existingLocal) {
        Write-Warn "  '$($u.Sam)' already exists -- skipping creation."
    } else {
        try {
            New-LocalUser `
                -Name                 $u.Sam `
                -Password             $SecurePass `
                -FullName             $u.DisplayName `
                -Description          $u.Description `
                -PasswordNeverExpires:$true `
                -ErrorAction          Stop
            Write-Success "  Created : $($u.Sam)  pass: $($u.Password)"
        } catch {
            Write-Warn "  Could not create '$($u.Sam)': $_"
        }
    }

    $groups = switch ($u.Tier) {
        "A" { @("Administrators") }
        "B" { @("Administrators", "Remote Desktop Users") }
        "C" { @("Backup Operators", "Remote Desktop Users") }
    }
    foreach ($group in $groups) {
        try {
            Add-LocalGroupMember -Group $group -Member $u.Sam -ErrorAction Stop
            Write-Success "  Group   : $group"
        } catch {
            if ($_ -match "already a member") {
                Write-Warn "  Already in $group."
            } else {
                Write-Warn "  Could not add to '$group': $_"
            }
        }
    }

    try {
        New-ItemProperty -Path $SpecialAccountsPath -Name $u.Sam -Value 0 -PropertyType DWORD -Force | Out-Null
        Write-Success "  Hidden  : login screen suppressed"
    } catch {
        Write-Warn "  Could not set SpecialAccounts key for '$($u.Sam)': $_"
    }
}

Write-Host ""
Write-Info "Rogue user summary:"
foreach ($u in $RogueUsers) {
    $groupLabel = switch ($u.Tier) { "A" { "Administrators" } "B" { "Administrators + RDP" } "C" { "Backup Operators + RDP" } }
    Write-Host ("  {0,-20} Tier {1}  {2}" -f $u.Sam, $u.Tier, $groupLabel) -ForegroundColor Green
}
Write-Host ""

# -----------------------------------------------------------------------------
# SUMMARY
# -----------------------------------------------------------------------------
Write-Section "SETUP COMPLETE"
Write-Host ""
Write-Host "  Machine    : $HostName  ($HostIP)" -ForegroundColor Cyan
Write-Host ""
Write-Host "  HTTP" -ForegroundColor Yellow
Write-Host "    URL      : http://$HostIP"
Write-Host "    Web root : $WebRoot"
Write-Host "    Site     : $WebSiteName"
Write-Host ""
Write-Host "  FTP" -ForegroundColor Yellow
Write-Host "    URL      : ftp://$HostIP"
Write-Host "    Root     : $FtpRoot"
Write-Host "    Auth     : anonymous (read only)"
Write-Host "    Passive  : $FtpPassiveLow - $FtpPassiveHigh"
Write-Host ""
Write-Host "  DNS" -ForegroundColor Yellow
Write-Host "    Zone     : $DnsZoneName"
Write-Host "    A record : $HostName.$DnsZoneName -> $HostIP"
Write-Host "    Server   : $HostIP port 53"
Write-Host ""
Write-Warn "Point DNS clients at $HostIP to resolve $DnsZoneName queries."
Write-Warn "Verify scoring checks reach the machine on ports 21, 53, and 80."
Write-Host ""
