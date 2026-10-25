#!/bin/sh
# KeepAwake passwordless toggle installer.
#
# Allows exactly three pmset commands via sudo without a password:
#   pmset -a disablesleep 0
#   pmset -a disablesleep 1
#   pmset -a sleep 10
# No other sudo command is affected.
#
# Usage: sudo sh install-sudoers.sh

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo: sudo sh install-sudoers.sh" >&2
    exit 1
fi

# The user who should get passwordless access (works under both sudo and su)
TARGET_USER="${SUDO_USER:-$(id -un)}"

RULE="$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a sleep 10"

echo "$RULE" > /etc/sudoers.d/keepawake
chown root:wheel /etc/sudoers.d/keepawake
chmod 440 /etc/sudoers.d/keepawake

# Validate before leaving
visudo -c -f /etc/sudoers.d/keepawake

echo "OK — passwordless lid toggle installed for '$TARGET_USER'."
echo "Remove anytime with: sudo sh uninstall-sudoers.sh"
