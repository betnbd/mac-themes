import AppKit
import CoreGraphics
import CryptoKit
import ImageIO
import Darwin
import ThemeCore

struct WallpaperChoice: Identifiable, Equatable {
    let id: String
    let name: String
    let url: URL
}

enum WallpaperCatalog {
    static func bundled(for theme: Theme) -> [WallpaperChoice] {
        let resources = Bundle.main.resourceURL?.appendingPathComponent("BuiltinWallpapers/\(theme.id)")
        guard let resources, let urls = try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { ["jpg", "jpeg", "png", "webp", "heic"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { WallpaperChoice(id: $0.lastPathComponent, name: $0.deletingPathExtension().lastPathComponent, url: $0) }
    }
}

enum WallpaperImage {
    static func source(_ url: URL) -> CGImageSource? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 50_000_000 else { return nil }
        return source
    }

    /// Preserve native JPEG/PNG bytes instead of decoding up to 200 MB of pixels.
    /// Other ImageIO formats still become PNG for desktop compatibility, written
    /// directly to disk so an additional encoded image isn't retained in memory.
    static func cachedWallpaper(_ original: URL, root: URL) throws -> URL {
        try autoreleasepool {
            guard let source = source(original) else {
                throw ThemeError.message("This wallpaper cannot be decoded or exceeds the 50-megapixel image limit.")
            }
            let data = try Data(contentsOf: original, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let type = CGImageSourceGetType(source) as String?
            let native = type == "public.jpeg" || type == "public.png"
            let directory = root.appendingPathComponent("Wallpapers")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent(digest + (type == "public.jpeg" ? ".jpg" : ".png"))
            guard !FileManager.default.fileExists(atPath: target.path) else { return target }
            if native {
                try data.write(to: target, options: .atomic)
            } else {
                let temporary = directory.appendingPathComponent(UUID().uuidString + ".png")
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, "public.png" as CFString, 1, nil) else {
                    throw ThemeError.message("macOS cannot create a background image.")
                }
                CGImageDestinationAddImageFromSource(destination, source, 0, nil)
                guard CGImageDestinationFinalize(destination) else {
                    throw ThemeError.message("macOS cannot decode this background image.")
                }
                try FileManager.default.moveItem(at: temporary, to: target)
            }
            return target
        }
    }

    static func preview(_ url: URL, maxPixelSize: Int = 1000) -> NSImage? {
        guard let source = source(url), let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(maxPixelSize, 1000)),
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary) else { return nil }
        return NSImage(cgImage: thumbnail, size: .zero)
    }
}

struct DesktopBackup: Codable {
    var wallpapers: [String: ScreenWallpaperBackup] = [:]
    var appearance: AppearanceBackup?
    var spaceWallpapers: [String: SpaceWallpaperBackup]?
    var followingWallpaper: String?
    var followingWallpaperSource: String?
    var restoringSpaces: Bool?
}

struct SpaceWallpaperBackup: Codable {
    let displayID: String
    var wallpaper: ScreenWallpaperBackup
    var pending: Bool?
}

struct ScreenWallpaperBackup: Codable {
    let original: String
    let originalOptions: Data
    var applied: String
    var previousApplied: String?

    func accepts(current: String?) -> Bool {
        guard let current else { return false }
        return current == original || current == applied || current == previousApplied
    }
}

struct AppearanceSnapshot: Codable {
    let dark: Bool
    let highlight: HighlightColor?
    let accent: Data?
    let automatic: Data?
}

struct AppearanceBackup: Codable {
    let dark: Bool
    let highlight: HighlightColor?
    let accent: Data?
    let automatic: Data?
    var appliedDark: Bool
    var appliedHighlight: HighlightColor?
    var appliedAccent: Int
    var previousApplied: AppearanceSnapshot?

