import AppKit
import Foundation
import Testing
import ThemeCore
@testable import MacThemes

@Test @MainActor func automationScriptsCompileWithoutExecution() throws {
    let colors = TerminalColors(name: "Profile with \"quotes\" and \\ backslash", background: [100, 200, 300], text: [400, 500, 600], bold: [700, 800, 900], cursor: [1000, 1100, 1200])
    let applied = TerminalColors(name: colors.name, background: [0, 0, 0], text: [65535, 65535, 65535], bold: [65535, 65535, 65535], cursor: [65535, 0, 0])
    let commands = [AppleScripts.restoreTerminalColors(TerminalBackup(original: colors, applied: applied))]
    for source in commands {
        let script = try #require(NSAppleScript(source: source))
        var error: NSDictionary?
        let compiled = script.compileAndReturnError(&error)
        #expect(compiled, "\(error?.description ?? "Script failed to compile")")
    }
}

@Test @MainActor func corruptRestoreJournalIsNotDiscarded() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("broken journal".utf8).write(to: root.appendingPathComponent("state.json"))
    #expect(throws: (any Error).self) { try Integrations(root: root) }
}

@Test @MainActor func newServiceDoesNotWriteSettingsOnLaunch() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = try Integrations(root: root)
    #expect(!service.hasBackups)
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test func chatGPTPalettesPreserveTypographyAndSelectCorrectMode() throws {
    for theme in Theme.all {
        let key = theme.id == "catppuccin-latte" ? "appearanceLightChromeTheme" : "appearanceDarkChromeTheme"
        let original: [String: Any] = [key: ["fonts": ["ui": "Custom UI", "code": "Custom Mono"], "contrast": 73, "opaqueWindows": false]]
        let values = ChatGPTConfigEditor.themedSettings(theme, current: original)
        let colors = try #require(values[key] as? [String: Any])
        #expect(values["appearanceTheme"] as? String == (theme.id == "catppuccin-latte" ? "light" : "dark"))
        #expect(colors["surface"] as? String == theme.background)
        #expect(colors["ink"] as? String == theme.foreground)
        #expect(colors["accent"] as? String == theme.accent)
        #expect(colors["accentSource"] as? String == "custom")
        #expect(colors["fonts"] as? [String: String] == ["ui": "Custom UI", "code": "Custom Mono"])
        #expect(colors["contrast"] as? Int == 73)
        #expect(colors["opaqueWindows"] as? Bool == false)
    }
}

@Test @MainActor func olderJournalStillLoadsWithoutChatGPTBackup() throws {
    let data = Data(#"{"ghosttyExisted":false,"terminal":{},"braveCaptured":false}"#.utf8)
    let state = try JSONDecoder().decode(SavedState.self, from: data)
    #expect(state.chatgpt == nil)
}

@Test func installedChatGPTEditorAppliesAndRestoresAllSamplesInIsolation() throws {
    let executable = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else { return }
    let original = """
    # Keep this user's unrelated configuration and comments
    model = "example-model"
    [desktop]
    unrelatedPreference = "keep me"
    appearanceTheme = "system"
    [desktop.appearanceDarkChromeTheme]
    accent = "#123456"
    surface = "#111111"
    ink = "#eeeeee"
    contrast = 72
    opaqueWindows = false
    [desktop.appearanceDarkChromeTheme.fonts]
    ui = "Custom UI"
    code = "Custom Mono"
    [desktop.appearanceDarkChromeTheme.semanticColors]
    diffAdded = "#00ff00"
    diffRemoved = "#ff0000"
    skill = "#0000ff"
    [projects."/tmp/example"]
    trust_level = "untrusted"

    """
    for theme in Theme.all {
        let editor = try ChatGPTConfigEditor(executable: executable, source: original)
        let values = ChatGPTConfigEditor.themedSettings(theme, current: editor.settings)
        var restore: [String: Any] = [:]
        for key in values.keys { restore[key] = editor.settings[key] ?? NSNull() }
        let updated = try editor.replacing(values)
        #expect(updated.contains("# Keep this user's unrelated configuration and comments"))
        #expect(updated.contains("model = \"example-model\""))
        #expect(updated.contains("unrelatedPreference = \"keep me\""))
        #expect(updated.contains("trust_level = \"untrusted\""))
        let reader = try ChatGPTConfigEditor(executable: executable, source: updated)
        #expect(reader.settings["appearanceTheme"] as? String == (theme.id == "catppuccin-latte" ? "light" : "dark"))
        let restored = try reader.replacing(restore)
        let check = try ChatGPTConfigEditor(executable: executable, source: restored)
        #expect(try ChatGPTConfigEditor.encode(check.settings) == ChatGPTConfigEditor.encode(editor.settings))
    }
}

@Test func chatGPTEditorRejectsNonAppearanceChanges() throws {
    let executable = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else { return }
    let editor = try ChatGPTConfigEditor(executable: executable, source: "[desktop]\n")
    #expect(throws: (any Error).self) { try editor.replacing(["unrelatedSetting": true]) }
}

@Test(.enabled(if: FileManager.default.fileExists(atPath: "/Applications/Ghostty.app"), "Requires Ghostty's installed scripting dictionary"))
@MainActor func ghosttyScriptCompilesWithoutExecutionWhenInstalled() throws {
    let script = try #require(NSAppleScript(source: AppleScripts.ghosttyReload))
    var error: NSDictionary?
    #expect(script.compileAndReturnError(&error), "\(error?.description ?? "Script failed to compile")")
}
