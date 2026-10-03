# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Target Scorer
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# Grades the DEFENDER (blue team) across 5 categories. Higher = better defense.
#   1. Scored Services        (100) - scored services still running
#   2. Persistence Removed    (100) - planted persistence found and cleaned
#   3. Rogue Users Removed    (100) - backdoor local accounts found and deleted
#   4. Rogue Web Removed      (100) - rogue IIS site found and torn down
#   5. Remote Access Hardened (100) - remote-access misconfigs reversed
# Total: /500
#
# Run: .\CCDC_Windows_Scorer.ps1  (requires Administrator)
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

#Requires -RunAsAdministrator

# -- Score accumulators -------------------------------------------------------
$script:S1 = 0
$script:S2 = 0
$script:S3 = 0
$script:S4 = 0
$script:S5 = 0

# -- Output helpers -----------------------------------------------------------
function Write-Section { param([string]$t)
    Write-Host ""
    Write-Host "==[ $t ]==" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Subtotal { param([int]$s, [int]$m)
    Write-Host ""
    Write-Host ("  Subtotal: {0} / {1}" -f $s, $m) -ForegroundColor Yellow
}

function Check {
    param(
        [string]$Cat,
        [string]$Label,
        [bool]  $Pass,
        [int]   $Pts
    )
    if ($Pass) {
        Write-Host ("[PASS +{0,2}] {1}" -f $Pts, $Label) -ForegroundColor Green
        switch ($Cat) {
            'S1' { $script:S1 += $Pts }
            'S2' { $script:S2 += $Pts }
            'S3' { $script:S3 += $Pts }
            'S4' { $script:S4 += $Pts }
            'S5' { $script:S5 += $Pts }
        }
    } else {
        Write-Host ("[FAIL  +{0,2}] {1}" -f 0, $Label) -ForegroundColor Red
    }
}

# -- Banner -------------------------------------------------------------------
Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  CCDC Blue Team Training - Windows Defender Scorer" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""

# -- Module loading -----------------------------------------------------------
$IISAvailable = $false
try {
    Import-Module WebAdministration -ErrorAction Stop
    $IISAvailable = $true
    Write-Host "[+] WebAdministration module loaded." -ForegroundColor Green
} catch {
    Write-Host "[!] WebAdministration not available - IIS checks score 0." -ForegroundColor Yellow
}

# =============================================================================
# CATEGORY 1 - SCORED SERVICES (100 pts)
# Blue team gets points for keeping legitimate services UP.
# =============================================================================
Write-Section "CATEGORY 1 - SCORED SERVICES (100 pts)"

# W3SVC (IIS HTTP) running - 15 pts
$svcW3 = Get-Service -Name 'W3SVC' -ErrorAction SilentlyContinue
Check 'S1' 'W3SVC (IIS HTTP) service running' ($null -ne $svcW3 -and $svcW3.Status -eq 'Running') 15

# HTTP GET http://localhost returns 200 - 15 pts
$httpOk = $false
try {
    $r = Invoke-WebRequest -Uri 'http://localhost' -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    $httpOk = ($r.StatusCode -eq 200)
} catch {}
Check 'S1' 'HTTP GET http://localhost returns 200' $httpOk 15

# Default Web Site started - 10 pts
$defaultSiteUp = $false
if ($IISAvailable) {
    $dSite = Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue
    $defaultSiteUp = ($null -ne $dSite -and $dSite.State -eq 'Started')
}
Check 'S1' 'IIS "Default Web Site" state = Started' $defaultSiteUp 10

# DNS service running - 15 pts
$svcDns = Get-Service -Name 'DNS' -ErrorAction SilentlyContinue
Check 'S1' 'DNS service running' ($null -ne $svcDns -and $svcDns.Status -eq 'Running') 15

# ccdc.local zone exists - 10 pts
$zoneOk = $false
try {
    $z = Get-DnsServerZone -Name 'ccdc.local' -ErrorAction Stop
    $zoneOk = ($null -ne $z)
} catch {}
Check 'S1' 'DNS zone "ccdc.local" exists' $zoneOk 10

# MSFTPSVC (IIS FTP) running - 15 pts
$svcFtp = Get-Service -Name 'MSFTPSVC' -ErrorAction SilentlyContinue
Check 'S1' 'MSFTPSVC (IIS FTP) service running' ($null -ne $svcFtp -and $svcFtp.Status -eq 'Running') 15

# TCP port 21 accepts connections - 10 pts
$port21 = $false
try {
    $port21 = (Test-NetConnection -ComputerName 'localhost' -Port 21 `
        -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
} catch {}
Check 'S1' 'TCP port 21 (FTP control) accepts connections' ([bool]$port21) 10

# CCDC-FTP site started - 10 pts
$ftpSiteUp = $false
if ($IISAvailable) {
    $fSite = Get-Website -Name 'CCDC-FTP' -ErrorAction SilentlyContinue
    $ftpSiteUp = ($null -ne $fSite -and $fSite.State -eq 'Started')
}
Check 'S1' 'IIS "CCDC-FTP" site state = Started' $ftpSiteUp 10

Write-Subtotal $script:S1 100

# =============================================================================
# CATEGORY 2 - PERSISTENCE REMOVED (100 pts)
# Blue team gets points for each planted persistence artifact that is GONE.
# =============================================================================
$DropDir = 'C:\ProgramData\Microsoft\Windows\DiagTrack\Telemetry\cache'

Write-Section "CATEGORY 2 - PERSISTENCE REMOVED (100 pts)"

# HKLM Run key WUDFComponentHost - 12 pts
$runKeyGone = $true
try {
    Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' `
        -Name 'WUDFComponentHost' -ErrorAction Stop | Out-Null
    $runKeyGone = $false
} catch {}
Check 'S2' 'HKLM Run key "WUDFComponentHost" removed' $runKeyGone 12

# Winlogon Userinit no longer tampered - 12 pts
$userinit = $true
try {
    $uv = (Get-ItemProperty `
        -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' `
        -Name 'Userinit' -ErrorAction Stop).Userinit
    if ($uv -match 'userinit-ext') { $userinit = $false }
} catch {}
Check 'S2' 'Winlogon Userinit no longer contains "userinit-ext"' $userinit 12

# Active Setup GUID key gone - 12 pts
$asPath = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{89820200-ECBD-11CF-8B85-00AA005B4383}'
Check 'S2' 'Active Setup GUID {89820200-ECBD-11CF-8B85-00AA005B4383} key removed' (-not (Test-Path $asPath)) 12

# Scheduled task NotepadAlert gone - 8 pts
$task1Gone = $true
try {
    Get-ScheduledTask -TaskName 'NotepadAlert' -TaskPath '\' -ErrorAction Stop | Out-Null
    $task1Gone = $false
} catch {}
Check 'S2' 'Scheduled task "NotepadAlert" removed' $task1Gone 8

# Scheduled task AcrobatUpdateTask gone - 8 pts
$task2Gone = $true
try {
    Get-ScheduledTask -TaskName 'AcrobatUpdateTask' -TaskPath '\' -ErrorAction Stop | Out-Null
    $task2Gone = $false
} catch {}
Check 'S2' 'Scheduled task "AcrobatUpdateTask" removed' $task2Gone 8

# Hidden task DiagnosticsHub-StandardCollector gone - 10 pts
$task3Gone = $true
try {
    Get-ScheduledTask -TaskName 'DiagnosticsHub-StandardCollector' `
        -TaskPath '\Microsoft\Windows\DiagnosticsHub\' -ErrorAction Stop | Out-Null
    $task3Gone = $false
} catch {}
Check 'S2' 'Hidden task "DiagnosticsHub-StandardCollector" removed' $task3Gone 10

# WmiPrvSE-Helper service gone - 10 pts
$fakeSvcGone = $null -eq (Get-Service -Name 'WmiPrvSE-Helper' -ErrorAction SilentlyContinue)
Check 'S2' 'Service "WmiPrvSE-Helper" removed' $fakeSvcGone 10

# Hidden task MusNotifyIconHandler gone - 5 pts
$task4Gone = $true
try {
    Get-ScheduledTask -TaskName 'MusNotifyIconHandler' `
        -TaskPath '\Microsoft\Windows\UpdateOrchestrator\' -ErrorAction Stop | Out-Null
    $task4Gone = $false
} catch {}
Check 'S2' 'Hidden task "MusNotifyIconHandler" (UpdateOrchestrator) removed' $task4Gone 5

# Hidden task OfficeBackgroundTaskHandlerRegistration gone - 5 pts
$task5Gone = $true
try {
    Get-ScheduledTask -TaskName 'OfficeBackgroundTaskHandlerRegistration' `
        -TaskPath '\Microsoft\Windows\OfficeData\' -ErrorAction Stop | Out-Null
    $task5Gone = $false
} catch {}
Check 'S2' 'Hidden task "OfficeBackgroundTaskHandlerRegistration" (OfficeData) removed' $task5Gone 5

# Drop directory gone - 3 pts
Check 'S2' 'Payload drop directory removed' (-not (Test-Path $DropDir)) 3

# Each payload file gone - 3 pts each
foreach ($f in @('wudf-host-svc.ps1', 'userinit-ext.ps1', 'diaghub-collector.ps1',
                  'wmiprvse-helper.ps1', 'iecompat-stub.ps1')) {
    Check 'S2' "Payload file `"$f`" removed" (-not (Test-Path "$DropDir\$f")) 3
}

Write-Subtotal $script:S2 100

# =============================================================================
# CATEGORY 3 - ROGUE USERS REMOVED (100 pts)
# Blue team gets points for each backdoor local account that is GONE.
# These are local accounts (not AD) planted by CCDC_Windows_Users_UsersAreInYourWalls.ps1.
# Scoring: 7 pts per user removed (13 x 7 = 91) + 9 pt all-gone bonus = 100 pts
# =============================================================================
Write-Section "CATEGORY 3 - ROGUE USERS REMOVED (100 pts)"

$RogueUsers = @(
    'svc_iisapppool', 'svc_backup', 'SolarWindsAgent', 'CrowdStrikeCS', 'KayneWhitney',
    'svc_monitoring', 'helpdesk_admin', 'NessusScanner', 'SplunkForwarder',
    'wsus_svc', 'OneDriveSync', 'net_probe', 'DefaultUser0'
)

$allGone = $true
foreach ($u in $RogueUsers) {
    $localUser = Get-LocalUser -Name $u -ErrorAction SilentlyContinue
    $gone = ($null -eq $localUser)
    if (-not $gone) { $allGone = $false }
    Check 'S3' "Local user `"$u`" removed" $gone 7
}

# 9 pt clean-sweep bonus
Check 'S3' 'All 13 rogue local users removed (clean sweep bonus)' $allGone 9

Write-Subtotal $script:S3 100

# =============================================================================
# CATEGORY 4 - ROGUE WEB CONTENT REMOVED (100 pts)
# Blue team gets points for tearing down the rogue IIS site on port 8080.
# =============================================================================
Write-Section "CATEGORY 4 - ROGUE WEB CONTENT REMOVED (100 pts)"

# DefaultApp_Pool gone - 20 pts
$poolGone = $true
if ($IISAvailable) {
    $poolGone = ($null -eq (Get-WebAppPool -Name 'DefaultApp_Pool' -ErrorAction SilentlyContinue))
}
Check 'S4' 'App pool "DefaultApp_Pool" removed' $poolGone 20

# No IIS site bound to port 777 - 20 pts
$no777Site = $true
if ($IISAvailable) {
    $bindings = Get-WebBinding -ErrorAction SilentlyContinue |
        Where-Object { $_.bindingInformation -match ':777:' }
    $no777Site = ($null -eq $bindings -or @($bindings).Count -eq 0)
}
Check 'S4' 'No IIS site bound to port 777' $no777Site 20

# Rogue web root directory gone - 15 pts
Check 'S4' 'Directory "C:\inetpub\evilwebpage" removed' `
    (-not (Test-Path 'C:\inetpub\evilwebpage')) 15

# Rogue index.asp gone - 15 pts
Check 'S4' 'Rogue "index.asp" in "C:\inetpub\evilwebpage\" removed' `
    (-not (Test-Path 'C:\inetpub\evilwebpage\index.asp')) 15

# Firewall rule for port 777 gone - 15 pts
$fw777Gone = $null -eq (Get-NetFirewallRule -DisplayName 'evilwebpage-training-port-777' `
    -ErrorAction SilentlyContinue)
Check 'S4' 'Firewall rule "evilwebpage-training-port-777" removed' $fw777Gone 15

# Port 777 no longer responds - 15 pts
$port777Closed = $true
try {
    $open = (Test-NetConnection -ComputerName 'localhost' -Port 777 `
        -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
    if ($open) { $port777Closed = $false }
} catch {}
Check 'S4' 'TCP port 777 no longer accepts connections' $port777Closed 15

Write-Subtotal $script:S4 100

# =============================================================================
# CATEGORY 5 – REMOTE ACCESS HARDENED (100 pts)
# Blue team gets points for reversing misconfigs planted by
# CCDC_Windows_RemoteAccess_OpenDoorPolicy.ps1
# =============================================================================
Write-Section "CATEGORY 5 - REMOTE ACCESS HARDENED (100 pts)"

# RDP NLA re-enabled (UserAuthentication = 1) - 15 pts
$rdpNla = $false
try {
    $uaVal = (Get-ItemProperty `
        -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
        -Name 'UserAuthentication' -ErrorAction Stop).UserAuthentication
    $rdpNla = ($uaVal -eq 1)
} catch {}
Check 'S5' 'RDP NLA (Network Level Authentication) re-enabled (UserAuthentication = 1)' $rdpNla 15

# RDP blank-password logins blocked (LimitBlankPasswordUse = 1) - 10 pts
$blankPwBlocked = $false
try {
    $bpVal = (Get-ItemProperty `
        -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' `
        -Name 'LimitBlankPasswordUse' -ErrorAction Stop).LimitBlankPasswordUse
    $blankPwBlocked = ($bpVal -eq 1)
} catch {}
Check 'S5' 'RDP blank-password logins blocked (LimitBlankPasswordUse = 1)' $blankPwBlocked 10

# WinRM basic authentication disabled - 15 pts
$winrmBasicOff = $false
try {
    $basicVal = (Get-Item 'WSMan:\localhost\Service\Auth\Basic' -ErrorAction Stop).Value
    $winrmBasicOff = ($basicVal -ieq 'false')
} catch {}
Check 'S5' 'WinRM basic authentication disabled' $winrmBasicOff 15

# SSH PermitRootLogin not "yes" - 20 pts
$sshdConf = "$env:ProgramData\ssh\sshd_config"
$sshNoRoot = $true
if (Test-Path $sshdConf) {
    $sshContent = Get-Content $sshdConf -Raw -ErrorAction SilentlyContinue
    if ($sshContent -match '(?im)^\s*PermitRootLogin\s+yes\s*$') { $sshNoRoot = $false }
}
Check 'S5' 'SSH sshd_config: PermitRootLogin is not "yes"' $sshNoRoot 20

# SSH PermitEmptyPasswords not "yes" - 15 pts
$sshNoEmpty = $true
if (Test-Path $sshdConf) {
    if (-not $sshContent) {
        $sshContent = Get-Content $sshdConf -Raw -ErrorAction SilentlyContinue
    }
    if ($sshContent -match '(?im)^\s*PermitEmptyPasswords\s+yes\s*$') { $sshNoEmpty = $false }
}
Check 'S5' 'SSH sshd_config: PermitEmptyPasswords is not "yes"' $sshNoEmpty 15

# Telnet service (TlntSvr) stopped or not installed - 15 pts
$telnetSafe = $true
$telnetSvc = Get-Service -Name 'TlntSvr' -ErrorAction SilentlyContinue
if ($null -ne $telnetSvc -and $telnetSvc.Status -eq 'Running') { $telnetSafe = $false }
Check 'S5' 'Telnet service (TlntSvr) stopped or not installed' $telnetSafe 15

# SNMP communities not write-enabled (ValidCommunities value < 8) - 10 pts
$snmpClean = $true
$snmpPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\SNMP\Parameters\ValidCommunities'
if (Test-Path $snmpPath) {
    $communities = Get-ItemProperty -Path $snmpPath -ErrorAction SilentlyContinue
    foreach ($prop in $communities.PSObject.Properties) {
        if ($prop.Name -notmatch '^PS') {
            if ([int]$prop.Value -ge 8) { $snmpClean = $false; break }
        }
    }
}
Check 'S5' 'SNMP ValidCommunities: no write-enabled community (value >= 8 means write)' $snmpClean 10

Write-Subtotal $script:S5 100

# =============================================================================
# SUMMARY TABLE
# =============================================================================
$total = $script:S1 + $script:S2 + $script:S3 + $script:S4 + $script:S5

function ScoreColor {
    param([int]$s)
    if ($s -ge 70) { 'Green' } elseif ($s -ge 40) { 'Yellow' } else { 'Red' }
}

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  CCDC WINDOWS DEFENDER SCORE" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ("  Scored Services         : {0,3} / 100" -f $script:S1) `
    -ForegroundColor (ScoreColor $script:S1)
Write-Host ("  Persistence Removed     : {0,3} / 100" -f $script:S2) `
    -ForegroundColor (ScoreColor $script:S2)
Write-Host ("  Rogue Users Removed     : {0,3} / 100" -f $script:S3) `
    -ForegroundColor (ScoreColor $script:S3)
Write-Host ("  Rogue Web Removed       : {0,3} / 100" -f $script:S4) `
    -ForegroundColor (ScoreColor $script:S4)
Write-Host ("  Remote Access Hardened  : {0,3} / 100" -f $script:S5) `
    -ForegroundColor (ScoreColor $script:S5)
Write-Host "--------------------------------------------------------" -ForegroundColor Cyan
Write-Host ("  TOTAL                   : {0,3} / 500" -f $total) -ForegroundColor White
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""
