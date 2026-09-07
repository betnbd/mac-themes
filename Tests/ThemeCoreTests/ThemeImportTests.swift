import Foundation
import Testing
@testable import ThemeCore

@Test func parsesOmarchyInstallStringsWithoutRunningCommands() throws {
    let expected = try ThemeImportSource.parse("https://github.com/example/omarchy-ocean-theme")
    for input in ["omarchy-theme-install https://github.com/example/omarchy-ocean-theme.git", "omarchy theme install 'https://github.com/example/omarchy-ocean-theme'", "git@github.com:example/omarchy-ocean-theme.git", "github.com/example/omarchy-ocean-theme"] {
        #expect(try ThemeImportSource.parse(input) == expected)
    }
    #expect(expected.name == "Ocean")
    #expect(expected.id.hasPrefix("imported-example-omarchy-ocean-theme-"))
    let folder = try ThemeImportSource.parse("https://github.com/omacom/omarchy/tree/quattro/themes/nord")
    #expect(folder.reference == "quattro")
    #expect(folder.subdirectory == "themes/nord")
    #expect(folder.name == "Nord")
    #expect(try ThemeImportSource.parse("https://github.com/example/repo/tree/main/Themes/Foo").id != ThemeImportSource.parse("https://github.com/example/repo/tree/main/themes/foo").id)
    #expect(try ThemeImportSource.parse("https://github.com/example/repo/tree/Main/theme").id != ThemeImportSource.parse("https://github.com/example/repo/tree/main/theme").id)
}

