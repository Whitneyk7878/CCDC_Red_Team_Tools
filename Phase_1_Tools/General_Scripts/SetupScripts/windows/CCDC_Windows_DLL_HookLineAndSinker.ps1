################################################################################
# CCDC_Windows_DLL_HookLineAndSinker.ps1
#
# Blue Team Training Script - DLL Injection & API Hooking
# Windows Equivalent of LD_PRELOAD Library Injection
#
# This script demonstrates DLL hijacking and hooking vulnerabilities:
# 1. AppInit_DLLs global injection (all processes with user32.dll)
# 2. DLL search order hijacking (trojanized dependencies)
# 3. AppCert DLLs for process creation interception
# 4. API hooking to hide processes and ports
# 5. Persists via registry across reboots
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
Write-Host "  CCDC Windows DLL Injection & Hooking Training Module"
Write-Host "  Detected: $osVersion"
Write-Host "========================================================================"
Write-Host ""

if ($Cleanup) {
    Write-Status "Starting cleanup process..." 'Warning'

    # Remove AppInit_DLLs
    Write-Status "Removing AppInit_DLLs registry entries..."
    $appInitPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows"
    $existingDlls = (Get-ItemProperty $appInitPath -ErrorAction SilentlyContinue)."AppInit_DLLs"

    if ($existingDlls -and $existingDlls -like '*ccdc*') {
        $newDlls = ($existingDlls -split ';' | Where-Object { $_ -notlike '*ccdc*' }) -join ';'
        if ($newDlls.Trim()) {
            Set-ItemProperty $appInitPath -Name "AppInit_DLLs" -Value $newDlls
        } else {
            Remove-ItemProperty $appInitPath -Name "AppInit_DLLs" -ErrorAction SilentlyContinue
        }
    }

    Set-ItemProperty $appInitPath -Name "LoadAppInit_DLLs" -Value 0 -ErrorAction SilentlyContinue

    # Remove AppCert DLLs
    Write-Status "Removing AppCert DLLs registry entries..."
    $appCertPath = "HKLM:\System\CurrentControlSet\Control\Session Manager\AppCertDLLs"
    if (Test-Path $appCertPath) {
        Get-ItemProperty $appCertPath -ErrorAction SilentlyContinue |
            Where-Object { $_.PSObject.Properties.Name -like '*ccdc*' } |
            ForEach-Object {
                $_.PSObject.Properties |
                    Where-Object { $_.Name -like '*ccdc*' } |
                    ForEach-Object { Remove-ItemProperty $appCertPath -Name $_.Name -ErrorAction SilentlyContinue }
            }
    }

    # Remove DLL search order hijack files
    Write-Status "Removing trojanized DLL files..."
    $injectionDir = "C:\Windows\Temp\ccdc_dll_injection"
    Remove-Item $injectionDir -Recurse -Force -ErrorAction SilentlyContinue

    # Remove hook information file
    Remove-Item "C:\Windows\Temp\ccdc_hook_log.txt" -Force -ErrorAction SilentlyContinue

    Write-Status "Cleanup complete" 'Success'
    exit 0
}

# ============================================================================
# Step 1: Create DLL Injection Directory and Marker DLLs
# ============================================================================

Write-Status "Step 1: Creating DLL injection infrastructure..."

$injectionDir = "C:\Windows\Temp\ccdc_dll_injection"
try {
    if (-not (Test-Path $injectionDir)) {
        $null = New-Item -ItemType Directory -Path $injectionDir -Force -ErrorAction Stop
        Write-Status "Created injection directory: $injectionDir" 'Success'
    }
}
catch {
    Write-Status "ERROR: Failed to create injection directory: $($_.Exception.Message)" 'Error'
    exit 1
}

# Create marker DLLs (would be real malicious DLLs in actual attack)
$markerDlls = @(
    "ccdc_hook.dll",
    "ccdc_inject.dll",
    "version.dll",        # Common trojan target
    "msvcrt.dll",         # Another common target
    "dxgi.dll"            # Direct X DLL (sometimes targeted)
)

