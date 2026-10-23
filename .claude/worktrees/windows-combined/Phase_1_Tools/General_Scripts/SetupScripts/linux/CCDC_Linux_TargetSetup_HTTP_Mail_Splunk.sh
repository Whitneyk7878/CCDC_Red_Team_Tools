#!/usr/bin/env bash
#
# setup-lab-server.sh
#
# All-in-one lab/test server setup for Ubuntu 24.04 LTS (x86_64):
#   1. Apache2 web server
#   2. Postfix + Dovecot local-only mail server (Maildir)
#   3. Splunk Enterprise (web UI on :8000)
#
# This is built for a LOCAL TEST/LAB box, not a hardened production server:
#   - Mail server binds to loopback only (no internet exposure)
#   - Dovecot auth allows plaintext (no TLS cert set up)
#   - Splunk gets a simple seeded admin password
# Change the variables below, and revisit the "not production ready" notes
# at the bottom before using this anywhere that matters.
#
# Usage:
#   sudo bash setup-lab-server.sh
#
# Tested target: Ubuntu 24.04 LTS, x86_64/amd64.

set -euo pipefail

# ============================================================================
# CONFIGURATION - edit these before running
# ============================================================================

# --- Mail server ---
MAIL_DOMAIN="mail.local"                 # local-only domain, doesn't need to be real
MAIL_TEST_USER="mailuser"                # a Linux user created to receive test mail
MAIL_TEST_PASS="ChangeMe123!"            # password for that user (also used for IMAP/POP3 login)

# --- Splunk ---
SPLUNK_ADMIN_USER="admin"
SPLUNK_ADMIN_PASS="ChangeMe123!"         # Splunk requires 8+ characters
SPLUNK_VERSION="10.4.3"
SPLUNK_BUILD_HASH="4174a2deda5d"         # from splunk.com/download as of writing
SPLUNK_DEB_URL="https://download.splunk.com/products/splunk/releases/${SPLUNK_VERSION}/linux/splunk-${SPLUNK_VERSION}-${SPLUNK_BUILD_HASH}-linux-amd64.deb"

# --- Firewall (ufw). Leave false unless you know ufw is already set up
#     correctly on this box - flipping it on blind can lock out SSH. ---
ENABLE_FIREWALL=false

# ============================================================================
# Helpers
# ============================================================================

log()  { echo -e "\n\033[1;32m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m!! $*\033[0m"; }
die()  { echo -e "\033[1;31mERROR: $*\033[0m" >&2; exit 1; }

trap 'die "Something failed near line $LINENO. Re-run after fixing; most steps are safe to repeat."' ERR

[[ $EUID -eq 0 ]] || die "Run this as root (sudo bash setup-lab-server.sh)."

ARCH="$(dpkg --print-architecture)"
[[ "$ARCH" == "amd64" ]] || warn "Detected architecture '$ARCH', script assumes amd64. Splunk download will likely fail."

export DEBIAN_FRONTEND=noninteractive

# ============================================================================
# 0. Base update
# ============================================================================

log "Updating package lists"
apt-get update -y

log "Installing base utilities"
apt-get install -y curl wget gnupg2 ca-certificates lsb-release

# ============================================================================
# 1. Apache2
# ============================================================================

log "Installing Apache2"
apt-get install -y apache2

cat > /var/www/html/index.html <<'EOF'
<!doctype html>
<html>
  <head><title>It works</title></head>
  <body style="font-family: sans-serif; margin: 4rem;">
    <h1>Apache2 is up</h1>
    <p>This page was dropped in by setup-lab-server.sh.</p>
  </body>
</html>
EOF

systemctl enable --now apache2

log "Verifying Apache2"
sleep 2
if curl -sf http://localhost/ >/dev/null; then
  echo "Apache2 responded on http://localhost/"
else
  warn "Apache2 did not respond on port 80 - check 'systemctl status apache2'"
fi

# ============================================================================
# 2. Mail server: Postfix + Dovecot (local only)
# ============================================================================