@Test func rejectsShellAndUnsafeThemeSources() {
    for input in [
        "omarchy-theme-install https://github.com/a/b; touch /tmp/wrong",
        "omarchy theme install $(curl https://github.com/a/b)",
        "curl https://github.com/a/b | sh",
        "omarchy-theme-install --upload-pack=evil https://github.com/a/b",
        "omarchy-theme-install https://github.com/a/b && echo done",
        "https://github.com/a/b\necho evil", "https://user:password@github.com/a/b",
        "https://github.com.evil.example/a/b", "file:///tmp/theme", "ext::evil",
        "https://github.com/a/b/tree/main/%2e%2e/escape", "https://github.com/a/b/tree/main/a%5cb",
        "https://github.com/a/b?command=evil", "https://github.com/a/b/blob/main/colors.toml"
    ] { #expect(throws: (any Error).self) { try ThemeImportSource.parse(input) } }
}

@Test func convertsOfficialSemanticPalettesExactly() throws {
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for expected in Theme.all {
        let source = try String(contentsOf: project.appendingPathComponent("Vendor/Omarchy/\(expected.id)/colors.toml"), encoding: .utf8)
        let result = try ThemePaletteConverter.convert(files: ["colors.toml": source], id: "fixture", name: "Fixture")
        #expect(result.background == expected.background)
        #expect(result.foreground == expected.foreground)
        #expect(result.accent == expected.accent)
        #expect(result.cursor == expected.cursor)
        #expect(result.selection == expected.selection)
        #expect(result.palette == expected.palette)
        #expect(result.isLight == expected.isLight)
    }
}

@Test func convertsLegacyPalettesAndIgnoresExecutableConfig() throws {
    let expected = Theme.all[0]
    let ansi = expected.palette.enumerated().map { "color\($0.offset) = '\($0.element)'" }.joined(separator: "\n")
    let legacy = try ThemePaletteConverter.convert(files: ["colors.toml": "theme_type = 'light'\n" + ansi], id: "legacy", name: "Legacy")
    #expect(legacy.palette == expected.palette)
    #expect(legacy.isLight)
    let ghostty = try ThemePaletteConverter.convert(files: ["ghostty.conf": expected.ghosttyConfig + "command = touch /tmp/never-run\nconfig-file = /tmp/never-read\n"], id: "g", name: "Ghostty")
    #expect(ghostty.palette == expected.palette)
    #expect(ghostty.selection == expected.selection)
    let specialCursor = try ThemePaletteConverter.convert(files: ["ghostty.conf": expected.ghosttyConfig + "cursor-color = #ff0000\n"], id: "cursor", name: "Cursor")
    #expect(specialCursor.cursor == "#ff0000")
    #expect(specialCursor.palette[15] == expected.palette[15])
    #expect(!ghostty.ghosttyConfig.contains("never-run"))
    let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
    let normal = names.enumerated().map { "\($0.element) = '\(expected.palette[$0.offset])'" }.joined(separator: "\n")
    let bright = names.enumerated().map { "\($0.element) = '\(expected.palette[$0.offset + 8])'" }.joined(separator: "\n")
    let alacritty = "[colors.primary]\nbackground = '\(expected.background)'\nforeground = '\(expected.foreground)'\n[colors.normal]\n\(normal)\n[colors.bright]\n\(bright)\n[terminal.shell]\nprogram = 'never-run'"
    let result = try ThemePaletteConverter.convert(files: ["alacritty.toml": alacritty], id: "a", name: "Alacritty", lightMode: true)
    #expect(result.palette == expected.palette)
    #expect(result.isLight)
    #expect(throws: (any Error).self) { try ThemePaletteConverter.convert(files: ["colors.toml": ansi.replacingOccurrences(of: expected.palette[1], with: "$(evil)")], id: "x", name: "Invalid") }
    #expect(throws: (any Error).self) { try ThemePaletteConverter.convert(files: ["neovim.lua": "os.execute('never-run')"], id: "x", name: "Missing") }
}

@Test func preservesExplicitANSIPaletteAlongsideSemanticColors() throws {
    let base = Theme.all[0]
    let ansi = base.palette.enumerated().map { "color\($0.offset) = '\($0.element)'" }.joined(separator: "\n")
    let semantic = "background = '#010203'\nforeground = '#f0f1f2'\nmuted = '#456789'\ndark_foreground = '#334455'\nbright_foreground = '#abcdef'\nred = '#112233'\n" + ansi
    let imported = try ThemePaletteConverter.convert(files: ["colors.toml": semantic], id: "semantic", name: "Semantic")
    #expect(imported.background == "#010203")
    #expect(imported.palette[0] == "#010203")
    #expect(imported.palette[7] == "#f0f1f2")
    #expect(imported.palette[1] == base.palette[1])
    #expect(imported.palette[8] == base.palette[8])
    #expect(imported.palette[15] == base.palette[15])
    #expect(imported.cursor == "#abcdef")
    let terminal = try ThemePaletteConverter.convert(files: ["ghostty.conf": base.ghosttyConfig + "palette = 0=#010203\npalette = 7=#f0f1f2\n"], id: "terminal", name: "Terminal")
    #expect(terminal.background == base.background)
    #expect(terminal.foreground == base.foreground)
    #expect(terminal.palette[0] == "#010203")
    #expect(terminal.palette[7] == "#f0f1f2")
    let noMuted = "background = '#010203'\nforeground = '#f0f1f2'\ndark_fg = '#334455'\n" + ansi.components(separatedBy: "\n").filter { !$0.hasPrefix("color8 =") }.joined(separator: "\n")
    let legacyMuted = try ThemePaletteConverter.convert(files: ["colors.toml": noMuted], id: "alias", name: "Alias")
    #expect(legacyMuted.palette[8] == "#334455")
}

private actor ImportFixture {
    var revision = String(repeating: "a", count: 40)
    var breakImage = false
    var unsafePath: String?
    var mode = "100644"
    let image = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0])
    func setFailure(_ value: Bool) { breakImage = value }
    func advance() { revision = String(repeating: "b", count: 40) }
    func setUnsafe(path: String? = nil, mode: String = "100644") { unsafePath = path; self.mode = mode }
    func fetch(_ url: URL, limit: Int) throws -> Data {
        if url.path.contains("/commits/") { return try JSONSerialization.data(withJSONObject: ["sha": revision]) }
        if url.path.contains("/git/trees/") {
            let tree: [[String: Any]] = [
                ["path": "ghostty.conf", "type": "blob", "mode": "100644", "size": Theme.all[0].ghosttyConfig.utf8.count],
                ["path": unsafePath ?? "backgrounds/1-first.png", "type": "blob", "mode": mode, "size": image.count],
                ["path": "backgrounds/2-second.png", "type": "blob", "mode": "100644", "size": image.count],
                ["path": "install.sh", "type": "blob", "mode": "100755", "size": 20]
            ]
            return try JSONSerialization.data(withJSONObject: ["truncated": false, "tree": tree])
        }
        if url.lastPathComponent == "ghostty.conf" { return Data(Theme.all[0].ghosttyConfig.utf8) }
        if breakImage { throw ThemeError.message("Simulated connection interruption") }
        return image
    }
}

