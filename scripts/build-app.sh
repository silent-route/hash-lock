#!/bin/bash
# Build build/Hash Lock.app — one universal bundle for Intel and Apple Silicon.
#
#   scripts/build-app.sh            release build
#   scripts/build-app.sh --debug    debug build (faster, unoptimized)
#
# Needs only the Command Line Tools: each architecture is compiled separately
# with --triple and merged with lipo, so no Xcode build system is involved.
# The binary is stripped of debug information (which would carry build
# paths) and signed with the hardened runtime and the App Sandbox.

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
[ "${1:-}" = "--debug" ] && CONFIG=debug

# shellcheck source=release.env
source scripts/release.env
# The release version comes from the latest tag (v1.2.3-beta) unless
# HL_VERSION says otherwise. FULL_VERSION may carry a pre-release suffix;
# macOS wants only the numbers in CFBundleShortVersionString.
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
FULL_VERSION=${HL_VERSION:-${LAST_TAG#v}}
FULL_VERSION=${FULL_VERSION:-1.0.0-dev}
SHORT_VERSION=${FULL_VERSION%%-*}
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)

[ -f Vendor/libsodium/lib/libsodium.a ] || scripts/fetch-libsodium.sh

for arch in arm64 x86_64; do
  echo "==> building $arch ($CONFIG)"
  swift build -c "$CONFIG" --triple "$arch-apple-macosx$MIN_OS" --product "$EXECUTABLE" 2>&1 \
    | grep -vE '^\[[0-9]+/[0-9]+\]' || true
  [ -x ".build/$arch-apple-macosx/$CONFIG/$EXECUTABLE" ] || { echo "build ($arch) failed" >&2; exit 1; }
done

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

lipo -create ".build/arm64-apple-macosx/$CONFIG/$EXECUTABLE" ".build/x86_64-apple-macosx/$CONFIG/$EXECUTABLE" \
  -output "$APP/Contents/MacOS/$EXECUTABLE"
strip -S -x "$APP/Contents/MacOS/$EXECUTABLE"

cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Vendor/libsodium/LICENSE "$APP/Contents/Resources/libsodium-LICENSE"
cp Resources/BIP39-LICENSE LICENSE "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>                 <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>          <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>           <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>           <string>$EXECUTABLE</string>
  <key>CFBundleIconFile</key>             <string>AppIcon</string>
  <key>CFBundlePackageType</key>          <string>APPL</string>
  <key>CFBundleShortVersionString</key>   <string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key>              <string>$BUILD</string>
  <key>HLVersion</key>                    <string>$FULL_VERSION</string>
  <key>LSMinimumSystemVersion</key>       <string>$MIN_OS</string>
  <key>LSApplicationCategoryType</key>    <string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key>      <true/>
  <key>NSPrincipalClass</key>             <string>NSApplication</string>
  <key>NSHumanReadableCopyright</key>     <string>Hash Lock</string>
  <!-- .hashlock: a vault in one file, still encrypted. Double-click imports it. -->
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key>         <string>$BUNDLE_ID.vault</string>
      <key>UTTypeDescription</key>        <string>Hash Lock Vault</string>
      <key>UTTypeConformsTo</key>         <array><string>public.data</string></array>
      <key>UTTypeIconFile</key>           <string>AppIcon</string>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>hashlock</string></array></dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>         <string>Hash Lock Vault</string>
      <key>CFBundleTypeRole</key>         <string>Viewer</string>
      <key>LSHandlerRank</key>            <string>Owner</string>
      <key>LSItemContentTypes</key>       <array><string>$BUNDLE_ID.vault</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# shellcheck source=signing.sh
source scripts/signing.sh
sign_begin
trap sign_end EXIT
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
  --entitlements Resources/HashLock.entitlements "$APP"
codesign --verify --strict "$APP"

# Nothing in the bundle may name the machine it was built on.
if strings -a "$APP/Contents/MacOS/$EXECUTABLE" | grep -qE "$HOME|/Users/|/private/var/folders"; then
  echo "the binary contains a local path:" >&2
  strings -a "$APP/Contents/MacOS/$EXECUTABLE" | grep -E "$HOME|/Users/|/private/var/folders" | head >&2
  exit 1
fi

echo "==> $APP ($FULL_VERSION, build $BUILD)"
lipo -info "$APP/Contents/MacOS/$EXECUTABLE"
