# Windows Training Scripts - Code Review

## Executive Summary

**Review Scope:** Windows Server 2019+ and Windows 10/11 compatibility  
**Scripts Reviewed:** 
- CCDC_Windows_LSA_LootTheVault.ps1 (21KB)
- CCDC_Windows_DLL_HookLineAndSinker.ps1 (31KB)

**Status:** ⚠️ **9 ISSUES FOUND** (3 CRITICAL, 4 HIGH, 2 MEDIUM)

---

## Critical Issues Found

### 1. ❌ CRITICAL: Registry Property Access Syntax Error (LSA Script)

**File:** CCDC_Windows_LSA_LootTheVault.ps1  
**Lines:** 88-98 (Cleanup section)  
**Severity:** CRITICAL

**Issue:**
```powershell
$lsaPath = "HKLM:\System\CurrentControlSet\Control\Lsa\Security Packages"
$packages = Get-ItemProperty $lsaPath
$newPackages = $packages.PSObject.Properties |
    Where-Object { $_.Value -notlike '*ccdc*' } |
    ForEach-Object { $_.Value }
```

**Problem:**
- `Get-ItemProperty` on a registry path with spaces requires quotes
- `Security Packages` is not a subkey, it's a VALUE
- The code tries to read it as if it were a key with properties
- This will throw errors in Windows Server 2019+

**Fix:**
```powershell
# Correct approach - read the SecurityPackages value
$lsaPath = "HKLM:\System\CurrentControlSet\Control\Lsa"
$currentPackages = (Get-ItemProperty -Path $lsaPath -Name "SecurityPackages" -ErrorAction SilentlyContinue).SecurityPackages

# Filter and rejoin
$newPackages = @($currentPackages -split ',' | Where-Object { $_ -notlike '*ccdc*' }) -join ','
```

---

### 2. ❌ CRITICAL: Unquoted Registry Paths with Spaces

**File:** Both scripts  
**Multiple Locations**  
**Severity:** CRITICAL

**Issue:**
```powershell
# Line 88 (LSA)
$lsaPath = "HKLM:\System\CurrentControlSet\Control\Lsa\Security Packages"

# Line 247 (LSA)
$credProvPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers"

# Line 277 (LSA)
$lsaNotifyPath = "HKLM:\System\CurrentControlSet\Control\Lsa\Notification Packages"
```

**Problem:**
- Registry paths with spaces MUST be quoted in PowerShell
- These ARE quoted as strings, but when used in registry operations, paths need escaping
- Will fail on Windows Server 2019+ with strict registry security policies

**Fix:**
```powershell
# Use -Path parameter explicitly
Get-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Lsa\Security Packages"

# Or escape the path
$lsaPath = 'HKLM:\System\CurrentControlSet\Control\Lsa\Security Packages'
```

---

### 3. ❌ CRITICAL: Incorrect Registry Value Name Syntax

**File:** CCDC_Windows_LSA_LootTheVault.ps1  
**Lines:** 259, 281  
**Severity:** CRITICAL

**Issue:**
```powershell
# Line 259 - trying to set "(Default)" which is wrong
Set-ItemProperty $providerKeyPath -Name "(Default)" -Value "CCDC Training Credential Provider"

# Line 281 - trying to read "(Default)" 
$currentNotify = (Get-ItemProperty $lsaNotifyPath).'(Default)'
```

**Problem:**
- The registry value is "SecurityPackages" or "Notification Packages", not "(Default)"
- Using "(Default)" will create a new value instead of modifying the actual value
- Will not work as intended in Server 2019+
- Credential providers have specific registry structure (CLSID in subkey)

**Fix:**
```powershell
# For SecurityPackages
Set-ItemProperty -Path $lsaPath -Name "SecurityPackages" -Value $newPackages

# For Notification Packages
Set-ItemProperty -Path $lsaNotifyPath -Name "" -Value $newNotify  # Default value
# Or use specific name if needed
```

---

## High Severity Issues

### 4. ⚠️ HIGH: Registry Path Not Found Error Handling

**File:** CCDC_Windows_LSA_LootTheVault.ps1  
**Lines:** 88-89  
**Severity:** HIGH

