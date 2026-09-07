import AppKit
import Foundation
import Testing
import ThemeCore
@testable import MacThemes

@Test func chromiumThemePackagesContainColorsWithoutCodeOrPermissions() throws {
    for theme in Theme.all {
        let value = try #require(JSONSerialization.jsonObject(with: ChromiumThemePackage.manifest(theme)) as? [String: Any])
        #expect(value["permissions"] == nil)
        #expect(value["background"] == nil)
        #expect(value["content_scripts"] == nil)
        let themed = try #require(value["theme"] as? [String: Any])
        let colors = try #require(themed["colors"] as? [String: [Int]])
        let frame = theme.id == "tokyo-night" ? "#13141c" : theme.background
        #expect(colors["frame"] == ScriptLiteral.rgb(frame).map { $0 / 257 })
        #expect(colors["tab_text"] == ScriptLiteral.rgb(theme.foreground).map { $0 / 257 })
        #expect(colors.values.allSatisfy { $0.count == 3 && $0.allSatisfy { (0...255).contains($0) } })
    }
}

@Test func chromiumThemeExportKeepsUntrustedNamesInsideExports() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let theme = Theme(id: "../../outside", name: "A \"quoted\" theme", subtitle: "Imported", background: "#ffffff", foreground: "#111111", accent: "#abcdef", selection: "#cccccc", cursor: "#111111", palette: Theme.all[0].palette)
    let directory = try ChromiumThemePackage.export(theme: theme, root: root)
    #expect(directory.deletingLastPathComponent() == root.appendingPathComponent("Exports/Chromium", isDirectory: true))
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path))
    let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as? [String: Any])
    #expect(manifest["name"] as? String == "Mac Themes · A \"quoted\" theme")
}

@Test func importedLightChatGPTThemeUsesItsModeInsteadOfItsName() throws {
    let theme = Theme(id: "community-daylight", name: "Daylight", subtitle: "Imported", background: "#f9f5e8", foreground: "#252525", accent: "#336699", selection: "#dddddd", cursor: "#252525", palette: Theme.all[0].palette, mode: "light")
    let values = ChatGPTConfigEditor.themedSettings(theme, current: [:])
    #expect(values["appearanceTheme"] as? String == "light")
    #expect(values["appearanceLightChromeTheme"] != nil)
    #expect(values["appearanceDarkChromeTheme"] == nil)
}

@Test func chatGPTThemeShareStringIncludesNullableDefaultFontsAndPalette() throws {
    for theme in Theme.all {
        let encoded = try ChatGPTConfigEditor.shareString(theme)
        #expect(encoded.hasPrefix("codex-theme-v1:"))
        let value = try #require(JSONSerialization.jsonObject(with: Data(encoded.dropFirst(15).utf8)) as? [String: Any])
        let appearance = try #require(value["theme"] as? [String: Any])
        let fonts = try #require(appearance["fonts"] as? [String: Any])
        #expect(fonts["ui"] is NSNull)
        #expect(fonts["code"] is NSNull)
        #expect(value["variant"] as? String == (theme.isLight ? "light" : "dark"))
        #expect(appearance["surface"] as? String == theme.background)
        #expect(appearance["ink"] as? String == theme.foreground)
    }
}

@Test func chatGPTSharePreservesExistingTypographyAndSyntaxTheme() throws {
    let theme = try #require(Theme.all.first { !$0.isLight })
    let current: [String: Any] = ["appearanceDarkChromeTheme": ["fonts": ["ui": "My Font", "code": "My Code Font"], "contrast": 72, "opaqueWindows": false], "appearanceDarkCodeThemeId": "nord"]
    let encoded = try ChatGPTConfigEditor.shareString(theme, current: current)
    let value = try #require(JSONSerialization.jsonObject(with: Data(encoded.dropFirst(15).utf8)) as? [String: Any])
    let appearance = try #require(value["theme"] as? [String: Any])
    #expect(value["codeThemeId"] as? String == "nord")
    #expect(appearance["fonts"] as? [String: String] == ["ui": "My Font", "code": "My Code Font"])
    #expect(appearance["contrast"] as? Int == 72)
    #expect(appearance["opaqueWindows"] as? Bool == false)
}

@Test @MainActor func restoreCancelsQueuedFirstChatGPTApplyWithoutAccessingConfiguration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = try Integrations(root: root)
    service.state.chatgptPending = .apply(Theme.all[0])
    try service.save()
    #expect(service.hasBackups)
    #expect(try service.restoreChatGPT() == "Cancelled queued palette")
    #expect(service.state.chatgptPending == nil)
    #expect(!service.hasBackups)
    #expect(try Integrations(root: root).state.chatgptPending == nil)
}

@Test @MainActor func chatGPTQueueKeepsLatestIntentAcrossLauncherRestarts() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = try Integrations(root: root)
    try service.queueChatGPT(.apply(Theme.all[0]))
    try service.queueChatGPT(.apply(Theme.all[1]))
    #expect(service.state.chatgpt == nil)
    #expect(try Integrations(root: root).state.chatgptPending == .apply(Theme.all[1]))
    try service.queueChatGPT(.restore)
    #expect(try Integrations(root: root).state.chatgptPending == .restore)
}

@Test func focusedChatGPTThemeSelectsNativeTokyoNightSyntax() throws {
    let text = try ChatGPTConfigEditor.shareString(Theme.all[0])
    let object = try #require(JSONSerialization.jsonObject(with: Data(text.dropFirst("codex-theme-v1:".count).utf8)) as? [String: Any])
    #expect(object["codeThemeId"] as? String == "tokyo-night")
    #expect(object["variant"] as? String == "dark")
}