foreach ($dll in $markerDlls) {
    $dllPath = Join-Path $injectionDir $dll
    if (-not (Test-Path $dllPath)) {
        Set-Content -Path $dllPath -Value "CCDC_TRAINING_DLL_MARKER - $dll"
        (Get-Item $dllPath).Attributes = 'Hidden'
    }
}

Write-Status "Created DLL marker files in $injectionDir" 'Success'

# ============================================================================
# Step 2: AppInit_DLLs Registry Injection (Global)
# ============================================================================

Write-Status "Step 2: Registering AppInit_DLLs (global injection point)..."

$appInitPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows"

try {
    # Backup existing settings
    $backupPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ccdc_backup"
    if (-not (Test-Path $backupPath)) {
        New-Item -Path $backupPath -Force | Out-Null

        $appInitValue = (Get-ItemProperty $appInitPath -ErrorAction SilentlyContinue)."AppInit_DLLs"
        $loadAppInitValue = (Get-ItemProperty $appInitPath -ErrorAction SilentlyContinue).LoadAppInit_DLLs

        Set-ItemProperty $backupPath -Name "AppInit_DLLs" -Value $appInitValue -ErrorAction SilentlyContinue
        Set-ItemProperty $backupPath -Name "LoadAppInit_DLLs" -Value $loadAppInitValue -ErrorAction SilentlyContinue
    }

    # Set AppInit_DLLs to load our malicious DLL
    $injectionDll = "$injectionDir\ccdc_hook.dll"
    Set-ItemProperty $appInitPath -Name "AppInit_DLLs" -Value $injectionDll
    Set-ItemProperty $appInitPath -Name "LoadAppInit_DLLs" -Value 1

    Write-Status "AppInit_DLLs registered: $injectionDll" 'Success'
}
catch {
    Write-Status "AppInit_DLLs setup error: $_" 'Warning'
}

# ============================================================================
# Step 3: AppCert DLLs Registration (Process Creation Interception)
# ============================================================================

Write-Status "Step 3: Registering AppCert DLLs (process creation intercept)..."

$appCertPath = "HKLM:\System\CurrentControlSet\Control\Session Manager\AppCertDLLs"

try {
    if (-not (Test-Path $appCertPath)) {
        New-Item -Path $appCertPath -Force | Out-Null
    }

    # Register hook DLL for process creation events
    $appCertDll = "$injectionDir\ccdc_inject.dll"
    Set-ItemProperty $appCertPath -Name "CCDC_ProcessHook" -Value $appCertDll

    Write-Status "AppCert DLL registered for process creation" 'Success'
}
catch {
    Write-Status "AppCert DLLs setup error: $_" 'Warning'
}

# ============================================================================
# Step 4: DLL Search Order Hijacking Setup
# ============================================================================

Write-Status "Step 4: Setting up DLL search order hijacking..."

try {
    # Create a trojanized version.dll in a strategic location
    # Windows will find this first when loading common dependencies

    $trojanDll = "$injectionDir\version.dll"
    $dllContent = @"
; Trojanized version.dll marker
; When a process tries to load version.dll, it gets this first
; This DLL would hook GetFileVersionInfoSize, GetFileVersionInfo, etc.
CCDC_TROJANIZED_DLL
"@

    if (-not (Test-Path $trojanDll)) {
        Set-Content -Path $trojanDll -Value $dllContent
        (Get-Item $trojanDll).Attributes = 'Hidden'
    }

    Write-Status "DLL search order hijacking prepared" 'Success'
}
catch {
    Write-Status "DLL search order setup error: $_" 'Warning'
}

# ============================================================================
# Step 5: API Hooking Configuration
# ============================================================================

Write-Status "Step 5: Configuring API hooks for process/port hiding..."

# Create a configuration file for API hooks that would be implemented in the DLL
$hookConfig = @"
================================================================================
                    CCDC DLL API HOOKING CONFIGURATION
================================================================================

TARGET FUNCTIONS TO HOOK:

Process Hiding Functions:
  - NtQuerySystemInformation (hide processes from Task Manager)
  - GetProcesses (hide from WMI/PowerShell)
  - CreateToolhelp32Snapshot (hide from process enumeration)
  - Process32First/Process32Next (hide from process iteration)

