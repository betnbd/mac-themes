import AppKit
import ThemeCore

enum Integration: String, CaseIterable, Identifiable, Codable {
    case macos, wallpaper, ghostty, terminal, alacritty, kitty, brave, chrome, chromium, edge, vscode, vscodeInsiders, vscodium, cursor, obsidian, neovim, helix, btop, opencode, tmux, pi, claude, hermes, chatgpt
    var id: String { rawValue }
    var name: String {
        switch self {
        case .macos: "macOS appearance"; case .wallpaper: "Desktop backgrounds"; case .ghostty: "Ghostty"; case .terminal: "Terminal"
        case .alacritty: "Alacritty"; case .kitty: "Kitty"; case .brave: "Brave"; case .chrome: "Google Chrome"; case .chromium: "Chromium"; case .edge: "Microsoft Edge"
        case .vscode: "VS Code"; case .vscodeInsiders: "VS Code Insiders"; case .vscodium: "VSCodium"; case .cursor: "Cursor"
        case .obsidian: "Obsidian"; case .neovim: "Neovim"; case .helix: "Helix"; case .btop: "btop"; case .opencode: "OpenCode"; case .chatgpt: "ChatGPT"
        case .tmux: "tmux"; case .pi: "Pi"; case .claude: "Claude Code"; case .hermes: "Hermes"
        }
    }
    var bundleID: String {
        switch self {
        case .ghostty: "com.mitchellh.ghostty"; case .terminal: "com.apple.Terminal"; case .brave: "com.brave.Browser"; case .chatgpt: "com.openai.codex"
        case .alacritty: "org.alacritty"; case .kitty: "net.kovidgoyal.kitty"; case .chrome: "com.google.Chrome"; case .chromium: "org.chromium.Chromium"; case .edge: "com.microsoft.edgemac"
        case .vscode: "com.microsoft.VSCode"; case .vscodeInsiders: "com.microsoft.VSCodeInsiders"; case .vscodium: "com.vscodium"; case .cursor: "com.todesktop.230313mzl4w4u92"; case .obsidian: "md.obsidian"
        default: ""
        }
    }
    var symbol: String {
        switch self {
        case .macos: "apple.logo"; case .wallpaper: "photo"; case .brave, .chrome, .chromium, .edge: "globe"; case .chatgpt: "bubble.left.and.bubble.right"
        case .vscode, .vscodeInsiders, .vscodium, .cursor, .neovim, .helix: "chevron.left.forwardslash.chevron.right"
        case .obsidian: "note.text"; case .btop: "chart.bar"; default: "terminal"
        }
    }
    var detail: String {
        switch self {
        case .ghostty: "Full palette · reloads open windows"
        case .terminal: "Background, text and cursor · live"
        case .macos: "Light/dark mode, highlight and nearest native accent"
        case .wallpaper: "Follows desktops and displays while Mac Themes is open"
        case .brave: "Native theme loader · enable Developer mode once in Brave"
        case .chrome, .chromium, .edge: "Theme package · manual browser installation required"
        case .chatgpt: "Automatic live theme · Accessibility permission required"
        case .alacritty: "Terminal palette · config auto reload"
        case .kitty: "Terminal palette · live reload signal"
        case .vscode, .vscodeInsiders, .vscodium, .cursor: "UI, syntax and terminal · watched settings"
        case .obsidian: "Watched CSS snippet · enable once in Appearance"
        case .neovim: "Editor colors · remote servers and file watcher"
        case .btop: "Monitor palette · live reload signal"
        case .helix: "Editor palette · live reload signal"
        case .opencode: "TUI palette · live after initial /theme selection"
        case .tmux: "Pane, cursor and status colors · live default tmux server"
        case .pi: "Agent theme · select Mac Themes once in /settings, then live file reload"
        case .claude: "Agent theme · select Mac Themes once in /theme, then live file reload"
        case .hermes: "Gateway skin watcher · CLI sessions may need /skin mac-themes"
        }
    }
}

struct TerminalColors: Codable, Equatable {
    var name: String
    var background: [Int]
    var text: [Int]
    var bold: [Int]
    var cursor: [Int]
}

