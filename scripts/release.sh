#!/usr/bin/env bash
# Archive, sign with Developer ID, notarize and staple Scribe.app.
#
# One-time setup:
#   1. Set DEVELOPMENT_TEAM in Config/Signing.xcconfig.
#   2. Store notary credentials:
#        xcrun notarytool store-credentials scribe-notary --apple-id you@example.com --team-id TEAMID
#
# Usage: scripts/release.sh            (output in build/release/)
set -euo pipefail

cd "$(dirname "$0")/.."
PROFILE="${NOTARY_PROFILE:-scribe-notary}"
OUT="build/release"
ARCHIVE="$OUT/Scribe.xcarchive"

rm -rf "$OUT"
mkdir -p "$OUT"

xcodegen generate
xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Release -archivePath "$ARCHIVE" archive
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT" -exportOptionsPlist scripts/ExportOptions.plist

APP="$OUT/Scribe.app"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -q "flags=.*runtime" || { echo "✗ Hardened runtime missing; notarization would fail."; exit 1; }

ditto -c -k --keepParent "$APP" "$OUT/Scribe.zip"
xcrun notarytool submit "$OUT/Scribe.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"

# Re-zip the stapled app for distribution.
rm "$OUT/Scribe.zip"
ditto -c -k --keepParent "$APP" "$OUT/Scribe.zip"
echo "Done: $OUT/Scribe.zip"