    func conflict(with current: AppearanceSnapshot) throws -> String? {
        if current.dark != dark && current.dark != appliedDark && current.dark != previousApplied?.dark { return "appearance mode" }
        if let highlight, ![highlight, appliedHighlight, previousApplied?.highlight].contains(where: { candidate in
            candidate.map { current.highlight?.matches($0) == true } ?? false
        }) { return "highlight color" }
        let expectedAccent = try AppearancePreference.archive(appliedAccent)
        let expectedAutomatic = try AppearancePreference.archive(false)
        if try !AppearancePreference.matches(current.accent, candidates: [accent, expectedAccent] + (previousApplied.map { [$0.accent] } ?? [])) { return "accent color" }
        if try !AppearancePreference.matches(current.automatic, candidates: [automatic, expectedAutomatic] + (previousApplied.map { [$0.automatic] } ?? [])) { return "automatic appearance" }
        return nil
    }
}

enum AppearancePreference {
    static func archive(_ value: Any?) throws -> Data? {
        guard let value else { return nil }
        return try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)
    }

    static func unarchive(_ data: Data?) throws -> Any? {
        guard let data else { return nil }
        guard let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              object.count == 1, let value = object["value"] else {
            throw ThemeError.message("A macOS preference backup is invalid. No preference was restored.")
        }
        return value
    }

    static func matches(_ current: Data?, candidates: [Data?]) throws -> Bool {
        let value = try unarchive(current)
        for candidate in candidates {
            let other = try unarchive(candidate)
            if value == nil && other == nil { return true }
            if let value, let other, NSDictionary(dictionary: ["value": value]).isEqual(to: ["value": other]) { return true }
        }
        return false
    }
}

enum HighlightColor: Codable, Equatable {
    case rgb([Int])
    case named(String)

    static let namesByCode: [String: String] = ["blue": "blue", "gold": "gold", "grft": "graphite", "gren": "green", "orng": "orange", "prpl": "purple", "red ": "red", "slvr": "silver"]

    private enum CodingKeys: String, CodingKey { case rgb, named }
    private enum ValueKeys: String, CodingKey { case _0 }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1 else { throw ThemeError.message("Invalid highlight color backup.") }
        if container.contains(.rgb) {
            let nested = try container.nestedContainer(keyedBy: ValueKeys.self, forKey: .rgb)
            let components = try nested.decode([Int].self, forKey: ._0)
            guard components.count == 3, components.allSatisfy({ (0...65535).contains($0) }) else { throw ThemeError.message("Invalid highlight color components in backup.") }
            self = .rgb(components)
        } else {
            let nested = try container.nestedContainer(keyedBy: ValueKeys.self, forKey: .named)
            let name = try nested.decode(String.self, forKey: ._0)
            guard Self.namesByCode.values.contains(name) else { throw ThemeError.message("Unknown highlight color in backup.") }
            self = .named(name)
        }
    }

    static func decode(_ descriptor: NSAppleEventDescriptor) throws -> HighlightColor {
        if descriptor.descriptorType == typeAEList, descriptor.numberOfItems == 3 {
            var components: [Int] = []
            for index in 1...3 {
                guard let component = descriptor.atIndex(index), [typeSInt16, typeSInt32, typeSInt64].contains(component.descriptorType) else { throw ThemeError.message("macOS returned invalid highlight color components.") }
                let value = Int(component.int32Value)
                guard (0...65535).contains(value) else { throw ThemeError.message("macOS returned out-of-range highlight components.") }
                components.append(value)
            }
            return .rgb(components)
        }
        guard descriptor.descriptorType == typeEnumerated else { throw ThemeError.message("macOS returned an unsupported highlight color.") }
        let code = descriptor.enumCodeValue
        let bytes = [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)]
        guard let name = namesByCode[String(decoding: bytes, as: UTF8.self)] else { throw ThemeError.message("macOS returned an unsupported highlight color; no appearance changes were made.") }
        return .named(name)
    }

    func matches(_ other: HighlightColor) -> Bool {
        switch (self, other) {
        case (.rgb(let a), .rgb(let b)): a.count == 3 && b.count == 3 && zip(a, b).allSatisfy { abs($0 - $1) <= 1 }
        default: self == other
        }
    }

    var script: String {
        switch self { case .rgb(let rgb): ScriptLiteral.list(rgb); case .named(let name): name }
    }
}

