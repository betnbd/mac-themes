import AppKit
import ThemeCore

/// One watched CSS file per vault. Obsidian owns activation and live reload; no CLI,
/// plugin, polling, or note contents are involved.
@MainActor
final class ObsidianIntegration {
    let root: URL
    let home: URL
    private let files = FileManager.default
    private let reader: BoundedFileReader
    private var backups: [PaletteFileBackup]
    private var journal: URL { root.appendingPathComponent("additional-state.json") }
    var configuredLocations: URL { root.appendingPathComponent("integration-locations.json") }
    var hasBackups: Bool { !backups.isEmpty }
    var isAvailable: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") != nil }

    init(root: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
         live: Bool = true, fileReader: BoundedFileReader = .shared) throws {
        self.root = root; self.home = home; self.reader = fileReader
        // Reuse the old Obsidian journal directly, so an upgrade retains the first backup.
        let state = try Self.object(fileReader.data(at: root.appendingPathComponent("additional-state.json")))
        let apps = try Self.apps(in: state)
        backups = try apps["obsidian"].map {
            try JSONDecoder().decode([PaletteFileBackup].self, from: JSONSerialization.data(withJSONObject: $0))
        } ?? []
        guard backups.allSatisfy({ $0.path.hasPrefix("/") && ["file", "obsidian-enabled"].contains($0.format) }) else {
            throw ThemeError.message("Obsidian's saved backup needs review. No vault files were changed.")
        }
    }

