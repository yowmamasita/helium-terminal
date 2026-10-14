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
STAGE=$(mktemp -d "$DEST/.helium-install.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto "build/Helium Terminal.app" "$STAGE/Helium Terminal.app"
BACKUP="$DEST/.Helium Terminal.app.backup.$$"
if [ -e "$APP" ]; then mv "$APP" "$BACKUP"; fi
if mv "$STAGE/Helium Terminal.app" "$APP"; then
  rm -rf "$BACKUP"
else
  [ -e "$BACKUP" ] && mv "$BACKUP" "$APP"
  exit 1
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
mdimport "$APP"
echo "installed $APP"