**Issue:**
```powershell
$lsaPath = "HKLM:\System\CurrentControlSet\Control\Lsa\Security Packages"
if (Test-Path $lsaPath) {  # This will be FALSE - it's not a key, it's a value
```

**Problem:**
- `Security Packages` is a registry VALUE, not a KEY
- `Test-Path` will return FALSE
- The entire block gets skipped
- No cleanup happens

**Fix:**
```powershell
$lsaPath = "HKLM:\System\CurrentControlSet\Control\Lsa"
if (Test-Path $lsaPath) {
    $packages = Get-ItemProperty -Path $lsaPath -Name "SecurityPackages" -ErrorAction SilentlyContinue
    if ($packages) {
        # Process...
    }
}
```

---

### 5. ⚠️ HIGH: AppInit_DLLs Setup on Server 2019+

**File:** CCDC_Windows_LSA_LootTheVault.ps1  
**Lines:** 298-320  
**Severity:** HIGH

**Issue:**
```powershell
$appInitPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows"
Set-ItemProperty $appInitPath -Name "LoadAppInit_DLLs" -Value 1
```

**Problem:**
- Windows Server 2019+ has security restrictions on AppInit_DLLs
- Setting this may fail silently or require additional registry permissions
- The registry path may not exist on Server Core installations
- No error handling for registry access denied

**Fix:**
```powershell
$appInitPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows"
try {
    if (Test-Path $appInitPath) {
        Set-ItemProperty -Path $appInitPath -Name "LoadAppInit_DLLs" -Value 1 -ErrorAction Stop
        Set-ItemProperty -Path $appInitPath -Name "AppInit_DLLs" -Value $dllPath -ErrorAction Stop
        Write-Status "AppInit_DLLs configured" 'Success'
    } else {
        Write-Status "Registry path not found (Server Core?)" 'Warning'
    }
}
catch {
    Write-Status "Failed to set AppInit_DLLs: $($_.Exception.Message)" 'Error'
}
```

---

### 6. ⚠️ HIGH: Missing Error Handling for Directory Creation

**File:** CCDC_Windows_DLL_HookLineAndSinker.ps1  
**Lines:** 88-94  
**Severity:** HIGH

**Issue:**
```powershell
$injectionDir = "C:\Windows\Temp\ccdc_dll_injection"
if (-not (Test-Path $injectionDir)) {
    New-Item -ItemType Directory -Path $injectionDir -Force | Out-Null
}  # No error checking if creation fails

foreach ($dll in $markerDlls) {
    $dllPath = Join-Path $injectionDir $dll
    Set-Content -Path $dllPath -Value "CCDC_TRAINING_DLL_MARKER - $dll"  # Could fail
}
```

**Problem:**
- Directory creation could fail due to permissions
- Set-Content could fail if directory doesn't exist
- No error messages to indicate why operations failed
- Script continues silently

**Fix:**
```powershell
try {
    if (-not (Test-Path $injectionDir)) {
        $null = New-Item -ItemType Directory -Path $injectionDir -Force -ErrorAction Stop
        Write-Status "Created injection directory: $injectionDir" 'Success'
    }
}
catch {
    Write-Status "CRITICAL: Failed to create injection directory: $($_.Exception.Message)" 'Error'
    exit 1
}
```

---

### 7. ⚠️ HIGH: Type Casting Error in Get-WindowsVersion

**File:** Both scripts  
**Lines:** 50-68 (LSA), similar in DLL script  
**Severity:** HIGH

**Issue:**
```powershell
function Get-WindowsVersion {
    $osVersion = [Environment]::OSVersion.Version
    $productType = (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\ProductOptions').ProductType
    # $productType is read but never used
    
    $version = switch ($osVersion.Major) {
        6 { ... }
        10 {
            if ($osVersion.Build -lt 22000) { "Windows 10" }
            else { "Windows 11" }
        }
        default { "Windows (Build $($osVersion.Build))" }
    }
    # Missing detection for Windows Server 2019, 2022, etc!
}
```

**Problem:**
- Windows Server 2019 has version 10 (Build 17763+)
- Windows Server 2022 has version 10 (Build 20348+)
- Code will misidentify Server as "Windows 10"
- The $productType variable is read but never used
- Server detection is completely broken

