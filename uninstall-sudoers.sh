#!/bin/sh
# Remove the KeepAwake passwordless rule. Toggles will ask for the admin
# password again, which is the default behavior.
#
# Usage: sudo sh uninstall-sudoers.sh

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo: sudo sh uninstall-sudoers.sh" >&2
    exit 1
fi

rm -f /etc/sudoers.d/keepawake
echo "OK — passwordless rule removed. Toggles will now prompt for the admin password."
