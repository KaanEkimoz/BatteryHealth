#!/bin/bash
# Builds build/BatteryHealth-<version>.dmg: the app plus an Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build.sh release
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
DMG="build/BatteryHealth-$VERSION.dmg"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto build/BatteryHealth.app "$STAGE/BatteryHealth.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -quiet -volname "BatteryHealth" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
