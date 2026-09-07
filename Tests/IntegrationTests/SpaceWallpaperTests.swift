import AppKit
import Foundation
import Testing
@testable import MacThemes

@MainActor private final class VirtualDesktops: WallpaperDesktopClient {
    var selected = "one"
    var spaces = [
        "one": WallpaperDesktopSnapshot(id: "display:test", legacyID: "1", image: URL(fileURLWithPath: "/original-one.png"), options: Data("one".utf8)),
        "two": WallpaperDesktopSnapshot(id: "display:test", legacyID: "1", image: URL(fileURLWithPath: "/original-two.png"), options: Data("two".utf8))
    ]
    var writes = 0
    var failNext = false
    func snapshots() -> [WallpaperDesktopSnapshot] { [spaces[selected]!] }
    func setImage(_ url: URL, on displayID: String, restoringOptions: Data?) throws {
        if failNext { failNext = false; throw CocoaError(.fileWriteUnknown) }
        writes += 1
        spaces[selected] = WallpaperDesktopSnapshot(id: displayID, legacyID: "1", image: url, options: restoringOptions ?? Data("managed".utf8))
    }
    var image: URL { spaces[selected]!.image }
}

@MainActor private func wallpaperFixture(_ root: URL, name: String, color: NSColor) throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
    for x in 0..<2 { for y in 0..<2 { bitmap.setColor(color, atX: x, y: y) } }
    let url = root.appendingPathComponent(name + ".png")
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    return url
}

@MainActor @Test func spaceSwitchesFollowLatestWallpaperAndRestoreDistinctOriginalsAfterRelaunch() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try wallpaperFixture(root, name: "first", color: .red)
    let second = try wallpaperFixture(root, name: "second", color: .blue)
    let client = VirtualDesktops()
    var desktop = try DesktopIntegration(root: root, wallpaperClient: client)
    _ = try desktop.applyWallpaper(first)
    let oneFirst = client.image
    client.selected = "two"
    _ = try desktop.synchronizeCurrentSpaces()
    let twoFirst = client.image
    #expect(oneFirst != twoFirst)
    #expect(try Data(contentsOf: oneFirst) == Data(contentsOf: twoFirst))
    _ = try desktop.applyWallpaper(second)
    let twoSecond = client.image
    client.selected = "one"
    desktop = try DesktopIntegration(root: root, wallpaperClient: client)
    _ = try desktop.synchronizeCurrentSpaces()
    #expect(client.image.deletingLastPathComponent() == oneFirst.deletingLastPathComponent())
    #expect(try Data(contentsOf: client.image) == Data(contentsOf: twoSecond))
    let count = client.writes
    _ = try desktop.synchronizeCurrentSpaces()
    #expect(client.writes == count)
    #expect(try desktop.restoreWallpapers().hasPrefix("Waiting"))
    #expect(client.image.path == "/original-one.png")
    #expect(client.spaces["one"]?.options == Data("one".utf8))
    client.selected = "two"
    desktop = try DesktopIntegration(root: root, wallpaperClient: client)
    #expect(try desktop.synchronizeCurrentSpaces() == "Restored previous wallpapers")
    #expect(client.image.path == "/original-two.png")
    #expect(client.spaces["two"]?.options == Data("two".utf8))
    #expect(!desktop.hasBackups)
    #expect(!desktop.followsSpaces)
}

@MainActor @Test func spaceRestorePreservesAnOutsideWallpaperAndRetainsItsBackup() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let image = try wallpaperFixture(root, name: "image", color: .red)
    let client = VirtualDesktops()
    let desktop = try DesktopIntegration(root: root, wallpaperClient: client)
    _ = try desktop.applyWallpaper(image)
    let ours = client.image
    try client.setImage(URL(fileURLWithPath: "/user-edit.png"), on: "display:test", restoringOptions: nil)
    let writes = client.writes
    #expect(try desktop.restoreWallpapers().hasPrefix("Waiting"))
    #expect(client.image.path == "/user-edit.png")
    #expect(client.writes == writes)
    #expect(desktop.hasBackups)
    try client.setImage(ours, on: "display:test", restoringOptions: nil)
    #expect(try desktop.synchronizeCurrentSpaces() == "Restored previous wallpapers")
    #expect(client.image.path == "/original-one.png")
}

@MainActor @Test func failedSpaceApplyRetainsOriginalAndRetriesWithoutDuplicateBackups() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let image = try wallpaperFixture(root, name: "image", color: .green)
    let client = VirtualDesktops()
    var desktop = try DesktopIntegration(root: root, wallpaperClient: client)
    client.failNext = true
    #expect(throws: (any Error).self) { try desktop.applyWallpaper(image) }
    #expect(client.image.path == "/original-one.png")
    desktop = try DesktopIntegration(root: root, wallpaperClient: client)
    _ = try desktop.synchronizeCurrentSpaces()
    let backup = try JSONDecoder().decode(DesktopBackup.self, from: Data(contentsOf: root.appendingPathComponent("desktop-state.json")))
    #expect(backup.spaceWallpapers?.count == 1)
    #expect(try desktop.restoreWallpapers() == "Restored previous wallpapers")
    #expect(client.image.path == "/original-one.png")
}

@MainActor @Test func legacyWallpaperBackupMigratesOnlyOnMatchingDesktop() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let image = try wallpaperFixture(root, name: "image", color: .red)
    let client = VirtualDesktops()
    let legacy = DesktopBackup(wallpapers: ["1": ScreenWallpaperBackup(original: "/before-old-app.png", originalOptions: Data("legacy".utf8), applied: "/original-one.png")])
    try JSONEncoder().encode(legacy).write(to: root.appendingPathComponent("desktop-state.json"))
    let desktop = try DesktopIntegration(root: root, wallpaperClient: client)
    client.selected = "two"
    _ = try desktop.applyWallpaper(image)
    client.selected = "one"
    _ = try desktop.synchronizeCurrentSpaces()
    #expect(try desktop.restoreWallpapers().hasPrefix("Waiting"))
    #expect(client.image.path == "/before-old-app.png")
    client.selected = "two"
    _ = try desktop.synchronizeCurrentSpaces()
    #expect(client.image.path == "/original-two.png")
    #expect(!desktop.hasBackups)
}