    private static func object(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ThemeError.message("Expected an Obsidian settings object. No settings were replaced.")
        }
        return object
    }
    private static func apps(in state: [String: Any]) throws -> [String: Any] {
        guard let value = state["apps"] else { return [:] }
        guard let apps = value as? [String: Any] else { throw ThemeError.message("Invalid saved integration backups.") }
        return apps
    }
    private static func snippets(in object: [String: Any]) throws -> [String] {
        guard let value = object["enabledCssSnippets"] else { return [] }
        guard let list = value as? [String] else {
            throw ThemeError.message("Obsidian's enabledCssSnippets setting must be a list of snippet names.")
        }
        return list
    }
    private func save() throws {
        // Preserve other legacy integrations, even if their journal was updated since launch.
        var state = try Self.object(reader.data(at: journal)), apps = try Self.apps(in: state)
        apps["obsidian"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(backups))
        state["apps"] = apps
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: journal, options: .atomic)
    }

    func obsidianVaults() throws -> [URL] {
        let locations = try Self.object(reader.data(at: configuredLocations))
        let paths: [String]
        if let configured = locations["obsidianVaults"] {
            guard let values = configured as? [String] else { throw ThemeError.message("Obsidian vault paths must be a list.") }
            paths = values
        } else {
            let registry = home.appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
            let object = try Self.object(reader.data(at: registry))
            if let registered = object["vaults"] {
                guard let vaults = registered as? [String: [String: Any]],
                      vaults.values.allSatisfy({ $0["path"] is String }) else {
                    throw ThemeError.message("Obsidian's vault registry needs review. Choose your vault folders in setup.")
                }
                paths = vaults.values.compactMap { $0["path"] as? String }
            } else { paths = [] }
        }
        guard paths.allSatisfy({ $0.hasPrefix("/") }) else { throw ThemeError.message("Obsidian vault paths must be absolute.") }
        return Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL }).sorted { $0.path < $1.path }
    }

    func apply(_ theme: Theme) throws -> String {
        guard theme.palette.count == 16,
              (theme.palette + [theme.background, theme.foreground, theme.accent, theme.selection]).allSatisfy({ $0.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil }) else {
            throw ThemeError.message("A complete hexadecimal theme palette is required.")
        }
        let vaults = try obsidianVaults()
        guard !vaults.isEmpty else { throw ThemeError.message("Choose your Obsidian vault folders in setup.") }
        var saved = 0, waiting = 0, failures: [String] = []
        for vault in vaults {
            do {
                let config = vault.appendingPathComponent(".obsidian")
                let appearance = config.appendingPathComponent("appearance.json")
                // Read provider-backed files with a deadline before any filesystem mutation.
                let original = try reader.text(at: appearance)
                let enabled = try Self.snippets(in: Self.object(original.map { Data($0.utf8) }))
                var directory: ObjCBool = false
                guard files.fileExists(atPath: config.path, isDirectory: &directory), directory.boolValue else {
                    throw ThemeError.message("Open this folder as an Obsidian vault first.")
                }
                let css = config.appendingPathComponent("snippets/mac-themes.css")
                let current = try reader.text(at: css)
                var backup = backups.first { $0.path == css.path } ?? PaletteFileBackup(path: css.path, format: "file", original: current)
                try check(current, against: backup)
                backup.previous = current; backup.applied = Self.css(theme)
                if !backups.contains(where: { $0.path == appearance.path }) {
                    backups.append(PaletteFileBackup(path: appearance.path, format: "obsidian-enabled", original: original,
                                          fields: [PaletteFieldBackup(path: ["enabledCssSnippets"], original: enabled.contains("mac-themes") ? "true" : "false", applied: "true")]))
                }
                backups.removeAll { $0.path == css.path }; backups.append(backup)
                try save()
                try ManagedConfig.write(backup.applied!, to: css)
                saved += 1
                if !enabled.contains("mac-themes") { waiting += 1 }
            } catch { failures.append("\(vault.lastPathComponent): \(error.localizedDescription)") }
        }
        guard saved > 0 else { throw ThemeError.message(failures.joined(separator: "\n")) }
        let status = waiting == 0 ? "Applied · watched CSS in \(saved) vault(s)" : "Saved · Appearance → CSS snippets → Reload snippets, then enable mac-themes once in \(waiting) vault(s)"
        return failures.isEmpty ? status : status + "; skipped \(failures.count): " + failures.joined(separator: "; ")
    }

    private func check(_ current: String?, against backup: PaletteFileBackup) throws {
        guard backup.applied == nil || current == backup.applied || current == backup.original || current == backup.previous else {
            throw ThemeError.message("mac-themes.css changed outside Mac Themes. Your changes and backup were kept.")
        }
    }

    func restore() throws -> String {
        guard hasBackups else { return "No Obsidian changes to restore" }
        // Preflight every vault so unavailable or malformed settings do not cause partial removal.
        var restored: [(PaletteFileBackup, String?)] = []
        for backup in backups {
            let current = try reader.text(at: URL(fileURLWithPath: backup.path))
            if backup.format == "file" {
                try check(current, against: backup); restored.append((backup, backup.original))
            } else {
                var object = try Self.object(current.map { Data($0.utf8) })
                let original = try Self.object(backup.original.map { Data($0.utf8) })
                let list = try Self.snippets(in: object)
                guard let membership = backup.fields.first?.original, ["true", "false"].contains(membership) else {
                    throw ThemeError.message("Obsidian's saved snippet selection needs review. Backup retained.")
                }
                let updated = membership == "true" ? (list.contains("mac-themes") ? list : list + ["mac-themes"]) : list.filter { $0 != "mac-themes" }
                object["enabledCssSnippets"] = updated.isEmpty && original["enabledCssSnippets"] == nil ? nil : updated
                let text: String?
                if NSDictionary(dictionary: object).isEqual(to: original) { text = backup.original }
                else if NSDictionary(dictionary: object).isEqual(to: try Self.object(current.map { Data($0.utf8) })) { text = current }
                else { text = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self) + "\n" }
                restored.append((backup, text))
            }
        }
        for (backup, text) in restored.reversed() {
            let url = URL(fileURLWithPath: backup.path)
            if let text { try ManagedConfig.write(text, to: url) }
            else if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
            backups.removeAll { $0.path == backup.path }; try save()
        }
        return "Restored · prior CSS and snippet selection"
    }

    nonisolated static func css(_ t: Theme) -> String {
        var colors = [
            "background-primary": t.background, "background-primary-alt": t.background,
            "background-secondary": t.background, "background-secondary-alt": t.background,
            "text-normal": t.foreground, "text-muted": t.foreground + "B3", "text-faint": t.foreground + "8C",
            "text-selection": t.selection, "background-modifier-border": t.palette[8],
            "text-link": t.palette[4], "text-accent": t.accent, "text-accent-hover": t.accent,
            "interactive-accent": t.accent, "interactive-accent-hover": t.accent, "text-on-accent": t.background,
            "code-normal": t.palette[6], "code-background": t.background, "text-error": t.palette[1], "text-success": t.palette[2],
            "h1-color": t.palette[1], "h2-color": t.palette[2], "h3-color": t.palette[3],
            "h4-color": t.palette[4], "h5-color": t.palette[5], "h6-color": t.palette[6],
            "graph-line": t.palette[8], "graph-node": t.accent, "graph-node-focused": t.palette[4],
            "graph-node-tag": t.palette[6], "graph-node-attachment": t.palette[2], "tag-color": t.palette[6],
            "tag-background": t.selection, "checkbox-color": t.accent, "nav-item-color-active": t.accent,
            "background-modifier-form-field": t.background, "background-modifier-form-field-hover": t.background,
            "background-modifier-hover": t.selection, "background-modifier-active-hover": t.selection,
            "background-modifier-border-hover": t.foreground + "8C", "background-modifier-border-focus": t.accent,
            "interactive-normal": t.background, "interactive-hover": t.selection,
            "dropdown-background": t.background, "dropdown-background-hover": t.selection,
            "input-placeholder-color": t.foreground + "E6"
        ]
        if t.id == "tokyo-night", t.background == "#1a1b26", !t.isLight {
            // Omarchy's Tokyo Night dark/lighter surfaces distinguish navigation,
            // reading space, and controls without changing typography or layout.
            let dark = "#13141c", lighter = "#24283b"
            colors.merge([
                "background-primary-alt": lighter, "background-secondary": dark,
                "background-secondary-alt": dark, "code-background": dark,
                "background-modifier-form-field": dark, "background-modifier-form-field-hover": lighter,
                "dropdown-background": dark, "interactive-normal": lighter,
                "ribbon-background": dark, "ribbon-background-collapsed": dark,
                "titlebar-background": dark, "titlebar-background-focused": dark,
                "status-bar-background": dark, "tab-container-background": dark,
                "tab-background-active": t.background
            ]) { _, value in value }
        }
        return "/* Generated by Mac Themes; no scripts or remote assets. */\nbody.theme-dark, body.theme-light {\n  color-scheme: \(t.isLight ? "light" : "dark");\n"
            + colors.sorted { $0.key < $1.key }.map { "  --\($0.key): \($0.value);" }.joined(separator: "\n") + "\n}\n"
    }
}
