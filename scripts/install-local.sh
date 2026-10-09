#!/bin/sh
# Builds Helium and installs it to /Applications (or ~/Applications if that isn't
# writable), so Spotlight, Raycast and Alfred can find it. A running Helium keeps
# going; the new build starts on its next launch.
set -eu
cd "$(dirname "$0")/.."
scripts/build-app.sh
DEST=/Applications
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
APP="$DEST/Helium Terminal.app"
rm -rf "$APP"
ditto "build/Helium Terminal.app" "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
mdimport "$APP"
echo "installed $APP"
