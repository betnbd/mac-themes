import Foundation
import Testing
import ThemeCore
@testable import MacThemes

@Test @MainActor func previewSelectionWorksWithAllDestinationsDisabled() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = ThemeStore(demo: true, root: root)
    store.enabled = []
    store.select(Theme.all[2])
    #expect(store.selected == Theme.all[2])
    #expect(!store.busy)
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test @MainActor func themeSelectionCannotEnterAnUndrainedRestoreQueue() {
    let store = ThemeStore(demo: true, root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let original = store.selected
    store.restoring = true
    store.busy = true
    store.select(Theme.all[2])
    #expect(!store.canApply)
    #expect(store.selected == original)
}

@Test @MainActor func previewWallpaperSelectionDoesNotCreateLiveRestoreState() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = ThemeStore(demo: true, root: root)
    store.selectWallpaper(WallpaperChoice(id: "sample.png", name: "Sample", url: root.appendingPathComponent("sample.png")))
    #expect(store.previewWallpaperIDs[store.selected.id] == "sample.png")
    #expect(store.wallpaperIDs.isEmpty)
    #expect(!store.hasBackups)
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test @MainActor func focusedReleaseStartsWithTokyoAndOnlyFourApplications() {
    let store = ThemeStore(demo: true, root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    #expect(store.themes.map(\.id) == ["tokyo-night", "gruvbox", "osaka-jade", "hackerman", "catppuccin", "solitude", "everforest"])
    #expect(store.selected.id == "tokyo-night")
    #expect(!store.selected.isLight)
    #expect(Set(ThemeStore.focusedIntegrations) == [.ghostty, .obsidian, .brave, .chatgpt, .wallpaper, .macos])
    store.toggle(.terminal, enabled: true)
    #expect(!store.enabled.contains(.terminal))
}

@Test @MainActor func focusedUpgradeFiltersOldDestinationsWithoutDiscardingTheirJournal() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "MacThemes-Tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    defaults.set(["ghostty", "obsidian", "btop", "neovim", "terminal"], forKey: "enabledIntegrations")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let original = Data(#"{"apps":{"btop":[{"path":"/tmp/example","format":"file","original":"original","applied":"theme","fields":[]}]}}"#.utf8)
    try original.write(to: root.appendingPathComponent("additional-state.json"))
    let store = ThemeStore(demo: false, root: root, defaults: defaults)
    #expect(store.enabled == [.ghostty, .obsidian])
    #expect(store.previewOnly)
    #expect(store.hasBackups)
    #expect(try Data(contentsOf: root.appendingPathComponent("additional-state.json")) == original)
}

@Test @MainActor func previewApplyCannotCommitOrWritePreferences() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "MacThemes-Tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ThemeStore(demo: true, root: root, defaults: defaults)
    store.selectWallpaper(WallpaperChoice(id: "other.jpg", name: "Other", url: root.appendingPathComponent("other.jpg")))
    store.applySelected()
    #expect(store.previewOnly)
    #expect(store.previewWallpaperIDs["tokyo-night"] == "other.jpg")
    #expect(defaults.dictionary(forKey: "wallpaperSelections") == nil)
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test @MainActor func restoreSummaryPreservesManualNextStepsInsteadOfReportingCompletion() {
    let waiting = "Waiting · quit ChatGPT, then choose Restore again"
    let pending = ThemeStore.restoreSummary(statuses: [.ghostty: "Restored · full terminal palette", .chatgpt: waiting], failures: [])
    #expect(pending == "ChatGPT: \(waiting)")
    #expect(!pending.contains("Previous settings restored"))
    let failure = "Terminal: Open Terminal to restore its colors."
    let mixed = ThemeStore.restoreSummary(statuses: [.chatgpt: waiting, .terminal: "Queued · open Terminal to finish"], failures: [failure])
    #expect(mixed.contains(failure))
    #expect(mixed.contains("Terminal: Queued · open Terminal to finish"))
    #expect(mixed.contains("ChatGPT: \(waiting)"))
    let complete = ThemeStore.restoreSummary(statuses: [.ghostty: "Restored · full terminal palette", .chatgpt: "No changes to restore"], failures: [])
    #expect(complete.hasPrefix("Previous settings restored."))
}

@Test @MainActor func reopeningAppliedThemeKeepsNewSelectionsPreviewOnly() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "MacThemes-Tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    defaults.set(true, forKey: "tokyoNightSetupSeen")
    defaults.set([String](), forKey: "enabledIntegrations")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var state = SavedState()
    state.activeTheme = "gruvbox"
    try JSONEncoder().encode(state).write(to: root.appendingPathComponent("state.json"))
    let store = ThemeStore(demo: false, root: root, defaults: defaults)
    for _ in 0..<100 where store.selected.id != "gruvbox" { try await Task.sleep(for: .milliseconds(10)) }
    #expect(store.selected.id == "gruvbox")
    #expect(store.previewOnly)
    let original = try Data(contentsOf: root.appendingPathComponent("state.json"))
    store.enabled = [.macos, .wallpaper, .ghostty, .brave, .chatgpt]
    store.select(Theme.bundled[0])
    store.selectWallpaper(WallpaperChoice(id: "preview.png", name: "Preview", url: root.appendingPathComponent("preview.png")))
    try await Task.sleep(for: .milliseconds(400))
    #expect(store.selected.id == "tokyo-night")
    #expect(!store.busy)
    #expect(store.previewOnly)
    #expect(store.wallpaperIDs.isEmpty)
    #expect(try Data(contentsOf: root.appendingPathComponent("state.json")) == original)
    #expect(defaults.dictionary(forKey: "wallpaperSelections") == nil)
}

@Test @MainActor func corruptApplicationResultsDisableApplyButRetainRestoreAccess() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var state = SavedState(); state.ghosttyPath = root.appendingPathComponent("config").path
    try JSONEncoder().encode(state).write(to: root.appendingPathComponent("state.json"))
    try Data("not a result journal".utf8).write(to: root.appendingPathComponent("application-results.json"))
    let store = ThemeStore(demo: false, root: root, defaults: defaults)
    #expect(!store.canApply)
    #expect(store.hasBackups)
    try await Task.sleep(for: .milliseconds(30))
    #expect(try Data(contentsOf: root.appendingPathComponent("application-results.json")) == Data("not a result journal".utf8))
}
