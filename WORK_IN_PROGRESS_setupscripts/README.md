# CCDC Setup Scripts - Blue Team Training Modules

This directory contains setup scripts for training cybersecurity teams on defensive techniques and attack recognition. These scripts simulate real-world attack scenarios in a controlled, authorized training environment.

## Compatibility

Scripts are tested and compatible with:
- ✅ Ubuntu 20.04+ (Debian-based)
- ✅ CentOS 7+ / RHEL 7+ (RPM-based)
- ✅ Fedora 30+ (RPM-based)

The scripts automatically detect your distribution and adjust paths/commands accordingly.

## Scripts

### CCDC_Linux_ExWifeNamedPAM.sh
**Purpose:** Demonstrate PAM (Pluggable Authentication Modules) vulnerabilities for blue team training

**Compatibility:** Ubuntu, Debian, CentOS, RHEL, Fedora

**What it does:**
1. **Authentication Capture** - Creates a malicious PAM module that logs all authentication attempts
   - Credentials are captured to: `~/LOOK_WHAT_PAM_CAPTURED_FLAG.txt`
   - Shows what information a compromised PAM module can steal

2. **Master Password Bypass** - Implements a hardcoded password that works regardless of the actual system password
   - Master password: `FLAGPASSWORD`
   - Demonstrates PAM authentication chain vulnerabilities

3. **Unrestricted Access** - Establishes multiple paths for access without proper authentication
   - Modifies PAM configuration for unrestricted authentication
   - Allows root SSH login
   - Enables passwordless sudo access
   - Does NOT modify shadow files or SSH authorized_keys

**Training Objectives:**
- Understand how PAM modules work and their role in Linux authentication
- Learn to identify suspicious PAM module entries
- Recognize authentication bypass techniques
- Know how to audit PAM configurations
- Understand persistence mechanisms via authentication systems

**Usage:**
```bash
sudo bash CCDC_Linux_ExWifeNamedPAM.sh
```

**Output:**
- Colored status messages showing setup progress
- Training documentation in: `/opt/ccdc_training/TRAINING_README.txt`
- Capture logs in user home directories: `~/LOOK_WHAT_PAM_CAPTURED_FLAG.txt`

---

### CCDC_Linux_PAM_Cleanup.sh
**Purpose:** Remove all training modifications and restore the system to its original state

**What it does:**
1. Restores backup PAM configurations
2. Removes malicious PAM modules (.so files)
3. Deletes training scripts and directories
4. Cleans up sudoers entries
5. Restores SSH configuration
6. Removes capture logs
7. Verifies cleanup was successful

**Usage:**
```bash
sudo bash CCDC_Linux_PAM_Cleanup.sh
```

**Important:** Run this script AFTER the training scenario is complete to ensure the system is clean.

---

## Training Workflow

### For Instructors:

1. **Setup Phase:**
   ```bash
   sudo bash CCDC_Linux_ExWifeNamedPAM.sh
   ```

2. **Training Phase:**
   - Have blue team members investigate the compromised system
   - Ask them to find:
     - How attackers got in (PAM configuration)
     - What data was captured (credential files)
     - All persistence mechanisms (sudo, SSH, PAM)
   - Have them determine how to detect and remove the backdoors

3. **Cleanup Phase:**
   ```bash
   sudo bash CCDC_Linux_PAM_Cleanup.sh
   ```

### For Blue Team Members:

**Detection Tasks:**
- [ ] Find all suspicious files in `/etc/pam.d/`
- [ ] Locate malicious .so files in `/lib/security/` directories
- [ ] Check `/opt/` for suspicious scripts
- [ ] Review `/etc/sudoers` for overly permissive entries
- [ ] Audit `/etc/ssh/sshd_config` configuration
- [ ] Find credential capture files in user home directories
- [ ] Review `/var/log/auth.log` for suspicious access patterns

**Remediation Tasks:**
- [ ] Restore backup PAM configurations
- [ ] Remove malicious modules
- [ ] Restore SSH to secure configuration
- [ ] Remove unauthorized sudoers entries
- [ ] Clear credential logs
- [ ] Verify system is clean

---

## Detection Methods

### Finding Suspicious PAM Modules
```bash
# List all PAM modules
ls -la /lib/security/
ls -la /lib64/security/
ls -la /usr/lib/security/

# Look for unexpected .so files
find /lib /usr/lib -name "pam_*.so" -newer /etc/pam.d/
```

### Auditing PAM Configuration
```bash
# Check main PAM configurations
cat /etc/pam.d/common-auth
cat /etc/pam.d/sshd
cat /etc/pam.d/sudo

# Look for backup files (training artifacts)
find /etc/pam.d/ -name "*.backup.ccdc_training"
```

### Finding Credential Capture Files
```bash
# Search for capture logs
find /home -name "LOOK_WHAT_PAM_CAPTURED_FLAG.txt"
find /root -name "LOOK_WHAT_PAM_CAPTURED_FLAG.txt"
```

### Checking SSH Configuration
```bash
# Review SSH config
cat /etc/ssh/sshd_config
ls -la /etc/ssh/sshd_config.d/

# Look for dangerous settings:
# - PermitRootLogin yes (without restrictions)
# - PermitEmptyPasswords yes
# - Authentication disabled settings
```

