# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Phase 3 — MSSQL: Dead In The Water
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# MITRE ATT&CK: T1489   (Service Stop)
#               T1565.001 (Stored Data Manipulation)
#               T1562.004 (Impair Defenses: Disable/Modify System Firewall)
#               T1222   (File and Directory Permissions Modification)
#
# Targets: Windows Server 2019 (MSSQL only)
#
# Description:
#   No Phase 1 or Phase 2 coverage of MSSQL — entirely new territory.
#   Three independent layers, each of which alone prevents SQL Server
#   from accepting scoring connections. Blue team must find and fix all
#   three before the service scores:
#
#   LAYER 1 — SERVICE ACCOUNT + STARTUP PARAMETER CORRUPTION
#      - Changes the SQL Server service account to a nonexistent local user
#        via the WMI-based SQL Server Configuration Manager API:
#          $wmi = New-Object Microsoft.SqlServer.Management.Smo.Wmi.ManagedComputer
#          $svc = $wmi.Services | Where-Object { $_.Name -eq 'MSSQLSERVER' }
#          $svc.SetServiceAccount('.\NonExistentUser2019', 'BadPass!1')
#      - SQL Server fails to start after any service restart
#      - Additionally adds invalid startup parameter to registry:
#          HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL<ver>\MSSQLServer\Parameters
#          -e C:\NonExistent\Path\sqlserver_error.log
#      - Service crashes at startup even if account is fixed (log path invalid)
#      - Blue team must: fix service account AND remove bad startup param
#
#   LAYER 2 — DATABASE-LEVEL SABOTAGE
#      - While SQL Server is still running, executes T-SQL:
#          ALTER DATABASE master SET RESTRICTED_USER WITH ROLLBACK IMMEDIATE
#          ALTER DATABASE msdb SET OFFLINE WITH ROLLBACK IMMEDIATE
#          ALTER DATABASE model SET READ_ONLY WITH ROLLBACK IMMEDIATE
#      - master in RESTRICTED_USER: only db_owner (SA) can connect
#      - msdb OFFLINE: SQL Agent, backup/restore history unavailable
#      - model READ_ONLY: cannot create any new databases
#      - Also disables TCP/IP protocol via registry:
#          HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL<ver>\MSSQLServer\SuperSocketNetLib\Tcp\Enabled = 0
#      - SQL Server only listens on named pipes after restart (blocked by FW)
#
#   LAYER 3 — NETWORK/DISCOVERY LAYER SABOTAGE
#      - Changes SQL Server TCP listening port from 1433 to 14334 via:
#          HKLM:\...\SuperSocketNetLib\Tcp\IPAll\TcpPort = "14334"
#      - Stops and disables SQL Server Browser service (SQLBROWSER)
#        Without browser: clients cannot auto-discover the non-standard port
#      - Firewall rules blocking TCP 1433 AND TCP 14334 inbound/outbound
#      - Blue team must: find the new port, fix browser service,
#        fix firewall, AND re-enable TCP/IP protocol (L2) — all in registry,
#        all looking unrelated
#
# Key registry base:
#   HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL<ver>\MSSQLServer
#   (version number varies: MSSQL15 = SQL 2019, MSSQL16 = SQL 2022)
#   Use: (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server').InstalledInstances
#
# Implementation notes:
#   - Detect SQL Server instance name/version before applying registry paths
#   - T-SQL commands require SQL auth or Windows auth via Invoke-Sqlcmd or .NET
#   - SMO assembly path: [reflection.assembly]::LoadWithPartialName('Microsoft.SqlServer.Smo')
#   - Script skips if MSSQLSERVER service is not installed
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
Write-Warn " CCDC Phase 3 — MSSQL: Dead In The Water"
Write-Warn "================================================================"
Write-Host ""

# TODO: implement
Write-Warn "STUB — not yet implemented. See Phase3_Windows_Plan.md for full design."
