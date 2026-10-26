# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Phase 3 — COMBINED Orchestrator
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# Runs all applicable Phase 3 scripts based on detected machine role.
#
# Usage:
#   .\CCDC_Windows_P3_COMBINED.ps1
#   .\CCDC_Windows_P3_COMBINED.ps1 -Targets DefenderOnly
#   .\CCDC_Windows_P3_COMBINED.ps1 -Targets ServiceOnly
#   .\CCDC_Windows_P3_COMBINED.ps1 -Targets PersistenceOnly
#   .\CCDC_Windows_P3_COMBINED.ps1 -AttackerIP 10.0.0.5 -AttackerPort 4444
#
# Role detection:
#   - AD/DC:    NTDS service present
#   - MSSQL:    MSSQLSERVER service present
#   - DNS:      DNS service present
#   - All others (workstation, generic server): base scripts only
#
# Scripts run (role-dependent):
#   ALL machines:
#     - CCDC_Windows_P3_Evasion_BlindSpot.ps1       (run FIRST)
#     - CCDC_Windows_P3_Defender_BreakingBad.ps1
#     - CCDC_Windows_P3_SysInternals_NoEscape.ps1
#     - CCDC_Windows_P3_Persist_GhostInTheWMI.ps1   (run LAST)
#   DC only (+above):
#     - CCDC_Windows_P3_DNS_ConditionalSurrender.ps1
#     - CCDC_Windows_P3_AD_KerberosKhaos.ps1
#   MSSQL server only (+base):
#     - CCDC_Windows_P3_MSSQL_DeadInTheWater.ps1
#   DNS role present (non-DC):
#     - CCDC_Windows_P3_DNS_ConditionalSurrender.ps1
#
# Plan reference: Phase_3_Tools/Scripts_Planning/Phase3_Windows_Plan.md
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

#Requires -RunAsAdministrator

param(
    [ValidateSet('All','DefenderOnly','ServiceOnly','PersistenceOnly')]
    [string]$Targets     = 'All',
    [string]$AttackerIP  = "10.0.0.1",
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
Write-Warn " CCDC Phase 3 — COMBINED  //  Targets: $Targets"
Write-Warn "================================================================"
Write-Host ""

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$IsAD    = (Get-Service -Name 'NTDS'         -ErrorAction SilentlyContinue) -ne $null
$IsMSSQL = (Get-Service -Name 'MSSQLSERVER'  -ErrorAction SilentlyContinue) -ne $null
$IsDNS   = (Get-Service -Name 'DNS'          -ErrorAction SilentlyContinue) -ne $null

Write-Info "Detected roles: AD=$IsAD  MSSQL=$IsMSSQL  DNS=$IsDNS"
Write-Host ""

# TODO: implement — dot-source or call each component script based on role detection
# and the -Targets filter. Pattern from Phase 2 P2_COMBINED.ps1.
Write-Warn "STUB — not yet implemented. See Phase3_Windows_Plan.md for full design."
