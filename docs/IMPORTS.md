# Omarchy theme imports

The menu's import field accepts a public GitHub repository URL or either Omarchy install command:

```
https://github.com/example/omarchy-ocean-theme
omarchy-theme-install https://github.com/example/omarchy-ocean-theme.git
omarchy theme install https://github.com/example/omarchy-ocean-theme.git
```

Quoted URLs and public `git@github.com:owner/repository.git` addresses work too. SSH addresses are converted to HTTPS; the app does not read SSH keys or Git credentials. A GitHub folder URL such as `https://github.com/omacom/omarchy/tree/quattro/themes/nord` imports one theme from a larger repository. In a tree URL, the first segment after `tree` names the branch/tag/revision; percent-encode a slash inside a branch name.

The string is parsed as data. Chained commands, pipes, shell substitutions, flags, scripts, private repositories and other Git hosting providers are not supported. The app downloads palette data and images over HTTPS without cloning, running repository code, or executing the pasted command.

## Conversion

At the theme root, the importer uses the first available palette in this order:

1. `colors.toml`: current semantic colors, legacy `color0`–`color15`, and short aliases such as `bg`/`fg`.
2. `alacritty.toml`: primary, normal, bright, selection and cursor color tables.
3. `ghostty.conf`: background, foreground, selection, cursor and indexed palette values.

It validates six-digit RGB hex values and generates the app's existing `Theme` model. Semantic colors take priority over their legacy aliases. Explicit ANSI entries remain intact alongside semantic colors; for `colors.toml`, indices 0 and 7 follow the base background and foreground, matching Omarchy. Legacy terminal files retain distinct ANSI black and white even when their main background and foreground differ. Missing bright colors are mixed with white using Omarchy's 20% fallback. Appearance mode follows `mode`, then legacy `theme_type`, then the `light.mode` marker, then Omarchy's background brightness inference. A malformed palette produces an error before replacing an installed theme.

Only colors are converted from terminal configuration files. Font settings, shell commands, includes, Lua, JavaScript and installation hooks are never applied. Rendering fonts and gradients identically to the Linux desktop is outside palette conversion.

Images under `backgrounds/` or `wallpapers/` are included recursively, in natural filename order. Supported extensions are PNG, JPEG, WebP, HEIC, TIFF and GIF, with format signatures checked before saving. Git LFS pointer files are rejected with an explanation. Limits are 80 images, 40 MB per image, 250 MB total, and 256 KB per palette/license. Symlinks, path traversal, case-colliding filenames and redirects outside GitHub's API/raw hosts are rejected. Transfer buffers enforce their bounds even without a Content-Length header.

## Library and updates

`ThemeLibrary(directory:)` is an actor. Its public operations are:

- `installedThemes()` to read the library.
- `importTheme(_ input:)` to download or replace one import.
- `update(_ theme:)` to fetch that import's current branch/revision again.
- `selectWallpaper(_ relativePath: String?, themeID:)` to persist a background choice; `nil` means no selected background.

Each `ImportedTheme` stores its `Theme`, source URL, pinned Git commit, import time, wallpapers, selected wallpaper and immutable version directory. `wallpaperURL(_:in:)` and `selectedWallpaperURL(in:)` resolve the local images.

Downloads go to a staging directory. Only after every file succeeds does an atomic manifest write expose the new version. Failure or cancellation leaves the old manifest and version available. The selected wallpaper survives an update when its relative filename remains present; otherwise the first available wallpaper is selected. A deliberate `nil` selection remains `nil`. Earlier version folders remain so a desktop currently displaying an old image keeps a valid file path. There is no automatic repository polling or library deletion.

GitHub's unauthenticated API rate limit applies. Import errors name unavailable repositories, rate limits and unsupported content. The importer does not request credentials.

## Upstream references

- [Omarchy theme installer](https://github.com/omacom/omarchy/blob/quattro/bin/omarchy-theme-install): current `omarchy theme install` and legacy command implementation.
- [Omarchy palette resolver](https://github.com/omacom/omarchy/blob/quattro/bin/omarchy-theme-color): semantic aliases, mode and bright-color fallback.
- [Omarchy theming guide](https://github.com/omacom/omarchy/blob/quattro/docs/theming.md): palette-to-template workflow.
- [Omarchy manual: making a theme](https://github.com/omacom/omarchy/blob/quattro/manual/43-making-your-own-theme.md): repository distribution and current handling of code-bearing imported files.

The application downloads a repository's root license when one is supplied alongside its palette. Theme and wallpaper rights remain with their respective authors.