Port/Connection Hiding Functions:
  - GetTcpTable/GetUdpTable (hide network connections from netstat)
  - GetExtendedTcpTable (hide from ss.exe, netstat -b)
  - WSAGetLastError (intercept network queries)
  - connect (intercept outbound connections)
  - WSAConnect (intercept Winsock connections)

File System Hiding Functions:
  - FindFirstFileA/W (hide files from dir/Explorer)
  - FindNextFileA/W (skip hidden files in enumeration)
  - QueryDirectoryFile (hide via NTAPI)

HOOKING MECHANISM:

1. Inline Hooking:
   Replace first bytes of target function with JMP to hook function
   Hook function filters results, then calls original

2. IAT Hooking:
   Modify Import Address Table in running process
   Redirect function pointers to hook function

3. Detours:
   Intercept function at load time or runtime
   Seamless redirection with minimal overhead

IMPLEMENTATION (C++ example):

typedef NTSTATUS (*pNtQuerySystemInformation)(
    SYSTEM_INFORMATION_CLASS SystemInformationClass,
    PVOID SystemInformation,
    ULONG SystemInformationLength,
    PULONG ReturnLength
);

NTSTATUS HookedNtQuerySystemInformation(
    SYSTEM_INFORMATION_CLASS SystemInformationClass,
    PVOID SystemInformation,
    ULONG SystemInformationLength,
    PULONG ReturnLength) {

    // Call original
    NTSTATUS result = OriginalNtQuerySystemInformation(
        SystemInformationClass, SystemInformation,
        SystemInformationLength, ReturnLength);

    // Filter results to hide CCDC processes
    if (SystemInformationClass == SystemProcessInformation) {
        FilterProcessList(SystemInformation);
    }

    return result;
}

HIDDEN ARTIFACTS:

Process: FLAG.exe or any process with "CCDC" in name
Port: 8888 (hidden flag service)
Files: C:\Windows\Temp\ccdc_* (hidden with attrib +h)
Registry: Backed up original values in ccdc_backup keys
"@

Set-Content -Path "$injectionDir\API_HOOK_CONFIG.txt" -Value $hookConfig
Write-Status "API hook configuration created" 'Success'

# ============================================================================
# Step 6: Create Hook Information Log
# ============================================================================

Write-Status "Step 6: Creating hook information log..."

$hookLog = @"
================================================================================
                        CCDC DLL HOOK ACTIVITY LOG
================================================================================
Timestamp: $(Get-Date)
System: $env:COMPUTERNAME
User: $env:USERNAME
Architecture: $([System.Environment]::Is64BitOperatingSystem ? '64-bit' : '32-bit')

HOOKED FUNCTIONS:
================================================================================

Process Hiding:
- NtQuerySystemInformation (NTAPI)
  Hides: Processes with 'CCDC' or 'FLAG' in name
  Method: Filter SystemProcessInformation results

- CreateToolhelp32Snapshot (Win32)
  Hides: Enumerated processes
  Method: Skip entries matching filter

- GetProcesses (WMI/DCOM)
  Hides: WMI process queries
  Method: Intercept WMI calls

Port Hiding:
- GetTcpTable (Winsock)
  Hides: TCP connections on port 8888
  Method: Filter port 8888 from table

- GetUdpTable (Winsock)
  Hides: UDP connections on port 8888
  Method: Filter port 8888 from table

- GetExtendedTcpTable (Winsock2)
  Hides: Extended TCP table on port 8888
  Method: Remove matching entries

File System Hiding:
- FindFirstFileW (Win32)
  Hides: Files with 'ccdc' in name
  Method: Skip in enumeration

- FindNextFileW (Win32)
  Hides: Subsequent files matching filter
  Method: Continue to next until non-hidden

HIDDEN ARTIFACTS:
================================================================================

Processes:
- FLAG.exe (hidden from ps/Task Manager)
- PowerShell.exe running payload (hidden)
- Any process spawned by training script

Ports:
- 127.0.0.1:8888 (hidden flag service)
- Hidden from netstat, ss.exe, Get-NetTCPConnection

Files:
- C:\Windows\Temp\ccdc_dll_injection\* (all hidden)
- C:\Windows\Temp\ccdc_hook_log.txt (hidden)
- All DLL files marked with 'H' attribute