@MainActor
final class DesktopIntegration {
    let root: URL
    private var state: DesktopBackup
    private let wallpaperClient: any WallpaperDesktopClient
    private var stateURL: URL { root.appendingPathComponent("desktop-state.json") }
    var hasBackups: Bool { state.appearance != nil || !state.wallpapers.isEmpty || !(state.spaceWallpapers ?? [:]).isEmpty }
    var followsSpaces: Bool { state.followingWallpaper != nil }
    var hasPendingSpaceRestore: Bool { state.restoringSpaces == true }
    func followsWallpaper(_ original: URL) -> Bool {
        followsSpaces && state.followingWallpaperSource == original.path
    }

    init(root: URL, wallpaperClient: any WallpaperDesktopClient = NativeWallpaperDesktopClient()) throws {
        self.root = root
        self.wallpaperClient = wallpaperClient
        let url = root.appendingPathComponent("desktop-state.json")
        state = FileManager.default.fileExists(atPath: url.path) ? try JSONDecoder().decode(DesktopBackup.self, from: Data(contentsOf: url)) : DesktopBackup()
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    func applyWallpaper(_ original: URL) throws -> String {
        let imageURL = try WallpaperImage.cachedWallpaper(original, root: root)
        state.followingWallpaper = imageURL.path
        state.followingWallpaperSource = original.path
        state.restoringSpaces = false
        try save()
        return try applyToCurrentSpaces(imageURL)
    }

    /// Notification-driven: no image decoding, idle polling or private Space IDs.
    func synchronizeCurrentSpaces() throws -> String? {
        if state.restoringSpaces == true { return try restoreCurrentSpaces() }
        guard let path = state.followingWallpaper else { return nil }
        return try applyToCurrentSpaces(URL(fileURLWithPath: path))
    }

    private func spaceDirectory(_ token: String) -> URL {
        root.appendingPathComponent("Wallpapers/Spaces", isDirectory: true).appendingPathComponent(token, isDirectory: true)
    }

    private func ownedSpace(on screen: WallpaperDesktopSnapshot) -> String? {
        (state.spaceWallpapers ?? [:]).first { token, entry in
            entry.displayID == screen.id && (
                screen.image.deletingLastPathComponent().standardizedFileURL == spaceDirectory(token).standardizedFileURL
                || (entry.pending == true && entry.wallpaper.previousApplied == screen.image.path))
        }?.key
    }

    private func legacyKey(on screen: WallpaperDesktopSnapshot) -> String? {
        state.wallpapers.keys.first { $0 == screen.id || $0 == screen.legacyID }
    }

    private func applyToCurrentSpaces(_ image: URL) throws -> String {
        let screens = try wallpaperClient.snapshots()
        guard !screens.isEmpty else { throw ThemeError.message("No connected display is available.") }
        for screen in screens {
            // The assigned file directory identifies the Space on later visits.
            // APFS clones share storage but retain distinct file identities for
            // macOS wallpaper bookmarks and separate restore records.
            let token = ownedSpace(on: screen) ?? UUID().uuidString.lowercased()
            let directory = spaceDirectory(token)
            let target = directory.appendingPathComponent(image.lastPathComponent)
            if screen.image.standardizedFileURL == target.standardizedFileURL { continue }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: target.path) {
                if clonefile(image.path, target.path, 0) != 0 {
                    try FileManager.default.copyItem(at: image, to: target)
                }
            }
            var entry = state.spaceWallpapers?[token]
            if entry == nil {
                let legacy = legacyKey(on: screen)
                let old = legacy.flatMap { state.wallpapers[$0] }
                let canMigrate = old?.accepts(current: screen.image.path) == true
                entry = SpaceWallpaperBackup(displayID: screen.id, wallpaper: ScreenWallpaperBackup(
                    original: canMigrate ? old!.original : screen.image.path,
                    originalOptions: canMigrate ? old!.originalOptions : screen.options,
                    applied: target.path, previousApplied: screen.image.path))
                if canMigrate, let legacy { state.wallpapers.removeValue(forKey: legacy) }
            }
            entry!.wallpaper.previousApplied = screen.image.path
            entry!.wallpaper.applied = target.path
            entry!.pending = true
            if state.spaceWallpapers == nil { state.spaceWallpapers = [:] }
            state.spaceWallpapers?[token] = entry
            try save()
            try wallpaperClient.setImage(target, on: screen.id, restoringOptions: nil)
            state.spaceWallpapers?[token]?.pending = false
            try save()
        }
        return "Applied · \(screens.count) display(s); follows Spaces while Mac Themes is open"
    }

