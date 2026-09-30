# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Target Setup  -  IIS (HTTP), FTP, DNS
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# Provisions a Windows Server 2022 standalone (workgroup) machine as a
# scoreable CCDC competition target running:
#   * IIS HTTP   -  Default Web Site on port 80
#   * IIS FTP    -  Anonymous read, port 21, passive 50000-50100
#   * DNS Server  -  Primary forward zone for ccdc.local
#
# Run as Administrator before competition start.
# Safe to re-run  -  idempotent checks throughout.
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

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

# Hostname
$HostName = [System.Net.Dns]::GetHostName()
Write-Info "Hostname : $HostName"

# Primary IPv4  -  follow the default route, fall back to first non-loopback
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
Write-Info "DNS zone   : $DnsZoneName"
Write-Host ""

# Show all IPv4 addresses so operator can sanity-check
Write-Info "All IPv4 addresses on this machine:"
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^127\.' } |
    ForEach-Object { Write-Host "    $($_.IPAddress)  (adapter: $((Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue).Name))" }
Write-Host ""

# Show relevant feature state before we change anything
Write-Info "Current Windows feature state (relevant roles):"
$checkFeatures = @('Web-Server','Web-Ftp-Server','DNS','Web-Mgmt-Tools','Web-ASP','Web-ISAPI-Ext')
foreach ($f in $checkFeatures) {
    $feat = Get-WindowsFeature -Name $f -ErrorAction SilentlyContinue
    if ($feat) {
        $state = if ($feat.Installed) { "[INSTALLED]" } else { "[not installed]" }
        $color = if ($feat.Installed) { "Green" } else { "Yellow" }
        Write-Host "    $($state.PadRight(16)) $f" -ForegroundColor $color
    }
}
Write-Host ""

# Show services that should be running after setup
Write-Info "Relevant services (current state):"
foreach ($svc in @('W3SVC','MSFTPSVC','DNS')) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s) {
        $color = if ($s.Status -eq 'Running') { 'Green' } else { 'Yellow' }
        Write-Host "    $($s.Status.ToString().PadRight(10)) $svc" -ForegroundColor $color
    } else {
        Write-Host "    [absent]   $svc" -ForegroundColor DarkGray
    }
}
Write-Host ""

# Show relevant open firewall ports
Write-Info "Inbound firewall rules for ports 21, 53, 80, $FtpPassiveLow-$FtpPassiveHigh :"
$relevantRules = Get-NetFirewallRule -Direction Inbound -ErrorAction SilentlyContinue |
    Where-Object { $_.Enabled -eq 'True' } |
    ForEach-Object {
        $portFilter = $_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
        [PSCustomObject]@{ Name = $_.DisplayName; Port = $portFilter.LocalPort; Action = $_.Action }
    } |
    Where-Object { $_.Port -match '21|53|80|50000' }

if ($relevantRules) {
    $relevantRules | ForEach-Object { Write-Host "    [$($_.Action)] $($_.Name)  (port $($_.Port))" }
} else {
    Write-Warn "    No matching inbound rules found."
}
Write-Host ""

# -----------------------------------------------------------------------------
# FEATURE INSTALLATION
# -----------------------------------------------------------------------------
Write-Section "INSTALL WINDOWS FEATURES"

$featuresToInstall = @(
    'Web-Server',           # IIS core
    'Web-Common-Http',      # Default doc, directory browsing, static content
    'Web-Default-Doc',
    'Web-Static-Content',
    'Web-Ftp-Server',       # IIS FTP service
    'Web-Ftp-Service',
    'Web-Mgmt-Tools',       # IIS management console + cmdlets
    'Web-Mgmt-Console',
    'Web-Scripting-Tools',
    'DNS'                   # DNS Server role
)