struct TerminalBackup: Codable {
    var original: TerminalColors
    var applied: TerminalColors
    var previousApplied: TerminalColors?
}

struct SavedState: Codable {
    var ghosttyPath: String?
    var ghosttyOriginal: Data?
    var ghosttyExisted: Bool = false
    var terminal: [String: TerminalBackup] = [:]
    var braveCaptured = false
    var braveOriginal: Data?
    var braveApplied: String?
    var braveLiveTheme: String?
    var activeTheme: String?
    var activeThemeSnapshot: Theme?
    var chatgpt: ChatGPTBackup?
    var chatgptPending: ChatGPTPendingAction?
}

@MainActor
final class Integrations {
    let root: URL
    var state: SavedState
    private let files = FileManager.default
    let desktop: DesktopIntegration
    let obsidian: ObsidianIntegration
    let liveChatGPT: ChatGPTLiveTheme

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mac Themes")) throws {
        self.root = root
        desktop = try DesktopIntegration(root: root)
        obsidian = try ObsidianIntegration(root: root)
        liveChatGPT = try ChatGPTLiveTheme(root: root)
        let path = root.appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: path.path) {
            // Fail closed on a corrupt journal; never silently discard original settings.
            state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: path))
        } else { state = SavedState() }
    }

    var hasBackups: Bool { state.ghosttyPath != nil || !state.terminal.isEmpty || state.braveCaptured || state.braveLiveTheme != nil || state.chatgpt != nil || state.chatgptPending != nil || desktop.hasBackups || obsidian.hasBackups || liveChatGPT.hasBackups || legacyHasBackups }

    func applyLiveBrave(_ theme: Theme) async throws -> String {
        let result = try await BraveAccessibility().apply(theme, root: root)
        if result.hasPrefix("Applied") {
            state.braveLiveTheme = theme.name
            try save()
        }
        return result
    }

    func applyLiveChatGPT(_ theme: Theme) async throws -> String {
        guard state.chatgpt == nil else {
            throw ThemeError.message("Restore the older ChatGPT configuration backup before using live Appearance automation.")
        }
        if case .apply = state.chatgptPending { state.chatgptPending = nil; try save() }
        return try await liveChatGPT.apply(theme)
    }

    func restoreLiveChatGPT() async throws -> String {
        if liveChatGPT.hasBackups { return try await liveChatGPT.restore() }
        return try restoreChatGPT()
    }

    // Older releases could theme other applications. Load those adapters only
    // while checking/restoring their existing journals, never on focused apply.
    private var legacyHasBackups: Bool {
        ((try? AdditionalIntegrations(root: root).hasBackups) ?? false)
            || ((try? OmarchyToolsIntegration(root: root).hasBackups) ?? false)
    }

    func save() throws {
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(state)
        try data.write(to: root.appendingPathComponent("state.json"), options: .atomic)
    }

    func remember(theme: Theme?) throws {
        state.activeTheme = theme?.id
        state.activeThemeSnapshot = theme
        try save()
    }

    func appURL(_ app: Integration) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) }
    func running(_ app: Integration) -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty }

    func isAvailable(_ app: Integration) -> Bool {
        if app == .macos || app == .wallpaper { return true }
        if app == .obsidian { return obsidian.isAvailable }
        guard ThemeStore.focusedIntegrations.contains(app) else { return false }
        return appURL(app) != nil
    }

    func apply(_ theme: Theme, to app: Integration) throws -> String {
        guard isAvailable(app) else { throw ThemeError.message("\(app.name) is not installed or configured.") }
        if app == .obsidian { return try obsidian.apply(theme) }
        switch app {
        case .macos: return try desktop.applyAppearance(theme)
        case .wallpaper: return "Choose a background from the menu"
        case .ghostty: return try applyGhostty(theme)
        case .brave: return try applyBrave(theme)
        case .chatgpt:
            // The focused build uses native import only. Cancel a superseded
            // queued application from an older build without altering app settings.
            if case .apply = state.chatgptPending { state.chatgptPending = nil; try save() }
            return "Ready · copy theme, then Appearance → Import"
        default: throw ThemeError.message("No adapter is available for \(app.name).")
        }
    }

    func restore(_ app: Integration) throws -> String {
        if app == .obsidian { return try obsidian.restore() }
        if let adapter = AdditionalIntegration(rawValue: app.rawValue) { return try AdditionalIntegrations(root: root).restore(adapter) }
        if let tool = OmarchyTool(rawValue: app.rawValue) { return try OmarchyToolsIntegration(root: root).restore(tool) }
        switch app {
        case .macos: return try desktop.restoreAppearance()
        case .wallpaper: return try desktop.restoreWallpapers()
        case .ghostty: return try restoreGhostty()
        case .terminal: return try restoreTerminal()
        case .brave: return try restoreBrave()
        case .chatgpt: return try restoreChatGPT()
        case .chrome, .chromium, .edge: return "Use the browser's Reset to default to remove an installed theme"
        default: return "No changes to restore"
        }
    }

    private func ghosttyConfigURL() throws -> URL {
        if let path = state.ghosttyPath { return URL(fileURLWithPath: path) }
        let home = files.homeDirectoryForCurrentUser
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
        let folders = [xdg.appendingPathComponent("ghostty"), home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty")]
        let candidates = folders.flatMap { folder in [folder.appendingPathComponent("config.ghostty"), folder.appendingPathComponent("config")] }
        let existing = candidates.filter { files.fileExists(atPath: $0.path) }
        // Multiple root files have version-specific precedence. Let the user select the active file.
        guard existing.count <= 1 else { throw ThemeError.message("Several Ghostty config files exist. Keep one active root config before using this prototype.") }
        let selected = existing.first ?? folders[1].appendingPathComponent("config")
        return selected.resolvingSymlinksInPath()
    }

    private func applyGhostty(_ theme: Theme) throws -> String {
        let url = try ghosttyConfigURL()
        let existed = files.fileExists(atPath: url.path)
        let original = existed ? try BoundedFileReader.shared.data(at: url) ?? Data() : Data()
        guard let source = String(data: original, encoding: .utf8) else { throw ThemeError.message("Ghostty config is not UTF-8.") }
        let generated = root.appendingPathComponent("ghostty.conf")
        let updated = try ManagedConfig.applying(to: source, includePath: generated.path)
        if state.ghosttyPath == nil {
            state.ghosttyPath = url.path
            state.ghosttyOriginal = original
            state.ghosttyExisted = existed
            try save()
        }
        try theme.ghosttyConfig.write(to: generated, atomically: true, encoding: .utf8)
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Resolve the symbolic link before atomic replacement, preserving the user's dotfiles link.
        try ManagedConfig.write(updated, to: url)
        return try reloadGhostty()
    }

    private func reloadGhostty() throws -> String {
        guard running(.ghostty) else { return "Saved · takes effect when Ghostty opens" }
        do {
            let result = try AppleScripts.run(AppleScripts.ghosttyReload)
            guard result.booleanValue else { return "Saved · use Ghostty → Reload Configuration" }
            return "Applied · full terminal palette"
        } catch {
            return "Saved · reload needed: \(error.localizedDescription)"
        }
    }

    private func restoreGhostty() throws -> String {
        guard let path = state.ghosttyPath else { return "No changes to restore" }
        let url = URL(fileURLWithPath: path)
        let source = try BoundedFileReader.shared.text(at: url) ?? ""
        let restored = try ManagedConfig.removing(from: source)
        if !state.ghosttyExisted && restored.isEmpty { try files.removeItem(at: url) }
        else { try ManagedConfig.write(restored, to: url) }
        state.ghosttyPath = nil
        state.ghosttyOriginal = nil
        try save()
        return "Restored · \(try reloadGhostty())"
    }

    private func restoreTerminal() throws -> String {
        guard !state.terminal.isEmpty else { return "No changes to restore" }
        guard running(.terminal) else { throw ThemeError.message("Open Terminal to restore its colors.") }
        // Read each saved profile by name, including profiles whose tabs have since been closed.
        for name in Array(state.terminal.keys).sorted() {
            guard let backup = state.terminal[name] else { continue }
            _ = try AppleScripts.run(AppleScripts.restoreTerminalColors(backup))
            state.terminal.removeValue(forKey: name)
            try save()
        }
        return "Restored previous profile colors"
    }

    private var braveDomain: CFString { "com.brave.Browser" as CFString }
    private var braveKey: CFString { "BrowserThemeColor" as CFString }
    private func localBraveValue() -> CFPropertyList? {
        CFPreferencesCopyValue(braveKey, braveDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private func applyBrave(_ theme: Theme) throws -> String {
        _ = try ChromiumThemePackage.export(theme: theme, root: root)
        return "Theme package ready · installation is managed in Brave"
    }

    private func refreshBrave() -> String {
        guard running(.brave), let app = appURL(.brave) else { return "Color saved · opens with Brave (unverified)" }
        let process = Process()
        process.executableURL = app.appendingPathComponent("Contents/MacOS/Brave Browser")
        process.arguments = ["--refresh-platform-policy", "--no-startup-window"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { return "Color saved · restart Brave to refresh" }
        // Command dispatch is not evidence the browser accepted or displayed the policy.
        return "Color saved · refresh requested; check Brave"
    }

    private func restoreBrave() throws -> String {
        if state.braveLiveTheme != nil {
            return "Setup required · restore your previous theme in Brave → Settings → Appearance"
        }
        guard state.braveCaptured else { return "No changes to restore" }
        guard !CFPreferencesAppValueIsForced(braveKey, braveDomain) else { throw ThemeError.message("A managed policy now controls Brave. Local backup retained.") }
        let current = localBraveValue() as? String
        guard current == state.braveApplied || current == nil else { throw ThemeError.message("Brave's color changed outside Mac Themes. Backup retained to avoid overwriting it.") }
        var value: Any?
        if let original = state.braveOriginal {
            value = (try PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any])?["value"]
        }
        CFPreferencesSetValue(braveKey, value as CFPropertyList?, braveDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(braveDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { throw ThemeError.message("Brave restore could not be saved.") }
        state.braveCaptured = false
        state.braveOriginal = nil
        state.braveApplied = nil
        try save()
        return "Restored local preference · \(refreshBrave())"
    }
}

enum AppleScripts {
    struct Failure: LocalizedError {
        let code: Int?
        let message: String
        var errorDescription: String? { message }
    }

    static let ghosttyReload = """
    tell application id "com.mitchellh.ghostty"
        if (count of terminals) is 0 then return false
        return perform action "reload_config" on first terminal
    end tell
    """

    static func restoreTerminalColors(_ backup: TerminalBackup) -> String {
        // Compare each owned field separately. A partial apply can always be restored.
        let properties = ["background color", "normal text color", "bold text color", "cursor color"]
        let originals = [backup.original.background, backup.original.text, backup.original.bold, backup.original.cursor]
        let applied = [backup.applied.background, backup.applied.text, backup.applied.bold, backup.applied.cursor]
        let previous = backup.previousApplied.map { [$0.background, $0.text, $0.bold, $0.cursor] } ?? originals
        var lines = ["tell application id \"com.apple.Terminal\"", "set p to settings set \(ScriptLiteral.string(backup.original.name))"]
        for i in properties.indices {
            lines.append("if \(properties[i]) of p is not \(ScriptLiteral.list(applied[i])) and \(properties[i]) of p is not \(ScriptLiteral.list(originals[i])) and \(properties[i]) of p is not \(ScriptLiteral.list(previous[i])) then error \"Terminal colors changed outside Mac Themes. Backup retained.\"")
        }
        for i in properties.indices { lines.append("set \(properties[i]) of p to \(ScriptLiteral.list(originals[i]))") }
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    @MainActor
    static func run(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: "with timeout of 15 seconds\n\(source)\nend timeout") else { throw ThemeError.message("Could not create the automation command.") }
        var error: NSDictionary?
        let value = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int
            if code == -1743 { throw ThemeError.message("Allow Mac Themes in System Settings → Privacy & Security → Automation, then retry.") }
            throw Failure(code: code, message: error[NSAppleScript.errorMessage] as? String ?? "Application automation failed.")
        }
        return value
    }
}
