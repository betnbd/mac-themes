import Foundation
import Testing
import ThemeCore
@testable import MacThemes

@MainActor private final class AppearanceFixture: ChatGPTAppearanceClient {
    var isRunning = true
    var appearanceMode = "system"
    var shares: [String: String]
    var imports: [String] = []
    var prepares = 0
    var failImport = false
    var ignoreImport = false
    var failCopy = false
    var failMode = false
    var finished = 0
    var beforeImport: (() throws -> Void)?
    var beforeMode: (() throws -> Void)?
    init() throws {
        shares = ["dark": try ChatGPTConfigEditor.shareString(Theme.all[1]), "light": try ChatGPTConfigEditor.shareString(Theme.all[2])]
    }
    func prepare() async throws { prepares += 1 }
    func mode() throws -> String { appearanceMode }
    func copyTheme(_ variant: String) async throws -> String {
        guard !failCopy, appearanceMode == "system" || appearanceMode == variant else {
            throw ThemeError.message("Fixture theme controls are unavailable")
        }
        return shares[variant]!
    }
    func importTheme(_ share: String, variant: String) async throws {
        guard appearanceMode == "system" || appearanceMode == variant else {
            throw ThemeError.message("Fixture importer is hidden")
        }
        try beforeImport?()
        if failImport { throw ThemeError.message("Fixture import rejected") }
        imports.append(variant)
        if !ignoreImport { shares[variant] = share }
    }
    func setMode(_ mode: String) async throws {
        try beforeMode?()
        if failMode { throw ThemeError.message("Fixture mode rejected") }
        appearanceMode = mode
    }
    func finish() { finished += 1 }
}

@Test @MainActor func liveChatGPTAppliesImmediatelyPreservesFontsAndRestoresOriginalMode() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let client = try AppearanceFixture()
    var source = try ChatGPTThemeShare(client.shares["dark"]!).object
    var appearance = source["theme"] as! [String: Any]
    appearance["fonts"] = ["ui": "Inter", "code": "Monaco", "content": "Georgia"]
    appearance["contrast"] = 71
    appearance["opaqueWindows"] = false
    source["theme"] = appearance
    let original = "codex-theme-v1:" + String(decoding: try JSONSerialization.data(withJSONObject: source), as: UTF8.self)
    client.shares["dark"] = original
    let service = try ChatGPTLiveTheme(root: root, client: client)
    client.beforeImport = {
        let saved = try JSONDecoder().decode(ChatGPTLiveTheme.Journal.self, from: Data(contentsOf: root.appendingPathComponent("chatgpt-live-state.json")))
        #expect(saved.themes["dark"]?.original == original)
    }
    #expect(try await service.apply(Theme.all[0]).hasPrefix("Applied"))
    let applied = try ChatGPTThemeShare(client.shares["dark"]!)
    #expect(applied.theme["surface"] as? String == "#1a1b26")
    #expect(applied.codeTheme == "tokyo-night")
    #expect((applied.theme["fonts"] as? [String: String])?["content"] == "Georgia")
    #expect(applied.theme["contrast"] as? Int == 71)
    #expect(applied.theme["opaqueWindows"] as? Bool == false)
    #expect(client.appearanceMode == "dark")
    #expect(service.pendingTheme == nil)
    #expect(try await service.restore().hasPrefix("Restored"))
    #expect(client.shares["dark"] == original)
    #expect(client.appearanceMode == "system")
    #expect(!service.hasBackups)
}

@Test @MainActor func closedChatGPTQueuesOnlyLatestThemeWithoutOpeningTheApp() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let client = try AppearanceFixture(); client.isRunning = false
    let service = try ChatGPTLiveTheme(root: root, client: client)
    #expect(try await service.apply(Theme.all[0]).hasPrefix("Waiting"))
    _ = try await service.apply(Theme.all[2])
    #expect(client.prepares == 0)
    #expect(client.imports.isEmpty)
    let recovered = try ChatGPTLiveTheme(root: root, client: client)
    #expect(recovered.pendingTheme == Theme.all[2])
    client.isRunning = true
    #expect(try await recovered.apply(recovered.pendingTheme!).hasPrefix("Applied"))
    #expect(client.appearanceMode == "light")
    #expect(recovered.pendingTheme == nil)
}

@Test @MainActor func repeatedLiveThemesKeepFirstBackupAcrossRelaunch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let client = try AppearanceFixture(), original = client.shares["dark"]!
    let service = try ChatGPTLiveTheme(root: root, client: client)
    _ = try await service.apply(Theme.all[0])
    let recovered = try ChatGPTLiveTheme(root: root, client: client)
    _ = try await recovered.apply(Theme.all[3])
    #expect(recovered.journal.themes["dark"]?.original == original)
    _ = try await recovered.restore()
    #expect(client.shares["dark"] == original)
}

