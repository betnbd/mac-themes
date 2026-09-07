import Foundation
import Testing
import ThemeCore
@testable import MacThemes

private let configurationEditor = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
private let originalChatGPTFixture = """
# Preserve unrelated preferences and comments across a whole theme sequence.
model = "fixture-model"
[desktop]
appearanceTheme = "system"
fixtureUnrelated = "unchanged"
appearanceDarkCodeThemeId = "nord"
[desktop.appearanceDarkChromeTheme]
accent = "#123456"
accentSource = "custom"
surface = "#121212"
ink = "#dedede"
contrast = 71
opaqueWindows = false
[desktop.appearanceDarkChromeTheme.fonts]
ui = "Fixture UI Font"
code = "Fixture Code Font"
[desktop.appearanceDarkChromeTheme.semanticColors]
diffAdded = "#00aa00"
diffRemoved = "#aa0000"
skill = "#0000aa"
[projects."/tmp/fixture-project"]
trust_level = "untrusted"

"""

@Test func chatGPTSwitchesAcrossBothVariantsAndRestoresInitialSettingsInIsolation() throws {
    guard FileManager.default.isExecutableFile(atPath: configurationEditor.path) else { return }
    let original = try ChatGPTConfigEditor(executable: configurationEditor, source: originalChatGPTFixture)
    var source = originalChatGPTFixture
    var backup = ChatGPTBackup(path: "/fixture/config.toml", settings: [:])
    for theme in Theme.all {
        let editor = try ChatGPTConfigEditor(executable: configurationEditor, source: source)
        let desired = ChatGPTConfigEditor.themedSettings(theme, current: editor.settings)
        backup = try backup.recording(desired, current: editor.settings)
        backup = try JSONDecoder().decode(ChatGPTBackup.self, from: JSONEncoder().encode(backup))
        source = try editor.replacing(desired)
        #expect(source.contains("# Preserve unrelated preferences and comments"))
        #expect(source.contains("fixtureUnrelated = \"unchanged\""))
        #expect(source.contains("trust_level = \"untrusted\""))
    }
    let final = try ChatGPTConfigEditor(executable: configurationEditor, source: source)
    #expect(backup.settings.count == 3)
    let restore = try backup.restoredSettings(current: final.settings)
    let restoredSource = try final.replacing(restore)
    let restored = try ChatGPTConfigEditor(executable: configurationEditor, source: restoredSource)
    #expect(try ChatGPTConfigEditor.encode(restored.settings) == ChatGPTConfigEditor.encode(original.settings))
    #expect(restored.settings["appearanceLightChromeTheme"] == nil)
    #expect(restored.settings["appearanceDarkCodeThemeId"] as? String == "nord")
}

@Test func chatGPTJournalAllowsPartialAttemptsButRefusesIndependentAppearanceEdits() throws {
    guard FileManager.default.isExecutableFile(atPath: configurationEditor.path) else { return }
    let editor = try ChatGPTConfigEditor(executable: configurationEditor, source: originalChatGPTFixture)
    let first = try #require(Theme.all.first { !$0.isLight })
    let desired = ChatGPTConfigEditor.themedSettings(first, current: editor.settings)
    let backup = try ChatGPTBackup(path: "/fixture/config.toml", settings: [:]).recording(desired, current: editor.settings)
    // A write that failed before commit leaves original settings restorable.
    #expect(try backup.restoredSettings(current: editor.settings).count == 2)
    var partial = editor.settings
    partial["appearanceTheme"] = desired["appearanceTheme"]
    #expect(try backup.restoredSettings(current: partial).count == 2)
    var externallyChanged = desired
    var appearance = try #require(externallyChanged["appearanceDarkChromeTheme"] as? [String: Any])
    appearance["accent"] = "#987654"
    externallyChanged["appearanceDarkChromeTheme"] = appearance
    #expect(throws: (any Error).self) { try backup.restoredSettings(current: externallyChanged) }
    // Reading the backup is pure; it does not mutate or discard the originals.
    #expect(try backup.restoredSettings(current: desired).count == 2)
}

@Test func chatGPTJournalRetainsLastVisiblePaletteAfterFailedSecondApply() throws {
    guard FileManager.default.isExecutableFile(atPath: configurationEditor.path) else { return }
    let original = try ChatGPTConfigEditor(executable: configurationEditor, source: originalChatGPTFixture)
    let darkThemes = Theme.all.filter { !$0.isLight }
    let first = try #require(darkThemes.first)
    let second = try #require(darkThemes.dropFirst().first)
    let desiredFirst = ChatGPTConfigEditor.themedSettings(first, current: original.settings)
    var backup = try ChatGPTBackup(path: "/fixture/config.toml", settings: [:]).recording(desiredFirst, current: original.settings)
    let updated = try original.replacing(desiredFirst)
    let visible = try ChatGPTConfigEditor(executable: configurationEditor, source: updated)
    let desiredSecond = ChatGPTConfigEditor.themedSettings(second, current: visible.settings)
    backup = try backup.recording(desiredSecond, current: visible.settings)
    let restoredSource = try visible.replacing(backup.restoredSettings(current: visible.settings))
    let check = try ChatGPTConfigEditor(executable: configurationEditor, source: restoredSource)
    #expect(try ChatGPTConfigEditor.encode(check.settings) == ChatGPTConfigEditor.encode(original.settings))
}

@Test func chatGPTMalformedConfigurationErrorDoesNotExposeSourceContents() throws {
    guard FileManager.default.isExecutableFile(atPath: configurationEditor.path) else { return }
    let marker = "PRIVATE_FIXTURE_VALUE_NOT_A_REAL_SECRET"
    do {
        _ = try ChatGPTConfigEditor(executable: configurationEditor, source: "[desktop\nfixture = \"\(marker)\"\n")
        Issue.record("Malformed TOML unexpectedly loaded")
    } catch {
        #expect(!error.localizedDescription.contains(marker))
    }
}

@Test func chatGPTMalformedBackupRefusesRestoreWithoutChangingCurrentSettings() throws {
    let backup = ChatGPTBackup(path: "/fixture/config.toml", settings: [
        "appearanceTheme": ChatGPTSettingBackup(original: Data("invalid json".utf8), applied: try ChatGPTConfigEditor.encode("dark"))
    ])
    #expect(throws: (any Error).self) { try backup.restoredSettings(current: ["appearanceTheme": "dark"]) }
}
