import AppKit
import Darwin
import ThemeCore

enum AdditionalIntegration: String, CaseIterable, Codable {
    case alacritty, kitty, vscode, vscodeInsiders, vscodium, cursor, obsidian, neovim, btop, helix, opencode

    var name: String { Integration(rawValue: rawValue)!.name }

    var bundleID: String? {
        let id = Integration(rawValue: rawValue)!.bundleID
        return id.isEmpty ? nil : id
    }
    var settingsFolder: String? {
        switch self { case .vscode: "Code"; case .vscodeInsiders: "Code - Insiders"; case .vscodium: "VSCodium"; case .cursor: "Cursor"; default: nil }
    }
}

/// Edits only named JSON/JSONC values; comments, strings, and unrelated settings keep their bytes.
/// Duplicate object keys are refused because the effective value is otherwise ambiguous.
enum PaletteJSON {
    indirect enum Node {
        case object(Range<Int>, [Member]), other(Range<Int>)
        var range: Range<Int> { switch self { case .object(let r, _), .other(let r): r } }
    }
    struct Member { let key: String; let start: Int; let value: Node; let comma: Int? }
    struct Parser {
        let bytes: [UInt8]
        var index = 0
        mutating func skip() throws {
            while index < bytes.count {
                if [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
                else if index + 1 < bytes.count && bytes[index] == 47 && bytes[index + 1] == 47 {
                    index += 2; while index < bytes.count && bytes[index] != 10 { index += 1 }
                } else if index + 1 < bytes.count && bytes[index] == 47 && bytes[index + 1] == 42 {
                    index += 2
                    while index + 1 < bytes.count && !(bytes[index] == 42 && bytes[index + 1] == 47) { index += 1 }
                    guard index + 1 < bytes.count else { throw ThemeError.message("Unclosed settings comment.") }
                    index += 2
                } else { break }
            }
        }
        mutating func string() throws -> String {
            let start = index
            guard index < bytes.count && bytes[index] == 34 else { throw ThemeError.message("Expected a quoted settings key.") }
            index += 1
            while index < bytes.count {
                if bytes[index] == 92 { index += 2; continue }
                if bytes[index] == 34 {
                    index += 1
                    guard let value = try JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: .fragmentsAllowed) as? String else { break }
                    return value
                }
                index += 1
            }
            throw ThemeError.message("Invalid JSON settings string.")
        }
        mutating func node(depth: Int = 0) throws -> Node {
            guard depth < 100 else { throw ThemeError.message("Settings nesting is too deep.") }
            try skip(); let start = index
            guard index < bytes.count else { throw ThemeError.message("Incomplete settings JSON.") }
            if bytes[index] == 123 {
                index += 1; try skip(); var members: [Member] = []; var keys = Set<String>()
                while index < bytes.count && bytes[index] != 125 {
                    let keyStart = index, key = try string()
                    guard keys.insert(key).inserted else { throw ThemeError.message("Duplicate settings key: \(key). Resolve it before applying.") }
                    try skip(); guard index < bytes.count && bytes[index] == 58 else { throw ThemeError.message("Expected a settings colon.") }
                    index += 1; let value = try node(depth: depth + 1); try skip()
                    let comma: Int? = index < bytes.count && bytes[index] == 44 ? index : nil
                    if comma != nil { index += 1; try skip() }
                    members.append(Member(key: key, start: keyStart, value: value, comma: comma))
                    if comma == nil { break }
                }
                guard index < bytes.count && bytes[index] == 125 else { throw ThemeError.message("Invalid settings object.") }
                index += 1; return .object(start..<index, members)
            }
            if bytes[index] == 91 {
                index += 1; try skip()
                while index < bytes.count && bytes[index] != 93 {
                    _ = try node(depth: depth + 1); try skip()
                    if index < bytes.count && bytes[index] == 44 { index += 1; try skip() } else { break }
                }
                guard index < bytes.count && bytes[index] == 93 else { throw ThemeError.message("Invalid settings array.") }
                index += 1; return .other(start..<index)
            }
            if bytes[index] == 34 { _ = try string(); return .other(start..<index) }
            while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125, 47].contains(bytes[index]) { index += 1 }
            guard index > start else { throw ThemeError.message("Invalid settings value.") }
            _ = try JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: .fragmentsAllowed)
            return .other(start..<index)
        }
    }
    static func parse(_ source: String) throws -> Node {
        var parser = Parser(bytes: Array(source.utf8)); let result = try parser.node(); try parser.skip()
        guard parser.index == parser.bytes.count, case .object = result else { throw ThemeError.message("Settings must contain one JSON object.") }
        return result
    }
    static func raw(_ source: String, path: [String]) throws -> String? {
        var node = try parse(source)
        for key in path {
            guard case .object(_, let members) = node else { throw ThemeError.message("Setting \(key) has a non-object parent.") }
            guard let member = members.first(where: { $0.key == key }) else { return nil }
            node = member.value
        }
        return String(decoding: Array(source.utf8)[node.range], as: UTF8.self)
    }
    static func literal(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
    }
    static func setting(_ source: String, path: [String], raw value: String?) throws -> String {
        guard !path.isEmpty else { throw ThemeError.message("Empty settings path.") }
        let bytes = Array(source.utf8), root = try parse(source)
        func replace(_ range: Range<Int>, _ text: String) -> String {
            String(decoding: bytes[..<range.lowerBound], as: UTF8.self) + text + String(decoding: bytes[range.upperBound...], as: UTF8.self)
        }
        func edit(_ node: Node, _ remaining: ArraySlice<String>) throws -> String {
            guard case .object(let range, let members) = node, let key = remaining.first else { throw ThemeError.message("Settings parent is not an object.") }
            if let position = members.firstIndex(where: { $0.key == key }) {
                let member = members[position]
                if remaining.count > 1 { return try edit(member.value, remaining.dropFirst()) }
                if let value { return replace(member.value.range, value) }
                if let comma = member.comma { return replace(member.start..<(comma + 1), "") }
                if position > 0, let previousComma = members[position - 1].comma { return replace(previousComma..<member.value.range.upperBound, "") }
                return replace(member.start..<member.value.range.upperBound, "")
            }
            guard var nested = value else { return source }
            for part in remaining.dropFirst().reversed() { nested = "{\(try literal(part)):\(nested)}" }
            let entry = "\n  \(try literal(key)): \(nested)\n"
            // Insert a comma adjacent to the previous value, before a possible trailing comment.
            if let last = members.last, last.comma == nil {
                let end = range.upperBound - 1
                return String(decoding: bytes[..<last.value.range.upperBound], as: UTF8.self) + "," + String(decoding: bytes[last.value.range.upperBound..<end], as: UTF8.self) + entry + String(decoding: bytes[end...], as: UTF8.self)
            }
            return replace((range.upperBound - 1)..<(range.upperBound - 1), entry)
        }
        let result = try edit(root, path[...]); _ = try parse(result); return result
    }
}

