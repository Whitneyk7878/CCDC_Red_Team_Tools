# Windows Attack Setup Playbook — CCDC Red Team

> **Phase:** Pre-game / initial access
> **Run as:** Administrator (all scripts require an elevated shell)
> **Target OS:** Windows Server 2022, domain-joined (AD DS)

These scripts are run **once you have Administrator access** on a Windows target. Their job is to plant backdoor accounts, persistence, a rogue web service, and scheduled tasks that blue team must find and remove while also keeping their scored services up.

---

## Script Execution Order

```
1. CCDC_Windows_Users_UsersAreInYourWalls.ps1          ← accounts first (fallback access)
2. CCDC_Windows_WebShell_SheWebShellOnMyIIS.ps1        ← rogue IIS site (visible target)
3. CCDC_Windows__ScheduledTasks_ScheduledTaskinator.ps1 ← keeps killing scored services
4. CCDC_Windows_Persistence_ClusterBombShells.ps1      ← 5-location payload (hardest to fully remove)
```

---

## 1 — Backdoor Users (`CCDC_Windows_Users_UsersAreInYourWalls.ps1`)

**Works on any Windows machine** — no AD required. AD accounts are a bonus when a DC is reachable.

**What it does:**

**Step 1 (always):** Creates local user accounts and adds them to the **local Administrators** group. This works on any Windows Server or workstation regardless of domain state.

**Step 2 (optional):** If the `ActiveDirectory` module is available and a domain controller is reachable, also creates the same users as domain accounts added to **Domain Admins**, **Administrators**, and **Enterprise Admins**.

| SamAccountName | Password | Disguise level |
|---|---|---|
| `JohnRedTeam` | `S1llyEv1l@2024!` | None — obviously adversarial |
| `AdobeAcrobat` | `R3m0veM3@2024!` | Medium — looks like a service account |
| `KayneWhitney` | `F@keUs3r@2024!` | Medium — looks like a real person |

- Sets `adminCount=1` on all three AD accounts (removes them from normal AD ACL inheritance — harder to restrict via standard tooling)
- Passwords never expire, accounts enabled immediately

> **Fix note:** `#Requires -Modules ActiveDirectory` was intentionally removed. That directive terminates the entire PowerShell session when the module is absent. The script now imports it manually and skips AD work gracefully.

**Run it:**
```powershell
.\CCDC_Windows_Users_UsersAreInYourWalls.ps1
```

**Blue team must remove local accounts:**
```powershell
Remove-LocalGroupMember -Group "Administrators" -Member JohnRedTeam,AdobeAcrobat,KayneWhitney
Remove-LocalUser -Name JohnRedTeam,AdobeAcrobat,KayneWhitney
```

**Blue team must also remove AD accounts (if domain-joined):**
```powershell
Remove-ADGroupMember -Identity "Domain Admins" -Members JohnRedTeam,AdobeAcrobat,KayneWhitney -Confirm:$false
Remove-ADGroupMember -Identity "Administrators" -Members JohnRedTeam,AdobeAcrobat,KayneWhitney -Confirm:$false
Remove-ADUser -Identity JohnRedTeam -Confirm:$false
Remove-ADUser -Identity AdobeAcrobat -Confirm:$false
Remove-ADUser -Identity KayneWhitney -Confirm:$false
```

**Notes:**
- `AdobeAcrobat` is the sneaky one — it looks like a service account. Blue team may skip it while hunting for obvious names.
- `Enterprise Admins` only exists in the forest root domain. The script warns gracefully if it can't add to that group on child domains.
- `adminCount=1` is the extra trap: even after removing them from groups, SDProp may re-apply restrictive ACLs slowly. Blue team needs to verify the accounts are fully gone, not just de-privileged.
- On a non-DC machine, only local accounts are created. Blue team may forget to check **local** users if they're focused on AD.

---

## 2 — Rogue IIS Web Site (`CCDC_Windows_WebShell_SheWebShellOnMyIIS.ps1`)

