#!/bin/bash
# Local code-signing identity, without a paid Apple Developer account.
#
#   source scripts/signing.sh      (defines sign_begin / sign_end / IDENTITY)
#
# The identity is a self-signed certificate with a private key, kept in its
# own keychain outside the repository:
#   ~/.hashlock-signing/signing.keychain-db   (password in .../password)
# It is created on first use.
#
# Keep it: macOS ties the app's sandbox container — where the vault lives —
# to the signature. A build signed with another certificate is a different
# app to macOS, which then asks before letting it at the old data. Back up
# ~/.hashlock-signing, and give the release workflow the same identity
# (see .github/workflows/release.yml).

SIGN_DIR="$HOME/.hashlock-signing"
SIGN_KC="$SIGN_DIR/signing.keychain-db"
SIGN_NAME="Hash Lock Local Signing"

_sign_create() {
  mkdir -p "$SIGN_DIR"
  chmod 700 "$SIGN_DIR"
  local pw tmp
  pw=$(openssl rand -hex 16)
  printf '%s' "$pw" > "$SIGN_DIR/password"
  chmod 600 "$SIGN_DIR/password"
  tmp=$(mktemp -d)
  cat > "$tmp/cert.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$SIGN_NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
  openssl req -x509 -newkey rsa:3072 -nodes -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
    -days 7300 -config "$tmp/cert.cnf" 2>/dev/null
  # Legacy PBE/MAC: macOS `security` cannot import OpenSSL 3's defaults.
  openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" \
    -passout "pass:$pw" -name "$SIGN_NAME" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null
  # The same identity as a .p12, for the release workflow's secret.
  cp "$tmp/id.p12" "$SIGN_DIR/identity.p12"
  chmod 600 "$SIGN_DIR/identity.p12"
  security create-keychain -p "$pw" "$SIGN_KC"
  security set-keychain-settings "$SIGN_KC"          # no auto-lock
  security unlock-keychain -p "$pw" "$SIGN_KC"
  security import "$tmp/id.p12" -k "$SIGN_KC" -P "$pw" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k "$pw" "$SIGN_KC" >/dev/null
  rm -rf "$tmp"
  echo "created signing identity in $SIGN_KC"
}

# The release workflow has no ~/.hashlock-signing: it gets the same
# identity from two repository secrets, HL_SIGNING_P12 (identity.p12 in
# base64) and HL_SIGNING_PASSWORD (its password), and puts it in a keychain
# of its own.
_sign_import() {
  mkdir -p "$SIGN_DIR"
  chmod 700 "$SIGN_DIR"
  printf '%s' "$HL_SIGNING_PASSWORD" > "$SIGN_DIR/password"
  chmod 600 "$SIGN_DIR/password"
  local tmp
  tmp=$(mktemp -d)
  printf '%s' "$HL_SIGNING_P12" | base64 --decode > "$tmp/id.p12"
  security create-keychain -p "$HL_SIGNING_PASSWORD" "$SIGN_KC"
  security set-keychain-settings "$SIGN_KC"
  security unlock-keychain -p "$HL_SIGNING_PASSWORD" "$SIGN_KC"
  security import "$tmp/id.p12" -k "$SIGN_KC" -P "$HL_SIGNING_PASSWORD" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k "$HL_SIGNING_PASSWORD" "$SIGN_KC" >/dev/null
  rm -rf "$tmp"
}

_SIGN_SAVED_LIST=""

# Unlock the keychain and put it on the search list for codesign.
sign_begin() {
  if [ ! -f "$SIGN_KC" ]; then
    if [ -n "${HL_SIGNING_P12:-}" ]; then _sign_import; else _sign_create; fi
  fi
  security unlock-keychain -p "$(cat "$SIGN_DIR/password")" "$SIGN_KC"
  _SIGN_SAVED_LIST=$(security list-keychains -d user | tr -d '"' | xargs)
  # shellcheck disable=SC2086
  security list-keychains -d user -s $_SIGN_SAVED_LIST "$SIGN_KC"
  IDENTITY=$(security find-identity -p codesigning "$SIGN_KC" | awk '/1\)/ {print $2; exit}')
  [ -n "$IDENTITY" ] || { echo "no signing identity in $SIGN_KC" >&2; return 1; }
}

# Restore the user's keychain search list exactly as it was.
sign_end() {
  # shellcheck disable=SC2086
  [ -n "$_SIGN_SAVED_LIST" ] && security list-keychains -d user -s $_SIGN_SAVED_LIST
  _SIGN_SAVED_LIST=""
}