log "Pre-seeding Postfix answers (avoids interactive prompts)"
echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections
echo "postfix postfix/mailname string ${MAIL_DOMAIN}" | debconf-set-selections

log "Installing Postfix, Dovecot, and mail utilities"
apt-get install -y postfix dovecot-imapd dovecot-pop3d mailutils

log "Making ${MAIL_DOMAIN} resolve locally"
if ! grep -q "${MAIL_DOMAIN}" /etc/hosts; then
  echo "127.0.0.1   ${MAIL_DOMAIN}" >> /etc/hosts
fi

log "Configuring Postfix (loopback-only, Maildir delivery)"
postconf -e "myhostname = ${MAIL_DOMAIN}"
postconf -e "mydestination = ${MAIL_DOMAIN}, localhost.localdomain, localhost"
postconf -e "inet_interfaces = loopback-only"
postconf -e "home_mailbox = Maildir/"
postconf -e "mailbox_command ="

log "Configuring Dovecot (Maildir, plaintext auth for local testing)"
sed -i 's|^mail_location =.*|mail_location = maildir:~/Maildir|' /etc/dovecot/conf.d/10-mail.conf
grep -q '^mail_location' /etc/dovecot/conf.d/10-mail.conf || \
  echo 'mail_location = maildir:~/Maildir' >> /etc/dovecot/conf.d/10-mail.conf

sed -i 's|^#disable_plaintext_auth.*|disable_plaintext_auth = no|' /etc/dovecot/conf.d/10-auth.conf
sed -i 's|^disable_plaintext_auth.*|disable_plaintext_auth = no|' /etc/dovecot/conf.d/10-auth.conf

sed -i 's|^ssl = required|ssl = no|' /etc/dovecot/conf.d/10-ssl.conf
sed -i 's|^#ssl = yes|ssl = no|' /etc/dovecot/conf.d/10-ssl.conf

sed -i 's|^#protocols = imap pop3 lmtp|protocols = imap pop3|' /etc/dovecot/dovecot.conf
grep -q '^protocols' /etc/dovecot/dovecot.conf || echo 'protocols = imap pop3' >> /etc/dovecot/dovecot.conf

log "Creating local test mailbox user: ${MAIL_TEST_USER}"
if ! id "${MAIL_TEST_USER}" &>/dev/null; then
  useradd -m -s /bin/bash "${MAIL_TEST_USER}"
fi
echo "${MAIL_TEST_USER}:${MAIL_TEST_PASS}" | chpasswd
mkdir -p "/home/${MAIL_TEST_USER}/Maildir/"{cur,new,tmp}
chown -R "${MAIL_TEST_USER}:${MAIL_TEST_USER}" "/home/${MAIL_TEST_USER}/Maildir"

log "Restarting mail services"
systemctl restart postfix
systemctl enable --now dovecot

log "Sending a test email to verify local delivery"
sleep 2
echo "Test message from setup-lab-server.sh at $(date)" | mail -s "Test mail" "${MAIL_TEST_USER}@${MAIL_DOMAIN}"
sleep 3
if find "/home/${MAIL_TEST_USER}/Maildir/new" -type f | grep -q .; then
  echo "Test email delivered to /home/${MAIL_TEST_USER}/Maildir/new"
else
  warn "Test email not found yet - check 'mail.log' with: journalctl -u postfix -n 50"
fi

# ============================================================================
# 3. Splunk Enterprise
# ============================================================================

log "Downloading Splunk Enterprise ${SPLUNK_VERSION}"
cd /tmp
SPLUNK_DEB="splunk-${SPLUNK_VERSION}-${SPLUNK_BUILD_HASH}-linux-amd64.deb"
if [[ ! -f "${SPLUNK_DEB}" ]]; then
  wget -O "${SPLUNK_DEB}" "${SPLUNK_DEB_URL}" || \
    die "Splunk download failed. The link may have rotated - grab a fresh 'Copy wget link' for the .deb (amd64) from https://www.splunk.com/en_us/download/splunk-enterprise.html and update SPLUNK_VERSION/SPLUNK_BUILD_HASH at the top of this script."