@Test func importsAndUpdatesAtomicallyWithWallpaperSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("theme-library-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = ImportFixture()
    let library = ThemeLibrary(directory: root, fetch: { try await fixture.fetch($0, limit: $1) })
    #expect(try await library.installedThemes().isEmpty)
    let original = try await library.importTheme("omarchy theme install https://github.com/example/omarchy-ocean-theme")
    #expect(original.wallpapers.count == 2)
    #expect(original.selectedWallpaper == "backgrounds/1-first.png")
    #expect(original.theme.palette == Theme.all[0].palette)
    #expect(FileManager.default.fileExists(atPath: try #require(original.selectedWallpaperURL(in: root)).path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(original.id).appendingPathComponent(original.version).appendingPathComponent("install.sh").path))
    _ = try await library.selectWallpaper("backgrounds/2-second.png", themeID: original.id)
    await fixture.advance(); await fixture.setFailure(true)
    await #expect(throws: (any Error).self) { try await library.update(original) }
    let afterFailure = try #require(await library.installedThemes().first)
    #expect(afterFailure.revision == original.revision)
    #expect(afterFailure.selectedWallpaper == "backgrounds/2-second.png")
    await fixture.setFailure(false)
    let updated = try await library.update(original)
    #expect(updated.id == original.id)
    #expect(updated.revision != original.revision)
    #expect(updated.version != original.version)
    #expect(updated.selectedWallpaper == "backgrounds/2-second.png")
    #expect(FileManager.default.fileExists(atPath: try #require(original.selectedWallpaperURL(in: root)).path))
    _ = try await library.selectWallpaper(nil, themeID: original.id)
    #expect(try await library.update(updated).selectedWallpaper == nil)
    await #expect(throws: (any Error).self) { try await library.selectWallpaper("../escape.png", themeID: original.id) }
}

@Test func rejectsRepositorySymlinksAndTraversalBeforeWriting() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("theme-library-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = ImportFixture()
    let library = ThemeLibrary(directory: root, fetch: { try await fixture.fetch($0, limit: $1) })
    await fixture.setUnsafe(path: "backgrounds/../../escape.png")
    await #expect(throws: (any Error).self) { try await library.importTheme("https://github.com/example/repo") }
    await fixture.setUnsafe(mode: "120000")
    await #expect(throws: (any Error).self) { try await library.importTheme("https://github.com/example/repo") }
    #expect(try await library.installedThemes().isEmpty)
    #expect(!ThemeLibrary.isImage(Data("version https://git-lfs.github.com/spec/v1".utf8)))
}

