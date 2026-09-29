# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Remote Access  -  Open Door Policy
# Claude Sonnet 4.6
# "I want a script for windows that does just about the same thing as the
#  CCDC_Linux_RemoteAccess_OpenDoorPolicy.sh. put it in the same folder.
#  I need about 4 or 5 different remote management things set up on the
#  windows server 2019 and I need it to install and configure anything it
#  needs to. the idea is that we can test the blueteam on finding remote
#  management tools that are misconfigured and or overly permissive."
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
#
# Installs and DELIBERATELY MISCONFIGURES 5 remote management services on
# a base Windows Server 2019 install so blue teams must find and remediate
# each overly permissive configuration.
#
# SERVICES CONFIGURED:
#   1. RDP      TCP 3389  - NLA disabled, blank passwords allowed, Everyone
#   2. WinRM    TCP 5985  - HTTP only, Basic auth, unencrypted, wildcard hosts
#   3. OpenSSH  TCP 22    - Empty passwords, full forwarding, logging silenced
#   4. Telnet   TCP 23    - Cleartext auth, no session timeout, max connections
#   5. SNMP     UDP 161   - public/private read-write, accepts any source host
#
# LESSER-KNOWN TECHNIQUES (documented, not implemented here):
#   - VNC (TightVNC / TigerVNC)       TCP 5900
#   - IIS Web Management Service      TCP 8172
#   - Remote Registry (unrestricted)  TCP 445 / RPC
#   - DCOM / WMI (weak ACLs)          TCP 135
#   - NetBIOS / SMB anonymous access  TCP 445 / 139
#
# Run as Administrator on a base Windows Server 2019 install.
# Safe to re-run -- idempotent checks throughout.
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Colour helpers ----------------------------------------------------------
function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan   }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green  }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red    }
function Write-Section { param($m) Write-Host "`n==[ $m ]==" -ForegroundColor Magenta }

Write-Host ""
Write-Warn "####################################################################"
Write-Warn "#  CCDC Windows Remote Access  -  Open Door Policy                #"
Write-Warn "#  Installing and MISCONFIGURING 5 remote management services.    #"
Write-Warn "#  BLUE TEAM TRAINING EXERCISE  -  Find and remediate each one.   #"
Write-Warn "####################################################################"
Write-Host ""

# -- Configuration -----------------------------------------------------------
$RdpRegPath      = "HKLM:\System\CurrentControlSet\Control\Terminal Server"
$RdpWinStaPath   = "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"
$LsaRegPath      = "HKLM:\System\CurrentControlSet\Control\Lsa"
$SshConfigPath   = "C:\ProgramData\ssh\sshd_config"
$SshConfigBackup = "C:\ProgramData\ssh\sshd_config.ccdc.bak"
$TelnetRegPath   = "HKLM:\SOFTWARE\Microsoft\TelnetServer\1.0"
$SnmpBasePath    = "HKLM:\SYSTEM\CurrentControlSet\Services\SNMP\Parameters"

# ============================================================================
# SECTION 1 OF 5 -- RDP (TCP 3389)
# Findings: NLA disabled, blank-password logins allowed, Everyone can RDP
# ============================================================================
Write-Section "1/5  RDP  (TCP 3389)"

