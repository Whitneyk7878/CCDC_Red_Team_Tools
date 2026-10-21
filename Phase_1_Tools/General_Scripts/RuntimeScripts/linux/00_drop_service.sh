#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run this as root (sudo)." >&2
    exit 1
fi

# HTTP
systemctl stop apache2 2>/dev/null || true
systemctl disable apache2 2>/dev/null || true

# Mail
systemctl stop dovecot 2>/dev/null || true
systemctl disable dovecot 2>/dev/null || true

systemctl stop postfix 2>/dev/null || true
systemctl disable postfix 2>/dev/null || true

# Splunk
systemctl stop splunkd 2>/dev/null || true
systemctl disable splunkd 2>/dev/null || true