    func restoreWallpapers() throws -> String {
        state.followingWallpaper = nil
        state.followingWallpaperSource = nil
        state.restoringSpaces = true
        try save()
        return try restoreCurrentSpaces()
    }

    private func restoreCurrentSpaces() throws -> String {
        for screen in try wallpaperClient.snapshots() {
            if let token = ownedSpace(on: screen), let entry = state.spaceWallpapers?[token] {
                try wallpaperClient.setImage(URL(fileURLWithPath: entry.wallpaper.original), on: screen.id, restoringOptions: entry.wallpaper.originalOptions)
                state.spaceWallpapers?.removeValue(forKey: token)
                try save()
            } else if let key = legacyKey(on: screen), let backup = state.wallpapers[key], backup.accepts(current: screen.image.path) {
                try wallpaperClient.setImage(URL(fileURLWithPath: backup.original), on: screen.id, restoringOptions: backup.originalOptions)
                state.wallpapers.removeValue(forKey: key)
                try save()
            }
        }
        let remaining = (state.spaceWallpapers ?? [:]).count + state.wallpapers.count
        state.restoringSpaces = remaining > 0
        try save()
        return remaining > 0
            ? "Waiting · visit other Spaces or reconnect displays to restore wallpapers; \(remaining) backup(s) retained"
            : "Restored previous wallpapers"
    }

    static let darkModeSnapshot = "tell application id \"com.apple.systemevents\" to tell appearance preferences to get dark mode"
    static let highlightSnapshot = "tell application id \"com.apple.systemevents\" to tell appearance preferences to get highlight color"

    static func scriptedAppearance(
        majorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        run: @MainActor (String) throws -> NSAppleEventDescriptor = AppleScripts.run
    ) throws -> (dark: Bool, highlight: HighlightColor?) {
        let dark = try run(darkModeSnapshot).booleanValue
        do { return (dark, try HighlightColor.decode(run(highlightSnapshot))) }
        catch let error as AppleScripts.Failure where majorVersion >= 27 && error.code == -10000 {
            // macOS 27 can read dark mode but its highlight getter fails. An
            // absent highlight means we neither own nor write that setting.
            return (dark, nil)
        }
    }

    static func appearanceScript(dark: Bool, highlight: HighlightColor?) -> String {
        """
        tell application id "com.apple.systemevents" to tell appearance preferences
            set dark mode to \(dark ? "true" : "false")
            \(highlight.map { "set highlight color to " + $0.script } ?? "")
        end tell
        """
    }

    private func appearance() throws -> AppearanceSnapshot {
        // Refresh the preference cache before comparing with a journal; changes
        // made in System Settings must not be mistaken for our last write.
        guard CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { throw ThemeError.message("Could not read current macOS appearance preferences.") }
        let result = try Self.scriptedAppearance()
        return try AppearanceSnapshot(dark: result.dark, highlight: result.highlight, accent: archivedPreference("AppleAccentColor"), automatic: archivedPreference("AppleInterfaceStyleSwitchesAutomatically"))
    }