try {
    # Enable Remote Desktop
    Set-ItemProperty -Path $RdpRegPath -Name "fDenyTSConnections" -Value 0 -Type DWord -ErrorAction Stop
    Write-Success "Remote Desktop enabled"

    # Disable Network Level Authentication -- auth happens at the Windows login
    # screen instead of before the session is created; any user can attempt login
    Set-ItemProperty -Path $RdpWinStaPath -Name "UserAuthentication" -Value 0 -Type DWord -ErrorAction Stop
    Set-ItemProperty -Path $RdpWinStaPath -Name "SecurityLayer"      -Value 0 -Type DWord -ErrorAction Stop
    Write-Warn "  NLA disabled (SecurityLayer=0, UserAuthentication=0)"

    # Allow accounts with blank passwords to authenticate over the network
    Set-ItemProperty -Path $LsaRegPath -Name "LimitBlankPasswordUse" -Value 0 -Type DWord -ErrorAction Stop
    Write-Warn "  Blank-password remote logins allowed (LimitBlankPasswordUse=0)"

    # Remove the concurrent-session cap
    Set-ItemProperty -Path $RdpRegPath -Name "MaxInstanceCount" -Value 0xFFFF -Type DWord -ErrorAction Stop
    Write-Warn "  Concurrent session limit removed (MaxInstanceCount=0xFFFF)"

    # Add Authenticated Users to Remote Desktop Users so every local/domain
    # account can connect without any explicit permission grant
    try {
        $sid     = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-11")
        $account = $sid.Translate([System.Security.Principal.NTAccount])
        Add-LocalGroupMember -Group "Remote Desktop Users" -Member $account -ErrorAction Stop
        Write-Warn "  Authenticated Users added to Remote Desktop Users group"
    } catch {
        Write-Warn "  Authenticated Users may already be in Remote Desktop Users: $_"
    }

    # Enable and add the built-in Guest account as an obvious weak-credential find
    net user Guest /active:yes 2>&1 | Out-Null
    try {
        Add-LocalGroupMember -Group "Remote Desktop Users" -Member "Guest" -ErrorAction Stop
        Write-Warn "  Guest account enabled and added to Remote Desktop Users"
    } catch {
        Write-Warn "  Guest may already be in Remote Desktop Users: $_"
    }

    Set-Service -Name "TermService" -StartupType Automatic -ErrorAction Stop
    Start-Service -Name "TermService" -ErrorAction Stop
    Write-Success "TermService started (Automatic)"

    $existing = Get-NetFirewallRule -DisplayName "CCDC-RDP-Any" -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-NetFirewallRule -DisplayName "CCDC-RDP-Any" `
            -Direction Inbound -Protocol TCP -LocalPort 3389 `
            -Action Allow -RemoteAddress Any | Out-Null
        Write-Success "Firewall rule created: TCP 3389 any-source"
    } else {
        Write-Warn "  Firewall rule CCDC-RDP-Any already exists"
    }

} catch {
    Write-Err "RDP setup failed: $_"
    exit 1
}

# ============================================================================
# SECTION 2 OF 5 -- WinRM / PowerShell Remoting (TCP 5985)
# Findings: HTTP (no TLS), Basic auth, unencrypted, CredSSP, wildcard hosts
# ============================================================================
Write-Section "2/5  WinRM / PowerShell Remoting  (TCP 5985)"

try {
    Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop
    Write-Success "PSRemoting enabled"

    # Trust every remote host -- no hostname verification whatsoever
    Set-Item WSMan:\localhost\Client\TrustedHosts -Value '*' -Force -ErrorAction Stop
    Write-Warn "  TrustedHosts = * (any host trusted)"

    # Basic auth sends credentials Base64-encoded -- trivially reversed
    Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true -ErrorAction Stop
    Write-Warn "  Basic authentication enabled (creds sent as Base64)"

    # Drop to plain HTTP -- credentials and commands travel in cleartext
    Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true -ErrorAction Stop
    Write-Warn "  Unencrypted HTTP allowed (TCP 5985, no TLS)"

    # CredSSP allows the remote end to re-use delegated credentials
    Enable-WSManCredSSP -Role Server -Force -ErrorAction Stop
    Write-Warn "  CredSSP enabled (credential delegation active)"

    # Raise memory ceiling so large payloads are less likely to be throttled
    Set-Item WSMan:\localhost\Shell\MaxMemoryPerShellMB -Value 2048 -ErrorAction Stop
    Write-Info "  Shell memory limit raised to 2048 MB"

    $existing = Get-NetFirewallRule -DisplayName "CCDC-WinRM-Any" -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-NetFirewallRule -DisplayName "CCDC-WinRM-Any" `
            -Direction Inbound -Protocol TCP -LocalPort 5985 `
            -Action Allow -RemoteAddress Any | Out-Null
        Write-Success "Firewall rule created: TCP 5985 any-source"
    } else {
        Write-Warn "  Firewall rule CCDC-WinRM-Any already exists"
    }

} catch {
    Write-Err "WinRM setup failed: $_"
    exit 1
}

