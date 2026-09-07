// Test-only writers create historical backups for the production restore regression tests.
// These obsolete apply paths are intentionally excluded from the shipped app.
import AppKit
import ThemeCore
@testable import MacThemes

extension AdditionalIntegrations {
    func editorBaseTheme(_ app: AdditionalIntegration, isLight: Bool) -> String {
        let target = isLight ? "Light+" : "Dark+"
        guard let bundle = app.bundleID, let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle),
              let data = try? fileReader.data(at: installed.appendingPathComponent("Contents/Resources/app/extensions/theme-defaults/package.json")),
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contributes = package["contributes"] as? [String: Any],
              let themes = contributes["themes"] as? [[String: Any]],
              let match = themes.compactMap({ $0["id"] as? String }).first(where: { $0 == target || $0 == "Default " + target }) else { return target }
        return match
    }
    func change(_ url: URL, app: AdditionalIntegration, format: String, values: [([String], String)]) throws {
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
    func generated(_ url: URL, app: AdditionalIntegration, content: String) throws {
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
    func changeKitty(_ url: URL, source: String, include: String) throws {
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
    func applyObsidian(_ theme: Theme) throws -> String {
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
    func refreshNeovim(_ plugin: URL) -> String {
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
    func location(_ key: String, fallback: URL) throws -> URL {
        guard let data = try fileReader.data(at: configuredLocations) else { return fallback }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let path = object?[key] as? String else { return fallback }
        guard path.hasPrefix("/") else { throw ThemeError.message("Integration location \(key) must be an absolute path.") }
        return URL(fileURLWithPath: path)
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
