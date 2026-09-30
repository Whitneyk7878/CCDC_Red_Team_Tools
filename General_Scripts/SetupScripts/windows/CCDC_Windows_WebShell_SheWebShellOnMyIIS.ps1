# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Web Shell
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# Claude 4.6
# "now I want you to create one that will create a new IIS page called "evilwebpage". for windows server 2019."
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

# THIS SCRIPT PUTS A ROGUE IIS WEBSITE IN THE DEVICE


#Requires -RunAsAdministrator

# -- Colour helpers ------------------------------------------------------------
function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan   }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green  }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red    }

Write-Host ""
Write-Warn  "========================================================"
Write-Warn  " CCDC Blue Team Training  -  Rogue IIS Website Injector"
Write-Warn  "========================================================"
Write-Host ""

# -- Configuration -------------------------------------------------------------
$SiteName    = "evilwebpage"
$SitePort    = 777                                       # non-standard port  -  easy to miss
$SitePath    = "C:\inetpub\$SiteName"                   # web root
$AppPoolName = "DefaultApp_Pool"                        # dedicated app pool

# -- Ensure IIS and management module are installed ----------------------------
Write-Info "Checking IIS installation..."

$iisFeature = Get-WindowsFeature -Name Web-Server -ErrorAction SilentlyContinue
if (-not $iisFeature.Installed) {
    Write-Warn "IIS not installed  -  installing Web-Server role (this may take a minute)..."
    try {
        # Web-ASP is required to execute .asp files; without it IIS serves them as plain text.
        Install-WindowsFeature -Name Web-Server, Web-Mgmt-Tools, Web-ASP -IncludeManagementTools -ErrorAction Stop | Out-Null
        Write-Success "IIS installed successfully."
    } catch {
        Write-Err "Failed to install IIS: $_"
        exit 1
    }
} else {
    Write-Success "IIS is already installed."
}

# Ensure Web-ASP is installed regardless of whether IIS was just installed.
# Without it, IIS serves .asp files as plain text instead of executing them.
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

# Ensure the WebAdministration module is available
try {
    Import-Module WebAdministration -ErrorAction Stop
    Write-Success "WebAdministration module loaded."
} catch {
    Write-Err "Could not load WebAdministration module: $_"
    Write-Err "Ensure IIS Management Tools are installed (Web-Mgmt-Tools feature)."
    exit 1
}

# -- Create web root directory -------------------------------------------------
Write-Info "Creating web root: $SitePath ..."
if (-not (Test-Path $SitePath)) {
    New-Item -ItemType Directory -Path $SitePath -Force | Out-Null
    Write-Success "Directory created: $SitePath"
} else {
    Write-Warn "Directory already exists: $SitePath"
}

# -- Write the ASP page -------------------------------------------------------
# Must be .asp (not .html) so IIS executes the <% Response.Write() %> tags.
# Requires the Web-ASP feature  -  installed above.
# Double-quoted here-string so $AppPoolName expands; no $ or ` in the HTML body.
Write-Info "Writing evilwebpage ASP page..."
$HtmlContent = @"
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
    <span class="label">app pool&nbsp;&nbsp;&nbsp;:</span> $AppPoolName<br>
    <span class="label">server sw&nbsp;&nbsp;:</span> <% Response.Write(Request.ServerVariables("SERVER_SOFTWARE")) %><br>
    <span class="label">timestamp&nbsp;&nbsp;:</span> <% Response.Write(Now()) %>
  </div>

</body>
</html>
"@

$HtmlContent | Set-Content -Path "$SitePath\index.asp" -Encoding UTF8 -Force
Write-Success "index.asp written: $SitePath\index.asp"

# -- Create dedicated Application Pool -----------------------------------------
Write-Info "Creating application pool: $AppPoolName ..."
if (Test-Path "IIS:\AppPools\$AppPoolName") {
    Write-Warn "App pool '$AppPoolName' already exists  -  reconfiguring."
    Remove-WebAppPool -Name $AppPoolName -ErrorAction SilentlyContinue
}

New-WebAppPool -Name $AppPoolName | Out-Null
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name "startMode"                      -Value "AlwaysRunning"
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name "autoStart"                      -Value $true
# processModel.identityType 4 = ApplicationPoolIdentity (the safe default virtual account).
# The old code set processModel.userName = "ApplicationPoolIdentity" which is wrong:
# userName holds a custom Windows account name; setting it to a non-existent string
# breaks the pool. identityType is the correct property to set the identity mode.
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name "processModel.identityType"      -Value 4
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name "recycling.periodicRestart.time" -Value "00:00:00"  # disable recycling
Write-Success "App pool created: $AppPoolName (AlwaysRunning, recycling disabled)"

# -- Remove existing site if present ------------------------------------------
if (Get-Website -Name $SiteName -ErrorAction SilentlyContinue) {
    Write-Warn "Site '$SiteName' already exists  -  removing and recreating."
    Remove-Website -Name $SiteName
}

# -- Create the IIS site -------------------------------------------------------
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

# -- Set site to auto-start ----------------------------------------------------
Set-ItemProperty "IIS:\Sites\$SiteName" -Name "serverAutoStart" -Value $true
Write-Success "Site set to auto-start on IIS service restart."

# -- Open firewall port --------------------------------------------------------
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

# -- Start the site ------------------------------------------------------------
Write-Info "Starting site: $SiteName ..."
Start-Website -Name $SiteName
$site = Get-Website -Name $SiteName
if ($site.State -eq "Started") {
    Write-Success "Site is running!"
} else {
    Write-Err "Site did not start. Check: Get-Website '$SiteName' and Event Viewer > Windows Logs > Application"
}

# -- Verify with a local request -----------------------------------------------
Write-Info "Verifying site responds on localhost:$SitePort ..."
Start-Sleep -Seconds 2
try {
    $resp = Invoke-WebRequest -Uri "http://localhost:$SitePort" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    Write-Success "HTTP $($resp.StatusCode) received  -  site is live at http://localhost:$SitePort"
} catch {
    Write-Warn "Could not reach site locally: $_ (site may still be starting)"
}