### Reviewing Sudoers
```bash
# Check for overly permissive entries
sudo grep -v "^#" /etc/sudoers | grep -v "^$"
sudo grep -r "NOPASSWD" /etc/sudoers.d/
```

---

## Security Implications

### Real-World Relevance

These training modules demonstrate actual attack techniques used by adversaries:

- **PAM Module Hijacking:** Real APTs have modified PAM modules for persistence and credential theft
- **Authentication Bypass:** Legitimate access without proper credentials enables lateral movement
- **Credential Logging:** Stolen credentials lead to account compromise and further attacks
- **Audit Evasion:** These techniques often evade traditional log-based detection

### Defensive Practices

To defend against these attacks:

1. **Monitor PAM Integrity:**
   - Use file integrity monitoring (AIDE, Tripwire) on `/etc/pam.d/`
   - Monitor PAM library locations for modifications
   - Alert on new PAM module installations

2. **Restrict File Permissions:**
   - PAM configuration should be readable only by root
   - PAM modules should not be world-writable
   - Use security SELinux policies for additional protection

3. **Configuration Management:**
   - Keep baseline PAM configurations
   - Use configuration management tools (Ansible, Puppet) to enforce standards
   - Regularly audit for unauthorized changes

4. **Logging and Monitoring:**
   - Enable comprehensive authentication logging
   - Monitor for unusual sudo usage
   - Alert on root SSH access attempts
   - Review authentication logs for impossible travel or unusual patterns

5. **Access Controls:**
   - Restrict SSH root login when possible
   - Use key-based authentication
   - Implement MFA where possible
   - Use sudo restrictions instead of root access

---

## Safety and Authorization

⚠️ **IMPORTANT SECURITY WARNING** ⚠️

These scripts should ONLY be used in:
- Authorized training environments
- Isolated test systems
- Controlled CCDC competitions
- Authorized red team exercises

These scripts must NOT be used on:
- Production systems
- Systems you don't own or have written permission to test
- Any system without explicit authorization from the owner

Using these scripts without authorization is illegal and unethical.

---

## Distribution-Specific Details

### Ubuntu / Debian
- PAM Library Path: `/lib/x86_64-linux-gnu/security/`
- PAM Config: `/etc/pam.d/common-auth`
- SSH Service: `ssh`
- Log Files: `/var/log/auth.log`
- Group for Sudo: `sudo`

### CentOS / RHEL / Fedora
- PAM Library Path: `/usr/lib64/security/`
- PAM Config: `/etc/pam.d/system-auth`, `/etc/pam.d/password-auth`
- SSH Service: `sshd`
- Log Files: `/var/log/secure`
- Group for Sudo: `wheel`

## Requirements

- Linux system (Ubuntu, Debian, CentOS, RHEL, or Fedora)
- Root access
- GCC compiler (for PAM module compilation; optional, script has fallbacks)
- Standard utilities: sed, grep, find, chown, etc.

## Testing

These scripts have been tested on:
- Ubuntu 20.04 LTS / 22.04 LTS
- Debian 11 / 12
- CentOS 7 / 8
- RHEL 7 / 8 / 9
- Fedora 35+

Results may vary on other distributions or versions. The scripts should gracefully handle most modern Linux distributions.

---

## Troubleshooting

### PAM Module Compilation Fails
**Symptom:** "Could not compile PAM module"
**Solution:** 
- Ensure gcc and pam development headers are installed
- Ubuntu/Debian: `apt-get install build-essential libpam0g-dev`
- CentOS/RHEL: `yum install gcc pam-devel`
- Fedora: `dnf install gcc pam-devel`
- Script includes fallback for auth bypass without compiled module

### SSH Won't Restart
**Symptom:** "Could not restart SSH" message
**Solution:**
1. Check SSH syntax: `sshd -t`
2. Manually restart: `systemctl restart sshd` (CentOS/RHEL/Fedora) or `systemctl restart ssh` (Ubuntu/Debian)
3. SSH may require manual restart if using non-standard port

### PAM Configuration Errors After Running Script
**Symptom:** Can't login after setup
**Solution:**
1. Boot into single-user/recovery mode
2. Restore from backup: `cp /etc/pam.d/*.backup.ccdc_training /etc/pam.d/`
3. Run cleanup script: `bash CCDC_Linux_PAM_Cleanup.sh`

### Sudo Not Working
**Symptom:** "sudo not found" or permission denied
**Solution:**
1. This is expected in training scenario - run cleanup script
2. Check sudoers was modified: `grep CCDC_Training /etc/sudoers`
3. Remove training entries and rebuild sudo cache

## Support and Notes

- The PAM module compilation may fail on systems with strict security policies - script includes fallbacks
- All backups are preserved with `.backup.ccdc_training` suffix
- SSH restart may fail if SSH is running on non-standard ports - manual restart may be needed
- Script automatically detects distribution and uses appropriate paths
- If capturing logs don't appear, check file permissions on user home directories

For questions or issues, review the inline comments in the scripts.
