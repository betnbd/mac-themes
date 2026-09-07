# Mac Themes

A native macOS menu-bar app for coordinating wallpapers and application colors.
Version **1.2.0** includes seven themes and 32 wallpapers: Tokyo Night, Gruvbox,
Osaka Jade, Hackerman, Catppuccin Mocha, Solitude and Everforest.

## Get started

1. Open Mac Themes from the menu bar and choose a theme and wallpaper.
2. Open **Setup & status** and select the applications you want to change.
3. Browse themes and wallpapers to preview them, then press **Apply** to change
   your enabled destinations. Selecting a theme never applies it automatically.

The **…** menu provides setup, theme imports, the theme library and restoration.
Each destination reports its own result and any remaining setup step. Results are
recorded independently as applied, pending or failed. A failed attempt never
replaces a destination's last successful theme; browsing is saved separately.

| Destination | Setup and behavior |
| --- | --- |
| Ghostty | Writes a managed palette and requests a live configuration reload. If unavailable, use Reload Configuration or reopen Ghostty. |
| Obsidian | Choose your vaults, apply, then enable **mac-themes** under Settings → Appearance → CSS snippets. Subsequent changes refresh automatically. |
| Brave | Enable Developer mode at `brave://extensions` and grant Mac Themes Accessibility permission. Apply opens Brave if necessary; keep it focused while its native theme loader runs. |
| ChatGPT | Grant Accessibility permission. Mac Themes uses the app's Appearance import controls; a pending theme applies when the app opens. Requires the English interface with custom theme import. Manual copy/import is also available. |
| Wallpaper | Applies to connected displays and follows Spaces as you visit them while Mac Themes stays open. |
| macOS appearance | Optional light/dark mode, nearest native accent and custom highlight where supported. |

Obsidian community themes and other snippets may affect the resulting colors.
Brave themes change browser chrome; websites and new-tab backgrounds have their
own settings. Native macOS controls determine which system colors can change.
On macOS builds where custom highlight is unavailable, the app reports the
limitation and still applies light/dark mode and the native accent.

See [permissions and signing](docs/SIGNING-AND-PERMISSIONS.md) if an application
cannot be controlled.

## Fonts

Choose a font beneath the theme preview. Each theme remembers its own selection;
font choices only take effect when you click **Apply**. The sample text previews
the selected face immediately. **Keep unchanged** preserves the current font,
including a font previously applied by Mac Themes. **Use app default** resets
managed typography to each application's built-in defaults. A named font
explicitly changes the supported typography in enabled applications.

The curated Nerd Font choices are JetBrains Mono, Fira Code, Hack, Iosevka,
Cascadia Code, Meslo LG S, IBM Plex Mono and Source Code Pro. Each family includes
only Regular and Bold in the Mono variant. Menlo and Monaco use macOS's installed
fonts. No full font packages are installed.

Fonts apply to Ghostty, Obsidian's interface/text/code and ChatGPT's code font.
ChatGPT's interface font is preserved. Brave and macOS system appearance do not
expose fonts through their theme adapters. The selected Nerd family's two files
are installed on Apply only when Ghostty, Obsidian or ChatGPT is enabled, in
`~/Library/Fonts/MacThemes`; they remain available if
you quit or restore the theme. Some apps may need reopening to discover a newly
installed font. Theme restoration uses the existing settings backups.

A font ownership journal allows safe upgrades of files installed by this version.
Independently installed, modified or untracked older font files are preserved.
The full eight-family collection remains bundled for offline use; only the family
you apply is installed on your Mac.

The bundled fonts and their individual licenses come from
[Nerd Fonts](https://www.nerdfonts.com/font-downloads). The pinned upstream commit
and file checksums are recorded in `Vendor/NerdFonts/origin.json`.

## Manage wallpapers and themes

Click **Add…** to select multiple images, or drag image files from Finder onto the
wallpaper section. Use the minus button to remove the selected image, or
right-click a thumbnail and choose **Remove from theme**. **Undo removal** and
**Restore removed** bring images back. Original files are never deleted, and
personal additions and removals survive theme updates.

**Import Omarchy theme…** accepts a public GitHub repository URL or an Omarchy
install command. Imports read palette data and images without executing scripts.
Downloads happen only when importing or updating a theme. See
[import formats and limits](docs/IMPORTS.md).

## Restore and storage

**Restore previous appearance** restores settings owned by Mac Themes while
preserving unrelated edits. Conflicting settings retain their backups for review.
Remove Brave's installed theme through **Reset to default** in Brave's Appearance
settings. Manual ChatGPT imports remain managed in ChatGPT itself.

Wallpaper restoration works on visible desktops first. Keep Mac Themes open and
visit other Spaces or reconnect displays to finish restoring their backgrounds.
Separately changed wallpapers are preserved. Compatibility with restore backups
from earlier builds is retained.

Settings, imported themes, personal wallpapers and backups live under
`~/Library/Application Support/Mac Themes`. Keep that directory until you have
restored any changes you want to undo.

The app uses SwiftUI and AppKit without an embedded browser or idle polling.
You can quit after applying a theme; keep it open to follow Spaces and displays
or apply a pending ChatGPT theme on launch.

## Build and validate

Requires macOS 15 or later and a Swift 6 toolchain.

```sh
zsh scripts/test.sh
zsh scripts/build.sh
zsh scripts/test-signing.sh
open "$HOME/Library/Caches/MacThemes/Products/Mac Themes.app"
```

The build produces **Mac Themes.app**, an isolated **Mac Themes Preview.app** in
`~/Library/Caches/MacThemes/Products`, and `dist/Mac Themes.zip`. Quit older app
instances before opening a new build. The standalone Preview app uses a temporary
library and does not change other applications or the desktop. The normal app's
**Open preview window** command opens its real controls, including Apply.

Builds use a persistent local signing identity. **The ZIP is locally signed and
is not notarized for public distribution.** See [release notes](docs/RELEASE.md)
for validation and packaging details.

## Source layout

- `Sources/ThemeCore`: palettes, catalog and bounded GitHub imports.
- `Sources/MacThemes`: native UI, apply coordinator, font/wallpaper libraries, application adapters and restoration.
- `Tests`: palette, import, UI logic, integration and backup regression tests; historical writers are test-only fixtures.
- `Assets`: app icon source; the menu-bar symbol is drawn in `BrandIcon.swift`.
- `Vendor/Omarchy`: upstream palettes, wallpapers, license and revision metadata.
- `Vendor/NerdFonts`: 16 font faces, individual licenses and pinned checksums.
- `scripts`: build, signing, icon generation, atomic app replacement and validation.

The catalog retains two earlier palettes for compatibility and regression tests;
only the seven curated themes and their wallpapers are packaged.
Upstream revisions and attribution are recorded in `Vendor/Omarchy/origin.json`,
`Vendor/Omarchy/backgrounds-origin.json` and `Vendor/Omarchy/LICENSE`.
Theme and wallpaper rights remain with their respective authors.

Apply saves Ghostty and Obsidian settings even while they are closed. Brave and
ChatGPT open automatically when needed to apply through their appearance controls.
They remain open afterward. Browsing themes never launches applications.
