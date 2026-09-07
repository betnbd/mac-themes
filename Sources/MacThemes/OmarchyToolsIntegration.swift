import Foundation
import ThemeCore

enum OmarchyTool: String, CaseIterable, Codable {
    case tmux, pi, claude, hermes
    var name: String { Integration(rawValue: rawValue)!.name }

}

struct ToolFileBackup: Codable {
    var path: String
    var format: String
    var original: String?
    var applied: String
    var previous: String?
    var fieldOriginal: String?
    var fieldApplied: String?
    var fieldPrevious: String?
}
struct TmuxValueBackup: Codable { var original: String; var applied: String; var previous: String? }
struct TmuxRuntimeBackup: Codable {
    var server: String
    var options: [String: TmuxValueBackup] = [:]
    var environment: [String: TmuxValueBackup] = [:]
}
struct ToolsState: Codable {
    var files: [String: [ToolFileBackup]] = [:]
    var tmux: TmuxRuntimeBackup?
}

@MainActor
final class OmarchyToolsIntegration {
    let root: URL
    let home: URL
    let live: Bool
    let files = FileManager.default
    var state = ToolsState()
    /// Fixture-only command transport; production runs installed executables with argument arrays.
    var commandRunner: ((URL, [String]) throws -> String)?
    var hasBackups: Bool { state.files.values.contains { !$0.isEmpty } || state.tmux != nil }
    var journal: URL { root.appendingPathComponent("cli-tools-state.json") }

    init(root: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser, live: Bool = true) throws {
        self.root = root; self.home = home; self.live = live
        if files.fileExists(atPath: journal.path) {
            do { state = try JSONDecoder().decode(ToolsState.self, from: Data(contentsOf: journal)) }
            catch { throw ThemeError.message("The CLI theme restore journal could not be read. Existing backups were retained.") }
        }
    }
    func executable(_ command: String) -> URL? {
        let paths = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        return paths.map { URL(fileURLWithPath: $0).appendingPathComponent(command) }.first { files.isExecutableFile(atPath: $0.path) }
    }
    func save() throws {
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: journal, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
    }
    func read(_ url: URL) throws -> String? {
        guard files.fileExists(atPath: url.path) else { return nil }
        let attributes = try files.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 10_000_000 else { throw ThemeError.message("\(url.lastPathComponent) is too large to edit safely.") }
        return try String(contentsOf: url, encoding: .utf8)
    }


    func envArguments(_ scope: String, command: String) -> [String] { scope == "global" ? [command, "-g"] : [command, "-t", scope] }

