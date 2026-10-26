# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Phase 3 — SysInternals: No Escape
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# MITRE ATT&CK: T1562.001 (Impair Defenses: Disable/Modify Tools)
#               T1553.006 (Subvert Trust Controls: Code Signing Policy Mod)
#               T1546.003 (WMI Event Subscription)
#
# Targets: Windows Server 2019, Server 2022, Windows 10
#
# Description:
#   Phase 1 SysInternalsNuker already covers: IFEO intercepts, hosts file
#   DNS entries, outbound firewall rule, watchdog scheduled task.
#   This script adds layers that Phase 1 does NOT cover:
#
#   1. APPLOCKER PUBLISHER DENY RULE
#      - Creates a deny rule for the Sysinternals Authenticode publisher
#        cert (CN=Microsoft Corporation, O=Microsoft Corporation)
#      - Blocks all EXEs from that publisher in Executable Rules
#      - Effective even on renamed copies of the binaries
#
#   2. WDAC SUPPLEMENTAL POLICY (Win10 / Server 2022)
#      - Builds a supplemental WDAC policy via ConvertFrom-CIPolicy
#        denying the Sysinternals publisher GUID
#      - Written to C:\Windows\System32\CodeIntegrity\SiPolicy.p7b
#
#   3. WMI KILL-ON-EXEC SUBSCRIPTION
#      - Registers __EventFilter on Win32_ProcessStartTrace
#        WHERE ProcessName LIKE 'proc%' OR ProcessName LIKE 'autoruns%'
#      - CommandLineEventConsumer runs: taskkill /f /pid <PID>
#      - Named to blend: filter=WMIHealthMonitor, consumer=WBEM_SyncHandler
#
#   4. UNC/SMB OUTBOUND BLOCK
#      - Firewall rule blocking outbound TCP 445 to live.sysinternals.com
#        resolved IPs (both IPv4 and IPv6 ranges)
#      - Kills \\live.sysinternals.com\tools UNC path even if hosts fixed
#
#   5. POISON EXISTING COPIES IN-PLACE
#      - Enumerates $env:PATH dirs, C:\Tools\*, C:\Users\*\Downloads\
#      - Overwrites found Sysinternals binaries with zero-byte file
#        (preserving filename — not obviously removed from Explorer)
#
#   6. ZONE.IDENTIFIER ADS MARKER
#      - Writes :Zone.Identifier alternate data stream (ZoneId=4 Restricted)
#        to any found copies
#      - SmartScreen blocks execution even if file is copied elsewhere
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
Write-Warn " CCDC Phase 3 — SysInternals: No Escape"
Write-Warn "================================================================"
Write-Host ""

# TODO: implement
Write-Warn "STUB — not yet implemented. See Phase3_Windows_Plan.md for full design."
