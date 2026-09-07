import Foundation
import Testing
import ThemeCore
@testable import MacThemes

private struct ObsidianFixture {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var root: URL { home.appendingPathComponent("state") }
    var vault: URL { home.appendingPathComponent("Notes") }
    var appearance: URL { vault.appendingPathComponent(".obsidian/appearance.json") }
    var css: URL { vault.appendingPathComponent(".obsidian/snippets/mac-themes.css") }
    func prepare(_ appearance: String = "{}") throws {
        try ManagedConfig.write(appearance, to: self.appearance)
        let paths = try JSONSerialization.data(withJSONObject: ["obsidianVaults": [vault.path]])
        try ManagedConfig.write(String(decoding: paths, as: UTF8.self), to: root.appendingPathComponent("integration-locations.json"))
    }
    func remove() { try? FileManager.default.removeItem(at: home) }
    func object(_ url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}

@MainActor @Test func focusedObsidianNeedsOnlyOneManualActivationAndPreservesLaterEdits() throws {
    let f = ObsidianFixture(); defer { f.remove() }
    let original = "{\n  \"theme\": \"moonstone\", \"enabledCssSnippets\": [\"personal\"], \"fontTextSize\": 17\n}"
    try f.prepare(original)
    let service = try ObsidianIntegration(root: f.root, home: f.home, live: false)
    #expect(!service.hasBackups)
    #expect(try service.apply(Theme.all[0]).state == .pending)
    #expect(try String(contentsOf: f.appearance, encoding: .utf8) == original)
    // The user enables the snippet once in Obsidian and changes unrelated preferences later.
    try ManagedConfig.write("{\"theme\":\"moonstone\",\"enabledCssSnippets\":[\"personal\",\"mac-themes\",\"later\"],\"fontTextSize\":21,\"custom\":\"keep my spaces\"}", to: f.appearance)
    for theme in Theme.all {
        #expect(try service.apply(theme).state == .applied)
        #expect(try String(contentsOf: f.css, encoding: .utf8) == ObsidianIntegration.css(theme))
    }
    let reopened = try ObsidianIntegration(root: f.root, home: f.home, live: false)
    #expect(reopened.hasBackups)
    _ = try reopened.restore()
    #expect(!reopened.hasBackups)
    #expect(!FileManager.default.fileExists(atPath: f.css.path))
    let restored = try f.object(f.appearance)
    #expect(restored["enabledCssSnippets"] as? [String] == ["personal", "later"])
    #expect(restored["fontTextSize"] as? Int == 21)
    #expect(restored["custom"] as? String == "keep my spaces")
}

@MainActor @Test func focusedObsidianRestoresExistingSnippetAndExactUnchangedAppearance() throws {
    let f = ObsidianFixture(); defer { f.remove() }
    let original = "{\n\"enabledCssSnippets\": [\"mac-themes\"], \"theme\": \"obsidian\"\n}"
    try f.prepare(original)
    try ManagedConfig.write("/* existing local customization */\n", to: f.css)
    let service = try ObsidianIntegration(root: f.root, home: f.home, live: false)
    for theme in Theme.all { _ = try service.apply(theme) }
    _ = try service.restore()
    #expect(try String(contentsOf: f.css, encoding: .utf8) == "/* existing local customization */\n")
    #expect(try String(contentsOf: f.appearance, encoding: .utf8) == original)
}

@MainActor @Test func focusedObsidianRejectsMalformedAppearanceBeforeCreatingCSS() throws {
    for malformed in ["[]", "{", "{\"enabledCssSnippets\":false}", "{\"enabledCssSnippets\":[1]}"] {
        let f = ObsidianFixture(); defer { f.remove() }
        try f.prepare(malformed)
        let service = try ObsidianIntegration(root: f.root, home: f.home, live: false)
        #expect(throws: (any Error).self) { try service.apply(Theme.all[0]) }
        #expect(!service.hasBackups)
        #expect(!FileManager.default.fileExists(atPath: f.css.path))
        #expect(try String(contentsOf: f.appearance, encoding: .utf8) == malformed)
    }
}

@MainActor @Test func focusedObsidianUnavailableProviderTimesOutWithoutLateMutation() throws {
    let f = ObsidianFixture(); defer { f.remove() }
    try f.prepare()
    let appearance = f.appearance.path
    let readStarted = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let reader = BoundedFileReader(timeout: 0.04) { url in
        if url.path == appearance { readStarted.signal(); release.wait() }
        return try BoundedFileReader.loadFile(url)
    }
    let service = try ObsidianIntegration(root: f.root, home: f.home, live: false, fileReader: reader)
    let start = Date()
    #expect(throws: (any Error).self) { try service.apply(Theme.all[0]) }
    #expect(Date().timeIntervalSince(start) < 0.5)
    #expect(readStarted.wait(timeout: .now()) == .success)
    #expect(reader.pendingReadCount == 1)
    #expect(throws: (any Error).self) { try service.apply(Theme.all[0]) }
    #expect(!service.hasBackups)
    #expect(!FileManager.default.fileExists(atPath: f.css.path))
    release.signal()
    // A late read completion cannot continue apply or modify the vault.
    Thread.sleep(forTimeInterval: 0.06)
    #expect(reader.pendingReadCount == 0)
    #expect(!FileManager.default.fileExists(atPath: f.css.path))
    #expect(try String(contentsOf: f.appearance, encoding: .utf8) == "{}")
}

@MainActor @Test func focusedObsidianReusesLegacyBackupAndPreservesOtherIntegrations() throws {
    let f = ObsidianFixture(); defer { f.remove() }
    try f.prepare("{\"enabledCssSnippets\":[\"mac-themes\"]}")
    let applied = ObsidianIntegration.css(Theme.all[1])
    try ManagedConfig.write(applied, to: f.css)
    let legacy: [String: Any] = ["extra": "preserve", "apps": [
        "kitty": [["path": "/other/config", "format": "file", "futureField": 42]],
        "obsidian": [
            ["path": f.appearance.path, "format": "obsidian-enabled", "original": "{}", "fields": [["path": ["enabledCssSnippets"], "original": "false", "applied": "true"]]],
            ["path": f.css.path, "format": "file", "fields": [], "applied": applied]
        ]
    ]]
    let journal = f.root.appendingPathComponent("additional-state.json")
    try JSONSerialization.data(withJSONObject: legacy).write(to: journal)
    let service = try ObsidianIntegration(root: f.root, home: f.home, live: false)
    #expect(service.hasBackups)
    _ = try service.apply(Theme.all[0])
    _ = try service.restore()
    #expect(!FileManager.default.fileExists(atPath: f.css.path))
    #expect(try String(contentsOf: f.appearance, encoding: .utf8) == "{}")
    let state = try f.object(journal)
    #expect(state["extra"] as? String == "preserve")
    let apps = try #require(state["apps"] as? [String: Any])
    #expect((apps["kitty"] as? [[String: Any]])?.first?["futureField"] as? Int == 42)
    #expect((apps["obsidian"] as? [Any])?.isEmpty == true)
}

@MainActor @Test func focusedObsidianRestoreInterleavesWithFreshLegacyAdaptersWithoutResurrectingBackups() throws {
    let f = ObsidianFixture(); defer { f.remove() }
    try f.prepare("{\"enabledCssSnippets\":[\"mac-themes\"]}")
    let originalCSS = "/* existing personal CSS */\n"
    try ManagedConfig.write(originalCSS, to: f.css)
    let btop = f.home.appendingPathComponent(".config/btop/btop.conf")
    try ManagedConfig.write("# personal settings\ncolor_theme = \"Default\"\nupdate_ms = 1000\n", to: btop)
    let legacy = try AdditionalIntegrations(root: f.root, home: f.home, live: false)
    for app: AdditionalIntegration in [.btop, .neovim, .obsidian] {
        _ = try legacy.apply(Theme.all[1], to: app)
    }
    let focused = try ObsidianIntegration(root: f.root, home: f.home, live: false)
    _ = try focused.apply(Theme.all[0])
    // This is the root's serial migration order: each retired adapter starts fresh,
    // while the focused Obsidian service remains alive from application launch.
    _ = try AdditionalIntegrations(root: f.root, home: f.home, live: false).restore(.btop)
    _ = try focused.restore()
    _ = try AdditionalIntegrations(root: f.root, home: f.home, live: false).restore(.neovim)
    #expect(!focused.hasBackups)
    #expect(try !AdditionalIntegrations(root: f.root, home: f.home, live: false).hasBackups)
    #expect(try String(contentsOf: f.css, encoding: .utf8) == originalCSS)
    let finalBtop = try String(contentsOf: btop, encoding: .utf8)
    #expect(finalBtop.contains("color_theme = \"Default\""))
    #expect(finalBtop.contains("update_ms = 1000"))
    #expect(!FileManager.default.fileExists(atPath: f.home.appendingPathComponent(".config/nvim/plugin/mac-themes.lua").path))
}

@MainActor @Test func focusedObsidianPreflightsRestoreAndKeepsConflictingUserCSS() throws {
    let f = ObsidianFixture(); defer { f.remove() }
    try f.prepare()
    let service = try ObsidianIntegration(root: f.root, home: f.home, live: false)
    _ = try service.apply(Theme.all[0])
    let appearance = "{\"enabledCssSnippets\":[\"mac-themes\"],\"fontTextSize\":25}"
    try ManagedConfig.write(appearance, to: f.appearance)
    try ManagedConfig.write("/* my edited CSS */", to: f.css)
    #expect(throws: (any Error).self) { try service.restore() }
    #expect(service.hasBackups)
    #expect(try String(contentsOf: f.appearance, encoding: .utf8) == appearance)
    #expect(try String(contentsOf: f.css, encoding: .utf8) == "/* my edited CSS */")
    #expect(throws: (any Error).self) { try service.apply(Theme.all[1]) }
    #expect(try String(contentsOf: f.css, encoding: .utf8) == "/* my edited CSS */")
}

@MainActor @Test func focusedObsidianUsesExplicitVaultSelectionAndValidatesPaths() throws {
    let f = ObsidianFixture(); defer { f.remove() }
    let registry = f.home.appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
    try ManagedConfig.write("{\"vaults\":{\"a\":{\"path\":\"/registered/notes\"}}}", to: registry)
    let service = try ObsidianIntegration(root: f.root, home: f.home, live: false)
    #expect(try service.obsidianVaults().map(\.path) == ["/registered/notes"])
    try f.prepare()
    #expect(try service.obsidianVaults() == [f.vault])
    try ManagedConfig.write("{\"obsidianVaults\":[]}", to: service.configuredLocations)
    #expect(try service.obsidianVaults().isEmpty)
    for malformed in ["{\"obsidianVaults\":\"/notes\"}", "{\"obsidianVaults\":[\"relative\"]}"] {
        try ManagedConfig.write(malformed, to: service.configuredLocations)
        #expect(throws: (any Error).self) { try service.obsidianVaults() }
    }
}

@Test func focusedObsidianFormColorsAndNativeSchemeRemainReadable() throws {
    let theme = try #require(Theme.all.first { $0.id == "tokyo-night" })
    let css = ObsidianIntegration.css(theme)
    #expect(css.contains("color-scheme: dark;"))
    #expect(css.contains("body.theme-dark, body.theme-light"))
    #expect(css.contains("--background-modifier-form-field: #13141c;"))
    #expect(css.contains("--input-placeholder-color: \(theme.foreground)E6;"))
    #expect(!css.contains("url("))
    #expect(!css.contains("@import"))
}

@Test func focusedObsidianTokyoNightUsesOmarchySurfacesWithReadableControls() throws {
    let theme = try #require(Theme.all.first { $0.id == "tokyo-night" })
    let css = ObsidianIntegration.css(theme)
    func color(_ name: String) throws -> String {
        let line = try #require(css.split(separator: "\n").first { $0.hasPrefix("  --\(name): ") })
        return String(line.split(separator: ":", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ";", with: "")
    }
    #expect(try color("background-primary") == "#1a1b26")
    #expect(try color("background-secondary") == "#13141c")
    #expect(try color("background-primary-alt") == "#24283b")
    #expect(try color("titlebar-background") == color("background-secondary"))
    #expect(try color("tab-background-active") == color("background-primary"))
    #expect(try color("background-modifier-border") == theme.palette[8])
    func rgb(_ value: String) -> [Double] { ScriptLiteral.rgb(String(value.prefix(7))).map { Double($0) / 65_535 } }
    func luminance(_ value: [Double]) -> Double {
        let linear = value.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
    }
    let placeholder = try color("input-placeholder-color"), ink = rgb(placeholder)
    let alpha = Double(try #require(UInt8(placeholder.suffix(2), radix: 16))) / 255
    for control in ["background-modifier-form-field", "background-modifier-form-field-hover", "interactive-normal", "interactive-hover", "dropdown-background", "dropdown-background-hover"] {
        let background = rgb(try color(control))
        let blended = (0..<3).map { ink[$0] * alpha + background[$0] * (1 - alpha) }
        let a = luminance(background), b = luminance(blended)
        #expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= 4.5, "\(control) placeholder contrast")
    }
    // Imported palettes keep their own background; Tokyo's curated surfaces never leak.
    for other in Theme.all where other.id != theme.id {
        #expect(!ObsidianIntegration.css(other).contains("#13141c"))
    }
}