Registry:
- HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows\AppInit_DLLs
- HKLM\System\CurrentControlSet\Control\Session Manager\AppCertDLLs
- HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ccdc_backup

DETECTION CHALLENGES:
================================================================================

1. PROCESS HIDING
   - ps.exe won't show process
   - Get-Process won't show process
   - Task Manager won't show process
   - BUT: Process still visible in /proc/<PID> if accessible
   - BUT: Kernel debuggers can detect hook
   - BUT: File handles still visible in handle.exe

2. PORT HIDING
   - netstat won't show port 8888
   - ss.exe won't show port 8888
   - Get-NetTCPConnection won't show connection
   - BUT: Port binding still active (service responds)
   - BUT: Can detect with network packet capture
   - BUT: Can detect with kernel driver monitoring

3. FILE HIDING
   - dir won't show files
   - Explorer won't show files
   - Get-ChildItem won't show (without -Force)
   - BUT: Files still accessible if path known
   - BUT: Can enumerate with low-level APIs

DETECTION METHODS:
================================================================================

1. Kernel Mode Analysis:
   - WinDbg kernel debugging
   - ETW (Event Tracing for Windows)
   - Minifilter drivers for file system hooks

2. Memory Analysis:
   - Check running process modules
   - Analyze heap for inline hooks
   - Check IAT for redirects

3. Network Analysis:
   - Packet capture to see actual traffic
   - Firewall logs for blocked connections
   - Network flow analysis

4. Registry Forensics:
   - Check AppInit_DLLs value
   - Check AppCert DLLs entries
   - Look for backup keys

5. File System Forensics:
   - Use 'dir /a:h' to show hidden files
   - Use attrib command to inspect
   - Low-level file system scanning

================================================================================
"@

Set-Content -Path "C:\Windows\Temp\ccdc_hook_log.txt" -Value $hookLog
(Get-Item "C:\Windows\Temp\ccdc_hook_log.txt").Attributes = 'Hidden'

Write-Status "Hook log created (hidden)" 'Success'

# ============================================================================
# Step 7: Create Training Documentation
# ============================================================================

Write-Status "Step 7: Creating training documentation..."

$trainingDocs = @"
================================================================================
                  CCDC WINDOWS DLL INJECTION TRAINING MODULE
================================================================================

WHAT THIS SCRIPT DOES:

This training demonstrates how Windows DLL injection and API hooking can be
used to:
1. Hide processes from monitoring tools (ps, Task Manager)
2. Hide network connections (netstat, ss.exe)
3. Hide files from the file system
4. Achieve system-wide persistence via registry

This is the Windows equivalent of Linux LD_PRELOAD attacks.

INJECTION METHODS DEMONSTRATED:

1. APPINIT_DLLS INJECTION (Global)
   Registry: HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows
   Trigger: Every process loading user32.dll
   Scope: System-wide
   Persistence: Survives reboot, user logoff, service restart

   Key: AppInit_DLLs = C:\Windows\Temp\ccdc_dll_injection\ccdc_hook.dll
   Key: LoadAppInit_DLLs = 1

   Effect: DLL loaded into ALL user-mode processes
   Equivalent: Linux /etc/ld.so.preload

2. APPCERT_DLLS INJECTION
   Registry: HKLM\System\CurrentControlSet\Control\Session Manager\AppCertDLLs
   Trigger: CreateProcess, WinExec, ShellExecute API calls
   Scope: Process creation monitoring
   Persistence: Registry-based, survives reboot

   Effect: Intercepts every process creation attempt
   Can: Modify child processes before execution

3. DLL SEARCH ORDER HIJACKING
   Location: Trojanized version.dll in injection directory
   Trigger: Application imports common dependencies
   Scope: Processes that load trojanized DLLs

   DLL Search Order:
   1. Application directory
   2. System directories (System32, SysWOW64)
   3. Windows directory
   4. PATH directories

   Attack: Place malicious DLL in application directory
   Windows loads it first, before legitimate version

API HOOKING TECHNIQUES:

1. INLINE HOOKING
   Overwrites first bytes of function with JMP instruction
   Redirects execution to hook function
   Hook function can:
   - Log parameters
   - Modify return values
   - Block certain operations
   - Hide specific results

