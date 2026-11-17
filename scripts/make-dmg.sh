#!/bin/bash
# Builds build/BatteryHealth-<version>.dmg: the app plus an Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build.sh release
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
DMG="build/BatteryHealth-$VERSION.dmg"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto build/app.noindex/BatteryHealth.app "$STAGE/BatteryHealth.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -quiet -volname "BatteryHealth" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"

# Sign and notarize when a Developer ID certificate and a notarytool profile exist.
# One-time setup: xcrun notarytool store-credentials BatteryHealth
IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
if [[ -n "$IDENTITY" ]]; then
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
    if xcrun notarytool history --keychain-profile BatteryHealth >/dev/null 2>&1; then
        xcrun notarytool submit "$DMG" --keychain-profile BatteryHealth --wait
        xcrun stapler staple "$DMG"
    else
        echo "Not notarized: run 'xcrun notarytool store-credentials BatteryHealth' once."
    fi
fi
# Same file under a fixed name, so the README's
# releases/latest/download/BatteryHealth.dmg link works for every version.
cp "$DMG" build/BatteryHealth.dmg
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
