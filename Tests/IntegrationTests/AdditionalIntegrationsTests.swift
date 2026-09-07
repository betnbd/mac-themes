import Foundation
import Darwin
import Testing
import ThemeCore
@testable import MacThemes

@Test func obsidianFormsStayReadableAcrossOppositeBaseAppearances() throws {
    func rgba(_ value: String) throws -> [Double] {
        let hex = String(value.dropFirst())
        #expect(hex.count == 6 || hex.count == 8)
        return try stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return Double(try #require(UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16))) / 255
        }
    }
    func luminance(_ color: [Double]) -> Double {
        let linear = color.prefix(3).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
    }
    for theme in Theme.all {
        let css = AdditionalPalette.obsidian(theme)
        #expect(css.contains("body.theme-dark, body.theme-light"))
        #expect(css.contains("color-scheme: \(theme.isLight ? "light" : "dark");"))
        func color(_ property: String) throws -> [Double] {
            let line = try #require(css.split(separator: "\n").first { $0.hasPrefix("  --\(property): ") })
            return try rgba(String(line.split(separator: ":", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ";", with: ""))
        }
        let placeholder = try color("input-placeholder-color")
        for field in ["background-modifier-form-field", "background-modifier-form-field-hover", "interactive-normal", "dropdown-background"] {
            let background = try color(field), alpha = placeholder.count == 4 ? placeholder[3] : 1
            let blended = (0..<3).map { placeholder[$0] * alpha + background[$0] * (1 - alpha) }
            let a = luminance(background), b = luminance(blended)
            #expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= 4.5, "\(theme.name): \(field) placeholder contrast")
        }
    }
}

@Test func jsoncPaletteEditsPreserveCommentsStringsAndOtherValues() throws {
    #expect(try PaletteJSON.literal("/a/b.lua") == "\"/a/b.lua\"")
    let original = """
    {
      // keep my editor setup
      "font.family": "a // b \\" c",
      "array": [{"comment": "/* inside a string */"},],
      "workbench.colorCustomizations": {
        "editor.background": "#121212", // keep the note
        "unrelated.color": "#123456",
      },
    }
    """
    let updated = try PaletteJSON.setting(original, path: ["workbench.colorCustomizations", "editor.background"], raw: "\"#abcdef\"")
    #expect(updated.contains("// keep my editor setup"))
    #expect(updated.contains("// keep the note"))
    #expect(try PaletteJSON.raw(updated, path: ["array"]) == PaletteJSON.raw(original, path: ["array"]))
    #expect(try PaletteJSON.raw(updated, path: ["workbench.colorCustomizations", "unrelated.color"]) == "\"#123456\"")
    #expect(try PaletteJSON.setting(updated, path: ["workbench.colorCustomizations", "editor.background"], raw: "\"#121212\"") == original)
    let inserted = try PaletteJSON.setting("{\"a\": 1 // trailing comment\n}", path: ["nested", "b"], raw: "true")
    #expect(try PaletteJSON.raw(inserted, path: ["nested", "b"]) == "true")
    #expect(inserted.contains("1, // trailing comment"))
    _ = try PaletteJSON.parse(PaletteJSON.setting(inserted, path: ["a"], raw: nil))
    _ = try PaletteJSON.parse(PaletteJSON.setting(inserted, path: ["nested"], raw: nil))
}

@Test func ambiguousConfigurationIsRejectedBeforeEditing() throws {
    #expect(throws: (any Error).self) { try PaletteJSON.setting("{\"x\":1,\"x\":2}", path: ["x"], raw: "3") }
    #expect(throws: (any Error).self) { try PaletteJSON.setting("{\"x\":false}", path: ["x", "y"], raw: "3") }
    #expect(throws: (any Error).self) { try PaletteScalar.setting("[colors]\nprimary = { background = '#000000' }\n", path: ["colors", "primary", "background"], raw: " '#ffffff'") }
    #expect(throws: (any Error).self) { try PaletteScalar.setting("theme='a'\ntheme='b'\n", path: ["theme"], raw: " 'c'") }
}

@Test func tomlPaletteEditsPreserveNonColorSectionsAndHandleMissingFinalNewline() throws {
    let input = "# personal\n[font]\nsize = 14\n[colors.primary]\nbackground = '#000000' # previous\n"
    let output = try PaletteScalar.setting(input, path: ["colors", "primary", "background"], raw: " \"#abcdef\"")
    #expect(output.contains("[font]\nsize = 14\n"))
    #expect(try PaletteScalar.setting(output, path: ["colors", "primary", "background"], raw: " '#000000' # previous") == input)
    #expect(try PaletteScalar.setting("[colors.primary]", path: ["colors", "primary", "background"], raw: " '#112233'") == "[colors.primary]\nbackground = '#112233'\n")
}

@MainActor @Test func additionalAdaptersApplySwitchAndRestoreFixturesWithoutTouchingApps() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let root = home.appendingPathComponent("state")
    let config = home.appendingPathComponent("Library/Application Support/Code/User/settings.json")
    try ManagedConfig.write("{\n // Personal preference\n \"editor.fontSize\": 19,\n \"workbench.colorCustomizations\": {\"editor.background\": \"#222222\"}\n}\n", to: config)
    let service = try AdditionalIntegrations(root: root, home: home, live: false)
    #expect(!service.hasBackups)
    for app in AdditionalIntegration.allCases where app != .obsidian {
        for theme in Theme.all { _ = try service.apply(theme, to: app) }
    }
    // A setting added after applying survives subsequent theme changes and restoration.
    var updated = try String(contentsOf: config, encoding: .utf8)
    updated = try PaletteJSON.setting(updated, path: ["files.autoSave"], raw: "\"afterDelay\"")
    try ManagedConfig.write(updated, to: config)
    _ = try service.apply(Theme.all[2], to: .vscode)
    let restored = try AdditionalIntegrations(root: root, home: home, live: false)
    for app in AdditionalIntegration.allCases where app != .obsidian { _ = try restored.restore(app) }
    let final = try String(contentsOf: config, encoding: .utf8)
    #expect(try PaletteJSON.raw(final, path: ["editor.fontSize"]) == "19")
    #expect(try PaletteJSON.raw(final, path: ["files.autoSave"]) == "\"afterDelay\"")
    #expect(try PaletteJSON.raw(final, path: ["workbench.colorCustomizations", "editor.background"]) == "\"#222222\"")
    #expect(final.contains("// Personal preference"))
    #expect(!restored.hasBackups)
}