**What it does:**
- Installs IIS (`Web-Server`) and the Classic ASP feature (`Web-ASP`) if not present
- Creates app pool `DefaultApp_Pool` (AlwaysRunning, ApplicationPoolIdentity)
- Writes `C:\inetpub\Default Web Site\index.asp` — a dark-themed page reading **"evilwebpage"** with server metadata rendered server-side via ASP
- Creates (or recreates) IIS site **"Default Web Site"** on **port 8080**
- Adds an inbound Windows Firewall rule for port 8080
- Verifies the site responds with `Invoke-WebRequest http://localhost:8080`

**Run it:**
```powershell
.\CCDC_Windows_WebShell_SheWebShellOnMyIIS.ps1
```

**Verify:**
```powershell
Invoke-WebRequest http://localhost:8080 -UseBasicParsing
Get-Website -Name "Default Web Site"
```

**Blue team must:**
```powershell
Stop-Website   -Name "Default Web Site"
Remove-Website -Name "Default Web Site"
Remove-WebAppPool -Name "DefaultApp_Pool"
Remove-NetFirewallRule -DisplayName "evilwebpage-training-port-8080"
Remove-Item "C:\inetpub\Default Web Site" -Recurse -Force
```

**Notes:**
- Runs on non-standard port 8080 — blue team needs `netstat -ano` or `Get-NetTCPConnection` to spot it, not just `Get-Website`.
- The site is named "Default Web Site" which collides with the legitimate IIS default — this is intentional. If the scored HTTP service uses that name, this script replaces it.
- The ASP page renders live server metadata (hostname, IP, app pool, timestamp) — confirms the page is executing server-side code, not just static HTML.

---

## 3 — Malicious Scheduled Tasks (`CCDC_Windows__ScheduledTasks_ScheduledTaskinator.ps1`)

**What it does — two tasks:**

| Task name | Schedule | Disguise | Action |
|---|---|---|---|
| `NotepadAlert` | Every 3 min | "Windows Defender credential cache refresh" | Opens Notepad with a taunting message |
| `AcrobatUpdateTask` | Every 3 min | "Acrobat Update Services maintenance cleanup" | `Stop-Service DNS, W3SVC, MSFTPSVC` |

Both tasks repeat indefinitely (`RepetitionDuration = TimeSpan.MaxValue`).

`NotepadAlert` runs as **BUILTIN\Users** so Notepad appears on the logged-in user's desktop. `AcrobatUpdateTask` runs as **SYSTEM** so it has the privileges to stop scored services.

**Run it:**
```powershell
.\CCDC_Windows__ScheduledTasks_ScheduledTaskinator.ps1
```

**Blue team must:**
```powershell
Unregister-ScheduledTask -TaskName "NotepadAlert"      -Confirm:$false
Unregister-ScheduledTask -TaskName "AcrobatUpdateTask" -Confirm:$false
# Then restart any services that were stopped:
Start-Service DNS, W3SVC, MSFTPSVC -ErrorAction SilentlyContinue
```

**Notes:**
- `AcrobatUpdateTask` targets `DNS` (DNS Server), `W3SVC` (IIS HTTP), and `MSFTPSVC` (IIS FTP). All three are scored services from the target setup script — this task will keep taking them down every 3 minutes until blue team finds it.
- `MSFTPSVC` only exists if FTP was installed (it is, via the target setup script).
- Blue team often looks in Task Scheduler's root folder (`\`) — both tasks are in root so they're not hidden. The disguise is entirely in the name and description.
- `NotepadAlert` is the obvious canary — if Notepad keeps popping up, something is running tasks.

---

## 4 — Multi-Location Persistence (`CCDC_Windows_Persistence_ClusterBombShells.ps1`)

**What it does:**
Deploys a payload script (you provide) to **five startup locations**, each using a different execution mechanism:

| # | Location | Trigger | Disguise |
|---|---|---|---|
| 1 | `HKLM:\...\CurrentVersion\Run\WUDFComponentHost` | Every user logon | Mimics `WUDFHost` Windows driver framework service |
| 2 | `HKLM:\...\Winlogon\Userinit` (appended) | Every logon via winlogon | Appended to the existing comma-separated launcher list |
| 3 | Scheduled task `\Microsoft\Windows\DiagnosticsHub\DiagnosticsHub-StandardCollector` | At startup (SYSTEM) | Hidden inside `\Microsoft\Windows\` task subfolder |
| 4 | Windows service `WmiPrvSE-Helper` (AUTO_START) | At boot (SYSTEM) | Name/description mimic `WmiPrvSE.exe` (WMI Provider Host) |
| 5 | `HKLM:\...\Active Setup\Installed Components\{89820200-ECBD-11CF-8B85-00AA005B4383}` (StubPath) | First logon for any user | GUID mimics Internet Explorer Active Setup format |

All payload copies are dropped to `C:\ProgramData\Microsoft\Windows\DiagTrack\Telemetry\cache\` (hidden directory) with inconspicuous filenames.

**Run it:**
```powershell
.\CCDC_Windows_Persistence_ClusterBombShells.ps1 -PayloadPath C:\path\to\payload.ps1
```

**Blue team must find and remove ALL of:**
```
HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run  → value: WUDFComponentHost
HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon → value: Userinit (trim the appended section)
Task: \Microsoft\Windows\DiagnosticsHub\DiagnosticsHub-StandardCollector
Service: WmiPrvSE-Helper
HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{89820200-ECBD-11CF-8B85-00AA005B4383}
C:\ProgramData\Microsoft\Windows\DiagTrack\Telemetry\cache\  (entire directory)
```

```powershell
# Registry Run key
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name "WUDFComponentHost" -Force

# Winlogon Userinit — restore to default
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" `
    -Name "Userinit" -Value "C:\Windows\system32\userinit.exe,"

# Scheduled task
Unregister-ScheduledTask -TaskName "DiagnosticsHub-StandardCollector" `
    -TaskPath "\Microsoft\Windows\DiagnosticsHub\" -Confirm:$false

# Service
Stop-Service WmiPrvSE-Helper -Force -ErrorAction SilentlyContinue
sc.exe delete WmiPrvSE-Helper

# Active Setup key
Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{89820200-ECBD-11CF-8B85-00AA005B4383}" -Recurse -Force

# Payload copies
Remove-Item "C:\ProgramData\Microsoft\Windows\DiagTrack\Telemetry\cache" -Recurse -Force
```

**Notes:**
- The scheduled task is in `\Microsoft\Windows\DiagnosticsHub\` — most defenders run `Get-ScheduledTask` without `-TaskPath` and only see the root folder. They must use `Get-ScheduledTask -TaskPath "\Microsoft\Windows\*"` or the GUI tree view to find it.
- The Active Setup StubPath fires **once per new user account**, not on every boot. If blue team creates a new admin account to lock out red team, the payload fires in that new session.
- The service binary path now uses `powershell.exe -File <dropped script>` directly — no `cmd.exe` wrapper — so the service stays running and the SCM won't restart it into a failure loop.
- If blue team misses even one location, the payload re-executes on the next boot or logon.

---

## Quick Reference — What Blue Team Must Check

```
Registry:
  HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run
  HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce
  HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon  (Userinit value)
  HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\

Task Scheduler:
  Get-ScheduledTask -TaskPath "\" | Select TaskName, TaskPath
  Get-ScheduledTask -TaskPath "\Microsoft\Windows\*" | Select TaskName, TaskPath

Services:
  Get-Service | Where-Object { $_.StartType -eq 'Automatic' } | Sort-Object Name

IIS:
  Get-Website
  Get-WebAppPool
  Get-NetTCPConnection -State Listen | Where-Object LocalPort -in 80,443,8080,8888

AD Users:
  Get-ADUser -Filter * -Properties MemberOf | Where-Object { $_.MemberOf -match "Domain Admins" }

Hidden files:
  Get-ChildItem "C:\ProgramData" -Force -Recurse | Where-Object { $_.Attributes -match "Hidden" }
```
