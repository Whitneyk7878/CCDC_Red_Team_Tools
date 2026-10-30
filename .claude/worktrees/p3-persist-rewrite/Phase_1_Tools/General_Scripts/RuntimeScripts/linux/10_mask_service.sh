#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run this as root (sudo)." >&2
    exit 1
fi

# HTTP
systemctl mask apache2

# Mail
systemctl mask dovecot
systemctl mask postfix

# Splunk
systemctl mask splunkd

# A little whimsy
wall "meow meow meow meow meow meow meow meow we are in your walls meow meow meow meow"
