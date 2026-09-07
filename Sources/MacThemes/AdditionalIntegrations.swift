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
struct AdditionalState: Codable { var apps: [String: [PaletteFileBackup]] = [:] }

@MainActor
final class AdditionalIntegrations {
    let root: URL
    let home: URL
    let files = FileManager.default
    let live: Bool
    let fileReader: BoundedFileReader
    let obsidianCommand: (([String], URL) throws -> String)?
    var state: AdditionalState
    var xdg: URL { home.appendingPathComponent(".config") }
    var hasBackups: Bool { state.apps.values.contains { !$0.isEmpty } }
    var configuredLocations: URL { root.appendingPathComponent("integration-locations.json") }

    init(root: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser, live: Bool = true, fileReader: BoundedFileReader = .shared, obsidianCommand: (([String], URL) throws -> String)? = nil) throws {
        self.root = root; self.home = home; self.live = live
        self.fileReader = fileReader
        self.obsidianCommand = obsidianCommand
        let journal = root.appendingPathComponent("additional-state.json")
        state = try fileReader.data(at: journal).map { try JSONDecoder().decode(AdditionalState.self, from: $0) } ?? AdditionalState()
    }
    func save() throws {
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("additional-state.json"), options: .atomic)
    }
    func executable(_ command: String) -> URL? {
        let folders = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return folders.map { URL(fileURLWithPath: $0).appendingPathComponent(command) }.first { files.isExecutableFile(atPath: $0.path) }
    }
    func read(_ url: URL, fallback: String) throws -> String {
        try fileReader.text(at: url) ?? fallback
    }


    static let kittyStart = "# >>> Mac Themes palette >>>"
    static let kittyEnd = "# <<< Mac Themes palette <<<"
    static func kittyRange(_ text: String) throws -> Range<String.Index>? {
        guard text.components(separatedBy: kittyStart).count <= 2, text.components(separatedBy: kittyEnd).count <= 2 else { throw ThemeError.message("Duplicate Mac Themes blocks in Kitty.") }
        let start = text.range(of: kittyStart), end = text.range(of: kittyEnd)
        if start == nil && end == nil { return nil }
        guard let start, let end, start.lowerBound < end.lowerBound else { throw ThemeError.message("Edited Mac Themes markers in Kitty.") }
        let lower = start.lowerBound > text.startIndex && text[text.index(before: start.lowerBound)] == "\n" ? text.index(before: start.lowerBound) : start.lowerBound
        let upper = end.upperBound < text.endIndex && text[end.upperBound] == "\n" ? text.index(after: end.upperBound) : end.upperBound
        return lower..<upper
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
    func run(_ executable: URL, _ arguments: [String], directory: URL? = nil) throws -> String {
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
    func refresh(_ app: AdditionalIntegration) -> String {
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

    func obsidianCLI() -> URL? {
        guard live, !NSRunningApplication.runningApplications(withBundleIdentifier: "md.obsidian").isEmpty,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") else { return nil }
        let cli = app.appendingPathComponent("Contents/MacOS/obsidian-cli")
        return files.isExecutableFile(atPath: cli.path) ? cli : nil
    }
    func obsidianVaultTarget(_ vault: URL) throws -> String? {
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
    func runObsidian(_ arguments: [String], vault: URL, cli: URL?) throws {
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
    func restoreObsidianEnabled(_ backups: [PaletteFileBackup]) throws -> Bool {
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
}