# ============================================================================
# SECTION 3 OF 5 -- OpenSSH Server (TCP 22)
# Findings: empty passwords, MaxAuthTries 100, full forwarding, QUIET logging
# ============================================================================
Write-Section "3/5  OpenSSH Server  (TCP 22)"

try {
    $cap = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction Stop
    if ($cap.State -ne "Installed") {
        Write-Info "Installing OpenSSH Server capability..."
        Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction Stop | Out-Null
        Write-Success "OpenSSH Server installed"
    } else {
        Write-Warn "  OpenSSH Server already installed"
    }
} catch {
    Write-Err "OpenSSH installation failed: $_"
    exit 1
}

try {
    if ((Test-Path $SshConfigPath) -and (-not (Test-Path $SshConfigBackup))) {
        Copy-Item $SshConfigPath $SshConfigBackup -ErrorAction Stop
        Write-Info "  Original sshd_config backed up to $SshConfigBackup"
    }

    # Write deliberately insecure sshd_config -- mirrors Linux OpenDoorPolicy
    $sshdConfig = @"
# CCDC Training - Deliberately Misconfigured sshd_config
# Blue team: compare against /etc/ssh/sshd_config defaults to spot issues

Port 22
ListenAddress 0.0.0.0

PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords yes
UsePAM no

MaxAuthTries 100
LoginGraceTime 120
MaxSessions 50

AllowTcpForwarding yes
GatewayPorts yes
PermitTunnel yes
X11Forwarding yes

LogLevel QUIET

Subsystem sftp C:/Windows/System32/OpenSSH/sftp-server.exe
"@
    $sshdConfig | Set-Content -Path $SshConfigPath -Encoding UTF8 -ErrorAction Stop
    Write-Warn "  PermitEmptyPasswords yes"
    Write-Warn "  PermitRootLogin yes"
    Write-Warn "  MaxAuthTries 100"
    Write-Warn "  LogLevel QUIET"
    Write-Warn "  AllowTcpForwarding / GatewayPorts / PermitTunnel yes"

    # Set PowerShell as the default SSH shell
    $psExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
    if ($psExe) {
        $sshRegPath = "HKLM:\SOFTWARE\OpenSSH"
        if (-not (Test-Path $sshRegPath)) { New-Item -Path $sshRegPath -Force | Out-Null }
        Set-ItemProperty -Path $sshRegPath -Name "DefaultShell" -Value $psExe -ErrorAction Stop
        Write-Info "  Default SSH shell set to PowerShell"
    }

    Set-Service -Name "sshd" -StartupType Automatic -ErrorAction Stop
    Restart-Service -Name "sshd" -ErrorAction Stop
    Write-Success "sshd started (Automatic)"

    $existing = Get-NetFirewallRule -DisplayName "CCDC-SSH-Any" -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-NetFirewallRule -DisplayName "CCDC-SSH-Any" `
            -Direction Inbound -Protocol TCP -LocalPort 22 `
            -Action Allow -RemoteAddress Any | Out-Null
        Write-Success "Firewall rule created: TCP 22 any-source"
    } else {
        Write-Warn "  Firewall rule CCDC-SSH-Any already exists"
    }

} catch {
    Write-Err "OpenSSH configuration failed: $_"
    exit 1
}

# ============================================================================
# SECTION 4 OF 5 -- Telnet Server (TCP 23)
# Findings: cleartext protocol running, no session timeout, max connections
# ============================================================================
Write-Section "4/5  Telnet Server  (TCP 23)"