@MainActor @Test func additionalRestoreRetainsConflictingUserChangesAndBackup() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let service = try AdditionalIntegrations(root: home.appendingPathComponent("state"), home: home, live: false)
    _ = try service.apply(Theme.all[0], to: .vscode)
    let url = home.appendingPathComponent("Library/Application Support/Code/User/settings.json")
    let current = try String(contentsOf: url, encoding: .utf8)
    let conflicting = try PaletteJSON.setting(current, path: ["workbench.colorCustomizations", "editor.background"], raw: "\"#123456\"")
    try ManagedConfig.write(conflicting, to: url)
    #expect(throws: (any Error).self) { try service.restore(.vscode) }
    #expect(try String(contentsOf: url, encoding: .utf8) == conflicting)
    #expect(service.hasBackups)
}

@MainActor @Test func editorRestorePreservesWhitespaceChangesInsideUnrelatedStrings() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let root = home.appendingPathComponent("state"), url = home.appendingPathComponent("Library/Application Support/Code/User/settings.json")
    try ManagedConfig.write("{\"custom.message\":\"keep this space\",\"workbench.colorCustomizations\":{},\"editor.tokenColorCustomizations\":{}}", to: url)
    let service = try AdditionalIntegrations(root: root, home: home, live: false)
    _ = try service.apply(Theme.all[0], to: .vscode)
    var current = try String(contentsOf: url, encoding: .utf8)
    current = try PaletteJSON.setting(current, path: ["custom.message"], raw: "\"keepthisspace\"")
    try ManagedConfig.write(current, to: url)
    _ = try service.restore(.vscode)
    #expect(try PaletteJSON.raw(String(contentsOf: url, encoding: .utf8), path: ["custom.message"]) == "\"keepthisspace\"")
}