private actor ImportBoundaryFixture {
    var scenario = "valid"
    private var imagePaused = false
    private var imageReady: CheckedContinuation<Void, Never>?
    private var imageRelease: CheckedContinuation<Void, Never>?
    let image = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0])
    func setScenario(_ value: String) { scenario = value; imagePaused = false }
    func waitForImage() async {
        if imagePaused { return }
        await withCheckedContinuation { imageReady = $0 }
    }
    func releaseImage() { imageRelease?.resume(); imageRelease = nil }
    func fetch(_ url: URL, limit: Int) async throws -> Data {
        if url.path.contains("/commits/") {
            return try JSONSerialization.data(withJSONObject: ["sha": scenario == "invalid-revision" ? "../escape" : String(repeating: "c", count: 40)])
        }
        if url.path.contains("/git/trees/") {
            var tree: [[String: Any]] = [
                ["path": "ghostty.conf", "type": "blob", "mode": "100644", "size": scenario == "large-palette" ? 256_001 : Theme.all[0].ghosttyConfig.utf8.count]
            ]
            if scenario == "missing-palette" { tree = [] }
            let count = scenario == "too-many-images" ? 81 : scenario == "large-total" ? 7 : 2
            for i in 0..<count {
                let size = scenario == "large-image" ? 40_000_001 : scenario == "large-total" ? 40_000_000 : image.count
                tree.append(["path": "backgrounds/\(i)-image.png", "type": "blob", "mode": "100644", "size": size])
            }
            if scenario == "case-collision" { tree.append(["path": "backgrounds/0-IMAGE.PNG", "type": "blob", "mode": "100644", "size": image.count]) }
            return try JSONSerialization.data(withJSONObject: ["tree": tree, "truncated": scenario == "truncated"])
        }
        if url.lastPathComponent == "ghostty.conf" {
            return Data((scenario == "bad-palette" ? "background = shell-command\n" : Theme.all[0].ghosttyConfig).utf8)
        }
        if scenario == "lfs" { return Data("version https://git-lfs.github.com/spec/v1".utf8) }
        if scenario == "pause-image", !imagePaused {
            imagePaused = true
            imageReady?.resume(); imageReady = nil
            await withCheckedContinuation { imageRelease = $0 }
        }
        return image
    }
}

@Test func importFailureBoundariesKeepInstalledManifestAndImages() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("import-failures-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = ImportBoundaryFixture(), library = ThemeLibrary(directory: root, fetch: { try await fixture.fetch($0, limit: $1) })
    let original = try await library.importTheme("https://github.com/example/boundary-theme")
    for scenario in ["invalid-revision", "truncated", "large-palette", "missing-palette", "too-many-images", "large-total", "large-image", "case-collision", "bad-palette", "lfs"] {
        await fixture.setScenario(scenario)
        await #expect(throws: (any Error).self) { try await library.update(original) }
        #expect(try await library.installedThemes() == [original], "Previous import must remain intact after \(scenario)")
        #expect(FileManager.default.fileExists(atPath: try #require(original.selectedWallpaperURL(in: root)).path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".staging-") })
    }
    await fixture.setScenario("valid")
    #expect(try await library.update(original).id == original.id)
}

@Test func cancelledImportAndConcurrentDuplicateCannotReplacePreviousVersion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("import-cancellation-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = ImportBoundaryFixture(), library = ThemeLibrary(directory: root, fetch: { try await fixture.fetch($0, limit: $1) })
    let original = try await library.importTheme("https://github.com/example/cancellation-theme")
    await fixture.setScenario("pause-image")
    let pending = Task { try await library.update(original) }
    await fixture.waitForImage()
    await #expect(throws: (any Error).self) { try await library.update(original) }
    pending.cancel()
    await fixture.releaseImage()
    await #expect(throws: CancellationError.self) { try await pending.value }
    #expect(try await library.installedThemes() == [original])
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".staging-") })
}

@Test func wallpaperSelectionDuringDownloadSurvivesCommit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("import-selection-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = ImportBoundaryFixture(), library = ThemeLibrary(directory: root, fetch: { try await fixture.fetch($0, limit: $1) })
    let original = try await library.importTheme("https://github.com/example/selection-theme")
    await fixture.setScenario("pause-image")
    let pending = Task { try await library.update(original) }
    await fixture.waitForImage()
    _ = try await library.selectWallpaper("backgrounds/1-image.png", themeID: original.id)
    await fixture.releaseImage()
    let result = try await pending.value
    #expect(result.selectedWallpaper == "backgrounds/1-image.png")
}