try {
    $feature = Get-WindowsFeature -Name Telnet-Server -ErrorAction Stop
    if ($feature.InstallState -ne "Installed") {
        Write-Info "Installing Telnet Server feature..."
        Install-WindowsFeature -Name Telnet-Server -ErrorAction Stop | Out-Null
        Write-Success "Telnet Server installed"
    } else {
        Write-Warn "  Telnet Server already installed"
    }
} catch {
    Write-Err "Telnet Server installation failed: $_"
    exit 1
}

try {
    if (-not (Test-Path $TelnetRegPath)) {
        New-Item -Path $TelnetRegPath -Force | Out-Null
    }

    # AuthenticationMode 3 = NTLM + cleartext password (both accepted)
    Set-ItemProperty -Path $TelnetRegPath -Name "AuthenticationMode" -Value 3 -Type DWord -ErrorAction Stop
    Write-Warn "  AuthenticationMode = 3 (NTLM and cleartext password both accepted)"

    # No session timeout -- idle sessions linger forever
    Set-ItemProperty -Path $TelnetRegPath -Name "SessionTimeout" -Value 0 -Type DWord -ErrorAction Stop
    Write-Warn "  SessionTimeout = 0 (sessions never expire)"

    # Raise connection cap well above default of 2
    Set-ItemProperty -Path $TelnetRegPath -Name "MaxConnections" -Value 999 -Type DWord -ErrorAction Stop
    Write-Warn "  MaxConnections = 999"

    Set-ItemProperty -Path $TelnetRegPath -Name "AllowTrustedDomain" -Value 1 -Type DWord -ErrorAction Stop

    Set-Service -Name "TlntSvr" -StartupType Automatic -ErrorAction Stop
    Start-Service -Name "TlntSvr" -ErrorAction Stop
    Write-Success "TlntSvr started (Automatic)"

    $existing = Get-NetFirewallRule -DisplayName "CCDC-Telnet-Any" -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-NetFirewallRule -DisplayName "CCDC-Telnet-Any" `
            -Direction Inbound -Protocol TCP -LocalPort 23 `
            -Action Allow -RemoteAddress Any | Out-Null
        Write-Success "Firewall rule created: TCP 23 any-source"
    } else {
        Write-Warn "  Firewall rule CCDC-Telnet-Any already exists"
    }

} catch {
    Write-Err "Telnet configuration failed: $_"
    exit 1
}

# ============================================================================
# SECTION 5 OF 5 -- SNMP Service (UDP 161)
# Findings: public/private communities with READ-WRITE, no host restriction
# ============================================================================
Write-Section "5/5  SNMP Service  (UDP 161)"

try {
    $feature = Get-WindowsFeature -Name SNMP-Service -ErrorAction Stop
    if ($feature.InstallState -ne "Installed") {
        Write-Info "Installing SNMP Service feature..."
        Install-WindowsFeature -Name SNMP-Service -IncludeManagementTools -ErrorAction Stop | Out-Null
        Write-Success "SNMP Service installed"
    } else {
        Write-Warn "  SNMP Service already installed"
    }
} catch {
    Write-Err "SNMP installation failed: $_"
    exit 1
}

