import AppKit
import ThemeCore

/// Separate from the legacy TOML editor: live changes go through ChatGPT's own
/// Appearance importer, which persists settings and notifies every open window.
@MainActor protocol ChatGPTAppearanceClient {
    var isRunning: Bool { get }
    func prepare() async throws
    func mode() throws -> String
    func copyTheme(_ variant: String) async throws -> String
    func importTheme(_ share: String, variant: String) async throws
    func setMode(_ mode: String) async throws
    func finish()
}

struct ChatGPTThemeShare {
    let object: [String: Any]
    let variant: String
    let theme: [String: Any]
    let codeTheme: String

    init(_ string: String) throws {
        let prefix = "codex-theme-v1:"
        guard string.utf8.count <= 65_536, string.hasPrefix(prefix) else { throw Self.invalid }
        let body = String(string.dropFirst(prefix.count))
        let json = body.hasPrefix("{") ? body : body.removingPercentEncoding ?? ""
        guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let variant = object["variant"] as? String, ["light", "dark"].contains(variant),
              let theme = object["theme"] as? [String: Any],
              let codeTheme = object["codeThemeId"] as? String, !codeTheme.isEmpty,
              ["accent", "surface", "ink"].allSatisfy({ Self.isHex(theme[$0]) }) else { throw Self.invalid }
        self.object = object; self.variant = variant; self.theme = theme; self.codeTheme = codeTheme
    }

    static var invalid: ThemeError { .message("ChatGPT did not return a valid theme. No appearance changes were made.") }
    static func isHex(_ value: Any?) -> Bool {
        (value as? String)?.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil
    }
    func applying(_ palette: Theme) throws -> String {
        guard variant == (palette.isLight ? "light" : "dark") else { throw Self.invalid }
        let key = palette.isLight ? "appearanceLightChromeTheme" : "appearanceDarkChromeTheme"
        // Preserve the actual current typography, contrast and translucency.
        // Tokyo Night also selects its built-in matching syntax palette.
        var settings: [String: Any] = [key: theme]
        if palette.id != "tokyo-night" { settings[palette.isLight ? "appearanceLightCodeThemeId" : "appearanceDarkCodeThemeId"] = codeTheme }
        return try ChatGPTConfigEditor.shareString(palette, current: settings)
    }
    func equivalent(to string: String) throws -> Bool {
        let other = try Self(string)
        return try Self.canonical(object) == Self.canonical(other.object)
    }
    private static func canonical(_ value: Any) throws -> Data {
        func normalize(_ v: Any) -> Any {
            if let d = v as? [String: Any] { return d.filter { !($0.value is NSNull) }.mapValues(normalize) }
            if let a = v as? [Any] { return a.map(normalize) }
            if let s = v as? String, Self.isHex(s) { return s.lowercased() }
            return v
        }
        return try JSONSerialization.data(withJSONObject: normalize(value), options: [.sortedKeys])
    }
}

@MainActor final class ChatGPTLiveTheme {
    struct Backup: Codable {
        var original: String
        var applied: String
        var previous: String
    }
    struct Journal: Codable {
        var originalMode: String?
        var appliedMode: String?
        var previousMode: String?
        var themes: [String: Backup] = [:]
        var pending: Theme?
    }
    private let path: URL
    private let client: any ChatGPTAppearanceClient
    private(set) var journal: Journal
    private var active = false
    var hasBackups: Bool { !journal.themes.isEmpty || journal.pending != nil || journal.originalMode != nil }
    var pendingTheme: Theme? { journal.pending }

    init(root: URL, client: any ChatGPTAppearanceClient = ChatGPTAccessibility()) throws {
        path = root.appendingPathComponent("chatgpt-live-state.json")
        self.client = client
        journal = try BoundedFileReader.shared.data(at: path).map { try JSONDecoder().decode(Journal.self, from: $0) } ?? Journal()
        for (variant, backup) in journal.themes {
            guard ["light", "dark"].contains(variant) else { throw ChatGPTThemeShare.invalid }
            for share in [backup.original, backup.applied, backup.previous] {
                guard try ChatGPTThemeShare(share).variant == variant else { throw ChatGPTThemeShare.invalid }
            }
        }
        for mode in [journal.originalMode, journal.appliedMode, journal.previousMode].compactMap({ $0 }) {
            guard ["light", "dark", "system"].contains(mode) else { throw ChatGPTThemeShare.invalid }
        }
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(journal).write(to: path, options: .atomic)
    }

