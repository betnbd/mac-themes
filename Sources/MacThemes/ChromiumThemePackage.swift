import Foundation
import ThemeCore

/// Standard Chromium theme package. It contains data only, no executable code
/// or permissions. Browser installation remains an explicit browser action.
enum ChromiumThemePackage {
    /// A fresh path gives an unpacked theme a fresh Chromium extension ID.
    /// Reloading an older path preserves its disabled state after switching
    /// themes; updating the current ID also suppresses the install infobar.
    /// Immutable, data-only copies keep activation and acknowledgement reliable
    /// for A → B → A and A → A without editing browser preferences.
    static func exportForActivation(theme: Theme, root: URL) throws -> URL {
        let directory = root.appendingPathComponent("Exports/Chromium/Installations", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try write(theme, to: directory)
        return directory
    }

    static func export(theme: Theme, root: URL) throws -> URL {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let component = String(theme.id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }.prefix(80))
        let directory = root.appendingPathComponent("Exports/Chromium", isDirectory: true)
            .appendingPathComponent(component.isEmpty ? "theme" : component, isDirectory: true)
        try write(theme, to: directory)
        return directory
    }

    static func manifest(_ theme: Theme) throws -> Data {
        func rgb(_ hex: String) -> [Int] { ScriptLiteral.rgb(hex).map { $0 / 257 } }
        // The bundled palette's darker surface separates inactive tabs from the
        // toolbar. Other palettes keep their own background unchanged.
        let frame = theme.id == "tokyo-night" && theme.background.lowercased() == "#1a1b26" ? "#13141c" : theme.background
        // Terminal selection colors can be bright accents (e.g. The Navigator's
        // gold), not readable input surfaces with the palette's normal text.
        let foreground = rgb(theme.foreground)
        let selection = rgb(theme.selection)
        let background = rgb(theme.background)
        let omnibox = contrast(foreground, selection) >= 4.5 ? selection : background
        let text = contrast(foreground, omnibox) >= 4.5 ? foreground
            : (contrast([0, 0, 0], omnibox) >= 4.5 ? [0, 0, 0] : [255, 255, 255])
        let colors: [String: [Int]] = [
            "frame": rgb(frame),
            "frame_inactive": rgb(frame),
            "toolbar": rgb(theme.background),
            "toolbar_text": rgb(theme.foreground),
            "toolbar_button_icon": rgb(theme.foreground),
            "tab_text": rgb(theme.foreground),
            "background_tab": rgb(frame),
            "background_tab_inactive": rgb(frame),
            "tab_background_text": rgb(theme.foreground),
            "tab_background_text_inactive": rgb(theme.foreground),
            "bookmark_text": rgb(theme.foreground),
            "ntp_background": rgb(theme.background),
            "ntp_text": rgb(theme.foreground),
            "ntp_link": rgb(theme.accent),
            "button_background": rgb(theme.selection),
            "omnibox_background": omnibox,
            "omnibox_text": text
        ]
        return try JSONSerialization.data(withJSONObject: [
            "manifest_version": 3,
            "name": "Mac Themes · \(theme.name)",
            "version": "1.1.0",
            "description": "A coordinated Omarchy palette for your browser.",
            "theme": ["colors": colors]
        ], options: [.prettyPrinted, .sortedKeys])
    }

    private static func contrast(_ a: [Int], _ b: [Int]) -> Double {
        func luminance(_ rgb: [Int]) -> Double {
            let linear = rgb.map { channel -> Double in
                let value = Double(channel) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    static func write(_ theme: Theme, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try manifest(theme).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        let instructions = """
        \(theme.name) for Brave

        This is a standard theme package with no scripts or permissions.

        One-time setup

        1. Open brave://extensions.
        2. Enable Developer mode, choose Load unpacked, and select this directory.
        3. In brave://settings/appearance, set Brave colors to \(theme.isLight ? "Light" : "Dark") so
           browser settings and other built-in pages match the theme's mode.

        The theme applies to open browser windows without a restart. It stays
        active when Mac Themes is closed and contains no background process.
        Keep this directory: Brave uses it for the installed theme.

        Colors cover the browser frame, tabs, toolbar, address bar and supported
        new-tab elements. Brave may adapt some colors for contrast. Website
        content and Brave's own new-tab backgrounds have separate settings.

        For manual installation, use Load unpacked to select a theme package.
        Automatic Apply in Mac Themes creates and loads a fresh colors-only copy,
        including when returning to a previous palette. These small copies are
        kept because Brave may still use them. To restore, choose Reset to default
        in Brave's Appearance settings and restore your previous Brave colors mode.

        This colors-only package also works in Chrome, Chromium and Edge through
        their equivalent Extensions and Appearance pages.

        """
        try instructions.write(to: directory.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
    }
}