try {
    # ValidCommunities: name -> DWORD permission level
    #   1=NONE  2=NOTIFY  4=READ ONLY  8=READ WRITE  16=READ CREATE
    $validCommPath = "$SnmpBasePath\ValidCommunities"
    if (-not (Test-Path $validCommPath)) {
        New-Item -Path $validCommPath -Force | Out-Null
    }
    Set-ItemProperty -Path $validCommPath -Name "public"  -Value 8 -Type DWord -ErrorAction Stop
    Set-ItemProperty -Path $validCommPath -Name "private" -Value 8 -Type DWord -ErrorAction Stop
    Write-Warn "  Community 'public'  = READ WRITE (8)"
    Write-Warn "  Community 'private' = READ WRITE (8)"

    # Removing PermittedManagers allows queries from any source IP
    $permMgrPath = "$SnmpBasePath\PermittedManagers"
    if (Test-Path $permMgrPath) {
        Remove-Item -Path $permMgrPath -Recurse -Force -ErrorAction Stop
        Write-Warn "  PermittedManagers key removed (all source IPs permitted)"
    } else {
        Write-Warn "  PermittedManagers key absent (all source IPs already permitted)"
    }

    # Suppress auth-failure traps -- brute-force community enumeration goes unnoticed
    Set-ItemProperty -Path $SnmpBasePath -Name "EnableAuthenticationTraps" -Value 0 -Type DWord -ErrorAction Stop
    Write-Warn "  EnableAuthenticationTraps = 0 (failed-auth traps suppressed)"

    Set-Service -Name "SNMP" -StartupType Automatic -ErrorAction Stop
    Restart-Service -Name "SNMP" -ErrorAction Stop
    Write-Success "SNMP started (Automatic)"

    $existing = Get-NetFirewallRule -DisplayName "CCDC-SNMP-Any" -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-NetFirewallRule -DisplayName "CCDC-SNMP-Any" `
            -Direction Inbound -Protocol UDP -LocalPort 161 `
            -Action Allow -RemoteAddress Any | Out-Null
        Write-Success "Firewall rule created: UDP 161 any-source"
    } else {
        Write-Warn "  Firewall rule CCDC-SNMP-Any already exists"
    }

} catch {
    Write-Err "SNMP configuration failed: $_"
    exit 1
}

# ============================================================================
# SUMMARY
# ============================================================================
Write-Section "SETUP COMPLETE"

Write-Host "  SERVICE    PORT    PROTO   MISCONFIGURATIONS" -ForegroundColor Yellow
Write-Host "  -------    ----    -----   -----------------" -ForegroundColor Yellow
Write-Host "  RDP        3389    TCP     NLA disabled; blank passwords; Authenticated Users + Guest in RDP group"
Write-Host "  WinRM      5985    TCP     HTTP only; Basic auth; AllowUnencrypted; CredSSP; TrustedHosts=*"
Write-Host "  OpenSSH    22      TCP     PermitEmptyPasswords; MaxAuthTries 100; LogLevel QUIET; full forwarding"
Write-Host "  Telnet     23      TCP     Cleartext protocol; no session timeout; MaxConnections=999"
Write-Host "  SNMP       161     UDP     'public'/'private' READ-WRITE; no PermittedManagers restriction"
Write-Host ""

Write-Host "  FIREWALL RULES ADDED (remove to lock down):" -ForegroundColor Yellow
Write-Host "  CCDC-RDP-Any  CCDC-WinRM-Any  CCDC-SSH-Any  CCDC-Telnet-Any  CCDC-SNMP-Any"
Write-Host ""

Write-Host "  BLUE TEAM REMEDIATION HINTS:" -ForegroundColor Yellow
Write-Host "  RDP     : Re-enable NLA: Set UserAuthentication=1, SecurityLayer=1 in RDP-Tcp reg key"
Write-Host "            Remove Authenticated Users / Guest from Remote Desktop Users group"
Write-Host "            Set LimitBlankPasswordUse=1 under HKLM\...\Lsa"
Write-Host "  WinRM   : Disable-PSRemoting -Force"
Write-Host "            Set WSMan:\localhost\Service\AllowUnencrypted to false"
Write-Host "            Set WSMan:\localhost\Service\Auth\Basic to false"
Write-Host "            Disable-WSManCredSSP -Role Server"
Write-Host "  SSH     : Restore from backup: Copy-Item $SshConfigBackup $SshConfigPath"
Write-Host "            Restart-Service sshd"
Write-Host "  Telnet  : Stop-Service TlntSvr; Set-Service TlntSvr -StartupType Disabled"
Write-Host "            Remove-WindowsFeature Telnet-Server"
Write-Host "  SNMP    : Change communities from READ-WRITE to READ-ONLY (or remove)"
Write-Host "            Recreate PermittedManagers key with specific allowed IPs"
Write-Host "            Stop-Service SNMP; Set-Service SNMP -StartupType Disabled"
Write-Host ""

Write-Success "Open Door Policy deployed. Good luck, blue team."
Write-Host ""
