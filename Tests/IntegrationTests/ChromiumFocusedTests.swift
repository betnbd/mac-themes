import Foundation
import Testing
import ThemeCore
@testable import MacThemes

@Test func braveActivationPackagesStayDistinctAcrossReturnAndRepeatedThemes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try #require(Theme.all.first { $0.id == "tokyo-night" })
    let second = try #require(Theme.all.first { $0.id != first.id })
    let manual = try ChromiumThemePackage.export(theme: first, root: root)
    let manualBytes = try Data(contentsOf: manual.appendingPathComponent("manifest.json"))
    var paths: [URL] = []
    var originalBytes: [Data] = []
    for theme in [first, second, first, first] {
        let path = try ChromiumThemePackage.exportForActivation(theme: theme, root: root)
        let bytes = try Data(contentsOf: path.appendingPathComponent("manifest.json"))
        #expect(path.deletingLastPathComponent().lastPathComponent == "Installations")
        #expect(bytes == (try ChromiumThemePackage.manifest(theme)))
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        // With no manifest key, Chromium derives each ID from its unique path.
        #expect(object["key"] == nil)
        paths.append(path)
        originalBytes.append(bytes)
    }
    #expect(Set(paths).count == 4)
    for (path, bytes) in zip(paths, originalBytes) {
        #expect(try Data(contentsOf: path.appendingPathComponent("manifest.json")) == bytes)
    }
    #expect(try Data(contentsOf: manual.appendingPathComponent("manifest.json")) == manualBytes)
    #expect(try ChromiumThemePackage.export(theme: first, root: root) == manual)
}

@Test func tokyoNightBrowserSurfacesAndTextRemainDistinctAndReadable() throws {
    let tokyo = try #require(Theme.all.first { $0.id == "tokyo-night" })
    let manifest = try #require(JSONSerialization.jsonObject(with: ChromiumThemePackage.manifest(tokyo)) as? [String: Any])
    let theme = try #require(manifest["theme"] as? [String: Any])
    let colors = try #require(theme["colors"] as? [String: [Int]])
    #expect(colors["frame"] == [19, 20, 28])
    #expect(colors["toolbar"] == [26, 27, 38])
    #expect(colors["omnibox_background"] == [41, 46, 66])
    #expect(colors["ntp_link"] == [122, 162, 247])
    for (foreground, background) in [
        ("tab_text", "toolbar"), ("tab_background_text", "background_tab"),
        ("tab_background_text_inactive", "background_tab_inactive"),
        ("toolbar_text", "toolbar"), ("toolbar_button_icon", "toolbar"),
        ("omnibox_text", "omnibox_background"), ("ntp_text", "ntp_background"),
        ("ntp_link", "ntp_background")
    ] {
        let a = luminance(try #require(colors[foreground]))
        let b = luminance(try #require(colors[background]))
        #expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= 4.5)
    }
}

@Test func browserPackageUsesOnlySupportedColorKeysAndNoExecutableResources() throws {
    // Chromium's kOverwritableColorTable is the authoritative theme color API.
    let supported = Set([
        "background_tab", "background_tab_inactive", "background_tab_incognito",
        "background_tab_incognito_inactive", "bookmark_text", "button_background",
        "frame", "frame_inactive", "frame_incognito", "frame_incognito_inactive",
        "ntp_background", "ntp_header", "ntp_link", "ntp_text", "omnibox_background",
        "omnibox_text", "tab_background_text", "tab_background_text_inactive",
        "tab_background_text_incognito", "tab_background_text_incognito_inactive",
        "tab_text", "toolbar", "toolbar_button_icon", "toolbar_text"
    ])
    for theme in Theme.all {
        let manifest = try #require(JSONSerialization.jsonObject(with: ChromiumThemePackage.manifest(theme)) as? [String: Any])
        #expect(Set(manifest.keys) == Set(["manifest_version", "name", "version", "description", "theme"]))
        let body = try #require(manifest["theme"] as? [String: Any])
        #expect(Set(body.keys) == Set(["colors"]))
        let colors = try #require(body["colors"] as? [String: [Int]])
        #expect(Set(colors.keys).isSubset(of: supported))
    }
}

private func luminance(_ rgb: [Int]) -> Double {
    let linear = rgb.map { channel -> Double in
        let value = Double(channel) / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
}
