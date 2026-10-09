#!/bin/sh
# Builds "build/Helium Terminal.app". Run scripts/build-ghostty.sh first.
#
#   SIGN_IDENTITY="Developer ID Application: ..." scripts/build-app.sh
#
# Without SIGN_IDENTITY the app is ad-hoc signed, which is fine for local use.
set -eu
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
swift build -c release
APP="build/Helium Terminal.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/helium-terminal "$APP/Contents/MacOS/helium-terminal"
strip "$APP/Contents/MacOS/helium-terminal"
sed "s/__VERSION__/$VERSION/g" packaging/Info.plist > "$APP/Contents/Info.plist"
cp packaging/Helium.icns "$APP/Contents/Resources/Helium.icns"
# libghostty finds its resources by locating terminfo/78/xterm-ghostty next to the binary.
SHARE=vendor/ghostty/zig-out/share
cp -R "$SHARE/terminfo" "$APP/Contents/Resources/terminfo"
mkdir -p "$APP/Contents/Resources/ghostty"
# Themes (2.6 MB) are left out; put any you use in ~/.config/ghostty/themes.
cp -R "$SHARE/ghostty/shell-integration" "$APP/Contents/Resources/ghostty/"

if [ -n "${SIGN_IDENTITY:-}" ]; then
  # Hardened runtime and a secure timestamp are what notarization requires.
  codesign --force --options runtime --timestamp --entitlements packaging/Helium.entitlements \
    --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - --entitlements packaging/Helium.entitlements "$APP"
fi
codesign --verify --strict "$APP"
du -sh "$APP"