2. IAT (IMPORT ADDRESS TABLE) HOOKING
   Modifies PE header Import Address Table
   Redirects function pointers at load time
   More reliable than inline hooks
   Harder to detect

3. DETOURS
   Microsoft library for function interception
   Seamless redirection at runtime
   Minimal overhead
   Works across DLL boundaries

REAL-WORLD EXAMPLES:

Mimikatz: Uses inline hooks to capture credentials
Rootkits: Use DLL injection for kernel-mode access
Bootkits: Use DLL hooks for early boot persistence
Ransomware: Use DLL hooks to prevent detection
Spyware: Use DLL hooks to monitor keystrokes, files
Cryptominers: Use DLL hooks to hide process and CPU usage

PERSISTENCE ADVANTAGES:

- Registry-based: No executable files in obvious locations
- Automatic loading: Survives reboots, service restarts
- Process-wide: Affects all processes, not just one
- Difficult to detect: No new processes, services, or tasks
- Kernel bypass: Can't be stopped by software firewalls
- LSA bypass: Happens before authentication completes

DETECTION METHODS:

1. REGISTRY INSPECTION
   reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows" /v AppInit_DLLs
   reg query "HKLM\System\CurrentControlSet\Control\Session Manager\AppCertDLLs"

   Look for:
   - Suspicious DLL paths
   - DLLs in unusual locations
   - Unsigned DLLs
   - DLLs with "test", "ccdc", "temp", "hook" in name

2. FILE SYSTEM INSPECTION
   dir /a:h C:\Windows\Temp\ccdc_*
   dir /a C:\Windows\Temp\*

   Use 'attrib' to toggle hidden attribute:
   attrib -h C:\Windows\Temp\ccdc_dll_injection\*

   Check file signatures:
   signtool verify /pa C:\Windows\Temp\ccdc_*\*.dll

3. PROCESS MONITORING
   Analyze running process modules:
   Get-Process | Select-Object -ExpandProperty Modules | Where-Object { $_.FileName -like '*ccdc*' }

   Use Process Monitor (Sysinternals) to trace DLL loading
   Watch for DLL loads from unusual locations

4. MEMORY ANALYSIS
   User WinDbg to attach to running processes
   Disassemble functions to detect inline hooks
   Check IAT for suspicious redirects

   Pattern: Instructions at function start (JMP, MOV, etc.)

5. ETW (Event Tracing for Windows)
   logman trace -n test -o test.etl -ets
   Enable process and module tracing
   Filter for suspicious DLL loads

6. BEHAVIORAL DETECTION
   Monitor for:
   - Processes not visible in Task Manager but consuming resources
   - Network connections not visible in netstat
   - Files that can't be seen but are accessible
   - Excessive API calls (sign of hooking)

REMEDIATION:

1. REMOVE REGISTRY ENTRIES
   reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows" /v AppInit_DLLs /f
   reg delete "HKLM\Software\Microsoft\Windows NT\CurrentVersion\Windows" /v LoadAppInit_DLLs /f
   reg delete "HKLM\System\CurrentControlSet\Control\Session Manager\AppCertDLLs" /f

2. REMOVE MALICIOUS DLLs
   attrib -h C:\Windows\Temp\ccdc_dll_injection\*.*
   del /F C:\Windows\Temp\ccdc_dll_injection\*
   rmdir C:\Windows\Temp\ccdc_dll_injection

3. RESTORE BACKUP
   Check ccdc_backup registry keys for original values

4. RESTART SYSTEM
   Reboot to ensure all hooked processes exit
   New processes won't load malicious DLLs

5. VERIFY CLEANUP
   Run detection methods to confirm removal

================================================================================
"@

Set-Content -Path "$injectionDir\TRAINING_README.txt" -Value $trainingDocs
Write-Status "Training documentation created" 'Success'

# ============================================================================
# Step 8: Create Blue Team Challenge
# ============================================================================

Write-Status "Step 8: Creating blue team challenge..."

$challengeGuide = @"
BLUE TEAM CHALLENGE - FIND THE DLL INJECTION ATTACK

OBJECTIVES:

1. Discover the DLL injection mechanism
   - What registry keys were modified?
   - Where are the malicious DLLs located?
   - How do you prevent DLL loading?

2. Find all hidden files
   - Use attrib to unhide hidden files
   - Locate all CCDC-related DLLs
   - Verify file signatures

3. Identify API hooks
   - What functions are likely hooked?
   - How would you detect hooking?
   - What tools can detect hooks?

4. Clean up all traces
   - Remove all registry modifications
   - Delete all malicious DLLs
   - Restore original settings

5. Verify system integrity
   - Ensure no processes are hidden
   - Verify network connections are visible
   - Confirm no persistence remains

PROGRESSIVE HINTS:

Hint 1: Check AppInit_DLLs registry key
        HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows

Hint 2: Look for hidden files in C:\Windows\Temp\
        Command: dir /a:h C:\Windows\Temp\

Hint 3: Check for AppCert DLLs
        HKLM\System\CurrentControlSet\Control\Session Manager\AppCertDLLs

Hint 4: Use PowerShell to find CCDC files
        Get-ChildItem -Path C:\Windows\Temp -Hidden -Filter "*ccdc*"

Hint 5: Restore files from ccdc_backup registry keys

USEFUL COMMANDS:

PowerShell:
  Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows"
  Get-ChildItem -Path C:\Windows\Temp -Hidden
  Get-Process | Where-Object { $_.Modules -like '*ccdc*' }
  (Get-Item -Path C:\file -Force).Attributes = 'Normal'

Command Prompt:
  reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows"
  dir /a:h C:\Windows\Temp\
  attrib -h C:\Windows\Temp\ccdc_*\*

EXPECTED FINDINGS:

Registry Changes:
- AppInit_DLLs set to C:\Windows\Temp\ccdc_dll_injection\ccdc_hook.dll
- LoadAppInit_DLLs set to 1
- AppCert DLLs entries under Session Manager
- Backup key: HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ccdc_backup

Files:
- C:\Windows\Temp\ccdc_dll_injection\ (directory)
- Multiple .dll files (hidden attribute)
- API_HOOK_CONFIG.txt
- TRAINING_README.txt

SUCCESS CRITERIA:

1. All registry modifications removed
2. All CCDC files deleted (unhidden first)
3. Original AppInit values restored
4. System rebooted (to unload hooked DLLs)
5. No CCDC artifacts remain
6. All processes visible in Task Manager
7. All network connections visible in netstat
8. No errors in Event Viewer

SCORING:

Finding registry modifications: 20 points
Unhiding and locating DLL files: 20 points
Understanding API hooking: 20 points
Complete cleanup: 30 points
Verification of cleanup: 10 points

Total: 100 points
"@

Set-Content -Path "$injectionDir\BLUE_TEAM_CHALLENGE.txt" -Value $challengeGuide
Write-Status "Challenge guide created" 'Success'

# ============================================================================
# Step 9: Create DLL Comparison File
# ============================================================================

Write-Status "Step 9: Creating DLL comparison guide..."

$dllComparison = @"
DLL INJECTION COMPARISON: LINUX LD_PRELOAD vs WINDOWS DLL INJECTION

================================================================================
                              MECHANISM COMPARISON
================================================================================

FEATURE                  LINUX LD_PRELOAD              WINDOWS DLL INJECTION
================================================================================

Configuration File       /etc/ld.so.preload            Registry (AppInit_DLLs)

Trigger Point           Dynamic linker (ld.so)        Windows loader / CreateProcess

Scope                   Process-wide (LD.SO loads)    Process-wide (system-wide)

Persistence             File-based + registry         Registry-based

Reboot Survives?        Yes                           Yes

Service Restart Effect  Depends on service type       All services affected

Detectability           File-based (easier)           Registry-based (harder)

Requires Reboot?        No (new processes only)       Yes (for old processes)

================================================================================
                              HOOKING COMPARISON
================================================================================

Linux Method                            Windows Method
================================================================================

dlsym(RTLD_NEXT, "funcname")           Inline patching / IAT hooking
  Get original function pointer          Modify function prologue

function override via .so                API interception via DLL
  Preprocessor level                     Loader/runtime level

environ variable based                  Registry/auto-load based
  Per-process setup                      System-wide setup

