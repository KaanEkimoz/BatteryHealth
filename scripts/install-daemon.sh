#!/bin/bash
# Installs only the root daemon (no app). Run: sudo scripts/install-daemon.sh
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
LABEL=com.kaanusta.batteryhealth.daemon
BIN="$(sudo -u "${SUDO_USER:-$USER}" swift build -c release --arch arm64 --show-bin-path)"
[ -x "$BIN/batteryhealthd" ] || { echo "build first: swift build -c release"; exit 1; }
launchctl bootout system/$LABEL 2>/dev/null || true
install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools "/Library/Application Support/BatteryHealth"
install -o root -g wheel -m 755 "$BIN/batteryhealthd" /Library/PrivilegedHelperTools/$LABEL
install -o root -g wheel -m 644 Resources/$LABEL.plist /Library/LaunchDaemons/$LABEL.plist
launchctl bootstrap system /Library/LaunchDaemons/$LABEL.plist
echo "Installed. Logs: /var/log/batteryhealthd.log"
