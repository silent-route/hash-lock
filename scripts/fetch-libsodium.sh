#!/bin/bash
# Build libsodium from its pinned release into Vendor/libsodium: the headers
# and one static library with both CPUs (arm64, x86_64).
#
#   scripts/fetch-libsodium.sh
#
# The tarball must match the SHA-256 in libsodium.pin, or nothing is built.
# Built without debug information, so no build paths end up in the app.

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(awk -F' *= *' '$1 == "version" {print $2}' libsodium.pin)
SHA256=$(awk -F' *= *' '$1 == "sha256" {print $2}' libsodium.pin)
MIN_OS="14.0"
OUT=Vendor/libsodium
NAME="libsodium-$VERSION"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "==> downloading $NAME"
curl -fsSL --retry 3 -o "$WORK/$NAME.tar.gz" \
  "https://download.libsodium.org/libsodium/releases/$NAME.tar.gz"
echo "$SHA256  $WORK/$NAME.tar.gz" | shasum -a 256 -c - >/dev/null \
  || { echo "checksum mismatch for $NAME.tar.gz" >&2; exit 1; }
tar -xzf "$WORK/$NAME.tar.gz" -C "$WORK"
SRC=$(find "$WORK" -maxdepth 1 -type d -name 'libsodium*' | head -1)

for arch in arm64 x86_64; do
  echo "==> building $arch"
  host=$([ "$arch" = arm64 ] && echo aarch64-apple-darwin || echo x86_64-apple-darwin)
  build="$WORK/build-$arch"
  mkdir -p "$build"
  (cd "$build" && \
    CFLAGS="-arch $arch -mmacosx-version-min=$MIN_OS -O2 -fno-common" \
    LDFLAGS="-arch $arch -mmacosx-version-min=$MIN_OS" \
    "$SRC/configure" --host="$host" --prefix="$build/prefix" \
      --disable-shared --enable-static --disable-dependency-tracking --disable-debug >/dev/null && \
    make -j"$(sysctl -n hw.ncpu)" >/dev/null && make install >/dev/null) \
    2> >(grep -v 'has no symbols' >&2)  # ranlib: the other CPU's files are empty
done

rm -rf "$OUT"
mkdir -p "$OUT/lib"
cp -R "$WORK/build-arm64/prefix/include" "$OUT/include"
lipo -create "$WORK/build-arm64/prefix/lib/libsodium.a" "$WORK/build-x86_64/prefix/lib/libsodium.a" \
  -output "$OUT/lib/libsodium.a"
cp "$SRC/LICENSE" "$OUT/LICENSE"
echo "$VERSION" > "$OUT/VERSION"
lipo -info "$OUT/lib/libsodium.a"