Typical targets:                        Typical targets:
  - execve()                              - NtQuerySystemInformation()
  - readdir()                             - CreateProcess()
  - open()                                - GetTcpTable()
  - read/write                            - FindFirstFile()

================================================================================
                              DETECTION COMPARISON
================================================================================

Linux Detection                          Windows Detection
================================================================================

cat /etc/ld.so.preload                  reg query HKLM\...Windows
  Check file directly                     Check registry directly

ldd /usr/bin/command                    signtool verify /pa file.dll
  Check library dependencies              Verify DLL signature

strace -f command                       Process Monitor (Sysinternals)
  Trace system calls                      Monitor process behavior

objdump -d /bin/ps                      WinDbg debugger
  Disassemble for hooks                   Disassemble for hooks

ps aux vs /proc inspection              Task Manager vs netstat mismatch
  Find hidden processes                  Find hidden connections

================================================================================
                              REMEDIATION COMPARISON
================================================================================

Linux Cleanup                            Windows Cleanup
================================================================================

1. Remove /etc/ld.so.preload            1. Remove AppInit_DLLs registry
2. Remove malicious .so files           2. Remove malicious .dll files
3. Kill hidden processes                3. Restart system (full reboot)
4. Verify with ldd/strace               4. Verify with Process Monitor
5. May not need reboot                  5. Reboot required (DLL in memory)

Success: New processes clean             Success: All processes clean after reboot

================================================================================
"@

Set-Content -Path "$injectionDir\DLL_INJECTION_COMPARISON.txt" -Value $dllComparison
Write-Status "DLL comparison guide created" 'Success'

# ============================================================================
# Final Summary
# ============================================================================

Write-Host ""
Write-Host "========================================================================"
Write-Host "         DLL INJECTION TRAINING MODULE SETUP COMPLETE"
Write-Host "========================================================================"
Write-Host ""

Write-Status "Training Location: $injectionDir" 'Info'
Write-Status "Hook Log: C:\Windows\Temp\ccdc_hook_log.txt (hidden)" 'Info'
Write-Status "Training Docs: $injectionDir\TRAINING_README.txt" 'Info'
Write-Status "Challenge Guide: $injectionDir\BLUE_TEAM_CHALLENGE.txt" 'Info'
Write-Status "Comparison Guide: $injectionDir\DLL_INJECTION_COMPARISON.txt" 'Info'

Write-Host ""
Write-Host "Registry Injection Points:" -ForegroundColor Cyan
Write-Host "  1. AppInit_DLLs" -ForegroundColor Gray
Write-Host "  2. LoadAppInit_DLLs" -ForegroundColor Gray
Write-Host "  3. AppCert DLLs (Session Manager)" -ForegroundColor Gray
Write-Host "  4. Backup Keys (ccdc_backup)" -ForegroundColor Gray

Write-Host ""
Write-Host "Hidden Files:" -ForegroundColor Cyan
Write-Host "  1. C:\Windows\Temp\ccdc_dll_injection\*.dll (hidden)" -ForegroundColor Gray
Write-Host "  2. C:\Windows\Temp\ccdc_hook_log.txt (hidden)" -ForegroundColor Gray
Write-Host "  3. Use 'dir /a:h' to reveal" -ForegroundColor Gray

Write-Host ""
Write-Host "BLUE TEAM CHALLENGES:" -ForegroundColor Yellow
Write-Host "  1. Find and remove AppInit_DLLs registry entry" -ForegroundColor Gray
Write-Host "  2. Discover hidden CCDC DLL files" -ForegroundColor Gray
Write-Host "  3. Unhide and delete malicious DLLs" -ForegroundColor Gray
Write-Host "  4. Remove AppCert DLLs entries" -ForegroundColor Gray
Write-Host "  5. Restore backup registry values" -ForegroundColor Gray
Write-Host "  6. Verify all DLLs are unloaded" -ForegroundColor Gray
Write-Host "  7. Confirm no persistence remains" -ForegroundColor Gray

Write-Host ""
Write-Host "To cleanup: .\CCDC_Windows_DLL_HookLineAndSinker.ps1 -Cleanup" -ForegroundColor Yellow
Write-Host ""
