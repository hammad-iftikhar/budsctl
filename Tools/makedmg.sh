#!/usr/bin/env bash
#
# Build BudsCtl (Release) and package it as a drag-to-install DMG.
#
#   ./Tools/makedmg.sh
#
# hdiutil ships with macOS, so there is nothing to install and no dependency
# to keep current. Deliberately not create-dmg or a Ruby gem: a plain disk
# image with an /Applications symlink is what those wrap, and it is 30 lines.
#
# DISTRIBUTION CAVEAT: this adds no signature of its own. The app inside
# carries whatever identity built it. On a free personal Apple team that is an
# "Apple Development" certificate, which Gatekeeper will refuse on any Mac
# other than the one that built it. Giving this DMG to someone else needs a
# paid Developer ID Application certificate and notarisation -- see README.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
DERIVED="$ROOT/.build/xcode-release"
APP="$DERIVED/Build/Products/Release/BudsCtl.app"

echo "==> Generating project"
xcodegen generate >/dev/null

echo "==> Building Release"
xcodebuild -project BudsCtl.xcodeproj -scheme BudsCtl \
    -configuration Release -derivedDataPath "$DERIVED" build >/dev/null

[ -d "$APP" ] || { echo "error: no app at $APP" >&2; exit 1; }

VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
BUILD=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")
DMG="$ROOT/BudsCtl-$VERSION.dmg"

# Fail before packaging rather than shipping a broken bundle: a DMG that
# installs an app macOS refuses to launch is worse than no DMG.
echo "==> Verifying the app bundle"
codesign --verify --deep --strict "$APP"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
# The symlink is what makes the window a drag-to-install target.
ln -s /Applications "$STAGE/Applications"

echo "==> Creating $(basename "$DMG")"
rm -f "$DMG"
hdiutil create \
    -volname "BudsCtl $VERSION" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null

hdiutil verify "$DMG" >/dev/null

echo "==> Done: $DMG"
echo "    version $VERSION ($BUILD), $(du -h "$DMG" | cut -f1)"