**Fix:**
```powershell
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
            # Check if it's Server
            if ($productType -eq "ServerNT") {
                if ($osVersion.Build -ge 20348) { "Windows Server 2022" }
                elseif ($osVersion.Build -ge 17763) { "Windows Server 2019" }
                else { "Windows Server 2016" }
            } else {
                if ($osVersion.Build -lt 22000) { "Windows 10" }
                else { "Windows 11" }
            }
        }
        default { "Windows (Build $($osVersion.Build))" }
    }
    
    return $version
}
```

---

## Medium Severity Issues

### 8. ⚠️ MEDIUM: Add-Type with C# Code May Fail

**File:** CCDC_Windows_LSA_LootTheVault.ps1  
**Lines:** 159-180  
**Severity:** MEDIUM

**Issue:**
```powershell
try {
    Add-Type -TypeDefinition $csharpCode -Language CSharp -OutputAssembly $assemblyPath -OutputType Library
    Write-Status "Created credential logging assembly" 'Success'
}
catch {
    Write-Status "Assembly creation skipped (using fallback mechanism)" 'Warning'
}
```

**Problem:**
- `Add-Type` requires .NET Framework installed (usually there, but not guaranteed on Server Core)
- No verification that the assembly was actually created
- If assembly creation fails, the script continues but doesn't explain why
- On Server 2019+, .NET Framework might not be available

**Fix:**
```powershell
try {
    Add-Type -TypeDefinition $csharpCode -Language CSharp -OutputAssembly $assemblyPath -OutputType Library -ErrorAction Stop
    if (Test-Path $assemblyPath) {
        Write-Status "Created credential logging assembly" 'Success'
    } else {
        throw "Assembly file not created"
    }
}
catch {
    Write-Status "Assembly compilation failed (fallback to marker files only): $($_.Exception.Message)" 'Warning'
    # Create marker file instead
    Set-Content -Path $assemblyPath -Value "CCDC_TRAINING_ASSEMBLY_MARKER"
}
```

---

### 9. ⚠️ MEDIUM: Unicode Box Drawing Characters

**File:** Both scripts  
**Lines:** 77-81 (LSA), 57-61 (DLL)  
**Severity:** MEDIUM

**Issue:**
```powershell
Write-Host "╔════════════════════════════════════════════════════════════════╗"
Write-Host "║  CCDC Windows LSA Credential Harvesting Training Module       ║"
```

**Problem:**
- Unicode box drawing characters may not display correctly on Server Core (no GUI)
- Output encoding issues on Windows Server 2019+
- PowerShell output encoding might default to ASCII
- Characters will display as garbage on some systems

**Fix:**
```powershell
# Use ASCII safe output
Write-Host "========================================================================"
Write-Host "  CCDC Windows LSA Credential Harvesting Training Module"
Write-Host "========================================================================"

# Or set output encoding explicitly
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Write-Host "╔════════════════════════════════════════════════════════════════╗"
```

---

## Summary Table

| # | Issue | Severity | File | Type | Status |
|---|-------|----------|------|------|--------|
| 1 | Registry property access syntax | 🔴 CRITICAL | LSA | Logic | ❌ NEEDS FIX |
| 2 | Unquoted registry paths | 🔴 CRITICAL | Both | Syntax | ⚠️ PARTIAL |
| 3 | Incorrect registry value names | 🔴 CRITICAL | LSA | Logic | ❌ NEEDS FIX |
| 4 | Registry path not found | 🟠 HIGH | LSA | Logic | ❌ NEEDS FIX |
| 5 | AppInit_DLLs on Server 2019+ | 🟠 HIGH | LSA | Compat | ⚠️ NEEDS ERROR HANDLING |
| 6 | Missing directory error handling | 🟠 HIGH | DLL | Error | ❌ NEEDS FIX |
| 7 | Windows Server detection broken | 🟠 HIGH | Both | Logic | ❌ NEEDS FIX |
| 8 | Add-Type may fail silently | 🟡 MEDIUM | LSA | Error | ⚠️ NEEDS IMPROVEMENT |
| 9 | Unicode box chars on Server Core | 🟡 MEDIUM | Both | Compat | ⚠️ MINOR |

---

## Windows Server 2019+ Specific Compatibility Issues

