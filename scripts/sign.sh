#!/bin/zsh
# A persistent, local-only signing identity keeps this app recognizable on updates.
# No trust settings or macOS privacy permissions are changed by this script.
set -euo pipefail
umask 077
APP="${1:?Usage: sign.sh path/to/app}"
case "${MAC_THEMES_SIGNING:-local}" in
  adhoc)
    codesign --force --sign - --entitlements "${0:A:h}/entitlements.plist" "$APP"
    codesign --verify --deep --strict "$APP"
    exit 0 ;;
  local) ;;
  *) print -u2 'Unknown signing mode; use local or adhoc.'; exit 1 ;;
esac
SIGNING_DIR="$HOME/Library/Application Support/Mac Themes Signing"
KEYCHAIN="$SIGNING_DIR/local-signing.keychain-db"
CERTIFICATE="$SIGNING_DIR/certificate.pem"
PASSWORD_FILE="$SIGNING_DIR/keychain-password"
IDENTITY="Mac Themes Local Signing"
mkdir -p "$SIGNING_DIR"
chmod 700 "$SIGNING_DIR"
if [[ ! -f "$KEYCHAIN" ]]; then
  if [[ -f "$CERTIFICATE" || -f "$PASSWORD_FILE" ]]; then
    print -u2 'Signing setup is incomplete. Keep the existing identity files and repair the keychain; do not generate a replacement.'
    exit 1
  fi
  openssl rand -base64 32 > "$PASSWORD_FILE"
  SIGNING_PASSWORD="$(cat "$PASSWORD_FILE")"
  STAGE="$(mktemp -d "$SIGNING_DIR/setup.XXXXXX")"
  trap 'rm -rf "$STAGE"' EXIT
  openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
    -subj "/CN=$IDENTITY/" -keyout "$STAGE/private.pem" -out "$CERTIFICATE" \
    -addext 'basicConstraints=critical,CA:FALSE' \
    -addext 'keyUsage=critical,digitalSignature' \
    -addext 'extendedKeyUsage=critical,codeSigning' 2>/dev/null
  openssl pkcs12 -export -legacy -inkey "$STAGE/private.pem" -in "$CERTIFICATE" \
    -name "$IDENTITY" -out "$STAGE/identity.p12" -passout "file:$PASSWORD_FILE"
  # Keep the user's existing keychain search list unchanged.
  SAVED_KEYCHAINS=(${(z)$(security list-keychains -d user)})
  SAVED_KEYCHAINS=("${(@Q)SAVED_KEYCHAINS}")
  security create-keychain -p "$SIGNING_PASSWORD" "$KEYCHAIN"
  security list-keychains -d user -s "${SAVED_KEYCHAINS[@]}"
  security import "$STAGE/identity.p12" -k "$KEYCHAIN" -P "$SIGNING_PASSWORD" -x -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k "$SIGNING_PASSWORD" "$KEYCHAIN" >/dev/null
  security set-keychain-settings -t 300 -l "$KEYCHAIN"
  rm -rf "$STAGE"
  trap - EXIT
fi
SIGNING_PASSWORD="$(cat "$PASSWORD_FILE")"
security unlock-keychain -p "$SIGNING_PASSWORD" "$KEYCHAIN"
trap 'security lock-keychain "$KEYCHAIN"' EXIT
FINGERPRINT="$(openssl x509 -in "$CERTIFICATE" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
[[ "$BUNDLE_ID" == local.macthemes.launcher || "$BUNDLE_ID" == local.macthemes.preview ]] || exit 1
# Bind identity to both this certificate and the bundle, never the identifier alone.
codesign --force --sign "$FINGERPRINT" --keychain "$KEYCHAIN" --timestamp=none \
  --requirements "=designated => identifier \"$BUNDLE_ID\" and certificate leaf = H\"$FINGERPRINT\"" \
  --entitlements "${0:A:h}/entitlements.plist" "$APP"
codesign --verify --deep --strict "$APP"
