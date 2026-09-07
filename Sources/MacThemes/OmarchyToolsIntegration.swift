import Foundation
import ThemeCore

enum OmarchyTool: String, CaseIterable, Codable {
    case tmux, pi, claude, hermes
    var name: String { Integration(rawValue: rawValue)!.name }

}

private struct ToolFileBackup: Codable {
    var path: String
    var format: String
    var original: String?
    var applied: String
    var previous: String?
    var fieldOriginal: String?
    var fieldApplied: String?
    var fieldPrevious: String?
}
private struct TmuxValueBackup: Codable { var original: String; var applied: String; var previous: String? }
private struct TmuxRuntimeBackup: Codable {
    var server: String
    var options: [String: TmuxValueBackup] = [:]
    var environment: [String: TmuxValueBackup] = [:]
}
private struct ToolsState: Codable {
    var files: [String: [ToolFileBackup]] = [:]
    var tmux: TmuxRuntimeBackup?
}

@MainActor
final class OmarchyToolsIntegration {
    let root: URL
    let home: URL
    let live: Bool
    private let files = FileManager.default
    private var state = ToolsState()
    /// Fixture-only command transport; production runs installed executables with argument arrays.
    var commandRunner: ((URL, [String]) throws -> String)?
    var hasBackups: Bool { state.files.values.contains { !$0.isEmpty } || state.tmux != nil }
    private var journal: URL { root.appendingPathComponent("cli-tools-state.json") }

    init(root: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser, live: Bool = true) throws {
        self.root = root; self.home = home; self.live = live
        if files.fileExists(atPath: journal.path) {
            do { state = try JSONDecoder().decode(ToolsState.self, from: Data(contentsOf: journal)) }
            catch { throw ThemeError.message("The CLI theme restore journal could not be read. Existing backups were retained.") }
        }
    }
    private func toolHome(_ tool: OmarchyTool) -> URL {
        let name: String, fallback: String
        switch tool {
        case .pi: name = "PI_CODING_AGENT_DIR"; fallback = ".pi/agent"
        case .claude: name = "CLAUDE_CONFIG_DIR"; fallback = ".claude"
        case .hermes: name = "HERMES_HOME"; fallback = ".hermes"
        case .tmux: name = "XDG_CONFIG_HOME"; fallback = ".config"
        }
        if home == files.homeDirectoryForCurrentUser, let value = ProcessInfo.processInfo.environment[name], value.hasPrefix("/") { return URL(fileURLWithPath: value) }
        return home.appendingPathComponent(fallback)
    }
    private func executable(_ command: String) -> URL? {
        let paths = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        return paths.map { URL(fileURLWithPath: $0).appendingPathComponent(command) }.first { files.isExecutableFile(atPath: $0.path) }
    }
    private func save() throws {
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: journal, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
    }
    private func read(_ url: URL) throws -> String? {
        guard files.fileExists(atPath: url.path) else { return nil }
        let attributes = try files.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 10_000_000 else { throw ThemeError.message("\(url.lastPathComponent) is too large to edit safely.") }
        return try String(contentsOf: url, encoding: .utf8)
    }
    private func change(_ url: URL, tool: OmarchyTool, format: String = "file", content: String) throws {
        let url = url.resolvingSymlinksInPath(), current = try read(url)
        var backups = state.files[tool.rawValue] ?? []
        var backup = backups.first { $0.path == url.path } ?? ToolFileBackup(path: url.path, format: format, original: current, applied: content)
        let source = current ?? (format == "json" ? "{}\n" : "")
        let updated: String
        if format == "json" || format == "yaml" {
            let value = try format == "json" ? PaletteJSON.raw(source, path: ["theme"]) : ToolSkinYAML.raw(source)
            if backup.fieldApplied != nil {
                guard value == backup.fieldOriginal || value == backup.fieldApplied || value == backup.fieldPrevious else { throw ThemeError.message("\(tool.name)'s theme preference changed outside Mac Themes. Backup retained.") }
            } else { backup.fieldOriginal = value }
            backup.fieldPrevious = value; backup.fieldApplied = content
            updated = try format == "json" ? PaletteJSON.setting(source, path: ["theme"], raw: content) : ToolSkinYAML.setting(source, raw: content)
        } else if format == "tmux" {
            let base = try ManagedConfig.removing(from: source)
            if source != base, !source.contains(content) { throw ThemeError.message("The managed tmux include was edited. Review it before applying.") }
            updated = base + content
        } else {
            if backups.contains(where: { $0.path == url.path }), current != backup.applied && current != backup.original && current != backup.previous { throw ThemeError.message("\(url.lastPathComponent) changed outside Mac Themes. Backup retained.") }
            updated = content
        }
        backup.previous = current; backup.applied = updated
        backups.removeAll { $0.path == url.path }; backups.append(backup)
        state.files[tool.rawValue] = backups
        try save()
        try ManagedConfig.write(updated, to: url)
    }