/// Conservative scalar TOML editor. Values can be scalar strings/numbers/bools. Inline table
/// ancestors and multiline target values are refused rather than guessing at TOML semantics.
enum PaletteScalar {
    struct Entry { let path: [String]; let range: Range<String.Index>; let whole: Range<String.Index> }
    struct Section { let path: [String]; let end: String.Index }
    static func scan(_ source: String) throws -> ([Entry], [Section]) {
        var entries: [Entry] = [], sections: [Section] = []; var table: [String] = []
        var index = source.startIndex; var multiline: String?
        while index < source.endIndex {
            let end = source[index...].firstIndex(of: "\n") ?? source.endIndex
            let after = end < source.endIndex ? source.index(after: end) : end
            let line = String(source[index..<end]), trimmed = line.trimmingCharacters(in: .whitespaces)
            if let delimiter = multiline {
                if trimmed.contains(delimiter) { multiline = nil }
                index = after; continue
            }
            if !trimmed.hasPrefix("#") && (trimmed.contains("\"\"\"") || trimmed.contains("'''")) {
                let delimiter = trimmed.contains("\"\"\"") ? "\"\"\"" : "'''"
                if trimmed.components(separatedBy: delimiter).count == 2 { multiline = delimiter }
            }
            if trimmed.hasPrefix("[") {
                guard let closing = trimmed.firstIndex(of: "]"), !trimmed.hasPrefix("[[") else { table = ["<array>"]; index = after; continue }
                table = path(String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing]))
                sections.append(Section(path: table, end: after))
            } else if !trimmed.hasPrefix("#"), let equal = line.firstIndex(of: "=") {
                let key = path(String(line[..<equal]).trimmingCharacters(in: .whitespaces))
                if !key.isEmpty {
                    let valueStart = line.index(after: equal)
                    let offset = line.distance(from: line.startIndex, to: valueStart)
                    let lower = source.index(index, offsetBy: offset)
                    entries.append(Entry(path: table + key, range: lower..<end, whole: index..<after))
                }
            }
            index = after
        }
        guard multiline == nil else { throw ThemeError.message("Unclosed or unsupported multiline configuration string.") }
        return (entries, sections)
    }
    static func path(_ text: String) -> [String] {
        text.split(separator: ".").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
    }
    static func entry(_ source: String, path: [String]) throws -> Entry? {
        let entries = try scan(source).0
        if entries.contains(where: { $0.path.count < path.count && path.starts(with: $0.path) }) { throw ThemeError.message("Inline configuration table controls \(path.joined(separator: ".")). Expand it before applying.") }
        let matches = entries.filter { $0.path == path }
        guard matches.count <= 1 else { throw ThemeError.message("Duplicate configuration value \(path.joined(separator: ".")).") }
        return matches.first
    }
    static func raw(_ source: String, path: [String]) throws -> String? { try entry(source, path: path).map { String(source[$0.range]) } }
    static func setting(_ source: String, path: [String], raw: String?) throws -> String {
        guard let key = path.last else { throw ThemeError.message("Empty scalar path.") }
        if let match = try entry(source, path: path) {
            if let raw {
                guard !source[match.range].contains("\"\"\""), !source[match.range].contains("'''") else { throw ThemeError.message("A multiline target setting cannot be safely changed.") }
                var result = source; result.replaceSubrange(match.range, with: raw); return result
            }
            var result = source; result.removeSubrange(match.whole); return result
        }
        guard let raw else { return source }
        let table = Array(path.dropLast()), sections = try scan(source).1
        if table.isEmpty { return "\(key) =\(raw)\n" + source }
        if let section = sections.first(where: { $0.path == table }) {
            var result = source
            let separator = section.end > source.startIndex && source[source.index(before: section.end)] != "\n" ? "\n" : ""
            result.insert(contentsOf: "\(separator)\(key) =\(raw)\n", at: section.end); return result
        }
        return source + (source.hasSuffix("\n") || source.isEmpty ? "" : "\n") + "\n[\(table.joined(separator: "."))]\n\(key) =\(raw)\n"
    }
}

struct PaletteFieldBackup: Codable { var path: [String]; var original: String?; var applied: String; var previous: String? }
struct PaletteFileBackup: Codable {
    var path: String; var format: String; var original: String?; var fields: [PaletteFieldBackup] = []; var applied: String?; var previous: String?
}
private struct AdditionalState: Codable { var apps: [String: [PaletteFileBackup]] = [:] }

@MainActor
final class AdditionalIntegrations {
    let root: URL
    let home: URL
    private let files = FileManager.default
    private let live: Bool
    private let fileReader: BoundedFileReader
    private let obsidianCommand: (([String], URL) throws -> String)?
    private var state: AdditionalState
    private var xdg: URL { home.appendingPathComponent(".config") }
    var hasBackups: Bool { state.apps.values.contains { !$0.isEmpty } }
    var configuredLocations: URL { root.appendingPathComponent("integration-locations.json") }

