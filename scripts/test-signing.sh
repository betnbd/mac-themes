#!/bin/zsh
# Verify identity continuity across changed builds without launching either app.
set -euo pipefail
cd "${0:A:h:h}"
APP="$HOME/Library/Caches/MacThemes/Products/Mac Themes.app"
STAGE="$(mktemp -d "$HOME/Library/Caches/MacThemes/signing-check.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
FIRST="$STAGE/First.app"
SECOND="$STAGE/Second.app"
ditto "$APP" "$FIRST"
ditto "$APP" "$SECOND"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 999' "$SECOND/Contents/Info.plist"
zsh scripts/sign.sh "$SECOND"
FIRST_REQUIREMENT="$(codesign -d -r- "$FIRST" 2>&1 | sed -n 's/^designated => //p')"
SECOND_REQUIREMENT="$(codesign -d -r- "$SECOND" 2>&1 | sed -n 's/^designated => //p')"
[[ -n "$FIRST_REQUIREMENT" && "$FIRST_REQUIREMENT" == "$SECOND_REQUIREMENT" ]]
[[ "$FIRST_REQUIREMENT" == *'certificate leaf ='* && "$FIRST_REQUIREMENT" != *cdhash* ]]
FIRST_HASH="$(codesign -dvvv "$FIRST" 2>&1 | sed -n 's/^CDHash=//p')"
SECOND_HASH="$(codesign -dvvv "$SECOND" 2>&1 | sed -n 's/^CDHash=//p')"
[[ -n "$FIRST_HASH" && "$FIRST_HASH" != "$SECOND_HASH" ]]
codesign --verify --deep --strict --test-requirement "=$FIRST_REQUIREMENT" "$SECOND"
# Sharing a certificate does not let Preview impersonate the permission-bearing app.
PREVIEW="$HOME/Library/Caches/MacThemes/Products/Mac Themes Preview.app"
if codesign --verify --test-requirement "=$FIRST_REQUIREMENT" "$PREVIEW" >/dev/null 2>&1; then
  print -u2 'Preview unexpectedly satisfies the normal app identity.'
  exit 1
fi
print 'PASS: different build hashes retain the same certificate-bound identity; Preview is distinct.'