    func apply(_ theme: Theme, to tool: OmarchyTool) throws -> String {
        try OmarchyToolPalette.validate(theme)
        switch tool {
        case .pi, .claude:
            let folder = toolHome(tool), themeFolder = folder.appendingPathComponent("themes")
            let themeDirectoryExisted = files.fileExists(atPath: themeFolder.path)
            let settings = folder.appendingPathComponent("settings.json")
            _ = try PaletteJSON.raw(read(settings) ?? "{}", path: ["theme"])
            let preference = try PaletteJSON.literal(tool == .pi ? "mac-themes" : "custom:mac-themes")
            let content = try tool == .pi ? OmarchyToolPalette.pi(theme) : OmarchyToolPalette.claude(theme)
            try change(themeFolder.appendingPathComponent("mac-themes.json"), tool: tool, content: content)
            try change(settings, tool: tool, format: "json", content: preference)
            guard live else { return "Saved · live reload disabled in fixture" }
            if tool == .claude, !themeDirectoryExisted { return "Saved · select Mac Themes in /theme; a running Claude may need one restart to discover its new themes folder" }
            return tool == .pi ? "Saved · active Mac Themes themes reload live; select once in /settings in open Pi sessions if needed" : "Saved · active Mac Themes themes reload live; select once in /theme in open Claude sessions if needed"
        case .hermes:
            return try applyHermes(theme)
        case .tmux:
            return try applyTmux(theme)
        }
    }
    private func applyHermes(_ theme: Theme) throws -> String {
        let folder = toolHome(.hermes)
        guard files.fileExists(atPath: folder.appendingPathComponent("config.yaml").path) else { return "Not configured · launch Hermes once before applying a skin" }
        var homes = [folder]
        let profiles = folder.appendingPathComponent("profiles")
        if let directories = try? files.contentsOfDirectory(at: profiles, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            homes += directories.filter { url in
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
                return values.isDirectory == true && values.isSymbolicLink != true
            }
        }
        var active = folder
        if let profile = try read(folder.appendingPathComponent("active_profile"))?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !profile.isEmpty, profile != "default" {
            guard profile.range(of: "^[a-z0-9_-]+$", options: .regularExpression) != nil else { throw ThemeError.message("Hermes active_profile is not a supported profile name.") }
            if let match = homes.first(where: { $0.lastPathComponent == profile }) { active = match }
        }
        // Change just the active preference before publishing its palette: gateway watchers see
        // both the new name and a fresh skin mtime, as in Hermes' native config-set command.
        try change(active.appendingPathComponent("config.yaml"), tool: .hermes, format: "yaml", content: " \"mac-themes\"")
        for destination in homes { try change(destination.appendingPathComponent("skins/mac-themes.yaml"), tool: .hermes, content: OmarchyToolPalette.hermes(theme)) }
        return live ? "Saved · Hermes gateway skin watcher follows; existing CLI sessions may need /skin mac-themes" : "Saved · live reload disabled in fixture"
    }