    init(root: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser, live: Bool = true, fileReader: BoundedFileReader = .shared, obsidianCommand: (([String], URL) throws -> String)? = nil) throws {
        self.root = root; self.home = home; self.live = live
        self.fileReader = fileReader
        self.obsidianCommand = obsidianCommand
        let journal = root.appendingPathComponent("additional-state.json")
        state = try fileReader.data(at: journal).map { try JSONDecoder().decode(AdditionalState.self, from: $0) } ?? AdditionalState()
    }
    private func save() throws {
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("additional-state.json"), options: .atomic)
    }
    private func executable(_ command: String) -> URL? {
        let folders = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return folders.map { URL(fileURLWithPath: $0).appendingPathComponent(command) }.first { files.isExecutableFile(atPath: $0.path) }
    }
    private func location(_ key: String, fallback: URL) throws -> URL {
        guard let data = try fileReader.data(at: configuredLocations) else { return fallback }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let path = object?[key] as? String else { return fallback }
        guard path.hasPrefix("/") else { throw ThemeError.message("Integration location \(key) must be an absolute path.") }
        return URL(fileURLWithPath: path)
    }
    private func read(_ url: URL, fallback: String) throws -> String {
        try fileReader.text(at: url) ?? fallback
    }
    private func editorBaseTheme(_ app: AdditionalIntegration, isLight: Bool) -> String {
        let target = isLight ? "Light+" : "Dark+"
        guard let bundle = app.bundleID, let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle),
              let data = try? fileReader.data(at: installed.appendingPathComponent("Contents/Resources/app/extensions/theme-defaults/package.json")),
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contributes = package["contributes"] as? [String: Any],
              let themes = contributes["themes"] as? [[String: Any]],
              let match = themes.compactMap({ $0["id"] as? String }).first(where: { $0 == target || $0 == "Default " + target }) else { return target }
        return match
    }
    private func change(_ url: URL, app: AdditionalIntegration, format: String, values: [([String], String)]) throws {
        let url = url.resolvingSymlinksInPath(), old = try read(url, fallback: format == "json" ? "{}\n" : "")
        var backups = state.apps[app.rawValue] ?? []
        var backup = backups.first(where: { $0.path == url.path }) ?? PaletteFileBackup(path: url.path, format: format, original: files.fileExists(atPath: url.path) ? old : nil)
        var updated = old
        for (path, value) in values {
            let current = try format == "json" ? PaletteJSON.raw(updated, path: path) : PaletteScalar.raw(updated, path: path)
            if let index = backup.fields.firstIndex(where: { $0.path == path }) {
                guard current == backup.fields[index].applied || current == backup.fields[index].original || current == backup.fields[index].previous else { throw ThemeError.message("\(url.lastPathComponent): \(path.joined(separator: ".")) changed outside Mac Themes. Restore/review it first.") }
                backup.fields[index].previous = current
                backup.fields[index].applied = value
            } else { backup.fields.append(PaletteFieldBackup(path: path, original: current, applied: value, previous: current)) }
            updated = try format == "json" ? PaletteJSON.setting(updated, path: path, raw: value) : PaletteScalar.setting(updated, path: path, raw: value)
        }
        backups.removeAll { $0.path == url.path }; backups.append(backup); state.apps[app.rawValue] = backups
        try save(); try ManagedConfig.write(updated, to: url)
    }
    private func generated(_ url: URL, app: AdditionalIntegration, content: String) throws {
        let url = url.resolvingSymlinksInPath(), current = try fileReader.text(at: url)
        var backups = state.apps[app.rawValue] ?? []
        var backup = backups.first(where: { $0.path == url.path }) ?? PaletteFileBackup(path: url.path, format: "file", original: current)
        if let applied = backup.applied, current != applied && current != backup.original && current != backup.previous { throw ThemeError.message("\(url.lastPathComponent) changed outside Mac Themes. Backup retained.") }
        backup.previous = current
        backup.applied = content
        backups.removeAll { $0.path == url.path }; backups.append(backup); state.apps[app.rawValue] = backups
        try save(); try ManagedConfig.write(content, to: url)
    }

    func apply(_ theme: Theme, to app: AdditionalIntegration) throws -> String {
        let colors = theme.palette + [theme.background, theme.foreground, theme.accent, theme.cursor, theme.selection]
        guard theme.palette.count == 16, colors.allSatisfy({ $0.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil }) else { throw ThemeError.message("A complete palette of 16 hexadecimal RGB colors is required.") }
        if let folder = app.settingsFolder {
            let fallback = home.appendingPathComponent("Library/Application Support/\(folder)/User/settings.json")
            let url = try location(app.rawValue, fallback: fallback)
            let fields = try AdditionalPalette.editorColors(theme).sorted(by: { $0.key < $1.key }).map { (["workbench.colorCustomizations", $0.key], try PaletteJSON.literal($0.value)) }
            let tokenColors = ["comments": theme.palette[8], "strings": theme.palette[2], "keywords": theme.palette[5], "numbers": theme.palette[3], "types": theme.palette[3], "functions": theme.palette[4], "variables": theme.foreground]
            let base = (["workbench.colorTheme"], try PaletteJSON.literal(editorBaseTheme(app, isLight: theme.isLight)))
            try change(url, app: app, format: "json", values: [base] + fields + (try tokenColors.sorted(by: { $0.key < $1.key }).map { (["editor.tokenColorCustomizations", $0.key], try PaletteJSON.literal($0.value)) }))
            return "Applied · watched editor settings (workspace overrides may win)"
        }
        switch app {
        case .alacritty:
            let candidates = [xdg.appendingPathComponent("alacritty/alacritty.toml"), xdg.appendingPathComponent("alacritty.toml"), home.appendingPathComponent(".alacritty.toml")]
            let url = try location("alacritty", fallback: candidates.first(where: { files.fileExists(atPath: $0.path) }) ?? candidates[0])
            try change(url, app: app, format: "scalar", values: AdditionalPalette.alacritty(theme).sorted(by: { $0.key < $1.key }).map { ($0.key.components(separatedBy: "."), " \"\($0.value)\"") })
            return "Applied · Alacritty watches its config (requires live_config_reload)"
        case .kitty:
            let url = try location("kitty", fallback: xdg.appendingPathComponent("kitty/kitty.conf"))
            let source = try read(url, fallback: "")
            let managed = root.appendingPathComponent("kitty.conf")
            try generated(managed, app: app, content: AdditionalPalette.kitty(theme))
            let include = "include \(managed.path)"
            guard !include.contains("\n") else { throw ThemeError.message("Unsupported config path.") }
            try changeKitty(url, source: source, include: include)
            return refresh(app)
        case .obsidian: return try applyObsidian(theme)
        case .btop:
            let url = try location("btop", fallback: xdg.appendingPathComponent("btop/btop.conf"))
            let themeURL = url.deletingLastPathComponent().appendingPathComponent("themes/mac-themes.theme")
            guard themeURL.path.rangeOfCharacter(from: CharacterSet(charactersIn: "\"\n\r")) == nil else { throw ThemeError.message("btop's theme path contains an unsupported quote or newline.") }
            try generated(themeURL, app: app, content: AdditionalPalette.btop(theme))
            try change(url, app: app, format: "scalar", values: [(["color_theme"], " \"\(themeURL.path)\"")])
            return refresh(app)
        case .helix:
            let url = try location("helix", fallback: xdg.appendingPathComponent("helix/config.toml"))
            try generated(url.deletingLastPathComponent().appendingPathComponent("themes/mac-themes.toml"), app: app, content: AdditionalPalette.helix(theme))
            try change(url, app: app, format: "scalar", values: [(["theme"], " \"mac-themes\"")])
            return refresh(app)
        case .neovim:
            let folder = try location("neovim", fallback: xdg.appendingPathComponent("nvim"))
            let plugin = folder.appendingPathComponent("plugin/mac-themes.lua")
            try generated(plugin, app: app, content: AdditionalPalette.neovim(theme))
            return refreshNeovim(plugin)
        case .opencode:
            let folder = try location("opencode", fallback: xdg.appendingPathComponent("opencode"))
            try generated(folder.appendingPathComponent("themes/mac-themes.json"), app: app, content: try AdditionalPalette.openCode(theme))
            try change(folder.appendingPathComponent("tui.json"), app: app, format: "json", values: [(["theme"], "\"mac-themes\"")])
            return "\(refresh(app)) · select mac-themes once in existing sessions via /theme"
        default: throw ThemeError.message("Unknown editor integration.")
        }
    }

    private static let kittyStart = "# >>> Mac Themes palette >>>"
    private static let kittyEnd = "# <<< Mac Themes palette <<<"
    private static func kittyRange(_ text: String) throws -> Range<String.Index>? {
        guard text.components(separatedBy: kittyStart).count <= 2, text.components(separatedBy: kittyEnd).count <= 2 else { throw ThemeError.message("Duplicate Mac Themes blocks in Kitty.") }
        let start = text.range(of: kittyStart), end = text.range(of: kittyEnd)
        if start == nil && end == nil { return nil }
        guard let start, let end, start.lowerBound < end.lowerBound else { throw ThemeError.message("Edited Mac Themes markers in Kitty.") }
        let lower = start.lowerBound > text.startIndex && text[text.index(before: start.lowerBound)] == "\n" ? text.index(before: start.lowerBound) : start.lowerBound
        let upper = end.upperBound < text.endIndex && text[end.upperBound] == "\n" ? text.index(after: end.upperBound) : end.upperBound
        return lower..<upper
    }
    private func changeKitty(_ url: URL, source: String, include: String) throws {
        let url = url.resolvingSymlinksInPath(); var backups = state.apps["kitty"] ?? []
        var backup = backups.first(where: { $0.path == url.path }) ?? PaletteFileBackup(path: url.path, format: "kitty", original: files.fileExists(atPath: url.path) ? source : nil)
        var updated = source
        if let range = try Self.kittyRange(source) {
            guard backup.applied == String(source[range]) else { throw ThemeError.message("Kitty's Mac Themes include changed. Review it before applying.") }
            updated.removeSubrange(range)
        }
        let block = "\n\(Self.kittyStart)\n\(include)\n\(Self.kittyEnd)\n"
        updated += block; backup.applied = block
        backups.removeAll { $0.path == url.path }; backups.append(backup); state.apps["kitty"] = backups
        try save(); try ManagedConfig.write(updated, to: url)
    }

    func restore(_ app: AdditionalIntegration) throws -> String {
        guard let backups = state.apps[app.rawValue], !backups.isEmpty else { return "No changes to restore" }
        var obsidianDisableConfirmed = true
        if app == .obsidian {
            // Validate all vault entries before disabling a live snippet or removing any files.
            for backup in backups {
                let url = URL(fileURLWithPath: backup.path)
                if backup.format == "obsidian-enabled" { _ = try Self.obsidianEnabledSnippets(read(url, fallback: "{}\n")) }
                if backup.format == "file" {
                    let current = try fileReader.text(at: url)
                    guard current == backup.applied || current == backup.original || current == backup.previous else { throw ThemeError.message("\(url.lastPathComponent) changed outside Mac Themes. Backup retained.") }
                }
            }
            obsidianDisableConfirmed = try restoreObsidianEnabled(backups)
        }
        for backup in backups.reversed() {
            let url = URL(fileURLWithPath: backup.path)
            var current = try read(url, fallback: ["json", "obsidian-enabled"].contains(backup.format) ? "{}\n" : "")
            if backup.format == "file" {
                guard current == backup.applied || current == backup.original || current == backup.previous else { throw ThemeError.message("\(url.lastPathComponent) changed outside Mac Themes. Backup retained.") }
                if let original = backup.original { try ManagedConfig.write(original, to: url) }
                else if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
            } else if backup.format == "kitty" {
                if let range = try Self.kittyRange(current) {
                    guard String(current[range]) == backup.applied else { throw ThemeError.message("Kitty's include was edited. Backup retained.") }
                    current.removeSubrange(range)
                }
                try ManagedConfig.write(current, to: url)
            } else if backup.format == "obsidian-enabled" {
                // The live CLI preserves all other snippets; without it, only our member is removed.
                let list = try Self.obsidianEnabledSnippets(current)
                let originallyEnabled = backup.fields.first?.original == "true"
                let updated = originallyEnabled ? (list.contains("mac-themes") ? list : list + ["mac-themes"]) : list.filter { $0 != "mac-themes" }
                let originalList = try backup.original.flatMap { try PaletteJSON.raw($0, path: ["enabledCssSnippets"]) }
                current = try PaletteJSON.setting(current, path: ["enabledCssSnippets"], raw: updated.isEmpty && originalList == nil ? nil : PaletteJSON.literal(updated))
                if backup.original == nil, current.trimmingCharacters(in: .whitespacesAndNewlines) == "{}" {
                    if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
                } else { try ManagedConfig.write(current, to: url) }
            } else {
                for field in backup.fields.reversed() {
                    let value = try backup.format == "json" ? PaletteJSON.raw(current, path: field.path) : PaletteScalar.raw(current, path: field.path)
                    guard value == field.applied || value == field.original || value == field.previous else { throw ThemeError.message("\(url.lastPathComponent): \(field.path.joined(separator: ".")) changed outside Mac Themes. Backup retained.") }
                    current = try backup.format == "json" ? PaletteJSON.setting(current, path: field.path, raw: field.original) : PaletteScalar.setting(current, path: field.path, raw: field.original)
                }
                // Preserve every unrelated byte, including meaningful whitespace inside strings.
                try ManagedConfig.write(current, to: url)
            }
            state.apps[app.rawValue]?.removeAll { $0.path == backup.path }; try save()
        }
        if app == .obsidian {
            return obsidianDisableConfirmed ? "Restored · CSS and snippet selection" : "Restored · prior CSS files and snippet settings saved"
        }
        return "Restored · \(refresh(app))"
    }
    private func run(_ executable: URL, _ arguments: [String], directory: URL? = nil) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        // Only bounded local configuration commands are dispatched; timeout never targets the app.
        let limit = Date().addingTimeInterval(3)
        while process.isRunning && Date() < limit { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate(); throw ThemeError.message("The application configuration command timed out.") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { throw ThemeError.message("The application did not accept its configuration command.") }
        return String(decoding: data, as: UTF8.self)
    }
    private func refresh(_ app: AdditionalIntegration) -> String {
        guard live else { return "Saved · live reload disabled in fixture" }
        let processName: String, signal: Int32
        switch app {
        case .kitty: processName = "kitty"; signal = SIGUSR1
        case .btop: processName = "btop"; signal = SIGUSR2
        case .helix: processName = "hx"; signal = SIGUSR1
        case .alacritty: return "Applied · watched Alacritty config"
        case .vscode, .vscodeInsiders, .vscodium, .cursor: return "Applied · watched editor settings"
        case .obsidian: return "Applied · watched CSS snippet"
        case .neovim: return "Saved · existing Neovim sessions retain colors until their next colorscheme command"
        case .opencode: processName = "opencode"; signal = SIGUSR2
        }
        do {
            let output = try run(URL(fileURLWithPath: "/usr/bin/pgrep"), ["-u", String(getuid()), "-x", processName])
            let pids = output.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
            guard !pids.isEmpty else { return "Saved · takes effect when \(app.rawValue) opens" }
            // Never deliver SIGUSR* to a version with the default terminating disposition.
            guard pids.allSatisfy({ Self.catchesReloadSignal(signal, pid: $0) }) else { return "Saved · a running session does not expose a reload signal" }
            let failed = pids.filter { Darwin.kill($0, signal) != 0 }
            return failed.isEmpty ? "Applied · configuration reload signaled" : "Saved · some running sessions could not be signaled"
        } catch { return "Saved · no running \(processName) session detected" }
    }

    static func catchesReloadSignal(_ signal: Int32, pid: pid_t) -> Bool {
        guard pid > 0, signal > 0, signal <= 32 else { return false }
        var info = kinfo_proc(), length = MemoryLayout<kinfo_proc>.stride
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &length, nil, 0) == 0,
              length == MemoryLayout<kinfo_proc>.stride,
              info.kp_eproc.e_ucred.cr_uid == getuid() else { return false }
        return (info.kp_proc.p_sigcatch & (UInt32(1) << UInt32(signal - 1))) != 0
    }

    func obsidianVaults() throws -> [URL] {
        if let data = try fileReader.data(at: configuredLocations),
           let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let paths = object["obsidianVaults"] as? [String] {
            guard paths.allSatisfy({ $0.hasPrefix("/") }) else { throw ThemeError.message("Obsidian vault paths must be absolute.") }
            return paths.map { URL(fileURLWithPath: $0) }
        }
        let registry = home.appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let data = try fileReader.data(at: registry),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = json["vaults"] as? [String: [String: Any]] else { return [] }
        return vaults.values.compactMap { $0["path"] as? String }.sorted().map { URL(fileURLWithPath: $0) }
    }
    private func obsidianCLI() -> URL? {
        guard live, !NSRunningApplication.runningApplications(withBundleIdentifier: "md.obsidian").isEmpty,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") else { return nil }
        let cli = app.appendingPathComponent("Contents/MacOS/obsidian-cli")
        return files.isExecutableFile(atPath: cli.path) ? cli : nil
    }
    private func obsidianVaultTarget(_ vault: URL) throws -> String? {
        let registry = home.appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let data = try fileReader.data(at: registry),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["vaults"] as? [String: [String: Any]] else { return nil }
        let target = vault.standardizedFileURL.path
        let matches = entries.compactMap { id, value -> String? in
            guard let path = value["path"] as? String, URL(fileURLWithPath: path).standardizedFileURL.path == target else { return nil }
            return id
        }
        return matches.count == 1 ? matches[0] : nil
    }
    private func runObsidian(_ arguments: [String], vault: URL, cli: URL?) throws {
        if let obsidianCommand { _ = try obsidianCommand(arguments, vault) }
        else if let cli { _ = try run(cli, arguments, directory: vault) }
    }
    static func obsidianEnabledSnippets(_ source: String) throws -> [String] {
        guard let raw = try PaletteJSON.raw(source, path: ["enabledCssSnippets"]) else { return [] }
        guard let snippets = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String] else {
            throw ThemeError.message("Obsidian's enabledCssSnippets setting must be a list of snippet names. No snippet changes were made.")
        }
        return snippets
    }
    private func applyObsidian(_ theme: Theme) throws -> String {
        let vaults = try obsidianVaults().filter { files.fileExists(atPath: $0.appendingPathComponent(".obsidian").path) }
        guard !vaults.isEmpty else { throw ThemeError.message("Open a vault in Obsidian, or add obsidianVaults paths to integration-locations.json.") }
        let cli = obsidianCLI(); var waiting = 0
        for vault in vaults {
            let config = vault.appendingPathComponent(".obsidian"), appearance = config.appendingPathComponent("appearance.json")
            let current = try read(appearance, fallback: "{}\n")
            let enabled = try Self.obsidianEnabledSnippets(current)
            var backups = state.apps["obsidian"] ?? []
            if !backups.contains(where: { $0.path == appearance.path }) {
                backups.append(PaletteFileBackup(path: appearance.path, format: "obsidian-enabled", original: files.fileExists(atPath: appearance.path) ? current : nil, fields: [PaletteFieldBackup(path: ["enabledCssSnippets"], original: enabled.contains("mac-themes") ? "true" : "false", applied: "true", previous: nil)]))
                state.apps["obsidian"] = backups; try save()
            }
            try generated(config.appendingPathComponent("snippets/mac-themes.css"), app: .obsidian, content: AdditionalPalette.obsidian(theme))
            if !enabled.contains("mac-themes") {
                if (obsidianCommand != nil || cli != nil), let target = try obsidianVaultTarget(vault) {
                    // Some CLI versions print "disabled" errors but still exit zero. Only the
                    // target vault's persisted membership can confirm that activation happened.
                    try? runObsidian(["vault=\(target)", "snippet:enable", "name=mac-themes"], vault: vault, cli: cli)
                    let confirmed = try Self.obsidianEnabledSnippets(read(appearance, fallback: "{}\n"))
                    if !confirmed.contains("mac-themes") { waiting += 1 }
                } else { waiting += 1 }
            }
        }
        return waiting == 0 ? "Applied · watched snippet in \(vaults.count) vault(s)" : "Saved · Appearance → CSS snippets → Reload snippets if needed, then enable mac-themes in \(waiting) vault(s); or enable Obsidian CLI"
    }
    private func restoreObsidianEnabled(_ backups: [PaletteFileBackup]) throws -> Bool {
        let cli = obsidianCLI()
        var confirmed = true
        for backup in backups where backup.format == "obsidian-enabled" && backup.fields.first?.original != "true" {
            let appearance = URL(fileURLWithPath: backup.path)
            let vault = appearance.deletingLastPathComponent().deletingLastPathComponent()
            if (obsidianCommand != nil || cli != nil), let target = try obsidianVaultTarget(vault) {
                try? runObsidian(["vault=\(target)", "snippet:disable", "name=mac-themes"], vault: vault, cli: cli)
            }
            if try Self.obsidianEnabledSnippets(read(appearance, fallback: "{}\n")).contains("mac-themes") { confirmed = false }
        }
        // The caller still restores/removes owned CSS and saves the original snippet membership
        // when the command failed or could not be confirmed. A CLI failure must not block that.
        return confirmed
    }
    private func refreshNeovim(_ plugin: URL) -> String {
        guard live, let nvim = executable("nvim") else { return "Saved · palette loads when Neovim starts" }
        var sockets: [URL] = []
        if let socket = ProcessInfo.processInfo.environment["NVIM"], socket.hasPrefix("/") { sockets.append(URL(fileURLWithPath: socket)) }
        let temp = FileManager.default.temporaryDirectory
        if let entries = try? files.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil) {
            for folder in entries where folder.lastPathComponent.hasPrefix("nvim.") {
                if let e = files.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for case let path as URL in e {
                        if sockets.count >= 100 { break }
                        if (try? files.attributesOfItem(atPath: path.path)[.type] as? FileAttributeType) == .typeSocket { sockets.append(path) }
                    }
                }
            }
        }
        let lua = "dofile(" + (try! PaletteJSON.literal(plugin.path)) + ")"
        let expression = "luaeval('" + lua.replacingOccurrences(of: "'", with: "''") + "')"
        let ownedSockets = sockets.filter { ((try? files.attributesOfItem(atPath: $0.path)[.ownerAccountID]) as? NSNumber)?.uint32Value == getuid() }
        let accepted = Set(ownedSockets).filter { (try? run(nvim, ["--server", $0.path, "--remote-expr", expression])) != nil }.count
        return accepted > 0 ? "Applied · \(accepted) Neovim server(s); palette watches future changes" : "Saved · source plugin/mac-themes.lua once in existing Neovim sessions; future starts follow automatically"
    }
}

