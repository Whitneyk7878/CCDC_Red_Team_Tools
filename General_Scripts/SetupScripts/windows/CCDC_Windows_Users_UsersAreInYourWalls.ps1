# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC User Injection  -  Local Rogue Accounts
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# Creates local rogue users disguised as service/vendor/helpdesk accounts.
# All accounts are hidden from the Windows login screen via the
# SpecialAccounts\UserList registry key.
#
# Tiers control group placement:
#   A  ->  Administrators
#   B  ->  Administrators + Remote Desktop Users
#   C  ->  Backup Operators + Remote Desktop Users
#
# No AD dependency.  Run as Administrator.  Safe to re-run (idempotent).
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

#Requires -RunAsAdministrator

# -- Colour helpers ------------------------------------------------------------
function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan   }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green  }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red    }
function Write-Section { param($m) Write-Host "`n==[ $m ]==" -ForegroundColor Magenta }

Write-Host ""
Write-Warn  "========================================================"
Write-Warn  " CCDC Blue Team Training  -  Rogue User Injector"
Write-Warn  "========================================================"
Write-Host ""

# -- User definitions ----------------------------------------------------------
# Tier A: Administrators
# Tier B: Administrators + Remote Desktop Users
# Tier C: Backup Operators + Remote Desktop Users
$EvilUsers = @(
    [PSCustomObject]@{ Sam = "svc_iisapppool";  DisplayName = "IIS AppPool Svc";  Password = "IIS@Svc2024!";    Description = "IIS application pool identity";                    Tier = "A" },
    [PSCustomObject]@{ Sam = "svc_backup";      DisplayName = "Backup Service";   Password = "Bkp@Svc2024!";    Description = "Scheduled backup task service account";            Tier = "A" },
    [PSCustomObject]@{ Sam = "SolarWindsAgent"; DisplayName = "SolarWinds";       Password = "SW0rion@2024!";   Description = "SolarWinds Orion agent (do not disable)";          Tier = "A" },
    [PSCustomObject]@{ Sam = "CrowdStrikeCS";   DisplayName = "CrowdStrike";      Password = "Cs@Falc0n2024!";  Description = "CrowdStrike Falcon sensor service account";         Tier = "A" },
    [PSCustomObject]@{ Sam = "KayneWhitney";    DisplayName = "Kayne Whitney";    Password = "F@keUs3r@2024!";  Description = "Exchange migration service account";                Tier = "A" },
    [PSCustomObject]@{ Sam = "svc_monitoring";  DisplayName = "Monitoring Svc";   Password = "M0n!tor2024@";    Description = "Infrastructure health monitor";                    Tier = "B" },
    [PSCustomObject]@{ Sam = "helpdesk_admin";  DisplayName = "Help Desk";        Password = "H3lpD3sk@2024!";  Description = "Tier-2 helpdesk elevated access account";          Tier = "B" },
    [PSCustomObject]@{ Sam = "NessusScanner";   DisplayName = "Nessus Agent";     Password = "N3ssus@Sc4n24!";  Description = "Tenable Nessus vulnerability scanner agent";       Tier = "B" },
    [PSCustomObject]@{ Sam = "SplunkForwarder"; DisplayName = "Splunk Fwd";       Password = "Spl@Fwd2024!";   Description = "Splunk universal forwarder service account";        Tier = "B" },
    [PSCustomObject]@{ Sam = "wsus_svc";        DisplayName = "WSUS Service";     Password = "Wsus@Upd2024!";   Description = "Windows Server Update Services account";           Tier = "C" },
    [PSCustomObject]@{ Sam = "OneDriveSync";    DisplayName = "OneDrive Sync";    Password = "0ne@Drv2024!";    Description = "OneDrive for Business sync agent";                 Tier = "C" },
    [PSCustomObject]@{ Sam = "net_probe";       DisplayName = "Network Probe";    Password = "N3t@Pr0be2024!";  Description = "Network connectivity probe (IT Ops)";              Tier = "C" },
    [PSCustomObject]@{ Sam = "DefaultUser0";    DisplayName = "Default User";     Password = "Def@Usr2024!";    Description = "Default user profile (do not remove)";             Tier = "C" }
)

# -- Registry path for login-screen suppression --------------------------------
$SpecialAccountsPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList"
if (-not (Test-Path $SpecialAccountsPath)) {
    New-Item -Path $SpecialAccountsPath -Force | Out-Null
    Write-Info "Created SpecialAccounts\UserList registry key."
}

# =============================================================================
# USER CREATION
# =============================================================================
Write-Section "LOCAL USER CREATION"

foreach ($u in $EvilUsers) {

    Write-Info "Processing: $($u.Sam) [Tier $($u.Tier)] ..."
    $SecurePass = ConvertTo-SecureString $u.Password -AsPlainText -Force

    # -- Create user -----------------------------------------------------------
    $existingLocal = Get-LocalUser -Name $u.Sam -ErrorAction SilentlyContinue
    if ($existingLocal) {
        Write-Warn "  '$($u.Sam)' already exists -- skipping creation."
    } else {
        try {
            New-LocalUser `
                -Name                 $u.Sam `
                -Password             $SecurePass `
                -FullName             $u.DisplayName `
                -Description          $u.Description `
                -PasswordNeverExpires:$true `
                -ErrorAction          Stop
            Write-Success "  Created  : $($u.Sam)  pass: $($u.Password)"
        } catch {
            Write-Err "  Failed to create '$($u.Sam)': $_"
            continue
        }
    }

    # -- Group membership by tier ----------------------------------------------
    $groups = switch ($u.Tier) {
        "A" { @("Administrators") }
        "B" { @("Administrators", "Remote Desktop Users") }
        "C" { @("Backup Operators", "Remote Desktop Users") }
    }

    foreach ($group in $groups) {
        try {
            Add-LocalGroupMember -Group $group -Member $u.Sam -ErrorAction Stop
            Write-Success "  Group    : $group"
        } catch {
            if ($_ -match "already a member") {
                Write-Warn "  Already in $group."
            } else {
                Write-Err "  Could not add to '$group': $_"
            }
        }
    }

    # -- Hide from login screen ------------------------------------------------
    try {
        New-ItemProperty -Path $SpecialAccountsPath -Name $u.Sam -Value 0 -PropertyType DWORD -Force | Out-Null
        Write-Success "  Hidden   : login screen suppressed (SpecialAccounts)"
    } catch {
        Write-Warn "  Could not set SpecialAccounts key for '$($u.Sam)': $_"
    }

    Write-Host ""
}

# =============================================================================
# SUMMARY
# =============================================================================
Write-Section "DONE"
Write-Host ""
Write-Info "Rogue user summary:"
foreach ($u in $EvilUsers) {
    $groupLabel = switch ($u.Tier) {
        "A" { "Administrators" }
        "B" { "Administrators + RDP" }
        "C" { "Backup Operators + RDP" }
    }
    Write-Host ("  {0,-20} Tier {1}  {2}" -f $u.Sam, $u.Tier, $groupLabel) -ForegroundColor Green
}
Write-Host ""
Write-Info "All accounts hidden from login screen via SpecialAccounts\UserList."
Write-Host ""
