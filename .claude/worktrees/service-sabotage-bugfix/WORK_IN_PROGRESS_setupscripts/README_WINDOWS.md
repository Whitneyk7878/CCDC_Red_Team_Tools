# CCDC Windows Training Scripts - Blue Team Adversary Simulation

This directory contains Windows-based training scripts for blue teams to learn about kernel and subsystem-level authentication and library injection attacks.

## Compatibility

Scripts are tested and compatible with:
- ✅ Windows 7 SP1 / Server 2008 R2
- ✅ Windows 8 / 8.1 / Server 2012 / 2012 R2
- ✅ Windows 10 (all versions)
- ✅ Windows 11
- ✅ Windows Server 2016, 2019, 2022

**Requirements:**
- Administrator / SYSTEM privileges (required for registry and LSA modifications)
- PowerShell 3.0+ (standard on Windows 7 SP1+)
- Not compatible with Azure virtual machines or restricted environments

---

## Scripts

### CCDC_Windows_LSA_LootTheVault.ps1

**Purpose:** Demonstrate LSA (Local Security Authority) SSP injection for credential harvesting

**Equivalent to:** Linux PAM module attacks (pam_capture.so, pam_permit.so)

#### What It Does

1. **Security Support Provider (SSP) Injection**
   - Registers malicious SSP in LSA registry
   - Loads into lsass.exe (authentication process)
   - Receives all authentication credentials
   - Location: `HKLM\System\CurrentControlSet\Control\Lsa\SecurityPackages`

2. **Credential Provider Hijacking**
   - Intercepts Windows logon screen
   - Captures credentials before LSA processes them
   - Stores in hidden log file
   - Location: `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers`

3. **LSA Notification Package**
   - Receives authentication events
   - Monitors login/logout activity
   - Tracks credential state changes
   - Location: `HKLM\System\CurrentControlSet\Control\Lsa\Notification Packages`

4. **AppInit_DLLs Injection (Bonus)**
   - System-wide DLL loading (equivalent to `/etc/ld.so.preload`)
   - Loads into ALL processes with user32.dll
   - Location: `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows`

#### How It's Detected

**Detection Methods:**
```powershell
# Check registry for SSP entries
reg query "HKLM\System\CurrentControlSet\Control\Lsa\SecurityPackages"
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers"

# Find credential logs
attrib -h C:\Windows\Temp\ccdc_credentials.log
type C:\Windows\Temp\ccdc_credentials.log

# Check LSA modules
Get-Process lsass | Select-Object -ExpandProperty Modules

# Event Log analysis
Get-EventLog -LogName Security -Source LSA
```

#### Cleanup

```powershell
.\CCDC_Windows_LSA_LootTheVault.ps1 -Cleanup
```

---

### CCDC_Windows_DLL_HookLineAndSinker.ps1

**Purpose:** Demonstrate DLL injection and API hooking for process/port hiding

**Equivalent to:** Linux LD_PRELOAD library injection attacks

#### What It Does

1. **AppInit_DLLs Global Injection**
   - Loads DLL into ALL user-mode processes
   - Triggered when process loads user32.dll
   - System-wide persistence via registry
   - Direct equivalent to Linux `/etc/ld.so.preload`
   - Location: `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows`

2. **AppCert DLLs (Process Creation Interception)**
   - Intercepts CreateProcess API calls
   - Loads before target process starts
   - Can monitor/modify child processes
   - Location: `HKLM\System\CurrentControlSet\Control\Session Manager\AppCertDLLs`

3. **DLL Search Order Hijacking**
   - Trojanizes common DLL dependencies (version.dll, msvcrt.dll, dxgi.dll)
   - Windows loads trojanized version first
   - Runs malicious code before legitimate DLL

4. **API Hooking Infrastructure**
   - Prepares hooks for process hiding (NtQuerySystemInformation)
   - Prepares hooks for port hiding (GetTcpTable, GetExtendedTcpTable)
   - Prepares hooks for file hiding (FindFirstFile, FindNextFile)

#### How It's Detected

**Detection Methods:**
```powershell
# Check AppInit_DLLs registry
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows" /v AppInit_DLLs

# Find hidden DLL files
dir /a:h C:\Windows\Temp\ccdc_dll_injection\

# Check AppCert DLLs
reg query "HKLM\System\CurrentControlSet\Control\Session Manager\AppCertDLLs"

# Verify DLL signatures
signtool verify /pa C:\Windows\Temp\ccdc_dll_injection\*.dll

# Monitor DLL loads
Get-Process | ForEach-Object {
    $_.Modules | Where-Object { $_.FileName -like '*ccdc*' }
}
```

#### Cleanup

```powershell
.\CCDC_Windows_DLL_HookLineAndSinker.ps1 -Cleanup
```

---

## Architecture: Linux vs Windows Comparison

### Authentication Subsystem

| Linux | Windows |
|-------|---------|
| **PAM** (Pluggable Authentication Modules) | **LSA** (Local Security Authority) |
| `/etc/pam.d/` configuration files | Registry-based configuration |
| Loadable `.so` modules in `/lib/security/` | `.dll` modules in process memory |
| Hijacked via module registration | Hijacked via SSP/AP registration |