@Test func installedNeovimLoadsEveryGeneratedPaletteAndRestoresItsOriginalColors() throws {
    let nvim = URL(fileURLWithPath: "/opt/homebrew/bin/nvim")
    guard FileManager.default.isExecutableFile(atPath: nvim.path) else { return }
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let plugin = fixture.appendingPathComponent("plugin/mac-themes.lua")
    try FileManager.default.createDirectory(at: plugin.deletingLastPathComponent(), withIntermediateDirectories: true)
    var paths: [String] = []
    for theme in Theme.all {
        let url = fixture.appendingPathComponent(theme.id + ".lua")
        try ManagedConfig.write(AdditionalPalette.neovim(theme), to: url)
        paths.append(url.path)
    }
    let palettePaths = "{" + (try paths.map(PaletteJSON.literal)).joined(separator: ",") + "}"
    let backgrounds = "{" + Theme.all.map { "0x" + $0.background.dropFirst() }.joined(separator: ",") + "}"
    let foregrounds = "{" + Theme.all.map { "0x" + $0.foreground.dropFirst() }.joined(separator: ",") + "}"
    let modes = "{" + Theme.all.map { $0.isLight ? "'light'" : "'dark'" }.joined(separator: ",") + "}"
    let script = """
    local plugin = \(try PaletteJSON.literal(plugin.path))
    local paths = \(palettePaths)
    local backgrounds = \(backgrounds)
    local foregrounds = \(foregrounds)
    local modes = \(modes)
    vim.o.termguicolors = false
    vim.o.background = 'dark'
    vim.g.colors_name = nil
    vim.api.nvim_set_hl(0, 'Normal', {fg=0x123456, bg=0x234567})
    vim.g.terminal_color_0 = '#345678'
    for i, source in ipairs(paths) do
      vim.fn.writefile(vim.fn.readfile(source), plugin)
      if i == 1 then dofile(plugin) end
      assert(vim.wait(2000, function()
        return vim.api.nvim_get_hl(0, {name='Normal'}).bg == backgrounds[i]
      end, 10), 'palette watcher did not update theme ' .. i)
      local normal = vim.api.nvim_get_hl(0, {name='Normal'})
      assert(normal.fg == foregrounds[i], 'wrong foreground for ' .. i)
      assert(vim.o.background == modes[i], 'wrong light/dark mode for ' .. i)
      assert(vim.g.colors_name == 'mac-themes', 'wrong active colorscheme')
    end
    vim.fn.delete(plugin)
    assert(vim.wait(2000, function() return _G.mac_themes_watcher == nil end, 10), 'watcher did not restore after removal')
    local restored = vim.api.nvim_get_hl(0, {name='Normal'})
    assert(restored.fg == 0x123456 and restored.bg == 0x234567, 'original highlight not restored')
    assert(vim.o.termguicolors == false, 'original truecolor option not restored')
    assert(vim.g.terminal_color_0 == '#345678', 'original ANSI color not restored')
    assert(vim.g.colors_name == nil, 'original colorscheme name not restored')
    print('All six palettes loaded, hot reloaded, and restored in isolated Neovim')
    vim.cmd('qa!')
    """
    let runner = fixture.appendingPathComponent("verify.lua")
    try ManagedConfig.write(script, to: runner)
    let process = Process(), output = Pipe()
    process.executableURL = nvim
    process.arguments = ["--headless", "-u", "NONE", "-i", "NONE", "--noplugin", "-l", runner.path]
    process.currentDirectoryURL = fixture
    var environment = ProcessInfo.processInfo.environment
    for key in ["HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"] { environment[key] = fixture.path }
    environment.removeValue(forKey: "NVIM"); environment.removeValue(forKey: "NVIM_LISTEN_ADDRESS")
    process.environment = environment
    process.standardOutput = output; process.standardError = output
    try process.run()
    let result = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, Comment(rawValue: String(decoding: result, as: UTF8.self)))
}

@MainActor @Test func obsidianSnippetsFollowConfiguredVaultsAndPreserveOtherSnippets() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let vault = home.appendingPathComponent("My Vault"), config = vault.appendingPathComponent(".obsidian/appearance.json")
    try ManagedConfig.write("{\"enabledCssSnippets\":[\"keep-me\"],\"baseFontSize\":18}", to: config)
    let service = try AdditionalIntegrations(root: home.appendingPathComponent("state"), home: home, live: false)
    try ManagedConfig.write(PaletteJSON.literal(["obsidianVaults": [vault.path]]), to: service.configuredLocations)
    let status = try service.apply(Theme.all[0], to: .obsidian)
    #expect(status.contains("enable mac-themes"))
    let snippet = vault.appendingPathComponent(".obsidian/snippets/mac-themes.css")
    #expect(try String(contentsOf: snippet, encoding: .utf8).contains(Theme.all[0].background))
    try ManagedConfig.write("{\"enabledCssSnippets\":[\"keep-me\",\"mac-themes\",\"added-later\"],\"baseFontSize\":20}", to: config)
    _ = try service.restore(.obsidian)
    let final = try String(contentsOf: config, encoding: .utf8)
    #expect(try PaletteJSON.raw(final, path: ["enabledCssSnippets"]) == "[\"keep-me\",\"added-later\"]")
    #expect(try PaletteJSON.raw(final, path: ["baseFontSize"]) == "20")
    #expect(!FileManager.default.fileExists(atPath: snippet.path))
}