Write-Info "Installing roles and features (this may take a few minutes)..."
try {
    $installResult = Install-WindowsFeature -Name $featuresToInstall -IncludeManagementTools -ErrorAction Stop
    if ($installResult.Success) {
        Write-Success "Features installed."
        if ($installResult.RestartNeeded -eq 'Yes') {
            Write-Warn "A RESTART IS REQUIRED before services will start. Reboot and re-run this script."
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

# Load the WebAdministration module now that IIS is installed
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

# Ensure the DNS service is running
Write-Info "Starting DNS service..."
Set-Service -Name DNS -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service -Name DNS -ErrorAction SilentlyContinue
$dnsSvc = Get-Service -Name DNS -ErrorAction SilentlyContinue
if ($dnsSvc.Status -eq 'Running') {
    Write-Success "DNS service running."
} else {
    Write-Err "DNS service failed to start. Check Event Viewer > System."
    exit 1
}

# Create the primary forward lookup zone (file-backed, no AD DS required)
$existingZone = Get-DnsServerZone -Name $DnsZoneName -ErrorAction SilentlyContinue
if ($existingZone) {
    Write-Warn "Zone '$DnsZoneName' already exists  -  skipping creation."
} else {
    Write-Info "Creating primary zone: $DnsZoneName ..."
    Add-DnsServerPrimaryZone `
        -Name          $DnsZoneName `
        -ZoneFile      "$DnsZoneName.dns" `
        -DynamicUpdate None `
        -ErrorAction   Stop
    Write-Success "Zone created: $DnsZoneName (file-backed, no dynamic update)"
}

# Create/update A record for this server's own hostname
Write-Info "Adding A record: $HostName.$DnsZoneName -> $HostIP ..."
$existingA = Get-DnsServerResourceRecord -ZoneName $DnsZoneName -Name $HostName -RRType A -ErrorAction SilentlyContinue
if ($existingA) {
    Write-Warn "  A record '$HostName' already exists  -  removing and recreating."
    Remove-DnsServerResourceRecord -ZoneName $DnsZoneName -Name $HostName -RRType A -Force -ErrorAction SilentlyContinue
}
Add-DnsServerResourceRecordA -ZoneName $DnsZoneName -Name $HostName -IPv4Address $HostIP -ErrorAction Stop
Write-Success "  A record: $HostName.$DnsZoneName = $HostIP"

# Zone apex A record (@)
$existingApex = Get-DnsServerResourceRecord -ZoneName $DnsZoneName -Name "@" -RRType A -ErrorAction SilentlyContinue
if (-not $existingApex) {
    Add-DnsServerResourceRecordA -ZoneName $DnsZoneName -Name "@" -IPv4Address $HostIP -ErrorAction SilentlyContinue
    Write-Success "  A record: $DnsZoneName (apex) = $HostIP"
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

# Ensure W3SVC is running
Set-Service -Name W3SVC -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service -Name W3SVC -ErrorAction SilentlyContinue
Write-Success "W3SVC started."

# Create web root if missing
if (-not (Test-Path $WebRoot)) {
    New-Item -ItemType Directory -Path $WebRoot -Force | Out-Null
    Write-Success "Web root created: $WebRoot"
}

# Write placeholder index page
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

# Ensure Default Web Site exists and is bound to port 80
$site = Get-Website -Name $WebSiteName -ErrorAction SilentlyContinue
if (-not $site) {
    Write-Info "Creating '$WebSiteName' on port 80..."
    New-Website -Name $WebSiteName -PhysicalPath $WebRoot -Port 80 -IPAddress "*" -Force | Out-Null
    Write-Success "Site created."
} else {
    # Make sure it's pointed at our web root and has a port-80 binding
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

# HTTP firewall rule
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

# Ensure MSFTPSVC (IIS FTP) is running
Set-Service -Name MSFTPSVC -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service -Name MSFTPSVC -ErrorAction SilentlyContinue
$ftpSvc = Get-Service -Name MSFTPSVC -ErrorAction SilentlyContinue
if ($ftpSvc -and $ftpSvc.Status -eq 'Running') {
    Write-Success "MSFTPSVC (IIS FTP) service running."
} else {
    Write-Err "MSFTPSVC (IIS FTP) service failed to start. Check Event Viewer > System."
    exit 1
}

# Create FTP root
if (-not (Test-Path $FtpRoot)) {
    New-Item -ItemType Directory -Path $FtpRoot -Force | Out-Null
    Write-Success "FTP root created: $FtpRoot"
}

# Drop a README so blue team can verify the service is live
$ReadmeContent = @"
CCDC Competition Target  -  FTP Service
======================================
Host    : $HostName
Address : $HostIP
Zone    : $DnsZoneName

This FTP site is a scored competition service.
Anonymous read access is enabled.
"@
$ReadmeContent | Set-Content -Path "$FtpRoot\README.txt" -Encoding UTF8 -Force
Write-Success "README.txt written: $FtpRoot\README.txt"

# Remove existing FTP site if present so we can create cleanly
$existingFtp = Get-WebSite -Name $FtpSiteName -ErrorAction SilentlyContinue
if (-not $existingFtp) {
    # Get-WebSite doesn't filter FTP sites by name cleanly  -  check the IIS: drive directly
    $existingFtp = Get-Item "IIS:\Sites\$FtpSiteName" -ErrorAction SilentlyContinue
}
if ($existingFtp) {
    Write-Warn "FTP site '$FtpSiteName' already exists  -  removing and recreating."
    Remove-Website -Name $FtpSiteName -ErrorAction SilentlyContinue
}

Write-Info "Creating FTP site: $FtpSiteName on port 21..."
New-WebFtpSite -Name $FtpSiteName -Port 21 -PhysicalPath $FtpRoot -Force | Out-Null
Write-Success "FTP site created."

# Disable basic authentication (default is enabled  -  we only want anonymous)
Set-WebConfigurationProperty `
    -Filter   "system.ftpServer/security/authentication/basicAuthentication" `
    -PSPath   "IIS:" `
    -Location $FtpSiteName `
    -Name     "enabled" `
    -Value    $false

# Enable anonymous authentication
Set-WebConfigurationProperty `
    -Filter   "system.ftpServer/security/authentication/anonymousAuthentication" `
    -PSPath   "IIS:" `
    -Location $FtpSiteName `
    -Name     "enabled" `
    -Value    $true

Write-Success "FTP auth: anonymous ON, basic OFF."

# Add authorization rule: allow all users (*) read access
Add-WebConfiguration `
    -Filter  "system.ftpServer/security/authorization" `
    -PSPath  "IIS:" `
    -Location $FtpSiteName `
    -Value   @{ accessType = "Allow"; users = "*"; permissions = "Read" } `
    -ErrorAction SilentlyContinue
Write-Success "FTP authorization: Allow * Read."

# Configure passive port range (firewall-friendly, avoids port conflicts)
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

# Set external IP for passive mode responses so clients get a routable address
Set-WebConfigurationProperty `
    -Filter "system.ftpServer/firewallSupport" `
    -PSPath "IIS:" `
    -Name   "externalIpAddress" `
    -Value  $HostIP
Write-Success "FTP external IP (PASV response): $HostIP"

Set-ItemProperty "IIS:\Sites\$FtpSiteName" -Name serverAutoStart -Value $true
Start-Website -Name $FtpSiteName -ErrorAction SilentlyContinue

# FTP firewall rules
foreach ($rule in @(
    @{ Name="FTP Control TCP 21 (inbound)";          Port=21;                       Proto="TCP" },
    @{ Name="FTP Passive Data TCP $FtpPassiveLow-$FtpPassiveHigh (inbound)"; Port="$FtpPassiveLow-$FtpPassiveHigh"; Proto="TCP" }
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

# Services
foreach ($svc in @('W3SVC','MSFTPSVC','DNS')) {
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

# FTP local check  -  just a TCP connect to port 21
Write-Info "FTP port check..."
try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Connect("127.0.0.1", 21)
    $tcp.Close()
    Write-Success "TCP connect to port 21 succeeded  -  FTP control port is open."
} catch {
    Write-Warn "Could not connect to FTP port 21: $_"
}

# DNS local check
Write-Info "DNS resolution check (querying $DnsZoneName from localhost)..."
try {
    $result = Resolve-DnsName -Name $DnsZoneName -Server 127.0.0.1 -Type A -ErrorAction Stop
    Write-Success "DNS resolved: $DnsZoneName -> $($result.IPAddress)"
} catch {
    Write-Warn "DNS query failed: $_ (may need a moment to load the zone)"
}

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
Write-Host "    Zone     : $DnsZoneName (primary, file-backed)"
Write-Host "    A record : $HostName.$DnsZoneName -> $HostIP"
Write-Host "    Server   : $HostIP port 53"
Write-Host ""
Write-Warn "Point DNS clients at $HostIP to resolve $DnsZoneName queries."
Write-Warn "Verify scoring checks reach the machine on ports 21, 53, and 80."
Write-Host ""
