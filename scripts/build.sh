#!/bin/bash
# Builds build/BatteryHealth.app (menu bar app with the daemon embedded).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG" --arch arm64
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

APP=build/BatteryHealth.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/BatteryHealth" "$APP/Contents/MacOS/BatteryHealth"
cp "$BIN/batteryhealthd" "$APP/Contents/Resources/batteryhealthd"
cp Resources/com.kaanusta.batteryhealth.daemon.plist "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: enough to run locally on Apple silicon.
codesign --force --sign - "$APP/Contents/Resources/batteryhealthd"
codesign --force --sign - "$APP"
echo "Built $APP"

# `scripts/build.sh release --install` also copies the app into /Applications.
if [[ "${2:-}" == "--install" ]]; then
    pkill -x BatteryHealth 2>/dev/null || true
    rm -rf /Applications/BatteryHealth.app
    ditto "$APP" /Applications/BatteryHealth.app
    echo "Installed /Applications/BatteryHealth.app"
    open /Applications/BatteryHealth.app
fi
