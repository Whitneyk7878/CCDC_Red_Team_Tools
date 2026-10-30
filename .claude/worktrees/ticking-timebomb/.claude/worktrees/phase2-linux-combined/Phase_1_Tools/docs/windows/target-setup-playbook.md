# Windows Target Setup Playbook — CCDC

> **Script:** `SetupScripts/windows/CCDC_Windows_TargetSetup_HTTP_FTP_DNS.ps1`
> **Phase:** Pre-game — run this **before** the competition starts
> **Run as:** Administrator (`#Requires -RunAsAdministrator`)
> **Target OS:** Windows Server 2022 (standalone / workgroup)

Provisions a Windows machine as a scored competition target with three services blue team will defend:

| Service | Port | Notes |
|---|---|---|
| IIS HTTP | 80 | Static placeholder page |
| IIS FTP | 21 | Anonymous read, passive 50000–50100 |
| DNS Server | 53 UDP+TCP | Primary zone `ccdc.local`, file-backed |

---

## Run It

```powershell
# In an elevated PowerShell prompt on the target machine
.\CCDC_Windows_TargetSetup_HTTP_FTP_DNS.ps1
```

The script is **idempotent** — safe to re-run if something goes wrong mid-setup.

---

## What Happens Step by Step

### 1 — Pre-flight check (read-only, no changes yet)

Before touching anything the script prints:
- Detected hostname and primary IP (derived from the default route)
- All IPv4 addresses on the machine — **verify this grabbed the right IP before continuing**
- Current install state of relevant Windows features (`Web-Server`, `Web-Ftp-Server`, `DNS`, etc.)
- Current state of services W3SVC, FTPSVC, DNS
- Existing inbound firewall rules on ports 21, 53, 80

This is your chance to catch misconfigured adapters or already-installed conflicting services before the script changes anything.

### 2 — Feature installation

Installs via `Install-WindowsFeature`:
```
Web-Server, Web-Common-Http, Web-Default-Doc, Web-Static-Content
Web-Ftp-Server, Web-Ftp-Service
Web-Mgmt-Tools, Web-Mgmt-Console, Web-Scripting-Tools
DNS
```

> **If a restart is required** (rare on Server 2022 but possible), the script exits cleanly with a message. Reboot and re-run.

### 3 — DNS Server

- Starts the DNS service, sets it to `Automatic`
- Creates a file-backed primary forward lookup zone for `ccdc.local`
  - Zone file: `%SystemRoot%\System32\dns\ccdc.local.dns`
  - Dynamic update: **disabled** (static zone, competitors must manage records manually)
- Adds an A record for the server's own hostname: `<hostname>.ccdc.local → <IP>`
- Adds a zone apex A record: `ccdc.local → <IP>`
- Opens TCP/UDP 53 in Windows Firewall

### 4 — IIS HTTP

- Starts W3SVC, sets it to `Automatic`
- Creates `C:\inetpub\wwwroot\index.html` — a minimal page that shows hostname and IP
- Configures **Default Web Site** on port 80 (creates it if absent, adds binding if missing)
- Opens TCP 80 in Windows Firewall

### 5 — IIS FTP

- Starts FTPSVC, sets it to `Automatic`
- Creates `C:\inetpub\ftproot\README.txt` with hostname/IP/zone info
- Creates FTP site `CCDC-FTP` on port 21 pointing at `C:\inetpub\ftproot`
- Authentication: **anonymous ON, basic auth OFF**
- Authorization: Allow `*` Read
- Passive port range: **50000–50100** (set on IIS global firewall support config)
- External IP for PASV responses set to the machine's primary IP
- Opens TCP 21 and TCP 50000–50100 in Windows Firewall

### 6 — Verification

After setup the script runs three checks and prints the results:
- `Invoke-WebRequest http://localhost` → expects HTTP 200
- TCP connect to 127.0.0.1:21 → expects success
- `Resolve-DnsName ccdc.local -Server 127.0.0.1` → expects an A record back

---

## Post-Setup Checklist

After the script finishes, confirm from a **different machine** on the same network:

```powershell
# HTTP
Invoke-WebRequest http://<target-ip>

# FTP (PowerShell doesn't have a built-in FTP client — use ftp.exe or FileZilla)
ftp <target-ip>
# Login: anonymous / any password
# Should see README.txt in the root

# DNS
Resolve-DnsName ccdc.local -Server <target-ip>
nslookup ccdc.local <target-ip>
```

If any of these fail from the remote machine but work from localhost, the problem is almost always Windows Firewall — check that the rules were created:
```powershell
Get-NetFirewallRule -Direction Inbound | Where-Object DisplayName -match "HTTP|FTP|DNS" | Select-Object DisplayName,Enabled,Action
```

---

## Configuration Reference

All tunable values are at the top of the script:

| Variable | Default | What it controls |
|---|---|---|
| `$DnsZoneName` | `ccdc.local` | DNS zone created |
| `$FtpSiteName` | `CCDC-FTP` | IIS FTP site name |
| `$FtpRoot` | `C:\inetpub\ftproot` | FTP root directory |
| `$FtpPassiveLow` | `50000` | Bottom of passive port range |
| `$FtpPassiveHigh` | `50100` | Top of passive port range |
| `$WebRoot` | `C:\inetpub\wwwroot` | IIS web root |
| `$WebSiteName` | `Default Web Site` | IIS HTTP site name |

Hostname and IP are **always read from the machine at runtime** — no hardcoding needed.

---

## Troubleshooting

**DNS service won't start**
Check Event Viewer → Windows Logs → System for DNS errors. On a fresh Server 2022 install the DNS role sometimes needs a reboot after install before the service will start cleanly.

**FTP connects but directory listing hangs**
Passive mode ports 50000–50100 are blocked. Check the firewall rule exists and that no upstream firewall/NAT is blocking the range.

**IIS returns 403 instead of the index page**
Default Document handler may not be configured. Run:
```powershell
Add-WebConfigurationProperty -Filter "system.webServer/defaultDocument/files" `
    -PSPath "IIS:\Sites\Default Web Site" -Name "." -Value @{value="index.html"}
```

**`New-WebFtpSite` not found**
The `Web-Scripting-Tools` feature (part of IIS Management Tools) was not installed. Run `Install-WindowsFeature Web-Scripting-Tools` and reload `WebAdministration`.
