import AppKit
import Foundation
import Testing
import ThemeCore
@testable import MacThemes

private func eventCode(_ value: String) -> UInt32 {
    value.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}

@Test @MainActor func allNativeHighlightEnumsDecodeAndCompileWithoutExecution() throws {
    // Values from the installed System Events Appearance Suite dictionary.
    let native = ["blue": "blue", "gold": "gold", "grft": "graphite", "gren": "green", "orng": "orange", "prpl": "purple", "red ": "red", "slvr": "silver"]
    for (code, expected) in native {
        let color = try HighlightColor.decode(NSAppleEventDescriptor(enumCode: eventCode(code)))
        #expect(color == .named(expected))
        for dark in [true, false] {
            let script = try #require(NSAppleScript(source: DesktopIntegration.appearanceScript(dark: dark, highlight: color)))
            var error: NSDictionary?
            let compiled = script.compileAndReturnError(&error)
            #expect(compiled, "\(error?.description ?? "Appearance script did not compile")")
        }
        #expect(try JSONDecoder().decode(HighlightColor.self, from: JSONEncoder().encode(color)) == color)
    }
}

@Test @MainActor func customHighlightDescriptorRetainsSixteenBitComponents() throws {
    let descriptor = NSAppleEventDescriptor.list()
    for (offset, value) in [0, 32768, 65535].enumerated() {
        descriptor.insert(NSAppleEventDescriptor(int32: Int32(value)), at: offset + 1)
    }
    let color = try HighlightColor.decode(descriptor)
    #expect(color == .rgb([0, 32768, 65535]))
    let script = try #require(NSAppleScript(source: DesktopIntegration.appearanceScript(dark: true, highlight: color)))
    var error: NSDictionary?
    let compiled = script.compileAndReturnError(&error)
    #expect(compiled, "\(error?.description ?? "Custom color script did not compile")")
}