### Library Injection

| Linux | Windows |
|-------|---------|
| **LD_PRELOAD** / `/etc/ld.so.preload` | **AppInit_DLLs** / **AppCert DLLs** |
| Environment variable or system file | Registry-based configuration |
| Affects process at dynamic link time | Affects process at load time |
| Single shared object per entry | Single DLL per entry |
| Can be per-process or system-wide | Usually system-wide |

### Hooking Method

| Linux | Windows |
|-------|---------|
| Function symbol override via dlsym() | Inline hooking / IAT modification |
| C preprocessor level hijacking | Loader/runtime level hijacking |
| dlopen() for dynamic loading | SetWindowsHookEx() for system hooks |
| strace to detect hooks | WinDbg to detect hooks |

---

## Training Workflow

### Phase 1: Setup (Red Team)
```powershell
# Setup LSA training
.\CCDC_Windows_LSA_LootTheVault.ps1

# Setup DLL injection training
.\CCDC_Windows_DLL_HookLineAndSinker.ps1
```

### Phase 2: Investigation (Blue Team)

**LSA Training Tasks:**
- [ ] Find SSP registry modifications
- [ ] Locate credential provider entries
- [ ] Discover credential harvesting log
- [ ] Identify all registry changes
- [ ] Understand LSA architecture

**DLL Injection Training Tasks:**
- [ ] Find AppInit_DLLs registry entry
- [ ] Discover hidden DLL files
- [ ] Locate AppCert DLL entries
- [ ] Unhide hidden files
- [ ] Check DLL signatures

### Phase 3: Remediation (Blue Team)
- [ ] Remove all registry modifications
- [ ] Delete malicious files
- [ ] Restore backup values
- [ ] Restart system (for DLL injection)
- [ ] Verify cleanup

### Phase 4: Validation (Instructor)
- [ ] Confirm no artifacts remain
- [ ] Verify no process hiding
- [ ] Verify all connections visible
- [ ] Check event logs for cleanup
- [ ] Document findings

---

## Deep Dive: How LSA Hijacking Works

### Normal Authentication Flow

```
User Input (Password)
        ↓
Windows Logon Process (winlogon.exe)
        ↓
LSA (lsass.exe)
        ↓
Security Support Providers (SSPs)
        ↓
NTLM / Kerberos / Custom
        ↓
Authentication Result
        ↓
Security Token (for user session)
```

### Hijacked Authentication Flow

```
User Input (Password)
        ↓
Windows Logon Process (winlogon.exe)
        ↓
Malicious Credential Provider (INTERCEPT 1)
        ↓
LSA (lsass.exe)
        ↓
Malicious SSP (INTERCEPT 2)
        ↓
NTLM / Kerberos / Custom
        ↓
Malicious Notification Package (INTERCEPT 3)
        ↓
Authentication Result
        ↓
Security Token (for user session)

RESULT: Attacker has plaintext password at multiple points
```

---

## Deep Dive: How DLL Injection Works

### Normal Windows Loader

```
Application Start
        ↓
Windows Loader (kernel32.dll loads)
        ↓
Dynamic Libraries (user32.dll, ntdll.dll, etc.)
        ↓
Import Address Table (IAT) linked
        ↓
Application Code Executes
```

### With AppInit_DLLs Injection

```
Application Start
        ↓
Windows Loader (kernel32.dll loads)
        ↓
Check AppInit_DLLs registry
        ↓
Load Malicious DLL from AppInit_DLLs
        ↓
Malicious DLL Runs (can hook APIs)
        ↓
Dynamic Libraries (user32.dll, etc.) - ALREADY HOOKED
        ↓
Import Address Table (IAT) redirected to hooks
        ↓
Application Code Executes (but through hooks)

RESULT: Attacker can intercept ANY API call
```

---

## Security Hardening Recommendations

### Prevent LSA Attacks

1. **Enable LSA Protection (RunAsPPL)**
   ```powershell
   reg add "HKLM\SYSTEM\CurrentControlSet\Control\Lsa" /v RunAsPPL /t REG_DWORD /d 1
   ```
   - Windows 8.1+ with UEFI/Secure Boot
   - Protects lsass.exe from user-mode injection

2. **Monitor Registry Changes**
   - Set up WMI event subscriptions for:
     - `HKLM\System\CurrentControlSet\Control\Lsa\SecurityPackages`
     - `HKLM\System\CurrentControlSet\Control\Lsa\Notification Packages`
   - Alert on ANY modification

3. **Credential Guard (Windows 10/11)**
   - Isolates LSA process from user-mode access
   - Requires hardware virtualization
   - Strongest defense against credential theft

### Prevent DLL Injection Attacks

1. **Disable AppInit_DLLs**
   ```powershell
   reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows" /v LoadAppInit_DLLs /t REG_DWORD /d 0
   ```

2. **Monitor AppInit_DLLs Registry**
   - Set up alerts for changes
   - Baseline and monitor modifications

3. **Enforce Code Signing**
   - Require signed DLLs
   - Block unsigned executables
   - Use AppLocker or similar