@MainActor @Test func obsidianInitiallyDisabledSnippetPreservesBetweenApplyEdits() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let vault = home.appendingPathComponent("Initially Unstyled Vault")
    let appearance = vault.appendingPathComponent(".obsidian/appearance.json")
    try ManagedConfig.write("{\"enabledCssSnippets\":[],\"baseFontSize\":16,\"cssTheme\":\"\"}", to: appearance)
    let root = home.appendingPathComponent("state")
    let service = try AdditionalIntegrations(root: root, home: home, live: false)
    try ManagedConfig.write(PaletteJSON.literal(["obsidianVaults": [vault.path]]), to: service.configuredLocations)
    _ = try service.apply(Theme.all[0], to: .obsidian)
    // Simulate one-time user activation, a font change, and a separately added snippet.
    try ManagedConfig.write("{\"enabledCssSnippets\":[\"mac-themes\",\"user-snippet\"],\"baseFontSize\":22,\"cssTheme\":\"A user-selected theme\"}", to: appearance)
    for theme in Theme.all.dropFirst() { _ = try service.apply(theme, to: .obsidian) }
    let fresh = try AdditionalIntegrations(root: root, home: home, live: false)
    _ = try fresh.restore(.obsidian)
    let result = try String(contentsOf: appearance, encoding: .utf8)
    #expect(try PaletteJSON.raw(result, path: ["enabledCssSnippets"]) == "[\"user-snippet\"]")
    #expect(try PaletteJSON.raw(result, path: ["baseFontSize"]) == "22")
    #expect(try PaletteJSON.raw(result, path: ["cssTheme"]) == "\"A user-selected theme\"")
    #expect(!fresh.hasBackups)
}

@MainActor @Test func malformedObsidianSnippetStateFailsBeforeRemovingItsCSS() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let vault = home.appendingPathComponent("Vault"), appearance = vault.appendingPathComponent(".obsidian/appearance.json")
    try ManagedConfig.write("{\"enabledCssSnippets\":[]}", to: appearance)
    let service = try AdditionalIntegrations(root: home.appendingPathComponent("state"), home: home, live: false)
    try ManagedConfig.write(PaletteJSON.literal(["obsidianVaults": [vault.path]]), to: service.configuredLocations)
    _ = try service.apply(Theme.all[0], to: .obsidian)
    let css = vault.appendingPathComponent(".obsidian/snippets/mac-themes.css")
    let before = try String(contentsOf: css, encoding: .utf8)
    try ManagedConfig.write("{\"enabledCssSnippets\":\"edited elsewhere\"}", to: appearance)
    #expect(throws: (any Error).self) { try service.restore(.obsidian) }
    #expect(try String(contentsOf: css, encoding: .utf8) == before)
    #expect(service.hasBackups)
    #expect(throws: (any Error).self) { try service.apply(Theme.all[1], to: .obsidian) }
    #expect(try String(contentsOf: css, encoding: .utf8) == before)
}