enum AdditionalPalette {
    static func editorColors(_ t: Theme) -> [String: String] {
        var colors: [String: String] = [:]
        for key in ["editor.background", "sideBar.background", "activityBar.background", "panel.background", "titleBar.activeBackground", "titleBar.inactiveBackground", "statusBar.background", "statusBar.noFolderBackground", "tab.activeBackground", "terminal.background", "input.background", "dropdown.background", "editorWidget.background", "menu.background", "notificationCenterHeader.background", "notifications.background", "quickInput.background"] { colors[key] = t.background }
        for key in ["foreground", "editor.foreground", "sideBar.foreground", "activityBar.foreground", "titleBar.activeForeground", "titleBar.inactiveForeground", "statusBar.foreground", "tab.activeForeground", "terminal.foreground", "input.foreground", "dropdown.foreground", "menu.foreground", "notifications.foreground"] { colors[key] = t.foreground }
        for key in ["focusBorder", "button.background", "activityBar.activeBorder", "panelTitle.activeBorder", "textLink.foreground", "progressBar.background", "tab.activeBorderTop"] { colors[key] = t.accent }
        colors["button.foreground"] = t.background
        colors["editor.selectionBackground"] = t.selection
        colors["terminal.selectionBackground"] = t.selection
        colors["editorCursor.foreground"] = t.cursor
        colors["terminalCursor.foreground"] = t.cursor
        colors["editorLineNumber.foreground"] = t.palette[8]
        colors["editorLineNumber.activeForeground"] = t.foreground
        colors["gitDecoration.addedResourceForeground"] = t.palette[2]
        colors["gitDecoration.deletedResourceForeground"] = t.palette[1]
        colors["gitDecoration.modifiedResourceForeground"] = t.palette[3]
        let names = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
        for (i, name) in names.enumerated() { colors["terminal.ansi\(name)"] = t.palette[i]; colors["terminal.ansiBright\(name)"] = t.palette[i + 8] }
        return colors
    }
    static func alacritty(_ t: Theme) -> [String: String] {
        var colors = ["colors.primary.background": t.background, "colors.primary.foreground": t.foreground, "colors.cursor.text": t.background, "colors.cursor.cursor": t.cursor, "colors.selection.text": t.foreground, "colors.selection.background": t.selection]
        for (i, name) in ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"].enumerated() { colors["colors.normal.\(name)"] = t.palette[i]; colors["colors.bright.\(name)"] = t.palette[i + 8] }
        return colors
    }
    static func kitty(_ t: Theme) -> String {
        (["# Generated by Mac Themes", "foreground \(t.foreground)", "background \(t.background)", "selection_foreground \(t.foreground)", "selection_background \(t.selection)", "cursor \(t.cursor)", "cursor_text_color \(t.background)", "active_border_color \(t.accent)", "active_tab_background \(t.accent)", "active_tab_foreground \(t.background)"] + t.palette.enumerated().map { "color\($0.offset) \($0.element)" }).joined(separator: "\n") + "\n"
    }
    static func obsidian(_ t: Theme) -> String {
        let variables = ["background-primary": t.background, "background-primary-alt": t.background, "background-secondary": t.background, "background-secondary-alt": t.background, "text-normal": t.foreground, "text-muted": t.foreground + "B3", "text-faint": t.foreground + "8C", "text-selection": t.selection, "background-modifier-border": t.palette[8], "text-link": t.palette[4], "text-accent": t.accent, "text-accent-hover": t.accent, "interactive-accent": t.accent, "interactive-accent-hover": t.accent, "text-on-accent": t.background, "code-normal": t.palette[6], "code-background": t.background, "text-error": t.palette[1], "text-success": t.palette[2], "h1-color": t.palette[1], "h2-color": t.palette[2], "h3-color": t.palette[3], "h4-color": t.palette[4], "h5-color": t.palette[5], "h6-color": t.palette[6], "graph-line": t.palette[8], "graph-node": t.accent, "graph-node-focused": t.palette[4], "graph-node-tag": t.palette[6], "graph-node-attachment": t.palette[2], "tag-color": t.palette[6], "tag-background": t.selection, "checkbox-color": t.accent, "nav-item-color-active": t.accent]
        // Obsidian's dark base appearance overrides these independently of its main background.
        // Keep light imported palettes readable without changing the user's base-theme setting.
        let controls = ["background-modifier-form-field": t.background, "background-modifier-form-field-hover": t.background, "background-modifier-hover": t.selection, "background-modifier-active-hover": t.selection, "background-modifier-border-hover": t.foreground + "8C", "background-modifier-border-focus": t.accent, "interactive-normal": t.background, "interactive-hover": t.selection, "dropdown-background": t.background, "dropdown-background-hover": t.selection, "input-placeholder-color": t.foreground + "E6"]
        let colors = variables.merging(controls) { _, new in new }
        return "/* Generated by Mac Themes; no scripts or remote assets. */\nbody.theme-dark, body.theme-light {\n  color-scheme: \(t.isLight ? "light" : "dark");\n" + colors.sorted(by: { $0.key < $1.key }).map { "  --\($0.key): \($0.value);" }.joined(separator: "\n") + "\n}\n"
    }
    static func btop(_ t: Theme) -> String {
        var values = ["main_bg": t.background, "main_fg": t.foreground, "title": t.foreground, "hi_fg": t.accent, "selected_bg": t.selection, "selected_fg": t.foreground, "inactive_fg": t.palette[8], "graph_text": t.foreground, "meter_bg": t.palette[8], "proc_misc": t.palette[6], "cpu_box": t.accent, "mem_box": t.palette[2], "net_box": t.palette[5], "proc_box": t.palette[4], "div_line": t.palette[8]]
        for name in ["temp", "cpu", "free", "cached", "available", "used", "download", "upload", "process"] { values[name + "_start"] = t.palette[2]; values[name + "_mid"] = t.palette[3]; values[name + "_end"] = t.palette[1] }
        return "# Generated by Mac Themes\n" + values.sorted(by: { $0.key < $1.key }).map { "theme[\($0.key)] = \"\($0.value)\"" }.joined(separator: "\n") + "\n"
    }
    static func helix(_ t: Theme) -> String {
        let scopes = ["keyword": t.palette[5], "function": t.palette[4], "type": t.palette[3], "constant": t.palette[3], "string": t.palette[2], "comment": t.palette[8], "variable": t.foreground, "operator": t.palette[6], "punctuation": t.palette[8], "diff.plus": t.palette[2], "diff.minus": t.palette[1], "diff.delta": t.palette[4], "ui.text": t.foreground, "ui.linenr": t.palette[8], "ui.linenr.selected": t.foreground, "error": t.palette[1], "warning": t.palette[3], "info": t.palette[4], "hint": t.palette[6]]
        return "# Generated by Mac Themes\n" + scopes.sorted(by: { $0.key < $1.key }).map { "\"\($0.key)\" = \"\($0.value)\"" }.joined(separator: "\n") + "\n\"ui.background\" = { fg = \"\(t.foreground)\", bg = \"\(t.background)\" }\n\"ui.selection\" = { bg = \"\(t.selection)\" }\n\"ui.cursor\" = { fg = \"\(t.background)\", bg = \"\(t.cursor)\" }\n\"ui.statusline\" = { fg = \"\(t.background)\", bg = \"\(t.accent)\" }\n\"ui.popup\" = { fg = \"\(t.foreground)\", bg = \"\(t.background)\" }\n\"ui.menu\" = { fg = \"\(t.foreground)\", bg = \"\(t.background)\" }\n\"ui.menu.selected\" = { fg = \"\(t.foreground)\", bg = \"\(t.selection)\" }\n"
    }
    static func neovim(_ t: Theme) -> String {
        let groups = ["Normal": (t.foreground, t.background), "NormalFloat": (t.foreground, t.background), "Comment": (t.palette[8], "NONE"), "String": (t.palette[2], "NONE"), "Number": (t.palette[3], "NONE"), "Constant": (t.palette[3], "NONE"), "Statement": (t.palette[5], "NONE"), "Identifier": (t.palette[4], "NONE"), "Function": (t.palette[4], "NONE"), "Type": (t.palette[3], "NONE"), "Special": (t.palette[6], "NONE"), "LineNr": (t.palette[8], "NONE"), "CursorLineNr": (t.accent, "NONE"), "Visual": (t.foreground, t.selection), "Cursor": (t.background, t.cursor), "StatusLine": (t.background, t.accent), "Pmenu": (t.foreground, t.background), "PmenuSel": (t.foreground, t.selection), "DiagnosticError": (t.palette[1], "NONE"), "DiagnosticWarn": (t.palette[3], "NONE"), "DiagnosticInfo": (t.palette[4], "NONE"), "DiagnosticHint": (t.palette[6], "NONE")]
        let lines = groups.sorted(by: { $0.key < $1.key }).map { "vim.api.nvim_set_hl(0, '\($0.key)', {fg='\($0.value.0)', bg='\($0.value.1)'})" }
        return """
        -- Generated by Mac Themes. Only color literals are imported from external themes.
        local path = debug.getinfo(1, 'S').source:sub(2)
        if not _G.mac_themes_original then
          local old = { name = vim.g.colors_name, background = vim.o.background, truecolor = vim.o.termguicolors, terminal = {}, highlights = {} }
          for i = 0, 15 do old.terminal[i] = vim.g['terminal_color_' .. i] end
          for _, name in ipairs({\(groups.keys.sorted().map { "'\($0)'" }.joined(separator: ","))}) do
            old.highlights[name] = vim.api.nvim_get_hl(0, { name = name })
          end
          _G.mac_themes_original = old
        end
        vim.o.termguicolors = true
        vim.o.background = '\(t.isLight ? "light" : "dark")'
        vim.g.colors_name = 'mac-themes'
        \(lines.joined(separator: "\n"))
        \(t.palette.enumerated().map { "vim.g.terminal_color_\($0.offset) = '\($0.element)'" }.joined(separator: "\n"))
        if not _G.mac_themes_watcher then
          local uv = vim.uv or vim.loop
          local watcher = uv.new_fs_event()
          _G.mac_themes_watcher = watcher
          watcher:start(vim.fn.fnamemodify(path, ':h'), {}, vim.schedule_wrap(function(_, filename)
            if filename ~= vim.fn.fnamemodify(path, ':t') then return end
            if vim.fn.filereadable(path) == 1 then pcall(dofile, path)
            else
              watcher:stop(); watcher:close(); _G.mac_themes_watcher = nil
              local old = _G.mac_themes_original
              if old and vim.g.colors_name == 'mac-themes' then
                vim.o.background = old.background
                vim.o.termguicolors = old.truecolor
                for name, value in pairs(old.highlights) do vim.api.nvim_set_hl(0, name, value) end
                for i = 0, 15 do vim.g['terminal_color_' .. i] = old.terminal[i] end
                vim.g.colors_name = old.name
              end
              _G.mac_themes_original = nil
            end
          end))
        end
        """ + "\n"
    }
    static func openCode(_ t: Theme) throws -> String {
        let values: [String: String] = ["primary": t.accent, "secondary": t.palette[5], "accent": t.palette[6], "error": t.palette[1], "warning": t.palette[3], "success": t.palette[2], "info": t.palette[4], "text": t.foreground, "textMuted": t.palette[8], "background": t.background, "backgroundPanel": t.background, "backgroundElement": t.selection, "border": t.palette[8], "borderActive": t.accent, "borderSubtle": t.palette[8], "diffAdded": t.palette[2], "diffRemoved": t.palette[1], "diffContext": t.palette[8], "diffHunkHeader": t.palette[4], "diffHighlightAdded": t.palette[2], "diffHighlightRemoved": t.palette[1], "diffAddedBg": t.background, "diffRemovedBg": t.background, "diffContextBg": t.background, "diffLineNumber": t.palette[8], "diffAddedLineNumberBg": t.background, "diffRemovedLineNumberBg": t.background, "markdownText": t.foreground, "markdownHeading": t.accent, "markdownLink": t.palette[4], "markdownLinkText": t.palette[6], "markdownCode": t.palette[2], "markdownBlockQuote": t.palette[8], "markdownEmph": t.palette[3], "markdownStrong": t.palette[3], "markdownHorizontalRule": t.palette[8], "markdownListItem": t.accent, "markdownListEnumeration": t.palette[6], "markdownImage": t.palette[4], "markdownImageText": t.palette[6], "markdownCodeBlock": t.foreground, "syntaxComment": t.palette[8], "syntaxKeyword": t.palette[5], "syntaxFunction": t.palette[4], "syntaxVariable": t.foreground, "syntaxString": t.palette[2], "syntaxNumber": t.palette[3], "syntaxType": t.palette[3], "syntaxOperator": t.palette[6], "syntaxPunctuation": t.palette[8]]
        return try PaletteJSON.literal(["$schema": "https://opencode.ai/theme.json", "theme": values]) + "\n"
    }
}
