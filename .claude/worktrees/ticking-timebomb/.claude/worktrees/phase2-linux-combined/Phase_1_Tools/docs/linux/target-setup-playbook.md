# Linux Target Setup Playbook — CCDC

> **Script:** `SetupScripts/linux/CCDC_Linux_TargetSetup_HTTP_Mail_Splunk.sh`
> **Phase:** Pre-game — run this **before** the competition starts
> **Run as:** root (`sudo bash CCDC_Linux_TargetSetup_HTTP_Mail_Splunk.sh`)
> **Target OS:** Ubuntu 24.04 LTS (x86_64/amd64)

Provisions a Linux machine as a scored competition target with three services blue team will defend:

| Service | Port | Notes |
|---|---|---|
| Apache2 (HTTP) | 80 | Static placeholder page |
| Postfix (SMTP) | 25 | Loopback-only by default |
| Dovecot (IMAP/POP3) | 143 / 110 | Plaintext auth, no TLS — lab only |
| Splunk Enterprise | 8000 | Web UI, 60-day trial license |

---

## Before You Run — Edit the Config Block

The top of the script has variables you should set before running:

```bash
# ── Mail ──────────────────────────────────────────────────────────────────────
MAIL_DOMAIN="mail.local"        # local-only domain (doesn't need to be real DNS)
MAIL_TEST_USER="mailuser"       # Linux user created to receive test mail
MAIL_TEST_PASS="ChangeMe123!"   # password for that user + IMAP/POP3 login

# ── Splunk ───────────────────────────────────────────────────────────────────
SPLUNK_ADMIN_USER="admin"
SPLUNK_ADMIN_PASS="ChangeMe123!"   # change this — 8+ chars required
SPLUNK_VERSION="10.4.3"
SPLUNK_BUILD_HASH="4174a2deda5d"   # update if Splunk download link rotates
```

**The Splunk download link may be stale.** If the download fails, go to [splunk.com/download](https://www.splunk.com/en_us/download/splunk-enterprise.html), grab a fresh `wget` link for the `.deb` (amd64), and update `SPLUNK_VERSION` and `SPLUNK_BUILD_HASH` at the top of the script.

---

## Run It

```bash
sudo bash SetupScripts/linux/CCDC_Linux_TargetSetup_HTTP_Mail_Splunk.sh
```

The script uses `set -euo pipefail` and traps errors with a message pointing at the failing line number — if something breaks mid-run, fix the issue and re-run. Most steps are idempotent.

---

## What Happens Step by Step

### 1 — Apache2

- Installs `apache2` via apt
- Writes a simple placeholder `index.html` to `/var/www/html/`
- Enables and starts the service
- Verifies with `curl http://localhost/`

### 2 — Mail server (Postfix + Dovecot)

- Pre-seeds debconf so Postfix installs non-interactively
- Installs `postfix`, `dovecot-imapd`, `dovecot-pop3d`, `mailutils`
- **Postfix** configured for:
  - `inet_interfaces = loopback-only` (no external SMTP by default)
  - Maildir delivery (`home_mailbox = Maildir/`)
  - Local domain only (`mydestination = $MAIL_DOMAIN, localhost`)
- **Dovecot** configured for:
  - Maildir storage (`maildir:~/Maildir`)
  - Plaintext auth allowed (`disable_plaintext_auth = no`)
  - SSL disabled (`ssl = no`) — lab only, no cert needed
  - Protocols: IMAP + POP3
- Creates the test mailbox user (`$MAIL_TEST_USER`) and their Maildir structure
- Sends a test email and checks `/home/$MAIL_TEST_USER/Maildir/new/` to confirm delivery

### 3 — Splunk Enterprise

- Downloads the `.deb` package from Splunk's CDN to `/tmp/`
- Installs via `dpkg`
- Creates a `splunk` system user, fixes ownership of `/opt/splunk`
- Starts Splunk for the first time: accepts the license, seeds the admin password
- Enables boot-start via a systemd unit (`splunk enable boot-start -user splunk`)
- Polls `http://localhost:8000` for up to 100 seconds to confirm the web UI is up

### 4 — Firewall (optional)

Off by default (`ENABLE_FIREWALL=false`). If you enable it, the script opens ports 22, 80, and 8000 via `ufw`. Mail stays loopback-only regardless of this setting.

---

## Post-Setup Verification

From another machine on the same network:

```bash
# Apache2
curl http://<target-ip>/

# SMTP — send a test email (requires a mail client or telnet)
telnet <target-ip> 25
# Note: loopback-only by default — won't respond from remote until you
# change `inet_interfaces = all` in /etc/postfix/main.cf

# Dovecot IMAP
telnet <target-ip> 143
# a LOGIN mailuser ChangeMe123!

# Splunk web UI
curl -sk https://<target-ip>:8000 | grep -i splunk
```

> **Note on Postfix:** The default config binds to loopback only, so the SMTP scoring check will fail from a remote host. Before competition, change `inet_interfaces` and restart Postfix:
> ```bash
> postconf -e "inet_interfaces = all"
> systemctl restart postfix
> ```

---

## Configuration Reference

| Variable | Default | What it controls |
|---|---|---|
| `MAIL_DOMAIN` | `mail.local` | Postfix `myhostname` and `mydestination` |
| `MAIL_TEST_USER` | `mailuser` | Linux user created to receive mail |
| `MAIL_TEST_PASS` | `ChangeMe123!` | Password for mail test user |
| `SPLUNK_ADMIN_USER` | `admin` | Splunk web UI admin username |
| `SPLUNK_ADMIN_PASS` | `ChangeMe123!` | Splunk admin password |
| `SPLUNK_VERSION` | `10.4.3` | Splunk package version to download |
| `SPLUNK_BUILD_HASH` | `4174a2deda5d` | Build hash in the download URL |
| `ENABLE_FIREWALL` | `false` | Whether to configure `ufw` |

---

## Troubleshooting

**Splunk download fails**
The build hash in the URL rotates with each release. Go to [splunk.com/download](https://www.splunk.com/en_us/download/splunk-enterprise.html), find the `.deb (amd64)` link, copy the `wget` URL, and update `SPLUNK_VERSION` and `SPLUNK_BUILD_HASH`.

**Test email not delivered**
```bash
journalctl -u postfix -n 50
# Check for "unknown user" (MAIL_TEST_USER doesn't exist) or
# "relay access denied" (inet_interfaces config issue)
```

**Dovecot login fails**
```bash
journalctl -u dovecot -n 30
# Confirm disable_plaintext_auth = no in /etc/dovecot/conf.d/10-auth.conf
# Confirm ssl = no in /etc/dovecot/conf.d/10-ssl.conf
```

**Splunk web UI doesn't come up**
```bash
sudo -u splunk /opt/splunk/bin/splunk status
sudo -u splunk /opt/splunk/bin/splunk start
journalctl -u Splunkd -n 50
```

**Script fails mid-run**
The trap message says which line failed. Fix the issue (usually a failed download or a package conflict) and re-run — most steps check for existing state before acting.