### Issue 1: Registry Permissions
- Server 2019+ has stricter registry ACLs
- LSA\SecurityPackages requires SYSTEM access
- AppInit_DLLs may be blocked by security policies
- **Fix:** Add explicit error handling with -ErrorAction Stop

### Issue 2: .NET Framework Availability
- Server 2019+ defaults to .NET Core (not Framework)
- Add-Type may not work with C# code
- **Fix:** Fallback to marker files without Add-Type

### Issue 3: Server Core Edition
- No GUI, minimal services
- Box drawing characters won't display
- Some registry keys may not exist
- **Fix:** Detect Server Core and adjust output

### Issue 4: PowerShell Execution Policies
- Server 2019+ may have stricter policies
- Scripts may not run without -ExecutionPolicy Bypass
- **Fix:** Document execution policy requirements

### Issue 5: Path Handling
- C:\Windows\Temp might be read-only on Server Core
- No GUI means no Explorer to verify files
- **Fix:** Use alternative temp paths or create under C:\Temp

---

## Recommendations

### Priority 1 (CRITICAL - Must Fix)

1. **Fix Registry Value Access**
   - Distinguish between registry KEYS and VALUES
   - Use correct property names (SecurityPackages, not "(Default)")
   - Add proper error handling

2. **Fix Registry Path Handling**
   - Quote all paths with spaces properly
   - Use -Path parameter explicitly in cmdlets
   - Add null checks for values

### Priority 2 (HIGH - Should Fix)

3. **Improve Windows Server Detection**
   - Check for Server 2019, 2022 specifically
   - Use ProductType to distinguish Server from Workstation
   - Handle Server Core editions

4. **Add Robust Error Handling**
   - Wrap directory operations in try-catch
   - Verify file creation success
   - Handle registry access denied gracefully

5. **Handle AppInit_DLLs Restrictions**
   - Check if setting is allowed
   - Document Server 2019+ restrictions
   - Provide workarounds

### Priority 3 (MEDIUM - Nice to Have)

6. **Fix Unicode Display Issues**
   - Set output encoding or use ASCII
   - Test on Server Core
   - Provide alternative output formats

7. **Improve Add-Type Error Handling**
   - Catch compilation failures
   - Fallback to marker files
   - Log actual error messages

---

## Testing Checklist for Windows Server 2019+

- [ ] Run on Windows Server 2019 (Standard edition)
- [ ] Run on Windows Server 2022 (Standard edition)
- [ ] Test with Server Core edition (no GUI)
- [ ] Test with restricted execution policies
- [ ] Verify registry modifications on Server systems
- [ ] Check permissions on LSA registry keys
- [ ] Test cleanup on Server 2019+
- [ ] Verify AppInit_DLLs functionality
- [ ] Check output encoding on console
- [ ] Test with .NET Framework missing

---

## Code Quality Score

**Overall:** ⚠️ 52/100 (Needs Improvement)

| Category | Score | Notes |
|----------|-------|-------|
| **Syntax** | 75/100 | PowerShell syntax mostly correct, but registry paths problematic |
| **Logic** | 45/100 | Registry operations have flawed logic, especially value handling |
| **Error Handling** | 40/100 | Try-catch blocks exist but don't validate success |
| **Compatibility** | 35/100 | Server 2019+ detection broken, registry access issues |
| **Documentation** | 90/100 | Excellent inline comments and training guides |

---

## Conclusion

**Before deploying to Windows Server 2019+, these scripts MUST be fixed:**

1. ❌ Registry value access syntax (CRITICAL)
2. ❌ Windows Server version detection (CRITICAL)
3. ⚠️ Registry permission/access error handling (HIGH)
4. ⚠️ Directory creation error handling (HIGH)

**Current Status:** ❌ **NOT READY FOR PRODUCTION**  
**Estimated Fix Time:** 1-2 hours  
**Post-Fix Status:** Will be ✅ **READY FOR TESTING**

---

## Next Steps

1. Apply critical fixes to both scripts
2. Test on Windows Server 2019 virtual machine
3. Test on Windows Server 2022 virtual machine
4. Test cleanup procedures
5. Verify registry modifications persist correctly
6. Create updated code review after fixes applied
