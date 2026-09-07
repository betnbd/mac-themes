import Foundation
import CoreText
import Testing
import ThemeCore
@testable import MacThemes

private var fontResources: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vendor/NerdFonts")
}

@Test func curatedFontsContainOnlyRegularAndBoldWithCorrectFamilyNames() throws {
    let resources = fontResources
    let bundled = ThemeFont.all.filter { $0.directory != nil }
    #expect(bundled.count == 8)
    for font in bundled {
        let urls = font.files(in: resources)
        #expect(urls.count == 2)
        for url in urls {
            let descriptors = try #require(CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])
            let descriptor = try #require(descriptors.first)
            #expect(CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String == font.family)
        }
    }
}

@Test func fontInstallationCopiesOnlySelectedFamilyAndPreservesConflicts() throws {
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: destination) }
    let font = ThemeFont.all[0]
    try font.install(resources: fontResources, destination: destination)
    try font.install(resources: fontResources, destination: destination)
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).filter { $0.hasSuffix(".ttf") }.count == 2)
    let target = destination.appendingPathComponent(font.files(in: fontResources)[0].lastPathComponent)
    let external = Data("external font data".utf8)
    try external.write(to: target)
    #expect(throws: (any Error).self) { try font.install(resources: fontResources, destination: destination) }
    #expect(try Data(contentsOf: target) == external)
}

@Test @MainActor func fontChoiceIsPerThemeAndDoesNotApplyUntilRequested() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    let store = ThemeStore(demo: false, root: root, defaults: defaults)
    store.selectFont("jetbrains")
    #expect(store.previewTheme.fontFamily == ThemeFont.all[0].family)
    #expect(store.previewOnly)
    #expect(!store.busy)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("state.json").path))
    store.select(Theme.bundled[1])
    #expect(store.selectedFontID.isEmpty)
    store.selectFont("monaco")
    store.select(Theme.bundled[0])
    #expect(store.selectedFontID == "jetbrains")
    let reopened = ThemeStore(demo: false, root: root, defaults: defaults)
    #expect(reopened.selectedFontID == "jetbrains")
    store.selectFont("")
    #expect(store.previewTheme.fontFamily == nil)
    // Allow startup tasks to finish before removing their temporary directory.
    try await Task.sleep(for: .milliseconds(30))
}

@Test @MainActor func selectedFontReachesSupportedFormatsAndPreservesChatGPTUI() throws {
    var theme = Theme.bundled[0]
    #expect(!theme.ghosttyConfig.contains("font-family"))
    #expect(!ObsidianIntegration.css(theme).contains("--font-text-theme"))
    theme.fontFamily = "JetBrainsMono Nerd Font Mono"
    #expect(theme.ghosttyConfig.contains("font-family = JetBrainsMono Nerd Font Mono"))
    #expect(ObsidianIntegration.css(theme).contains("--font-text-theme: \"JetBrainsMono Nerd Font Mono\""))
    let current: [String: Any] = ["appearanceDarkChromeTheme": ["fonts": ["ui": "Existing UI", "code": "Old Code"]]]
    let share = try ChatGPTThemeShare(ChatGPTConfigEditor.shareString(theme, current: current))
    let fonts = try #require(share.theme["fonts"] as? [String: String])
    #expect(fonts["ui"] == "Existing UI")
    #expect(fonts["code"] == theme.fontFamily)
    #expect(try JSONDecoder().decode(Theme.self, from: JSONEncoder().encode(theme)) == theme)
}

@Test func savedFontNamesCannotInjectConfiguration() throws {
    var theme = Theme.bundled[0]
    theme.fontFamily = "Menlo\ncommand = malicious"
    let data = try JSONEncoder().encode(theme)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(Theme.self, from: data) }
}

@Test @MainActor func fontModesPreserveOrResetConsistentlyAcrossAdapters() throws {
    var custom = Theme.bundled[0]; custom.fontFamily = "Monaco"
    let ghostty = Integrations.ghosttyConfiguration(custom, current: "")
    let obsidian = ObsidianIntegration.css(custom)
    let current = try ChatGPTThemeShare(ChatGPTConfigEditor.shareString(custom))
    let unchanged = Theme.bundled[1]
    #expect(Integrations.ghosttyConfiguration(unchanged, current: ghostty).contains("font-family = Monaco"))
    #expect(ObsidianIntegration.css(unchanged, current: obsidian).contains("--font-text-theme: \"Monaco\""))
    let kept = try ChatGPTThemeShare(current.applying(unchanged))
    #expect((kept.theme["fonts"] as? [String: Any])?["code"] as? String == "Monaco")
    var reset = unchanged; reset.useDefaultFont = true
    #expect(!Integrations.ghosttyConfiguration(reset, current: ghostty).contains("Monaco"))
    #expect(Integrations.ghosttyConfiguration(reset, current: ghostty).contains("font-family =\n"))
    #expect(!ObsidianIntegration.css(reset, current: obsidian).contains("Monaco"))
    let cleared = try ChatGPTThemeShare(current.applying(reset))
    #expect((cleared.theme["fonts"] as? [String: Any])?["code"] is NSNull)
    #expect(try JSONDecoder().decode(Theme.self, from: JSONEncoder().encode(reset)).useDefaultFont == true)
}

@Test func trackedFontUpgradesAreRetryableAndUntrackedFontsStayUnowned() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = root.appendingPathComponent("source"), destination = root.appendingPathComponent("installed")
    let font = ThemeFont.all[0], sources = font.files(in: resources)
    for source in sources {
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("version one".utf8).write(to: source)
    }
    try font.install(resources: resources, destination: destination)
    for source in sources { try Data("version two".utf8).write(to: source) }
    try font.install(resources: resources, destination: destination)
    // Simulate a crash after the journal and first face were written.
    try Data("version one".utf8).write(to: destination.appendingPathComponent(sources[1].lastPathComponent))
    try font.install(resources: resources, destination: destination)
    for source in sources {
        #expect(try Data(contentsOf: destination.appendingPathComponent(source.lastPathComponent)) == Data("version two".utf8))
    }
    let external = root.appendingPathComponent("external")
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    for source in sources { try FileManager.default.copyItem(at: source, to: external.appendingPathComponent(source.lastPathComponent)) }
    try font.install(resources: resources, destination: external)
    #expect(!FileManager.default.fileExists(atPath: external.appendingPathComponent(".mac-themes-fonts.json").path))
    for source in sources { try Data("version three".utf8).write(to: source) }
    #expect(throws: (any Error).self) { try font.install(resources: resources, destination: external) }
}
