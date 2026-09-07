#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
BUILD="$HOME/Library/Caches/MacThemes/Build"
swift build --scratch-path "$BUILD" -c release
BIN="$(swift build --scratch-path "$BUILD" -c release --show-bin-path)"
STAGE="$(mktemp -d "$HOME/Library/Caches/MacThemes/bundle.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Mac Themes.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MacThemes" "$APP/Contents/MacOS/MacThemes"
cp scripts/Info.plist "$APP/Contents/Info.plist"
zsh scripts/build-icon.sh "$APP/Contents/Resources/AppIcon.icns"
cp Vendor/Omarchy/LICENSE "$APP/Contents/Resources/Omarchy-LICENSE.txt"
cp Vendor/Omarchy/origin.json "$APP/Contents/Resources/Omarchy-origin.json"
cp Vendor/Omarchy/backgrounds-origin.json "$APP/Contents/Resources/Omarchy-backgrounds-origin.json"
# Bundle only the curated collection.
for THEME_NAME in tokyo-night gruvbox osaka-jade hackerman catppuccin solitude everforest; do
  THEME_DIR="Vendor/Omarchy/$THEME_NAME/backgrounds"
  mkdir -p "$APP/Contents/Resources/BuiltinWallpapers/$THEME_NAME"
  ditto "$THEME_DIR" "$APP/Contents/Resources/BuiltinWallpapers/$THEME_NAME"
done
ditto Vendor/NerdFonts "$APP/Contents/Resources/NerdFonts"
zsh scripts/sign.sh "$APP"
mkdir -p dist
ditto -c -k --norsrc --keepParent "$APP" "dist/Mac Themes.zip"
PREVIEW="$STAGE/Mac Themes Preview.app"
ditto "$APP" "$PREVIEW"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.macthemes.preview' "$PREVIEW/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Mac Themes Preview' "$PREVIEW/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :MacThemesPreview bool true' "$PREVIEW/Contents/Info.plist"
zsh scripts/sign.sh "$PREVIEW"
python3 scripts/replace-app.py "$APP" "$HOME/Library/Caches/MacThemes/Products/Mac Themes.app"
python3 scripts/replace-app.py "$PREVIEW" "$HOME/Library/Caches/MacThemes/Products/Mac Themes Preview.app"
printf 'Built %s\n' "$HOME/Library/Caches/MacThemes/Products/Mac Themes.app"