@Test func malformedHighlightDescriptorsAndJournalValuesAreRejected() throws {
    let invalid: [NSAppleEventDescriptor] = [.list(), NSAppleEventDescriptor(enumCode: eventCode("pink")), NSAppleEventDescriptor(string: "blue")]
    for descriptor in invalid { #expect(throws: (any Error).self) { try HighlightColor.decode(descriptor) } }
    for components in [[-1, 0, 0], [0, 0, 65536]] {
        let list = NSAppleEventDescriptor.list()
        for (offset, value) in components.enumerated() { list.insert(NSAppleEventDescriptor(int32: Int32(value)), at: offset + 1) }
        #expect(throws: (any Error).self) { try HighlightColor.decode(list) }
    }
    let textList = NSAppleEventDescriptor.list()
    for index in 1...3 { textList.insert(NSAppleEventDescriptor(string: "123"), at: index) }
    #expect(throws: (any Error).self) { try HighlightColor.decode(textList) }
    for json in [#"{"named":{"_0":"blue\nend tell"}}"#, #"{"rgb":{"_0":[1,2]}}"#, #"{"rgb":{"_0":[0,0,70000]}}"#] {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(HighlightColor.self, from: Data(json.utf8)) }
    }
}

@Test func appearanceRestoreAcceptsPartialApplyButRejectsSeparatelyEditedFields() throws {
    let original = AppearanceSnapshot(dark: false, highlight: .named("blue"), accent: nil, automatic: nil)
    let previous = try AppearanceSnapshot(dark: true, highlight: .rgb([1000, 2000, 3000]), accent: AppearancePreference.archive(5), automatic: AppearancePreference.archive(false))
    let applied = try AppearanceSnapshot(dark: true, highlight: .rgb([4000, 5000, 6000]), accent: AppearancePreference.archive(4), automatic: AppearancePreference.archive(false))
    let backup = AppearanceBackup(dark: original.dark, highlight: original.highlight, accent: original.accent, automatic: original.automatic, appliedDark: applied.dark, appliedHighlight: applied.highlight, appliedAccent: 4, previousApplied: previous)
    for current in [original, previous, applied, AppearanceSnapshot(dark: original.dark, highlight: previous.highlight, accent: applied.accent, automatic: original.automatic)] {
        #expect(try backup.conflict(with: current) == nil)
    }
    #expect(try backup.conflict(with: AppearanceSnapshot(dark: applied.dark, highlight: .named("red"), accent: applied.accent, automatic: applied.automatic)) == "highlight color")
    #expect(try backup.conflict(with: AppearanceSnapshot(dark: applied.dark, highlight: applied.highlight, accent: AppearancePreference.archive(99), automatic: applied.automatic)) == "accent color")
    #expect(try backup.conflict(with: AppearanceSnapshot(dark: applied.dark, highlight: applied.highlight, accent: applied.accent, automatic: AppearancePreference.archive(true))) == "automatic appearance")
}

@Test func appearancePreferencesPreserveMissingValuesAndRejectMalformedBackups() throws {
    #expect(try AppearancePreference.matches(nil, candidates: [nil]))
    #expect(try !AppearancePreference.matches(AppearancePreference.archive(0), candidates: [nil]))
    #expect(try !AppearancePreference.matches(nil, candidates: [AppearancePreference.archive(false)]))
    #expect(try AppearancePreference.unarchive(AppearancePreference.archive(-1)) as? Int == -1)
    let invalid = try PropertyListSerialization.data(fromPropertyList: ["unexpected": 123], format: .binary, options: 0)
    #expect(throws: (any Error).self) { try AppearancePreference.unarchive(invalid) }
    #expect(throws: (any Error).self) { try AppearancePreference.unarchive(Data("not a plist".utf8)) }
}

@Test func wallpaperRestoreAcceptsLastVisibleImageAfterFailedSecondApply() throws {
    let backup = ScreenWallpaperBackup(original: "/original.jpg", originalOptions: Data(), applied: "/new-attempt.png", previousApplied: "/previous-theme.png")
    #expect(backup.accepts(current: "/original.jpg"))
    #expect(backup.accepts(current: "/previous-theme.png"))
    #expect(backup.accepts(current: "/new-attempt.png"))
    #expect(!backup.accepts(current: "/separately-chosen.jpg"))
    #expect(!backup.accepts(current: nil))
    let older = try JSONDecoder().decode(ScreenWallpaperBackup.self, from: Data(#"{"original":"/original.jpg","originalOptions":"","applied":"/applied.png"}"#.utf8))
    #expect(older.previousApplied == nil)
    #expect(older.accepts(current: "/applied.png"))
}

@Test @MainActor func desktopInitializationDoesNotModifyPreferencesOrCreateFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = try DesktopIntegration(root: root)
    #expect(!service.hasBackups)
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test @MainActor func corruptDesktopRestoreJournalFailsClosed() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("invalid journal".utf8).write(to: root.appendingPathComponent("desktop-state.json"))
    #expect(throws: (any Error).self) { try DesktopIntegration(root: root) }
}

@Test @MainActor func nativeAccentApproximationStaysWithinMacOSPalette() {
    #expect(DesktopIntegration.nearestAccent("#0000ff") == 4)
    #expect(DesktopIntegration.nearestAccent("#00ff00") == 3)
    #expect(DesktopIntegration.nearestAccent("#888888") == -1)
    for theme in Theme.all { #expect([-1, 0, 1, 2, 3, 4, 5, 6].contains(DesktopIntegration.nearestAccent(theme.accent))) }
}

@Test @MainActor func everyBundledBackgroundCanBeDecodedAndConvertedByMacOS() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = repository.appendingPathComponent("Vendor/Omarchy")
    let enumerator = try #require(FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil))
    let images = enumerator.compactMap { $0 as? URL }.filter { ["jpg", "jpeg", "png", "webp", "heic"].contains($0.pathExtension.lowercased()) }
    #expect(images.count == 38)
    for url in images {
        #expect(WallpaperImage.source(url) != nil, "Wallpaper exceeds decoder limits: \(url.lastPathComponent)")
        try autoreleasepool {
            let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: url)), "Cannot decode \(url.lastPathComponent)")
            #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
            let png = try #require(bitmap.representation(using: .png, properties: [:]), "Cannot convert \(url.lastPathComponent)")
            #expect(png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
        }
    }
}

