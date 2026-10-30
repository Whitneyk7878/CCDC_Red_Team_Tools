# Distro Support

**All Linux service-sabotage scripts must support Ubuntu/Debian, Fedora, and Oracle Linux 9 / RHEL / CentOS.**

- Distro detection via `/etc/os-release` (`ID` field): `ubuntu`/`debian` → `apache2`, `/etc/apache2/`; Fedora/RHEL/OL → `httpd`, `/etc/httpd/`.
- Service names are distro-dependent: always probe both `apache2` and `httpd`.
- iptables is available on all supported distros; persist with `netfilter-persistent` (Ubuntu) or writing `/etc/iptables/rules.v4` (RHEL/Fedora).

---

# Context

Runtime service-sabotage script for CCDC Linux targets. Deploys directly onto a scored machine
and applies three independent layers of disruption per service. Blue team must identify and
remediate all three layers to restore scoring — fixing one layer still leaves the next blocking.

Script detects installed services before acting and skips any that are not present.

---

## Script

| Filename | OS | Privilege |
|---|---|---|
| `CCDC_Linux_ServiceSabotage_BrokenClock.sh` | Linux (Ubuntu, Fedora, OL9) | root |

---

## MITRE ATT&CK Coverage

| ID | Technique | Usage |
|---|---|---|
| T1489 | Service Stop | Layer 1 — `systemctl stop` + `mask` |
| T1565.001 | Stored Data Manipulation | Layer 2 — config file corruption |
| T1562.004 | Disable or Modify System Firewall | Layer 3 — iptables DROP rules |
| T1222 | File and Directory Permissions Modification | Layer 3 — `chattr +i`, `chmod`, `chown` |
| T1053.003 | Scheduled Task/Job: Cron | Layer 3 (Splunk) — recurring kill cron |

---

## 3-Layer Strategy

| Layer | Category | Description |
|---|---|---|
| 1 | **Service Kill** | `systemctl stop` + `systemctl mask` — service is down and can't be started normally |
| 2 | **Config Corruption** | Config file modified so service errors out at startup (even after unmask) |
| 3 | **Hidden Blocker** | `iptables DROP` on service port(s) + `chattr +i` on config (immutable) + filesystem ACL or cron killer |

---

## Per-Service Design

### Dovecot (IMAP/POP3 — ports 110, 143, 993, 995)

| Layer | Technique | Detail |
|---|---|---|
| L1 | Stop + mask | `systemctl stop dovecot && systemctl mask dovecot` |
| L2 | SSL cert path poison | Append `ssl = required` + `ssl_cert = </nonexistent/cert.pem` + `listen = 127.0.0.1` to `/etc/dovecot/dovecot.conf` |
| L3 | Immutable + FW + mail perms | `chattr +i /etc/dovecot/dovecot.conf`; iptables DROP 110/143/993/995; `chmod 700 /var/mail && chown root:root /var/mail` |

### Postfix (SMTP — ports 25, 587, 465)

| Layer | Technique | Detail |
|---|---|---|
| L1 | Stop + mask | `systemctl stop postfix && systemctl mask postfix` |
| L2 | Loopback-only + broken TLS + master.cf | Append `inet_interfaces = loopback-only`, invalid `smtpd_tls_cert_file`, broken chroot path in `master.cf` smtp line |
| L3 | Immutable + FW + queue lockout | `chattr +i main.cf master.cf`; iptables DROP 25/587/465; `chmod 700 /var/spool/postfix/incoming` |

### Apache / HTTP (HTTP/HTTPS — ports 80, 443)

| Layer | Technique | Detail |
|---|---|---|
| L1 | Stop + mask | `systemctl stop apache2/httpd && systemctl mask apache2/httpd` |
| L2 | Wrong Listen port + broken include | Ubuntu: `ports.conf` Listen 80 → 12345 + add broken Include glob; RHEL: `httpd.conf` same treatment |
| L3 | Immutable + FW + webroot perms | `chattr +i ports.conf/httpd.conf`; iptables DROP 80/443; `chmod o-rx /var/www/html` |

### Splunk (Web UI port 8000, management 8089, forwarder 9997)

| Layer | Technique | Detail |
|---|---|---|
| L1 | Stop via binary + mask units | `/opt/splunk/bin/splunk stop --answer-yes`; mask all `*splunk*` systemd units; `pkill -9 -f splunkd` |
| L2 | Bad web.conf + broken SSL | Overwrite `etc/system/local/web.conf` with port 12345 + `startwebserver=false`; append invalid `sslRootCAPath` to `server.conf` |
| L3 | var/run lockout + FW + cron killer | `chown root:root var/run && chmod 700 var/run`; iptables DROP 8000/8089/9997; add `/etc/cron.d/splunk-health` that `pkill -9 splunkd` every 3 min |

### OpenCart (PHP app — web port 80/443, MySQL port 3306)

| Layer | Technique | Detail |
|---|---|---|
| L1 | Corrupt DB credentials | Read credentials from `config.php` first; replace `DB_PASSWORD` + `DB_USERNAME` with invalid values in both `config.php` and `admin/config.php` |
| L2 | Deny web access | Append `Deny from all` to `.htaccess`; find Apache vhost for OpenCart webroot, append `Require all denied` block |
| L3 | Drop DB + immutable + FW MySQL | `mysql -e "DROP DATABASE opencart_db"`; `chattr +i config.php admin/config.php`; iptables DROP 3306 |

---

## OpenCart Config Discovery

```bash
find /var/www -maxdepth 6 -name "config.php" \
    -exec grep -l "DB_SERVER\|DB_DATABASE" {} \; 2>/dev/null
```

Credential extraction pattern:
```bash
db_pass=$(grep -oP "define\('DB_PASSWORD',\s*'\K[^']+" "$cfg")
```

---

## File Destinations

```
Phase_2_Tools/General_Scripts/SetupScripts/linux/
└── CCDC_Linux_ServiceSabotage_BrokenClock.sh
```

---

## Verification

```bash
# Syntax check
bash -n Phase_2_Tools/General_Scripts/SetupScripts/linux/CCDC_Linux_ServiceSabotage_BrokenClock.sh

# After running on test Ubuntu VM:
iptables -L INPUT -n | grep DROP          # Confirm DROP rules on 25/80/110/143/443/993/995/3306/8000/8089
lsattr /etc/dovecot/dovecot.conf          # Should show ----i---- (immutable)
lsattr /etc/postfix/main.cf              # Should show ----i----
systemctl status dovecot                  # Should show "masked"
systemctl start dovecot                   # Should fail
curl http://localhost                     # Should time out (FW DROP)
```