@Test @MainActor func liveImportFailureKeepsBackupAndNeverReportsApplied() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let client = try AppearanceFixture(); client.failImport = true
    let original = client.shares["dark"]
    let service = try ChatGPTLiveTheme(root: root, client: client)
    await #expect(throws: (any Error).self) { try await service.apply(Theme.all[0]) }
    #expect(service.hasBackups)
    #expect(service.pendingTheme == Theme.all[0])
    #expect(client.shares["dark"] == original)
    #expect(client.finished == 1)
    client.failImport = false
    _ = try await service.apply(Theme.all[0])
    #expect(service.journal.themes["dark"]?.original == original)
}

@Test @MainActor func liveImportReadbackMismatchIsAnError() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let client = try AppearanceFixture(); client.ignoreImport = true
    let service = try ChatGPTLiveTheme(root: root, client: client)
    await #expect(throws: (any Error).self) { try await service.apply(Theme.all[0]) }
    #expect(service.pendingTheme != nil)
    #expect(service.hasBackups)
}

@Test @MainActor func liveRestorePreflightsBothVariantsAndPreservesOutsideEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let client = try AppearanceFixture()
    let service = try ChatGPTLiveTheme(root: root, client: client)
    _ = try await service.apply(Theme.all[0]); _ = try await service.apply(Theme.all[2])
    client.shares["dark"] = try ChatGPTConfigEditor.shareString(Theme.all[4])
    let count = client.imports.count
    await #expect(throws: (any Error).self) { try await service.restore() }
    #expect(client.imports.count == count)
    #expect(service.journal.themes.count == 2)
    #expect(client.appearanceMode == "light")
}

@Test @MainActor func liveThemeSwitchesFromLightToDarkAndRestoresBothHiddenVariants() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let client = try AppearanceFixture()
    client.appearanceMode = "light"
    let originals = client.shares
    let service = try ChatGPTLiveTheme(root: root, client: client)
    client.beforeMode = {
        let saved = try JSONDecoder().decode(ChatGPTLiveTheme.Journal.self, from: Data(contentsOf: root.appendingPathComponent("chatgpt-live-state.json")))
        #expect(saved.originalMode == "light")
    }
    _ = try await service.apply(Theme.all[0])
    #expect(client.appearanceMode == "dark")
    _ = try await service.apply(Theme.all[2])
    #expect(client.appearanceMode == "light")
    _ = try await service.restore()
    #expect(client.shares == originals)
    #expect(client.appearanceMode == "light")
}

@Test @MainActor func failedCaptureRetainsModeBackupAcrossRelaunch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let client = try AppearanceFixture()
    client.appearanceMode = "light"; client.failCopy = true
    let service = try ChatGPTLiveTheme(root: root, client: client)
    await #expect(throws: (any Error).self) { try await service.apply(Theme.all[0]) }
    #expect(client.appearanceMode == "dark")
    #expect(service.journal.themes.isEmpty)
    let recovered = try ChatGPTLiveTheme(root: root, client: client)
    #expect(recovered.hasBackups)
    _ = try await recovered.restore()
    #expect(client.appearanceMode == "light")
    #expect(!recovered.hasBackups)
}

@Test @MainActor func failedModeSwitchKeepsPreviouslyAppliedModeRestorable() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let client = try AppearanceFixture()
    let service = try ChatGPTLiveTheme(root: root, client: client)
    _ = try await service.apply(Theme.all[0])
    client.failMode = true
    await #expect(throws: (any Error).self) { try await service.apply(Theme.all[2]) }
    #expect(client.appearanceMode == "dark")
    client.failMode = false
    let recovered = try ChatGPTLiveTheme(root: root, client: client)
    _ = try await recovered.restore()
    #expect(client.appearanceMode == "system")
}

@Test @MainActor func liveThemeJournalCorruptionCannotOverwriteBackups() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let data = Data(#"{"themes":{"dark":{"original":"invalid","applied":"invalid","previous":"invalid"}}}"#.utf8)
    let path = root.appendingPathComponent("chatgpt-live-state.json")
    try data.write(to: path)
    let client = try AppearanceFixture()
    #expect(throws: (any Error).self) { try ChatGPTLiveTheme(root: root, client: client) }
    #expect(try Data(contentsOf: path) == data)
    #expect(client.prepares == 0)
}

@Test func nativeThemeComparisonAllowsEquivalentHexCaseAndNullFonts() throws {
    let share = try ChatGPTConfigEditor.shareString(Theme.all[0])
    var object = try ChatGPTThemeShare(share).object
    var theme = object["theme"] as! [String: Any]
    theme["surface"] = "#1A1B26"
    theme["fonts"] = [String: String]()
    object["theme"] = theme
    let equivalent = "codex-theme-v1:" + String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    #expect(try ChatGPTThemeShare(share).equivalent(to: equivalent))
    #expect(throws: (any Error).self) { try ChatGPTThemeShare("codex-theme-v1:{\"theme\":{}}") }
}
