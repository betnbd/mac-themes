import Foundation
import Testing
import ThemeCore
@testable import MacThemes

private final class ReadProbe: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@Test func blockedReadsTimeOutDeduplicateAndNeverReuseLateBytes() throws {
    let probe = ReadProbe()
    defer { probe.release.signal() }
    let reader = BoundedFileReader(timeout: 0.04) { _ in
        if probe.next() == 1 {
            probe.release.wait()
            return Data("stale bytes".utf8)
        }
        return Data("fresh bytes".utf8)
    }
    let url = URL(fileURLWithPath: "/fixture/cloud/appearance.json")
    let start = Date()
    #expect(throws: BoundedFileReadError.self) { try reader.text(at: url) }
    #expect(Date().timeIntervalSince(start) < 1)
    #expect(probe.calls == 1)
    for _ in 0..<5 { #expect(throws: BoundedFileReadError.self) { try reader.text(at: url) } }
    #expect(probe.calls == 1)
    #expect(reader.pendingReadCount == 1)
    probe.release.signal()
    let finish = Date().addingTimeInterval(1)
    while reader.pendingReadCount != 0 && Date() < finish { Thread.sleep(forTimeInterval: 0.002) }
    #expect(reader.pendingReadCount == 0)
    #expect(try reader.text(at: url) == "fresh bytes")
    #expect(probe.calls == 2)
}

@MainActor @Test func cloudVaultTimeoutCannotWriteSettingsLaterOrSpawnRetryWorkers() throws {
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let vault = fixture.appendingPathComponent("iCloud Vault"), appearance = vault.appendingPathComponent(".obsidian/appearance.json")
    try FileManager.default.createDirectory(at: appearance.deletingLastPathComponent(), withIntermediateDirectories: true)
    let registry = fixture.appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
    try ManagedConfig.write(PaletteJSON.literal(["vaults": ["fixture": ["path": vault.path]]]), to: registry)
    let root = fixture.appendingPathComponent("QA-State")
    let probe = ReadProbe()
    defer { probe.release.signal() }
    let reader = BoundedFileReader(timeout: 0.04) { url in
        if url.standardizedFileURL == appearance.standardizedFileURL {
            if probe.next() == 1 { probe.release.wait() }
            return Data("{\"enabledCssSnippets\":[]}".utf8)
        }
        return try BoundedFileReader.loadFile(url)
    }
    let service = try AdditionalIntegrations(root: root, home: fixture, live: false, fileReader: reader)
    #expect(throws: BoundedFileReadError.self) { try service.apply(Theme.all[0], to: .obsidian) }
    #expect(!service.hasBackups)
    #expect(!FileManager.default.fileExists(atPath: root.path))
    #expect(throws: BoundedFileReadError.self) { try service.apply(Theme.all[1], to: .obsidian) }
    #expect(probe.calls == 1)
    probe.release.signal()
    let finish = Date().addingTimeInterval(1)
    while reader.pendingReadCount != 0 && Date() < finish { Thread.sleep(forTimeInterval: 0.002) }
    #expect(reader.pendingReadCount == 0)
    #expect(!service.hasBackups)
    #expect(!FileManager.default.fileExists(atPath: root.path))
    #expect(!FileManager.default.fileExists(atPath: vault.appendingPathComponent(".obsidian/snippets/mac-themes.css").path))
    // Only a new explicit apply is allowed to use a new snapshot and mutate fixture files.
    _ = try service.apply(Theme.all[2], to: .obsidian)
    #expect(probe.calls == 2)
    #expect(service.hasBackups)
    #expect(FileManager.default.fileExists(atPath: vault.appendingPathComponent(".obsidian/snippets/mac-themes.css").path))
}