@MainActor @Test func obsidianZeroExitWithoutActivationStaysPendingAndRestoreStillRemovesCSS() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let vault = home.appendingPathComponent("Local/Notes"), otherVault = home.appendingPathComponent("Cloud/Notes")
    let appearance = vault.appendingPathComponent(".obsidian/appearance.json")
    try ManagedConfig.write("{\"enabledCssSnippets\":[]}", to: appearance)
    let registry = home.appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
    try ManagedConfig.write(PaletteJSON.literal(["vaults": ["local-vault-id": ["path": vault.path], "other-vault-id": ["path": otherVault.path]]]), to: registry)
    var calls: [[String]] = []
    let service = try AdditionalIntegrations(root: home.appendingPathComponent("state"), home: home, live: false, obsidianCommand: { arguments, directory in
        #expect(directory.standardizedFileURL.path == vault.standardizedFileURL.path)
        calls.append(arguments)
        // Models the observed bundled CLI: normal process completion, no state mutation.
        return "Error: Command line interface is disabled."
    })
    try ManagedConfig.write(PaletteJSON.literal(["obsidianVaults": [vault.path]]), to: service.configuredLocations)
    let status = try service.apply(Theme.all[0], to: .obsidian)
    #expect(status.hasPrefix("Saved"))
    #expect(!status.hasPrefix("Applied"))
    #expect(calls == [["vault=local-vault-id", "snippet:enable", "name=mac-themes"]])
    #expect(try AdditionalIntegrations.obsidianEnabledSnippets(String(contentsOf: appearance, encoding: .utf8)).isEmpty)
    // After manual activation, a zero-exit disable command is also insufficient. The normal
    // restoration path must nevertheless remove owned CSS and preserve other snippets.
    try ManagedConfig.write("{\"enabledCssSnippets\":[\"mac-themes\",\"keep-me\"]}", to: appearance)
    let restored = try service.restore(.obsidian)
    #expect(restored == "Restored · prior CSS files and snippet settings saved")
    #expect(calls.last == ["vault=local-vault-id", "snippet:disable", "name=mac-themes"])
    #expect(try AdditionalIntegrations.obsidianEnabledSnippets(String(contentsOf: appearance, encoding: .utf8)) == ["keep-me"])
    #expect(!FileManager.default.fileExists(atPath: vault.appendingPathComponent(".obsidian/snippets/mac-themes.css").path))
}

@MainActor @Test func obsidianReportsAppliedOnlyAfterTargetMembershipIsConfirmed() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let vault = home.appendingPathComponent("Notes"), appearance = vault.appendingPathComponent(".obsidian/appearance.json")
    try ManagedConfig.write("{\"enabledCssSnippets\":[\"keep-me\"]}", to: appearance)
    let registry = home.appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
    try ManagedConfig.write(PaletteJSON.literal(["vaults": ["wanted-id": ["path": vault.path]]]), to: registry)
    let service = try AdditionalIntegrations(root: home.appendingPathComponent("state"), home: home, live: false, obsidianCommand: { arguments, directory in
        #expect(arguments.first == "vault=wanted-id")
        #expect(directory.standardizedFileURL.path == vault.standardizedFileURL.path)
        try ManagedConfig.write("{\"enabledCssSnippets\":[\"keep-me\",\"mac-themes\"]}", to: appearance)
        return "Enabled."
    })
    let status = try service.apply(Theme.all[0], to: .obsidian)
    #expect(status == "Applied · watched snippet in 1 vault(s)")
}

@Test func generatedBtopColorsUseTheInstalledThemesKnownFields() throws {
    let folder = URL(fileURLWithPath: "/opt/homebrew/share/btop/themes")
    guard FileManager.default.fileExists(atPath: folder.path) else { return }
    let expression = try NSRegularExpression(pattern: ##"(?m)^theme\[([a-z_]+)\]\s*=\s*"#[0-9a-fA-F]{6}""##)
    func keys(_ text: String) -> Set<String> {
        let ns = text as NSString
        return Set(expression.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })
    }
    let references = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "theme" }
    let known = try references.reduce(into: Set<String>()) { result, file in result.formUnion(keys(try String(contentsOf: file, encoding: .utf8))) }
    #expect(known.contains("main_bg"))
    for theme in Theme.all {
        let generated = AdditionalPalette.btop(theme), generatedKeys = keys(generated)
        #expect(generatedKeys.isSubset(of: known))
        #expect(generatedKeys.contains("main_fg") && generatedKeys.contains("cpu_start") && generatedKeys.contains("selected_bg"))
        #expect(generated.split(separator: "\n").filter { !$0.hasPrefix("#") }.count == generatedKeys.count)
    }
}

@MainActor @Test func additionalJournalCorruptionFailsClosedAndInitializationDoesNotWrite() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let root = home.appendingPathComponent("state")
    _ = try AdditionalIntegrations(root: root, home: home, live: false)
    #expect(!FileManager.default.fileExists(atPath: root.path))
    try ManagedConfig.write("bad journal", to: root.appendingPathComponent("additional-state.json"))
    #expect(throws: (any Error).self) { try AdditionalIntegrations(root: root, home: home, live: false) }
}

@MainActor @Test func reloadSignalsRequireACurrentUserInstalledHandler() {
    #expect(!AdditionalIntegrations.catchesReloadSignal(SIGKILL, pid: getpid()))
    #expect(!AdditionalIntegrations.catchesReloadSignal(SIGUSR2, pid: -1))
    #expect(!AdditionalIntegrations.catchesReloadSignal(0, pid: getpid()))
}