    func apply(_ theme: Theme) async throws -> ApplyResult {
        guard !active else { throw ThemeError.message("ChatGPT appearance update is already running.") }
        active = true
        defer { active = false; client.finish() }
        journal.pending = theme
        try save()
        guard client.isRunning else { return .pending("Waiting · applies automatically when ChatGPT opens") }
        try await client.prepare()
        let mode = try client.mode()
        let variant = theme.isLight ? "light" : "dark"
        // The importer for the other variant is absent until its mode is
        // selected. Persist the original mode before this first UI mutation,
        // including when capturing the palette subsequently fails.
        journal.originalMode = journal.originalMode ?? mode
        journal.previousMode = mode
        journal.appliedMode = variant
        try save()
        if mode != variant { try await client.setMode(variant) }
        let current = try await client.copyTheme(variant)
        let desired = try ChatGPTThemeShare(current).applying(theme)
        journal.themes[variant] = Backup(original: journal.themes[variant]?.original ?? current, applied: desired, previous: current)
        journal.appliedMode = variant
        // Commit intent and first backup before touching the application's colors.
        try save()
        try await client.importTheme(desired, variant: variant)
        try await client.setMode(variant)
        let actual = try await client.copyTheme(variant)
        guard try ChatGPTThemeShare(actual).equivalent(to: desired), try client.mode() == variant else {
            throw ThemeError.message("ChatGPT did not confirm the selected theme. Backup retained; choose Apply again.")
        }
        journal.pending = nil
        try save()
        return .applied("Applied · verified through ChatGPT's live Appearance controls")
    }

    func restore() async throws -> String {
        guard !active else { throw ThemeError.message("Wait for the current ChatGPT appearance update.") }
        journal.pending = nil
        try save()
        guard !journal.themes.isEmpty || journal.originalMode != nil else { return "Cancelled pending ChatGPT theme" }
        guard client.isRunning else { return "Waiting · open ChatGPT, then choose Restore again" }
        active = true
        defer { active = false; client.finish() }
        try await client.prepare()
        let mode = try client.mode()
        guard mode == journal.appliedMode || mode == journal.originalMode || mode == journal.previousMode else {
            throw ThemeError.message("ChatGPT's appearance mode was changed separately. Backup retained.")
        }
        // System displays both importers. Record the intermediate mode so an
        // interrupted restoration can be retried from the saved journal.
        if !journal.themes.isEmpty, mode != "system" {
            journal.previousMode = mode
            journal.appliedMode = "system"
            try save()
            try await client.setMode("system")
        }
        // Check every owned variant before restoring any of them.
        do {
            for (variant, backup) in journal.themes {
                let current = try ChatGPTThemeShare(await client.copyTheme(variant))
                guard try current.equivalent(to: backup.applied) || current.equivalent(to: backup.original) || current.equivalent(to: backup.previous) else {
                    throw ThemeError.message("ChatGPT's theme was changed separately. Backup retained.")
                }
            }
        } catch {
            // Preflight has not changed any palette. Return to the entering
            // mode when focus still permits it, while retaining the journal.
            if mode != "system" { try? await client.setMode(mode) }
            throw error
        }
        for (variant, backup) in journal.themes.sorted(by: { $0.key < $1.key }) {
            try await client.importTheme(backup.original, variant: variant)
            let actual = try await client.copyTheme(variant)
            guard try ChatGPTThemeShare(actual).equivalent(to: backup.original) else {
                throw ThemeError.message("ChatGPT did not confirm restoration. Backup retained.")
            }
        }
        if let original = journal.originalMode { try await client.setMode(original) }
        journal = Journal()
        try save()
        return "Restored · previous ChatGPT themes and appearance mode"
    }
}
