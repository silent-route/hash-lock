#!/bin/bash
# Package build/Hash Lock.app as a disk image for a release.
#
#   scripts/package-release.sh
#
# Writes to build/release/:
#   Hash-Lock-<version>.dmg          open it, drag Hash Lock to Applications
#   Hash-Lock-<version>.dmg.sha256   its checksum

set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=release.env
source scripts/release.env
APP="build/$APP_NAME.app"
OUT=build/release
[ -d "$APP" ] || { echo "build the app first: scripts/build-app.sh" >&2; exit 1; }
VERSION=$(defaults read "$PWD/$APP/Contents/Info.plist" HLVersion)
NAME="Hash-Lock-$VERSION.dmg"

# dmgbuild writes Finder's view settings itself, without scripting Finder;
# it is pinned with hashes in scripts/dmgbuild-requirements.txt.
DMGBUILD=${DMGBUILD:-build/dmgbuild/bin/dmgbuild}
if [ ! -x "$DMGBUILD" ]; then
  python3 -m venv build/dmgbuild
  build/dmgbuild/bin/pip install --quiet --require-hashes -r scripts/dmgbuild-requirements.txt
fi
[ -f Resources/dmg-background.png ] || swift scripts/make-dmg-background.swift Resources/dmg-background.png

rm -rf "$OUT"
mkdir -p "$OUT"
# A disk of the same name already open would make the new one "<name> 1"
# while it is built, and that name would end up in its Finder settings.
if [ -e "/Volumes/$APP_NAME $VERSION" ]; then
  echo "eject \"/Volumes/$APP_NAME $VERSION\" first" >&2
  exit 1
fi
"$DMGBUILD" -s scripts/dmg-settings.py -D app="$APP" -D background=Resources/dmg-background.png \
  -D icon=Resources/AppIcon.icns "$APP_NAME $VERSION" "$OUT/$NAME"

# Check the app as it will be installed: copied off the disk image, its
# signature must pass a strict check.
CHECK=$(mktemp -d)
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$CHECK/mnt" "$OUT/$NAME" >/dev/null
ditto "$CHECK/mnt/$APP_NAME.app" "$CHECK/$APP_NAME.app"
hdiutil detach -force "$CHECK/mnt" >/dev/null
codesign --verify --strict "$CHECK/$APP_NAME.app"
rm -rf "$CHECK"
(cd "$OUT" && shasum -a 256 "$NAME" > "$NAME.sha256")
ls -l "$OUT"
