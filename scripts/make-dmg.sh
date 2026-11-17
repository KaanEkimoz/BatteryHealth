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

# Sparkle appcast: one item for this version, signed with the EdDSA key that
# generate_keys stored in the login keychain (account "BatteryHealth").
# Attach build/appcast.xml to the same GitHub release as the DMG; the app
# reads releases/latest/download/appcast.xml.
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Resources/Info.plist)"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' Resources/Info.plist)"
SPARKLE_BIN="$(swift build -c release --arch arm64 --show-bin-path)/../../artifacts/sparkle/Sparkle/bin"
SIG="$("$SPARKLE_BIN/sign_update" --account BatteryHealth build/BatteryHealth.dmg)"
NOTES="${RELEASE_NOTES:-BatteryHealth $VERSION}"
cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>BatteryHealth</title>
    <item>
      <title>BatteryHealth $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <description><![CDATA[$NOTES]]></description>
      <enclosure url="https://github.com/KaanEkimoz/BatteryHealth/releases/download/v$VERSION/BatteryHealth.dmg"
                 type="application/octet-stream" $SIG />
    </item>
  </channel>
</rss>
XML
echo "Wrote build/appcast.xml (attach it and build/BatteryHealth.dmg to release v$VERSION)"
