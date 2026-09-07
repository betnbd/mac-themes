# Release 1.2.0

The version and build number are maintained in `scripts/Info.plist`.
The production and Preview identifiers remain distinct and stable to preserve
local permission continuity. Keep existing tags immutable.

## Validation

```sh
python3 scripts/verify-assets.py
zsh scripts/test.sh
zsh scripts/build.sh
zsh scripts/test-signing.sh
python3 scripts/verify-package.py
```

GitHub Actions runs asset validation, tests, an ad-hoc signed build and extracted
package verification on pushes to main, version tags and pull requests. Its ZIP
is a test artifact, not a notarized release. CI does not receive signing secrets.

Tests cover imports, restoration conflicts, accessibility navigation, wallpaper
persistence and Spaces, per-destination application results, failed applies across
restarts, font-mode transitions and interrupted font upgrades. Historical apply
writers live only in test fixtures and still exercise production restore code.
Live external app UI behavior needs checking against installed app versions.

`MAC_THEMES_VERIFY_LIVE_APPEARANCE=1` explicitly enables an otherwise disabled
macOS appearance test. It changes the real desktop using the normal backup path.
Do not set it in CI.

## Local packaging

The local build contains the executable, icon, 32 wallpapers, 16 font faces and
upstream licenses/provenance. It excludes source, tests, trash and credentials.
`replace-app.py` atomically replaces signed build products and archives the old
bundle outside the project. The default local signer preserves its identity.
`MAC_THEMES_SIGNING=adhoc` is for disposable CI builds only.

## Notarized distribution

Requires a valid **Developer ID Application** certificate and its private key,
and a notarytool keychain profile. The current development Mac has no valid
Developer ID identity; notarization cannot be completed until one is configured.

Commit the release source, tag that commit with the version in Info.plist, then:

```sh
DEVELOPER_ID_APPLICATION='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE='your-notarytool-profile' \
zsh scripts/release.sh
```

The script requires a clean checkout and matching version tag. It validates and
builds the app, signs a separate distribution copy with hardened runtime and a
secure timestamp, submits it to Apple, requires acceptance, staples the ticket,
checks Gatekeeper assessment and verifies the final ZIP. It writes the versioned
ZIP and SHA-256 checksum under `dist/`. It does not replace your installed app or
publish anything to GitHub. Notarization credentials stay in Keychain.

See Apple's [notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## State and compatibility

`application-results.json` records each destination's requested theme, last
confirmed applied theme and typed result. `previewThemeID` in app preferences is
independent of these records. Old `state.json` snapshots remain readable and
retain their original restore data. Pending ChatGPT applications update their
own result when completed after launch.

Fonts use a private `.mac-themes-fonts.json` ownership journal in
`~/Library/Fonts/MacThemes`. Upgrades accept the recorded current or previous
hash, making an interrupted pair replacement retryable. Identical untracked fonts
are usable but are not claimed as owned; differing untracked fonts are preserved.
