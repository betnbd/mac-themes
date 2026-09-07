import Foundation
import Testing
import ThemeCore
@testable import MacThemes

@Test @MainActor func failedApplyAfterSuccessPreservesPerDestinationStateAcrossRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = try ApplyCoordinator(root: root)
    let original = Theme.bundled[0], next = Theme.bundled[1]
    _ = try await coordinator.run(theme: original, destinations: [.ghostty, .brave], installFont: {},
                                  apply: { _, _ in .applied("Success without a magic prefix") }, progress: { _, _ in })
    let report = try await coordinator.run(theme: next, destinations: [.ghostty, .brave], installFont: {},
        apply: { destination, _ in
            if destination == .ghostty { throw ThemeError.message("Reload failed") }
            return .pending("Browser closed")
        }, progress: { _, _ in })
    #expect(!report.allApplied)
    #expect(report.results[.ghostty]?.state == .failed)
    let reopened = try ApplyCoordinator(root: root)
    #expect(reopened.records["ghostty"]?.appliedTheme == original)
    #expect(reopened.records["brave"]?.appliedTheme == original)
    #expect(reopened.records["ghostty"]?.requestedTheme == next)
    #expect(reopened.records["brave"]?.result.state == .pending)
}

@Test @MainActor func firstFailedApplyNeverCreatesAnAppliedTheme() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = try ApplyCoordinator(root: root)
    _ = try await service.run(theme: Theme.bundled[0], destinations: [.macos], installFont: {},
        apply: { _, _ in .failed("Denied") }, progress: { _, _ in })
    #expect(try ApplyCoordinator(root: root).records["macos"]?.appliedTheme == nil)
}

@Test @MainActor func fontInstallRunsOnlyForSupportedEnabledDestinations() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = try ApplyCoordinator(root: root)
    var theme = Theme.bundled[0]; theme.fontFamily = "Menlo"
    var installs = 0
    for destinations: [Integration] in [[], [.wallpaper], [.brave, .macos], [.ghostty, .obsidian, .chatgpt]] {
        _ = try await service.run(theme: theme, destinations: destinations,
            installFont: { installs += 1 }, apply: { _, _ in .applied("Done") }, progress: { _, _ in })
    }
    #expect(installs == 1)
    theme.fontFamily = nil; theme.useDefaultFont = true
    _ = try await service.run(theme: theme, destinations: [.ghostty], installFont: { installs += 1 },
                             apply: { _, _ in .applied("Done") }, progress: { _, _ in })
    #expect(installs == 1)
}

@Test @MainActor func fontFailureDoesNotBlockIndependentWallpaperApplication() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = try ApplyCoordinator(root: root)
    var theme = Theme.bundled[0]; theme.fontFamily = "Menlo"
    var applied: [Integration] = []
    let report = try await service.run(theme: theme, destinations: [.ghostty, .wallpaper],
        installFont: { throw ThemeError.message("Font conflict") },
        apply: { destination, _ in applied.append(destination); return .applied("Done") }, progress: { _, _ in })
    #expect(applied == [.wallpaper])
    #expect(report.results[.ghostty]?.state == .failed)
    #expect(report.results[.wallpaper]?.state == .applied)
}

@Test @MainActor func pendingIntentIsDurableBeforeAdapterChangesAnything() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = try ApplyCoordinator(root: root)
    _ = try await service.run(theme: Theme.bundled[0], destinations: [.ghostty], installFont: {},
        apply: { _, _ in
            let disk = try ApplyCoordinator(root: root)
            #expect(disk.records["ghostty"]?.result.state == .pending)
            #expect(disk.records["ghostty"]?.appliedTheme == nil)
            return .applied("Done")
        }, progress: { _, _ in })
}