@Test @MainActor func unavailableHighlightOnMacOS27DoesNotBlockDarkMode() throws {
    let result = try DesktopIntegration.scriptedAppearance(majorVersion: 27) { source in
        if source == DesktopIntegration.darkModeSnapshot { return NSAppleEventDescriptor(boolean: true) }
        throw AppleScripts.Failure(code: -10000, message: "AppleEvent handler failed.")
    }
    #expect(result.dark)
    #expect(result.highlight == nil)
    let source = DesktopIntegration.appearanceScript(dark: result.dark, highlight: result.highlight)
    #expect(!source.contains("set highlight color"))
    let script = try #require(NSAppleScript(source: source))
    var error: NSDictionary?
    #expect(script.compileAndReturnError(&error))
}

@Test @MainActor func appearanceFallbackDoesNotHideOtherFailures() throws {
    for version in [26, 27] {
        for code in [-1743, -1712, -10000] where version < 27 || code != -10000 {
            #expect(throws: (any Error).self) {
                try DesktopIntegration.scriptedAppearance(majorVersion: version) { source in
                    if source == DesktopIntegration.darkModeSnapshot { return NSAppleEventDescriptor(boolean: false) }
                    throw AppleScripts.Failure(code: code, message: "Failure")
                }
            }
        }
    }
    #expect(throws: (any Error).self) {
        try DesktopIntegration.scriptedAppearance(majorVersion: 27) { _ in
            throw AppleScripts.Failure(code: -10000, message: "Dark mode failed")
        }
    }
    #expect(throws: (any Error).self) {
        try DesktopIntegration.scriptedAppearance(majorVersion: 27) { source in
            source == DesktopIntegration.darkModeSnapshot ? NSAppleEventDescriptor(boolean: true) : NSAppleEventDescriptor(string: "malformed")
        }
    }
}

@Test @MainActor func supportedHighlightStillUsesNativeColor() throws {
    let result = try DesktopIntegration.scriptedAppearance(majorVersion: 27) { source in
        source == DesktopIntegration.darkModeSnapshot ? NSAppleEventDescriptor(boolean: false) : NSAppleEventDescriptor(enumCode: eventCode("blue"))
    }
    #expect(!result.dark)
    #expect(result.highlight == .named("blue"))
    #expect(DesktopIntegration.appearanceScript(dark: true, highlight: result.highlight).contains("set highlight color to blue"))
}

@Test func absentHighlightIsNotOwnedButOlderHighlightBackupsRemainProtected() throws {
    let original = AppearanceSnapshot(dark: true, highlight: nil, accent: nil, automatic: nil)
    let backup = AppearanceBackup(dark: true, highlight: nil, accent: nil, automatic: nil, appliedDark: true, appliedHighlight: nil, appliedAccent: 4, previousApplied: original)
    let decoded = try JSONDecoder().decode(AppearanceBackup.self, from: JSONEncoder().encode(backup))
    #expect(decoded.highlight == nil)
    #expect(try decoded.conflict(with: original) == nil)
    #expect(try decoded.conflict(with: AppearanceSnapshot(dark: true, highlight: .named("red"), accent: nil, automatic: nil)) == nil)
    let older = AppearanceBackup(dark: true, highlight: .named("blue"), accent: nil, automatic: nil, appliedDark: true, appliedHighlight: .named("red"), appliedAccent: 4)
    #expect(try older.conflict(with: original) == "highlight color")
}

// Explicit opt-in: applies only macOS appearance using the user's saved theme
// and the real restore journal. Never runs as part of the ordinary test suite.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_THEMES_VERIFY_LIVE_APPEARANCE"] == "1"))
@MainActor func liveMacOSAppearanceAppliesSavedTheme() throws {
    let service = try Integrations()
    let theme = try #require(service.state.activeThemeSnapshot)
    let result = try service.apply(theme, to: .macos)
    #expect(result.hasPrefix("Applied"))
    print("Live macOS appearance: \(result)")
}
