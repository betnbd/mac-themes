import AppKit
import Testing
@testable import MacThemes
@testable import ThemeCore

@MainActor private func wallpaperFixture() throws -> (URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for x in 0..<2 { for y in 0..<2 { bitmap.setColor(.red, atX: x, y: y) } }
    let image = root.appendingPathComponent("My wallpaper.png")
    try bitmap.representation(using: .png, properties: [:])!.write(to: image)
    return (root, image)
}

@Test @MainActor func personalWallpapersAreCopiedDeduplicatedAndSurviveRestart() async throws {
    let (root, image) = try wallpaperFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try WallpaperLibrary(root: root)
    let original = try Data(contentsOf: image)
    let ids = try await library.add([image, image], to: "tokyo-night")
    #expect(ids.count == 1)
    let snapshot = await library.snapshot()
    let choices = WallpaperLibrary.choices([], themeID: "tokyo-night", root: root, snapshot: snapshot)
    #expect(choices.count == 1)
    #expect(choices[0].name == "My wallpaper")
    #expect(choices[0].url != image)
    #expect(try Data(contentsOf: choices[0].url) == original)
    #expect(WallpaperLibrary.choices([], themeID: "other", root: root, snapshot: snapshot).isEmpty)
    let restarted = try WallpaperLibrary(root: root)
    #expect(await restarted.snapshot()["tokyo-night"]?.added.first?.id == ids.first)
    try await restarted.setHidden(true, id: ids[0], themeID: "tokyo-night")
    #expect(try Data(contentsOf: image) == original)
    #expect(FileManager.default.fileExists(atPath: choices[0].url.path))
    #expect(WallpaperLibrary.choices([], themeID: "tokyo-night", root: root, snapshot: await restarted.snapshot()).isEmpty)
    _ = try await restarted.add([image], to: "tokyo-night")
    #expect(WallpaperLibrary.choices([], themeID: "tokyo-night", root: root, snapshot: await restarted.snapshot()).count == 1)
}

@Test @MainActor func removedUpstreamWallpapersStayHiddenAcrossThemeUpdatesAndCanBeRestored() async throws {
    let (root, image) = try wallpaperFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try WallpaperLibrary(root: root)
    _ = try await library.add([image], to: "imported-theme")
    let base = WallpaperChoice(id: "backgrounds/a.png", name: "A", url: root.appendingPathComponent("version-1/a.png"))
    try await library.setHidden(true, id: base.id, themeID: "imported-theme")
    let restarted = try WallpaperLibrary(root: root)
    let newer = WallpaperChoice(id: base.id, name: "A", url: root.appendingPathComponent("version-2/a.png"))
    let snapshot = await restarted.snapshot()
    #expect(WallpaperLibrary.choices([newer], themeID: "imported-theme", root: root, snapshot: snapshot).count == 1)
    #expect(WallpaperLibrary.choices([base], themeID: "other", root: root, snapshot: snapshot) == [base])
    try await restarted.setHidden(false, id: base.id, themeID: "imported-theme")
    #expect(WallpaperLibrary.choices([newer], themeID: "imported-theme", root: root, snapshot: await restarted.snapshot()).count == 2)
}

@Test @MainActor func invalidWallpaperBatchDoesNotLeavePartialImports() async throws {
    let (root, image) = try wallpaperFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let bad = root.appendingPathComponent("not-an-image.png")
    try Data("hello".utf8).write(to: bad)
    let library = try WallpaperLibrary(root: root)
    await #expect(throws: (any Error).self) { try await library.add([image, bad], to: "theme") }
    #expect(await library.snapshot().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("wallpaper-library.json").path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("CustomWallpapers").path).isEmpty)
    #expect(FileManager.default.fileExists(atPath: image.path))
}

@Test func corruptWallpaperJournalIsNotOverwritten() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("wallpaper-library.json")
    let data = Data(#"{"theme":{"added":[{"id":"custom:a","file":"../outside.png","name":"Bad"}],"hidden":[]}}"#.utf8)
    try data.write(to: path)
    #expect(throws: (any Error).self) { try WallpaperLibrary(root: root) }
    #expect(try Data(contentsOf: path) == data)
}

@Test @MainActor func customWallpaperSelectionPersistsInLocalPreferences() async throws {
    let (root, image) = try wallpaperFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ThemeStore(demo: false, root: root, defaults: defaults)
    store.enabled = [] // Exercise selection persistence without changing this Mac.
    store.addWallpapers([image])
    while store.editingWallpapers { try await Task.sleep(for: .milliseconds(10)) }
    let selected = try #require(store.selectedWallpaper)
    #expect(selected.id.hasPrefix("custom:"))
    store.applySelected()
    #expect((defaults.dictionary(forKey: "wallpaperSelections") as? [String: String])?[store.selected.id] == selected.id)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Themes").path))
    store.removeWallpaper(selected)
    while store.editingWallpapers { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!store.wallpapers.contains { $0.id == selected.id })
    #expect(store.hasRemovedWallpapers)
    store.undoWallpaperRemoval()
    while store.editingWallpapers { try await Task.sleep(for: .milliseconds(10)) }
    #expect(store.wallpapers.contains { $0.id == selected.id })
    #expect(!store.hasRemovedWallpapers)
}

@Test @MainActor func restoringRemovedWallpapersAfterRestartKeepsThemeScope() async throws {
    let (root, _) = try wallpaperFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try WallpaperLibrary(root: root)
    try await library.setHidden(true, id: "a.png", themeID: "one")
    try await library.setHidden(true, id: "b.png", themeID: "one")
    try await library.setHidden(true, id: "a.png", themeID: "two")
    let restarted = try WallpaperLibrary(root: root)
    try await restarted.restoreRemoved(themeID: "one")
    let snapshot = await restarted.snapshot()
    #expect(snapshot["one"]?.hidden.isEmpty == true)
    #expect(snapshot["two"]?.hidden == ["a.png"])
}

@Test @MainActor func importedThemeAcceptsCustomSelectionAndKeepsItsOriginalManifest() async throws {
    let (root, image) = try wallpaperFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try ThemeImportSource.parse("https://github.com/example/wallpaper-theme")
    let palette = Theme.bundled[0]
    let theme = Theme(id: source.id, name: "Imported", subtitle: "Test", background: palette.background, foreground: palette.foreground, accent: palette.accent, selection: palette.selection, cursor: palette.cursor, palette: palette.palette)
    let item = ImportedTheme(theme: theme, source: source, revision: String(repeating: "a", count: 40), version: "version-test", wallpapers: [], selectedWallpaper: nil, importedAt: Date())
    let manifest = root.appendingPathComponent("Themes/\(source.id)/manifest.json")
    try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = try JSONEncoder().encode(item)
    try original.write(to: manifest)
    let suite = UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ThemeStore(demo: false, root: root, defaults: defaults)
    while store.imported.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    store.selected = theme
    store.enabled = []
    #expect(store.selectedWallpaper == nil)
    store.addWallpapers([image])
    while store.editingWallpapers { try await Task.sleep(for: .milliseconds(10)) }
    let selected = try #require(store.selectedWallpaper)
    store.applySelected()
    #expect(store.selectedWallpaper?.id == selected.id)
    #expect(try Data(contentsOf: manifest) == original)
    #expect((defaults.dictionary(forKey: "wallpaperSelections") as? [String: String])?[source.id] == selected.id)
}
