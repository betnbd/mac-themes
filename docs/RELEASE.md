# Release 1.0.0

The version and build number are maintained in `scripts/Info.plist`.
The production and Preview identifiers remain distinct and stable to preserve
local permission continuity.

## Validation

Run these from the project root:

```sh
zsh scripts/test.sh
zsh scripts/build.sh
zsh scripts/test-signing.sh
unzip -t "dist/Mac Themes.zip"
```

The automated suite covers palette conversion, bounded imports, generated
configuration, restoration conflicts, accessibility navigation, wallpaper
library persistence and following Spaces. Live application appearance still
requires a manual check against the installed application versions; passing
unit tests does not verify every external application's UI.

The optional live macOS appearance test is disabled by default. Setting
`MAC_THEMES_VERIFY_LIVE_APPEARANCE=1` explicitly enables a test that applies the
saved theme to the actual desktop appearance using the normal backup mechanism.

## Packaging

`build.sh` assembles a fresh bundle with the executable, icon, 32 curated
wallpapers and upstream license/provenance. Source files, tests, development
reports and signing secrets are not bundled. `replace-app.py` validates signatures
and atomically replaces existing build products, archiving the previous bundle
outside the project under `~/Library/Caches/MacThemes/Archives/updates`.

The current build produces a locally signed ZIP, not a notarized public release.
Before posting a downloadable macOS app, sign the distribution bundle with a
Developer ID Application identity, notarize it with Apple, staple the accepted
ticket and rebuild the ZIP from that bundle. That distribution workflow is not
implemented by the local build script.