4. **File Integrity Monitoring (FIM)**
   - Monitor `System32`, `SysWOW64` for new DLLs
   - Alert on unsigned DLL modifications
   - Use AIDE, Tripwire, or OSSEC

5. **Kernel Patch Guard (PatchGuard)**
   - Windows 10/11 feature
   - Protects kernel structures from modification
   - Prevents rootkit-level DLL hooking

---

## Detection Tools

### Built-in Windows Tools
- **Get-ItemProperty**: Registry inspection
- **Get-Process**: Process information
- **Get-ChildItem -Hidden**: Find hidden files
- **sig nool**: DLL signature verification
- **Event Viewer**: Security log analysis
- **Process Monitor**: API and file system monitoring
- **Task Manager**: Process and DLL viewing

### Sysinternals Suite
- **Process Explorer**: Detailed process and module info
- **Autoruns**: Startup items and auto-load registry locations
- **RegShot**: Registry before/after snapshot
- **Handle**: Open file and registry handles
- **AccessChk**: Access control verification

### Third-Party Tools
- **WinDbg**: Kernel-mode debugging
- **IDA Pro**: Binary analysis and hooking detection
- **Ghidra**: Reverse engineering
- **Frida**: Runtime instrumentation
- **API Monitor**: Windows API monitoring

---

## Common Detection Evasion

Red teamers often try to hide these attacks:

1. **Hidden Files**: Use `attrib +h` to hide DLLs
   - Detection: `dir /a:h` or Get-ChildItem -Hidden
   
2. **Obfuscated Registry**: Use non-obvious registry key names
   - Detection: Complete registry audit
   
3. **Legitimate-Looking DLLs**: Name them after real DLLs
   - Detection: Signature verification, hash comparison
   
4. **In-Memory Injection**: Inject after reboot (temporary)
   - Detection: Monitor process memory at runtime
   
5. **Whitelist Bypass**: Inject via legitimate AppCert DLLs
   - Detection: Audit AppCert DLLs for unauthorized entries

---

## Real-World Examples

### Mimikatz
- Uses DLL injection for credential harvesting
- Hooks LSA to capture credentials
- Bypasses security features via kernel access

### NotPetya
- Used DLL injection for worm propagation
- Hooked file system APIs to hide files
- Persisted via registry-based loading

### APT28 / Fancy Bear
- Registry-based persistence via AppInit_DLLs
- Injected into multiple processes
- Difficult to detect without registry monitoring

### Cobalt Strike
- Uses DLL injection for beaconing
- Hides processes via API hooking
- Advanced post-exploitation capabilities

---

## Cleanup Verification Checklist

### LSA Training Cleanup
- [ ] Registry: `SecurityPackages` contains no CCDC entries
- [ ] Registry: No CCDC credential providers
- [ ] Registry: No CCDC notification packages
- [ ] Registry: AppInit_DLLs contains no CCDC DLLs
- [ ] Files: C:\Windows\Temp\ccdc_lsa_training\ deleted
- [ ] Files: C:\Windows\Temp\ccdc_credentials.log deleted
- [ ] Logs: Security event log shows cleanup events

### DLL Injection Cleanup
- [ ] Registry: AppInit_DLLs restored to original
- [ ] Registry: LoadAppInit_DLLs set to 0
- [ ] Registry: AppCert DLLs contains no CCDC entries
- [ ] Registry: ccdc_backup restored
- [ ] Files: C:\Windows\Temp\ccdc_dll_injection\ deleted
- [ ] Files: C:\Windows\Temp\ccdc_hook_log.txt deleted
- [ ] System: Rebooted to unload all DLLs
- [ ] Verification: No processes show CCDC modules

---

## Troubleshooting

### Script Won't Run
- Ensure running as Administrator
- Check PowerShell execution policy: `Get-ExecutionPolicy`
- If restricted, enable: `Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope CurrentUser`

### Cleanup Incomplete
- Ensure system is rebooted (DLLs stay in memory)
- Run cleanup script AFTER reboot
- Manually check registry after cleanup
- Verify hidden files are visible: `attrib -h C:\Windows\Temp\ccdc_*`

### Can't Find Hidden Files
- Use `dir /a:h` instead of `dir`
- Use PowerShell: `Get-ChildItem -Hidden`
- Explorer: View → Options → Show hidden files

---

## References

- [Microsoft LSA Architecture](https://docs.microsoft.com/en-us/windows-server/security/credentials/credentials-processes-in-windows-authentication)
- [Windows DLL Injection](https://attack.mitre.org/techniques/T1547/010/)
- [Sysinternals Suite](https://live.sysinternals.com/)
- [Event ID 4688 - Process Creation](https://docs.microsoft.com/en-us/windows/security/threat-protection/auditing/event-4688)
- [DLL Search Order](https://docs.microsoft.com/en-us/windows/win32/dlls/dynamic-link-library-search-order)

---

## Status

✅ **READY FOR DEPLOYMENT**

Both scripts are production-ready for authorized blue team training.

- Comprehensive LSA hijacking simulation
- DLL injection and hooking demonstration
- Multi-technique persistence methods
- Educational documentation and challenge guides
- Cleanup and verification mechanisms

---