    func restore(_ tool: OmarchyTool) throws -> String {
        let backups = state.files[tool.rawValue] ?? []
        guard !backups.isEmpty || (tool == .tmux && state.tmux != nil) else { return "No changes to restore" }
        let restoredLiveTmux = tool == .tmux ? try restoreTmuxRuntime() : false
        for backup in backups.reversed() {
            let url = URL(fileURLWithPath: backup.path), current = try read(url)
            var restored: String?
            if backup.format == "json" || backup.format == "yaml" {
                let fallback = backup.format == "json" ? "{}\n" : ""
                let source = current ?? fallback
                let value = try backup.format == "json" ? PaletteJSON.raw(source, path: ["theme"]) : ToolSkinYAML.raw(source)
                guard [backup.fieldOriginal, backup.fieldApplied, backup.fieldPrevious].contains(value) else { throw ThemeError.message("\(tool.name)'s theme preference changed outside Mac Themes. Backup retained.") }
                func withTheme(_ source: String, _ field: String?) throws -> String {
                    try backup.format == "json" ? PaletteJSON.setting(source, path: ["theme"], raw: field) : ToolSkinYAML.setting(source, raw: field)
                }
                // A full-file applied snapshot can contain unrelated user edits made between
                // switches. Restore whole original bytes only when the theme field was its sole change.
                let original = backup.original ?? fallback
                let expectedApplied = try withTheme(original, backup.fieldApplied)
                let expectedPrevious = try withTheme(original, backup.fieldPrevious)
                if current == backup.original || source == expectedApplied || source == expectedPrevious {
                    restored = backup.original
                } else if current == nil && backup.fieldOriginal == nil { restored = nil }
                else { restored = try withTheme(source, backup.fieldOriginal) }
            } else if backup.format == "tmux" {
                let source = current ?? "", original = backup.original ?? ""
                let removed = try ManagedConfig.removing(from: source)
                let appliedBlock = String(backup.applied.suffix(backup.applied.count - (try ManagedConfig.removing(from: backup.applied)).count))
                guard source == removed || source.contains(appliedBlock) else { throw ThemeError.message("The tmux include changed outside Mac Themes. Backup retained.") }
                restored = current == nil ? nil : removed == original ? backup.original : removed
            } else if current == backup.applied || current == backup.original || current == backup.previous { restored = backup.original }
            else { throw ThemeError.message("\(url.lastPathComponent) changed outside Mac Themes. Backup retained.") }
            if let restored { try ManagedConfig.write(restored, to: url) }
            else if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
            state.files[tool.rawValue]?.removeAll { $0.path == backup.path }; try save()
        }
        switch tool {
        case .tmux: return restoredLiveTmux ? "Restored · previous tmux settings and running server values" : "Restored · previous tmux configuration; original server is not active"
        case .pi: return "Restored · open Pi sessions may need their previous theme selected in /settings"
        case .claude: return "Restored · open Claude sessions may need their previous theme selected in /theme"
        case .hermes: return "Restored · gateway follows its skin; CLI sessions may need /skin"
        }
    }
    func restoreTmuxRuntime() throws -> Bool {
        guard let runtime = state.tmux else { return false }
        guard live, let command = executable("tmux"), let server = try? run(command, ["display-message", "-p", "#{pid}"]), server == runtime.server else {
            state.tmux = nil; try save(); return false
        }
        for (name, backup) in runtime.options.sorted(by: { $0.key < $1.key }) {
            let current = try run(command, ["show-options", "-gv", name])
            guard [backup.original, backup.applied, backup.previous].contains(current) else { throw ThemeError.message("tmux \(name) changed outside Mac Themes. Backup retained.") }
            // tmux 3.7 reports its unset cursor colour as "none", but rejects that
            // token as a colour value. Unsetting the global option restores that default.
            if name == "cursor-colour" && backup.original == "none" {
                _ = try run(command, ["set-option", "-gu", name])
            } else { _ = try run(command, ["set-option", "-g", name, backup.original]) }
        }
        for (scope, backup) in runtime.environment {
            if scope != "global", (try? run(command, ["has-session", "-t", scope])) == nil { continue }
            let current = (try? run(command, envArguments(scope, command: "show-environment") + ["COLORFGBG"])) ?? "<absent>"
            guard [backup.original, "COLORFGBG=" + backup.applied, backup.previous].contains(current) else { throw ThemeError.message("tmux COLORFGBG changed outside Mac Themes. Backup retained.") }
            var arguments = envArguments(scope, command: "set-environment")
            if backup.original == "<absent>" { arguments += ["-u", "COLORFGBG"] }
            else if backup.original == "-COLORFGBG" { arguments += ["-r", "COLORFGBG"] }
            else if backup.original.hasPrefix("COLORFGBG=") { arguments += ["COLORFGBG", String(backup.original.dropFirst(10))] }
            else { throw ThemeError.message("tmux's saved environment is invalid. Backup retained.") }
            _ = try run(command, arguments)
        }
        state.tmux = nil; try save(); return true
    }
    func run(_ command: URL, _ arguments: [String]) throws -> String {
        if let commandRunner { return try commandRunner(command, arguments) }
        let process = Process(), output = Pipe()
        process.executableURL = command; process.arguments = arguments
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        if process.isRunning { process.terminate(); throw ThemeError.message("The tmux configuration command timed out.") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0, data.count <= 128_000 else { throw ThemeError.message("tmux did not accept its configuration command.") }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}

/// Restricted YAML editing for display.skin. Other values, comments and model settings keep bytes.
/// Ambiguous/inline/anchored display objects are refused instead of parsing arbitrary YAML.
enum ToolSkinYAML {
    private struct Match { var range: Range<String.Index>?; var whole: Range<String.Index>?; var insert: String.Index; var prefix: String }
    private static func match(_ source: String) throws -> Match {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard !lines.contains(where: { $0.range(of: "^[\"']display[\"']\\s*:", options: .regularExpression) != nil }) else { throw ThemeError.message("Use a plain display key in Hermes config before applying a skin.") }
        let displays = lines.filter { $0.range(of: "^display\\s*:", options: .regularExpression) != nil }
        guard displays.count <= 1, !source.contains("\t"), !lines.contains(where: { $0 == "---" || $0 == "..." }) else { throw ThemeError.message("Hermes config has ambiguous YAML. Use a single plain display section.") }
        guard let display = displays.first else { return Match(insert: source.endIndex, prefix: (source.isEmpty || source.hasSuffix("\n") ? "" : "\n") + "display:\n  ") }
        let afterColon = display[display.index(after: display.firstIndex(of: ":")!)...].trimmingCharacters(in: .whitespaces)
        guard afterColon.isEmpty || afterColon.hasPrefix("#") else { throw ThemeError.message("Hermes display must be a plain YAML block, not an inline object or alias.") }
        let start = display.endIndex < source.endIndex ? source.index(after: display.endIndex) : display.endIndex
        var block: [Substring] = []
        for line in lines where line.startIndex >= start {
            if !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("#") { break }
            block.append(line)
        }
        let meaningful = block.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        let indent = meaningful.map { $0.prefix(while: { $0 == " " }).count }.min() ?? 2
        let prefix = String(repeating: " ", count: indent)
        guard !meaningful.contains(where: { $0.range(of: "^" + prefix + "[\"']skin[\"']\\s*:", options: .regularExpression) != nil }) else { throw ThemeError.message("Use a plain skin key in Hermes config before applying a skin.") }
        let skins = meaningful.filter { $0.range(of: "^" + prefix + "skin\\s*:", options: .regularExpression) != nil }
        guard skins.count <= 1, !meaningful.contains(where: { $0.hasPrefix(prefix + "<<:") }) else { throw ThemeError.message("Hermes display.skin is duplicated or inherited through YAML merge keys.") }
        if let skin = skins.first {
            let colon = skin.firstIndex(of: ":")!, lower = source.index(after: colon)
            let value = String(source[lower..<skin.endIndex]).trimmingCharacters(in: .whitespaces)
            guard !value.hasPrefix("|") && !value.hasPrefix(">") && !value.hasPrefix("&") && !value.hasPrefix("*") && !value.hasPrefix("{") && !value.hasPrefix("[") else { throw ThemeError.message("Hermes display.skin must be a scalar name.") }
            return Match(range: lower..<skin.endIndex, whole: skin.startIndex..<(skin.endIndex < source.endIndex ? source.index(after: skin.endIndex) : skin.endIndex), insert: start, prefix: prefix)
        }
        return Match(insert: start, prefix: (start == source.endIndex && !source.hasSuffix("\n") ? "\n" : "") + prefix)
    }
    static func raw(_ source: String) throws -> String? { try match(source).range.map { String(source[$0]) } }
    static func setting(_ source: String, raw: String?) throws -> String {
        let found = try match(source); var result = source
        if let range = found.range {
            if let raw { result.replaceSubrange(range, with: raw) }
            else if let whole = found.whole { result.removeSubrange(whole) }
        } else if let raw { result.insert(contentsOf: found.prefix + "skin:" + raw + "\n", at: found.insert) }
        return result
    }
}

/// Color-only equivalents of Quattro's pi.json, claude.json and hermes.yaml templates.