    private func globalValue(_ key: String) -> CFPropertyList? {
        CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
    private func archivedPreference(_ key: String) throws -> Data? {
        try AppearancePreference.archive(globalValue(key))
    }
    private func restorePreference(_ key: String, data: Data?) throws {
        let value = try AppearancePreference.unarchive(data)
        CFPreferencesSetValue(key as CFString, value as CFPropertyList?, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
    private func notifyColors() throws {
        guard CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { throw ThemeError.message("macOS appearance preferences could not be saved. Restore is available.") }
        for name in ["AppleColorPreferencesChangedNotification", "AppleAquaColorVariantChanged", "AppleInterfaceThemeChangedNotification"] {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name(name), object: nil, userInfo: nil, deliverImmediately: true)
        }
    }

    static func nearestAccent(_ hex: String) -> Int {
        let candidates: [(Int, String)] = [(0,"#ff3b30"),(1,"#ff9500"),(2,"#ffcc00"),(3,"#34c759"),(4,"#007aff"),(5,"#af52de"),(6,"#ff2d55"),(-1,"#8e8e93")]
        let target = ScriptLiteral.rgb(hex).map(Double.init)
        return candidates.min { a, b in
            func distance(_ value: String) -> Double { zip(target, ScriptLiteral.rgb(value).map(Double.init)).reduce(0) { $0 + pow($1.0 - $1.1, 2) } }
            return distance(a.1) < distance(b.1)
        }!.0
    }

    func applyAppearance(_ theme: Theme) throws -> String {
        let current = try appearance()
        if state.appearance?.highlight != nil, current.highlight == nil {
            throw ThemeError.message("macOS no longer exposes the highlight color saved by an earlier release. Its restore backup is retained; no new appearance settings were changed.")
        }
        // Do not acquire ownership halfway through an existing restore journal.
        let ownsHighlight = current.highlight != nil && (state.appearance == nil || state.appearance?.highlight != nil)
        let highlight: HighlightColor? = ownsHighlight ? .rgb(ScriptLiteral.rgb(theme.accent)) : nil
        let accent = Self.nearestAccent(theme.accent)
        if state.appearance == nil {
            state.appearance = AppearanceBackup(dark: current.dark, highlight: current.highlight, accent: current.accent, automatic: current.automatic, appliedDark: !theme.isLight, appliedHighlight: highlight, appliedAccent: accent, previousApplied: current)
        } else {
            state.appearance?.appliedDark = !theme.isLight
            state.appearance?.appliedHighlight = highlight
            state.appearance?.appliedAccent = accent
            state.appearance?.previousApplied = current
        }
        try save()
        CFPreferencesSetValue("AppleAccentColor" as CFString, accent as CFNumber, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSetValue("AppleInterfaceStyleSwitchesAutomatically" as CFString, kCFBooleanFalse, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        try notifyColors()
        _ = try AppleScripts.run(Self.appearanceScript(dark: !theme.isLight, highlight: highlight))
        let check = try appearance()
        guard check.dark == !theme.isLight, highlight.map({ check.highlight?.matches($0) == true }) ?? true,
              try AppearancePreference.matches(check.accent, candidates: [AppearancePreference.archive(accent)]),
              try AppearancePreference.matches(check.automatic, candidates: [AppearancePreference.archive(false)]) else { throw ThemeError.message("macOS did not confirm all appearance changes. Restore is available.") }
        let detail = highlight == nil ? "mode and nearest native accent; custom highlight unavailable on this macOS" : "mode and highlight; native accent refresh requested"
        return "Applied · \(theme.isLight ? "light" : "dark") \(detail)"
    }

    func restoreAppearance() throws -> String {
        guard let backup = state.appearance else { return "No macOS appearance changes to restore" }
        let current = try appearance()
        if let conflict = try backup.conflict(with: current) { throw ThemeError.message("macOS \(conflict) changed separately; backup retained.") }
        // Validate both archived values before the first external write.
        _ = try AppearancePreference.unarchive(backup.accent)
        _ = try AppearancePreference.unarchive(backup.automatic)
        _ = try AppleScripts.run(Self.appearanceScript(dark: backup.dark, highlight: backup.highlight))
        try restorePreference("AppleAccentColor", data: backup.accent)
        try restorePreference("AppleInterfaceStyleSwitchesAutomatically", data: backup.automatic)
        try notifyColors()
        let check = try appearance()
        let automatic = try AppearancePreference.unarchive(backup.automatic) as? Bool ?? false
        guard (automatic || check.dark == backup.dark), backup.highlight.map({ check.highlight?.matches($0) == true }) ?? true,
              try AppearancePreference.matches(check.accent, candidates: [backup.accent]),
              try AppearancePreference.matches(check.automatic, candidates: [backup.automatic]) else { throw ThemeError.message("macOS did not confirm all restored appearance settings. Its backup is retained.") }
        state.appearance = nil
        try save()
        return "Restored previous macOS appearance"
    }
}
