#!/bin/zsh
# Build and notarize a distribution copy without replacing the local signing identity.
set -euo pipefail
cd "${0:A:h:h}"
: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to your Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"
[[ "$DEVELOPER_ID_APPLICATION" == 'Developer ID Application: '* ]] || { print -u2 'A Developer ID Application identity is required.'; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { print -u2 'Commit the release source before packaging.'; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' scripts/Info.plist)"
[[ "$(git rev-parse "v$VERSION^{commit}")" == "$(git rev-parse HEAD)" ]] || { print -u2 'The version tag must point to HEAD.'; exit 1; }
python3 scripts/verify-assets.py
zsh scripts/test.sh
MAC_THEMES_SIGNING=local zsh scripts/build.sh
STAGE="$(mktemp -d "$HOME/Library/Caches/MacThemes/release.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Mac Themes.app"
ditto "$HOME/Library/Caches/MacThemes/Products/Mac Themes.app" "$APP"
codesign --remove-signature "$APP"
codesign --force --sign "$DEVELOPER_ID_APPLICATION" --options runtime --timestamp --entitlements scripts/entitlements.plist "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --norsrc --keepParent "$APP" "$STAGE/submission.zip"
xcrun notarytool submit "$STAGE/submission.zip" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$STAGE/notarization.json"
python3 - "$STAGE/notarization.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization not accepted. Submission ID: ' + result.get('id', 'unknown'))
PY
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose "$APP"
OUTPUT="dist/Mac-Themes-$VERSION.zip"
ditto -c -k --norsrc --keepParent "$APP" "$OUTPUT"
python3 scripts/verify-package.py "$OUTPUT"
shasum -a 256 "$OUTPUT" > "$OUTPUT.sha256"
print "Verified notarized release: $OUTPUT"
