#!/bin/bash
# Restores stock charging and removes the daemon. Run: sudo scripts/uninstall-daemon.sh
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
LABEL=com.kaanusta.batteryhealth.daemon
/Library/PrivilegedHelperTools/$LABEL reset 2>/dev/null
launchctl bootout system/$LABEL 2>/dev/null
rm -f /Library/LaunchDaemons/$LABEL.plist /Library/PrivilegedHelperTools/$LABEL
echo "Removed. Config left in /Library/Application Support/BatteryHealth"
