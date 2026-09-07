// Test-only writers create historical backups for the production restore regression tests.
// These obsolete apply paths are intentionally excluded from the shipped app.
import AppKit
import ThemeCore
@testable import MacThemes

extension OmarchyToolsIntegration {
    func toolHome(_ tool: OmarchyTool) -> URL {
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
    func change(_ url: URL, tool: OmarchyTool, format: String = "file", content: String) throws {
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
    func applyHermes(_ theme: Theme) throws -> String {
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
    func tmuxConfig() throws -> URL {
        let traditional = home.appendingPathComponent(".tmux.conf")
        let modern = toolHome(.tmux).appendingPathComponent("tmux/tmux.conf")
        let candidates = [traditional, modern].filter { files.fileExists(atPath: $0.path) }
        guard candidates.count <= 1 else { throw ThemeError.message("Both .tmux.conf and the XDG tmux config exist. Keep the intended main config unambiguous before enabling tmux.") }
        return candidates.first ?? traditional
    }
    func applyTmux(_ theme: Theme) throws -> String {
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
    static func tmuxString(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
}

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