    private func tmuxConfig() throws -> URL {
        let traditional = home.appendingPathComponent(".tmux.conf")
        let modern = toolHome(.tmux).appendingPathComponent("tmux/tmux.conf")
        let candidates = [traditional, modern].filter { files.fileExists(atPath: $0.path) }
        guard candidates.count <= 1 else { throw ThemeError.message("Both .tmux.conf and the XDG tmux config exist. Keep the intended main config unambiguous before enabling tmux.") }
        return candidates.first ?? traditional
    }
    private func applyTmux(_ theme: Theme) throws -> String {
        let script = root.appendingPathComponent("tmux-theme.conf")
        let options = OmarchyToolPalette.tmuxOptions(theme)
        let envValue = theme.isLight ? "0;15" : "15;0"
        let command = live ? executable("tmux") : nil
        var activeServer: String?
        var activeSessions: [String] = []
        if let command, let server = try? run(command, ["display-message", "-p", "#{pid}"]), !server.isEmpty {
            activeServer = server
            if state.tmux?.server != server { state.tmux = TmuxRuntimeBackup(server: server) }
            for (name, applied) in options.sorted(by: { $0.key < $1.key }) {
                let original = try run(command, ["show-options", "-gv", name])
                if var backup = state.tmux?.options[name] {
                    guard [backup.original, backup.applied, backup.previous].contains(original) else { throw ThemeError.message("tmux \(name) changed outside Mac Themes. Backup retained.") }
                    backup.previous = original; backup.applied = applied; state.tmux?.options[name] = backup
                } else { state.tmux?.options[name] = TmuxValueBackup(original: original, applied: applied) }
            }
            let sessions = try run(command, ["list-sessions", "-F", "#{session_id}"]).split(separator: "\n").map(String.init)
            activeSessions = sessions.filter { $0.range(of: "^\\$[0-9]+$", options: .regularExpression) != nil }
            for scope in ["global"] + activeSessions {
                let previous = (try? run(command, envArguments(scope, command: "show-environment") + ["COLORFGBG"])) ?? "<absent>"
                if var backup = state.tmux?.environment[scope] {
                    guard [backup.original, "COLORFGBG=" + backup.applied, backup.previous].contains(previous) else { throw ThemeError.message("tmux COLORFGBG changed outside Mac Themes. Backup retained.") }
                    backup.previous = previous; backup.applied = envValue; state.tmux?.environment[scope] = backup
                } else { state.tmux?.environment[scope] = TmuxValueBackup(original: previous, applied: envValue) }
            }
            try save()
        }
        try change(script, tool: .tmux, content: OmarchyToolPalette.tmux(theme))
        let include = "\n\(ManagedConfig.start)\nsource-file \(Self.tmuxString(script.path))\n\(ManagedConfig.end)\n"
        try change(tmuxConfig(), tool: .tmux, format: "tmux", content: include)
        guard let command, activeServer != nil else { return "Saved · tmux will load the palette when its server starts" }
        _ = try run(command, ["source-file", script.path])
        for scope in activeSessions {
            _ = try run(command, envArguments(scope, command: "set-environment") + ["COLORFGBG", envValue])
        }
        for client in ((try? run(command, ["list-clients", "-F", "#{client_name}"])) ?? "").split(separator: "\n") { _ = try? run(command, ["refresh-client", "-t", String(client)]) }
        return "Applied · running tmux globals and sessions; explicit window overrides remain"
    }
    private func envArguments(_ scope: String, command: String) -> [String] { scope == "global" ? [command, "-g"] : [command, "-t", scope] }
    static func tmuxString(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

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
    private func restoreTmuxRuntime() throws -> Bool {
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
    private func run(_ command: URL, _ arguments: [String]) throws -> String {
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
enum OmarchyToolPalette {
    static func validate(_ t: Theme) throws {
        guard t.palette.count == 16, (t.palette + [t.background, t.foreground, t.accent, t.selection, t.cursor]).allSatisfy({ $0.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil }) else { throw ThemeError.message("A complete RGB palette is required for CLI themes.") }
    }
    static func mix(_ a: String, _ b: String, _ amount: Double) -> String {
        "#" + zip(ScriptLiteral.rgb(a), ScriptLiteral.rgb(b)).map { String(format: "%02x", Int((Double($0) / 257 * (1 - amount) + Double($1) / 257 * amount).rounded())) }.joined()
    }
    static func json(_ object: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self) + "\n" }
    static func pi(_ t: Theme) throws -> String {
        var colors = [String: String]()
        let groups: [(String, [String])] = [
            (t.accent, ["accent", "borderAccent", "customMessageLabel", "toolTitle", "mdLink", "syntaxVariable", "thinkingMinimal"]),
            (t.foreground, ["text", "userMessageText", "customMessageText", "toolOutput", "mdCodeBlock", "scrollbarThumb", "searchMatchText"]),
            (mix(t.background, t.foreground, 0.30), ["border"]),
            (mix(t.background, t.foreground, 0.20), ["borderMuted", "mdCodeBlockBorder", "mdQuoteBorder", "mdHr", "thinkingOff", "scrollbarTrack"]),
            (mix(t.foreground, t.background, 0.34), ["muted", "mdQuote", "toolDiffContext", "syntaxPunctuation"]),
            (mix(t.foreground, t.background, 0.52), ["dim", "thinkingText", "syntaxComment"]),
            (mix(t.background, t.accent, 0.22), ["selectedBg", "searchMatchBg"]),
            (mix(t.background, t.foreground, 0.06), ["userMessageBg", "customMessageBg"]),
            (mix(t.background, t.accent, 0.12), ["toolPendingBg"]),
            (mix(t.background, t.palette[2], 0.12), ["toolSuccessBg"]),
            (mix(t.background, t.palette[1], 0.12), ["toolErrorBg"]),
            (t.palette[1], ["error", "toolDiffRemoved", "thinkingXhigh"]),
            (t.palette[2], ["success", "toolDiffAdded", "syntaxString"]),
            (t.palette[3], ["warning", "syntaxNumber", "thinkingHigh", "bashMode"]),
            (t.palette[4], ["syntaxFunction", "syntaxType", "thinkingLow"]),
            (t.palette[5], ["mdHeading", "mdListBullet", "syntaxKeyword", "syntaxOperator", "thinkingMedium"]),
            (t.palette[6], ["mdLinkUrl", "mdCode"])
        ]
        for (color, keys) in groups { for key in keys { colors[key] = color } }
        return try json(["$schema": "https://raw.githubusercontent.com/earendil-works/pi/main/packages/coding-agent/src/modes/interactive/theme/theme-schema.json", "name": "mac-themes", "colors": colors, "export": ["pageBg": t.background, "cardBg": mix(t.background, t.foreground, 0.06), "infoBg": mix(t.background, t.foreground, 0.10)]])
    }
    static func claude(_ t: Theme) throws -> String {
        var colors = ["claude": t.accent, "text": t.foreground, "inverseText": t.background, "subtle": t.palette[8], "suggestion": t.palette[6], "permission": t.palette[4], "remember": t.palette[3], "success": t.palette[2], "error": t.palette[1], "warning": t.palette[3], "merged": t.palette[5], "promptBorder": t.accent, "planMode": t.palette[6], "autoAccept": t.palette[3], "bashBorder": t.palette[11], "ide": t.palette[14], "selectionBg": t.selection, "rate_limit_fill": t.accent, "briefLabelYou": t.palette[3], "briefLabelClaude": t.accent]
        for (key, base) in [("claudeShimmer", t.accent), ("permissionShimmer", t.palette[4]), ("warningShimmer", t.palette[3]), ("promptBorderShimmer", t.accent)] { colors[key] = mix(base, t.foreground, 0.35) }
        colors["inactive"] = mix(t.foreground, t.background, 0.40); colors["inactiveShimmer"] = mix(t.foreground, t.background, 0.25)
        for (name, color) in [("Added", t.palette[2]), ("Removed", t.palette[1])] { colors["diff" + name] = mix(t.background, color, 0.15); colors["diff" + name + "Dimmed"] = mix(t.background, color, 0.08); colors["diff" + name + "Word"] = mix(t.background, color, 0.32) }
        for key in ["userMessageBackground", "bashMessageBackgroundColor", "memoryBackgroundColor"] { colors[key] = mix(t.background, t.foreground, 0.06) }
        colors["userMessageBackgroundHover"] = mix(t.background, t.foreground, 0.10); colors["rate_limit_empty"] = mix(t.background, t.foreground, 0.20)
        return try json(["name": "Mac Themes", "base": t.isLight ? "light" : "dark", "overrides": colors])
    }
    static func hermes(_ t: Theme) -> String {
        var colors = [String: String]()
        for (color, keys) in [
            (t.background, ["background"]), (t.foreground, ["ui_text", "banner_text", "status_bar_text"]),
            (t.accent, ["ui_primary", "ui_accent", "ui_label", "banner_title", "banner_accent", "response_border", "session_label", "status_bar_strong"]),
            (t.palette[8], ["ui_border", "ui_thinking", "banner_border", "banner_dim", "input_rule", "session_border", "status_bar_dim", "syntax_comment"]),
            (t.palette[1], ["ui_error", "status_bar_bad", "diff_removed_word"]), (t.palette[2], ["ui_ok", "status_bar_good", "diff_added_word", "syntax_string"]),
            (t.palette[3], ["ui_warn", "status_bar_warn", "syntax_number"]), (t.palette[4], ["shell_dollar"]), (t.palette[5], ["syntax_keyword"]), (t.palette[6], ["ui_tool"]),
            (t.cursor, ["prompt"]), (t.selection, ["selection_bg", "completion_menu_current_bg", "completion_menu_meta_current_bg"]),
            (mix(t.background, "#000000", 0.25), ["status_bar_bg", "voice_status_bg"]),
            (mix(t.background, t.foreground, 0.06), ["completion_menu_bg", "completion_menu_meta_bg"]), (t.palette[9], ["status_bar_critical"]),
            (mix(t.background, t.palette[2], 0.15), ["diff_added"]), (mix(t.background, t.palette[1], 0.15), ["diff_removed"])
        ] { for key in keys { colors[key] = color } }
        return "name: mac-themes\ndescription: Mac Themes synchronized palette\ncolors:\n" + colors.sorted(by: { $0.key < $1.key }).map { "  \($0.key): \"\($0.value)\"" }.joined(separator: "\n") + "\n"
    }
    static func tmuxOptions(_ t: Theme) -> [String: String] {
        ["window-style": "fg=\(t.foreground),bg=\(t.background)", "window-active-style": "fg=\(t.foreground),bg=\(t.background)", "cursor-colour": t.cursor, "status-style": "fg=\(t.foreground),bg=\(t.background)", "pane-border-style": "fg=\(t.palette[8])", "pane-active-border-style": "fg=\(t.accent)", "mode-style": "fg=\(t.foreground),bg=\(t.selection)"]
    }
    static func tmux(_ t: Theme) -> String {
        "# Generated by Mac Themes; only color options and appearance environment.\n" + tmuxOptions(t).sorted(by: { $0.key < $1.key }).map { "set-option -g \($0.key) '\($0.value)'" }.joined(separator: "\n") + "\nset-environment -g COLORFGBG '\(t.isLight ? "0;15" : "15;0")'\n"
    }
}
