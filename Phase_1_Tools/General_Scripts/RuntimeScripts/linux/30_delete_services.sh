#!/usr/bin/env bash
#
# purge-services.sh
# Nukes apache2, dovecot, postfix, and splunk from a Debian-based host:
# stops services, purges packages, deletes leftover config/data dirs,
# and removes the service users/groups.
#
# Run as root. Review before running on anything you care about —
# this is destructive and irreversible.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run this as root (sudo)." >&2
    exit 1
fi

echo "=== Stopping services ==="
for svc in apache2 dovecot postfix splunk; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
done

# Splunk usually isn't systemd-managed unless you ran
# `splunk enable boot-start`. Try its own control script too.
if [[ -x /opt/splunk/bin/splunk ]]; then
    /opt/splunk/bin/splunk stop || true
fi

echo "=== Purging apt packages ==="
apt-get purge -y \
    apache2 apache2-bin apache2-data apache2-utils \
    dovecot-core dovecot-imapd dovecot-pop3d dovecot-lmtpd dovecot-sieve dovecot-managesieved \
    postfix postfix-sqlite postfix-ldap postfix-pcre \
    2>/dev/null || true

apt-get autoremove --purge -y

echo "=== Removing leftover config/data directories ==="
rm -rf \
    /etc/apache2 \
    /var/www \
    /var/log/apache2 \
    /etc/dovecot \
    /var/lib/dovecot \
    /var/mail \
    /var/vmail \
    /var/log/dovecot* \
    /etc/postfix \
    /var/spool/postfix \
    /var/lib/postfix \
    /var/log/mail* \
    /opt/splunk \
    /opt/splunkforwarder \
    /var/log/splunk*

echo "=== Removing service users/groups ==="
for user in postfix dovecot dovenull splunk; do
    if id "$user" &>/dev/null; then
        deluser --remove-home "$user" 2>/dev/null || true
    fi
done

for group in postfix dovecot; do
    if getent group "$group" &>/dev/null; then
        delgroup "$group" 2>/dev/null || true
    fi
done

echo "=== Done. Everything's gone. ==="