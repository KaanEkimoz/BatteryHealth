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

# Developer ID + hardened runtime when the certificate is in the keychain
# (needed for notarization); otherwise ad-hoc, enough to run locally.
IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
if [[ -n "$IDENTITY" ]]; then
    SIGN=(--force --sign "$IDENTITY" --options runtime --timestamp)
else
    SIGN=(--force --sign -)
fi
codesign "${SIGN[@]}" "$APP/Contents/Resources/batteryhealthd"
codesign "${SIGN[@]}" "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"
echo "Built $APP"

# `scripts/build.sh release --install` also copies the app into /Applications.
if [[ "${2:-}" == "--install" ]]; then
    pkill -x BatteryHealth 2>/dev/null || true
    rm -rf /Applications/BatteryHealth.app
    ditto "$APP" /Applications/BatteryHealth.app
    echo "Installed /Applications/BatteryHealth.app"
    open /Applications/BatteryHealth.app
fi
