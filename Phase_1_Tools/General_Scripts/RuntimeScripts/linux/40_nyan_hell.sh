#!/usr/bin/env bash
#
# install-nyanload.sh
# Builds ohnx/nyan-load, installs it to the EFI System Partition,
# sets it as the default boot entry, and reboots.
#
# Requires: UEFI boot mode (not legacy BIOS), an accessible ESP.
# Run as root.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run this as root (sudo)." >&2
    exit 1
fi

if [[ ! -d /sys/firmware/efi ]]; then
    echo "This system isn't booted in UEFI mode — nyan-load won't work here." >&2
    exit 1
fi

echo "=== Installing build deps ==="
apt-get update
apt-get install -y build-essential gnu-efi git efibootmgr

WORKDIR=$(mktemp -d)
cd "$WORKDIR"

echo "=== Cloning nyan-load ==="
git clone https://github.com/ohnx/nyan-load.git
cd nyan-load

echo "=== Building ==="
make

if [[ ! -f nyan-load.efi ]]; then
    echo "Build didn't produce nyan-load.efi, aborting." >&2
    exit 1
fi

# Find the ESP mountpoint (commonly /boot/efi on Debian).
ESP_MOUNT=$(findmnt -n -o TARGET /boot/efi 2>/dev/null || true)
if [[ -z "$ESP_MOUNT" ]]; then
    echo "Couldn't find the ESP mounted at /boot/efi. Mount it and rerun." >&2
    exit 1
fi

ESP_DEV=$(findmnt -n -o SOURCE /boot/efi)
ESP_DISK=$(lsblk -no PKNAME "$ESP_DEV")
ESP_PARTNUM=$(cat "/sys/class/block/$(basename "$ESP_DEV")/partition")

echo "=== Installing nyan-load.efi to the ESP ==="
mkdir -p "$ESP_MOUNT/EFI/nyanload"
cp nyan-load.efi "$ESP_MOUNT/EFI/nyanload/nyan-load.efi"

echo "=== Registering boot entry and setting it as default ==="
efibootmgr --create \
    --disk "/dev/$ESP_DISK" \
    --part "$ESP_PARTNUM" \
    --label "nyan-load" \
    --loader '\EFI\nyanload\nyan-load.efi'

NEW_ENTRY=$(efibootmgr | grep "nyan-load" | grep -oP '(?<=Boot)[0-9A-Fa-f]{4}' | head -1)
efibootmgr --bootorder "$NEW_ENTRY"

echo "=== Done. Rebooting now. ==="
reboot