fi

log "Installing Splunk package"
dpkg -i "${SPLUNK_DEB}"

log "Creating dedicated 'splunk' user and fixing ownership"
if ! id splunk &>/dev/null; then
  useradd -r -d /opt/splunk -s /bin/bash splunk
fi
chown -R splunk:splunk /opt/splunk

log "Starting Splunk for the first time (accepting license, seeding admin password)"
sudo -u splunk /opt/splunk/bin/splunk start \
  --accept-license --answer-yes --no-prompt \
  --seed-passwd "${SPLUNK_ADMIN_PASS}"

log "Stopping the manually-started instance before handing off to boot-start"
sudo -u splunk /opt/splunk/bin/splunk stop
rm -f /opt/splunk/var/run/splunk/splunkd.pid

log "Enabling Splunk boot-start (systemd service, runs as 'splunk' user)"
/opt/splunk/bin/splunk enable boot-start -user splunk --accept-license --answer-yes --no-prompt

log "Starting Splunk via systemd"
systemctl start splunk

log "Verifying Splunk web interface (this can take up to a minute to come up)"
SPLUNK_UP=false
for i in $(seq 1 20); do
  if curl -sk --max-time 3 https://localhost:8000 2>/dev/null | grep -qi splunk; then
    SPLUNK_UP=true; SPLUNK_PROTO="https"; break
  fi
  if curl -s --max-time 3 http://localhost:8000 2>/dev/null | grep -qi splunk; then
    SPLUNK_UP=true; SPLUNK_PROTO="http"; break
  fi
  sleep 5
done

if [[ "${SPLUNK_UP}" == "true" ]]; then
  echo "Splunk web UI responded over ${SPLUNK_PROTO} on port 8000"
else
  warn "Splunk web UI didn't respond yet - give it another minute, then check: sudo -u splunk /opt/splunk/bin/splunk status"
fi

# ============================================================================
# 4. Optional firewall rules
# ============================================================================

if [[ "${ENABLE_FIREWALL}" == "true" ]]; then
  log "Configuring ufw"
  apt-get install -y ufw
  ufw allow OpenSSH
  ufw allow 80/tcp
  ufw allow 8000/tcp
  ufw --force enable
else
  log "Skipping firewall changes (ENABLE_FIREWALL=false). Mail is loopback-only regardless."
fi

# ============================================================================
# Summary
# ============================================================================

SERVER_IP="$(hostname -I | awk '{print $1}')"

cat <<SUMMARY

============================================================
  SETUP COMPLETE
============================================================

Apache2:
  http://${SERVER_IP}/   (or http://localhost/ on this box)

Mail (Postfix + Dovecot, LOOPBACK ONLY - not reachable from
other machines by design):
  Domain:      ${MAIL_DOMAIN}
  Test user:   ${MAIL_TEST_USER} / ${MAIL_TEST_PASS}
  Send a test: echo "hi" | mail -s "subject" ${MAIL_TEST_USER}@${MAIL_DOMAIN}
  IMAP:        127.0.0.1:143 (plaintext, no TLS configured)
  POP3:        127.0.0.1:110

Splunk Enterprise:
  http://${SERVER_IP}:8000/  or  https://${SERVER_IP}:8000/
  Login: ${SPLUNK_ADMIN_USER} / ${SPLUNK_ADMIN_PASS}

NOT production-ready as-is:
  - Dovecot allows plaintext auth, no TLS cert installed
  - Splunk admin password is the placeholder above - change it
    (Settings > Users) if this box will live for a while
  - Firewall changes were skipped unless you set ENABLE_FIREWALL=true
  - Splunk license is a 60-day trial; it converts to a free license
    after that, or you can apply a real license in Splunk Web

SUMMARY
