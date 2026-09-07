import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import ThemeCore

@MainActor
final class ThemeStore: ObservableObject {
    static let focusedIntegrations: [Integration] = [.ghostty, .obsidian, .brave, .chatgpt, .wallpaper, .macos]
    @Published var selected: Theme = Theme.all[0]
    @Published private var fontSelections: [String: String] = [:]
    var selectedFontID: String { fontSelections[selected.id] ?? "" }
    var selectedFont: ThemeFont? { ThemeFont.all.first { $0.id == selectedFontID } }
    var previewTheme: Theme {
        var theme = selected
        theme.fontFamily = selectedFont?.family
        theme.useDefaultFont = selectedFontID == "default" ? true : nil
        return theme
    }
    func selectFont(_ id: String) {
        guard !busy, !importing, !restoring else { return }
        guard id.isEmpty || id == "default" || ThemeFont.all.contains(where: { $0.id == id }) else { return }
        fontSelections[selected.id] = id
        if !demo { preferences.set(fontSelections, forKey: "fontSelections") }
        selectedFont?.registerPreview()
        previewOnly = true
        message = "Font selected. Click Apply theme to use it."
    }
    @Published var imported: [ImportedTheme] = []
    @Published var enabled = Set<Integration>()
    @Published var statuses: [Integration: String] = [:]
    @Published var chatGPTAuthorized = false
    @Published var busy = false {
        didSet { if oldValue && !busy { scheduleWallpaperSync() } }
    }
    @Published var restoring = false
    @Published private(set) var editingWallpapers = false
    @Published private var wallpaperSnapshot: WallpaperLibrary.Snapshot = [:]
    @Published private var removedWallpaper: (themeID: String, id: String)?
    private var wallpaperLibrary: WallpaperLibrary?
    var canEditWallpapers: Bool { !busy && !importing && !editingWallpapers && wallpaperLibrary != nil }
    var hasRemovedWallpapers: Bool { !(wallpaperSnapshot[selected.id]?.hidden.isEmpty ?? true) }
    var canUndoWallpaperRemoval: Bool { removedWallpaper?.themeID == selected.id }
    @Published var importing = false {
        didSet { if oldValue && !importing { scheduleWallpaperSync() } }
    }
    @Published var message = "Choose a theme from the menu."
    @Published var hasBackups = false
    @Published var importText = ""
    @Published var importMessage = "Paste a repository URL or the same Omarchy install command."
    @Published var libraryNotice = ""
    @Published var wallpaperIDs: [String: String] = [:]
    @Published var previewWallpaperIDs: [String: String] = [:]
    @Published var previewOnly = false
    static var isDemo: Bool {
        ProcessInfo.processInfo.arguments.contains("--demo") || Bundle.main.object(forInfoDictionaryKey: "MacThemesPreview") as? Bool == true
    }
    let shouldOpenSetupWindow: Bool
    let shouldOpenStatusWindow: Bool
    let demo: Bool
    private let preferences: UserDefaults
    let root: URL
    let library: ThemeLibrary
    private var integrations: Integrations?
    private var coordinator: ApplyCoordinator?
    private var chatGPTLaunchObserver: AnyCancellable?
    private var chatGPTLaunchedDuringApply = false
    private var wallpaperObservers = Set<AnyCancellable>()
    private var wallpaperSyncTask: Task<Void, Never>?
    private let observesSpaces: Bool

    var themes: [Theme] { Theme.bundled + imported.map(\.theme) }
    var selectedImport: ImportedTheme? { imported.first { $0.id == selected.id } }
    var libraryURL: URL { root.appendingPathComponent("Themes") }
    var wallpapers: [WallpaperChoice] { wallpapers(for: selected) }
    private func wallpapers(for theme: Theme) -> [WallpaperChoice] {
        let base: [WallpaperChoice]
        if let item = imported.first(where: { $0.id == theme.id }) {
            base = item.wallpapers.compactMap { wallpaper in
                guard let url = item.wallpaperURL(wallpaper, in: libraryURL) else { return nil }
                return WallpaperChoice(id: wallpaper.relativePath, name: wallpaper.name, url: url)
            }
        } else { base = WallpaperCatalog.bundled(for: theme) }
        return WallpaperLibrary.choices(base, themeID: theme.id, root: root, snapshot: wallpaperSnapshot)
    }
    var selectedWallpaper: WallpaperChoice? {
        selectedWallpaper(for: selected)
    }
    private func selectedWallpaper(for theme: Theme) -> WallpaperChoice? {
        let item = imported.first { $0.id == theme.id }
        if item != nil, item?.selectedWallpaper == nil, wallpaperIDs[theme.id] == nil, previewWallpaperIDs[theme.id] == nil { return nil }
        let savedID = wallpaperIDs[theme.id] ?? item?.selectedWallpaper
        let id = previewOnly ? previewWallpaperIDs[theme.id] ?? savedID : savedID
        let choices = wallpapers(for: theme)
        return choices.first { $0.id == id } ?? choices.first
    }
    var canApply: Bool { !editingWallpapers && !importing && !restoring && (demo || (integrations != nil && coordinator != nil)) }

    init(demo: Bool = ThemeStore.isDemo, root suppliedRoot: URL? = nil, defaults: UserDefaults = .standard) {
        preferences = defaults
        if !demo { fontSelections = defaults.dictionary(forKey: "fontSelections") as? [String: String] ?? [:] }
        self.demo = demo
        observesSpaces = !demo && suppliedRoot == nil
        shouldOpenSetupWindow = demo || !defaults.bool(forKey: "tokyoNightSetupSeen") || !defaults.bool(forKey: "automaticAppsSelected")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        shouldOpenStatusWindow = !demo && defaults.bool(forKey: "tokyoNightSetupSeen")
            && defaults.string(forKey: "lastSeenLauncherVersion") != version
        root = suppliedRoot ?? (demo ? FileManager.default.temporaryDirectory.appendingPathComponent("MacThemes-Preview-Library") : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mac Themes"))
        library = ThemeLibrary(directory: root.appendingPathComponent("Themes"))
        previewOnly = demo
        do { wallpaperLibrary = try WallpaperLibrary(root: root) }
        catch { message = error.localizedDescription }
        if demo {
            enabled = Set(Self.focusedIntegrations.filter { $0 != .macos })
            message = "Preview only · changes stay inside this window."
        } else {
            wallpaperIDs = preferences.dictionary(forKey: "wallpaperSelections") as? [String: String] ?? [:]
            do {
                let service = try Integrations(root: root)
                integrations = service
                hasBackups = service.hasBackups
                coordinator = try ApplyCoordinator(root: root)
                for (key, record) in coordinator?.records ?? [:] {
                    if let app = Integration(rawValue: key) { statuses[app] = record.result.message }
                }
                previewOnly = true
                if let saved = preferences.stringArray(forKey: "enabledIntegrations") {
                    enabled = Set(saved.compactMap(Integration.init(rawValue:))).intersection(Self.focusedIntegrations)
                    if !preferences.bool(forKey: "tokyoNightSetupSeen") { enabled.remove(.macos) }
                } else {
                    enabled = Set(Self.focusedIntegrations.filter { $0 != .macos && service.isAvailable($0) })
                }
                refreshAvailability()
                hasBackups = service.hasBackups
            } catch { message = "Could not read restore data: \(error.localizedDescription)" }
        }
        let initialSelection = selected.id
        Task {
            do {
                if let wallpaperLibrary { wallpaperSnapshot = await wallpaperLibrary.snapshot() }
                imported = try await library.installedThemes()
                if selected.id == initialSelection,
                   let id = preferences.string(forKey: "previewThemeID") ?? integrations?.state.activeTheme,
                   let restored = themes.first(where: { $0.id == id }) { selected = restored }
                selectedFont?.registerPreview()
                if suppliedRoot == nil { resumePendingChatGPT() }
                scheduleWallpaperSync()
            } catch { message = "Could not read the theme library: \(error.localizedDescription)" }
        }
        if !demo, suppliedRoot == nil {
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
                .sink { [weak self] _ in Task { @MainActor in self?.scheduleWallpaperSync() } }
                .store(in: &wallpaperObservers)
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                .sink { [weak self] _ in Task { @MainActor in self?.scheduleWallpaperSync() } }
                .store(in: &wallpaperObservers)
            // The user requested both integrations enabled for the automatic build.
            // This changes our selection only; applying a fresh theme requires a click.
            if !preferences.bool(forKey: "automaticAppsSelected") {
                enabled.formUnion([.ghostty, .chatgpt])
                preferences.set(enabled.map(\.rawValue), forKey: "enabledIntegrations")
                preferences.set(true, forKey: "automaticAppsSelected")
            }
            chatGPTLaunchObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
                .compactMap { ($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier }
                .filter { $0 == Integration.chatgpt.bundleID }
                .sink { [weak self] _ in Task { @MainActor in
                    self?.chatGPTLaunchedDuringApply = true
                    self?.resumePendingChatGPT()
                } }
        }
    }

    func markSetupSeen() {
        if !demo { preferences.set(true, forKey: "tokyoNightSetupSeen") }
    }

    func markStatusSeen() {
        if !demo {
            preferences.set(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development", forKey: "lastSeenLauncherVersion")
        }
    }

    func refreshAvailability() {
        guard let integrations else { return }
        refreshAccessibilityPermission()
        for app in Self.focusedIntegrations where statuses[app] == nil || statuses[app] == "Not installed or configured" {
            statuses[app] = integrations.isAvailable(app) ? app.detail : "Not installed or configured"
        }
    }

    func refreshAccessibilityPermission() {
        guard !demo else { return }
        chatGPTAuthorized = ChatGPTAccessibility.hasPermission
        if chatGPTAuthorized, let status = statuses[.chatgpt],
           status.hasPrefix("Setup required") || status.hasPrefix("Permission not recognized") {
            statuses[.chatgpt] = "Ready · Accessibility granted. Choose Apply theme."
        }
        recordStatus()
    }

    private func recordStatus() {
        guard !demo else { return }
        let status: [String: Any] = [
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "test",
            "updated": ISO8601DateFormatter().string(from: Date()),
            "theme": selected.id, "accessibilityGranted": chatGPTAuthorized,
            "applications": Dictionary(uniqueKeysWithValues: statuses.map { ($0.key.rawValue, $0.value) })
        ]
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("last-status.json"), options: .atomic)
        }
    }

    func toggle(_ app: Integration, enabled value: Bool) {
        guard Self.focusedIntegrations.contains(app) else { return }
        if value { enabled.insert(app) } else { enabled.remove(app) }
        if !demo { preferences.set(enabled.map(\.rawValue), forKey: "enabledIntegrations") }
        if app == .wallpaper { scheduleWallpaperSync() }
    }

    private func scheduleWallpaperSync() {
        guard observesSpaces else { return }
        wallpaperSyncTask?.cancel()
        wallpaperSyncTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return }
            self?.synchronizeSpaceWallpaper()
        }
    }

    private func synchronizeSpaceWallpaper() {
        guard !busy, !importing, !restoring, let integrations else { return }
        let desktop = integrations.desktop
        guard desktop.hasPendingSpaceRestore || enabled.contains(.wallpaper) else { return }
        do {
            // Follow only the last explicitly applied wallpaper, never the preview.
            if let result = try desktop.synchronizeCurrentSpaces() {
                let latest = coordinator?.records[Integration.wallpaper.rawValue]?.result.state
                if desktop.hasPendingSpaceRestore || latest == nil || latest == .applied {
                    statuses[.wallpaper] = result
                }
            }
        } catch { statuses[.wallpaper] = error.localizedDescription }
        hasBackups = integrations.hasBackups
        recordStatus()
    }

    func applySelected() {
        guard canApply, !busy else { return }
        if demo { message = "Previewing \(selected.name)."; return }
        let destinations = Self.focusedIntegrations.filter { enabled.contains($0) }
        guard !destinations.isEmpty else { message = "Enable an application before applying."; return }
        runApply(destinations: destinations)
    }

    private func runApply(destinations: [Integration]) {
        guard let integrations, let coordinator else { return }
        let theme = previewTheme, wallpaper = selectedWallpaper, font = selectedFont
        busy = true
        message = "Applying \(theme.name)…"
        Task { @MainActor in
            do {
                let report = try await coordinator.run(theme: theme, destinations: destinations,
                    installFont: { try await Task.detached(priority: .utility) { try font?.install() }.value },
                    apply: { destination, requested in
                        switch destination {
                        case .wallpaper:
                            guard let wallpaper else { return .pending("Choose a wallpaper to apply.") }
                            return .applied(try integrations.desktop.applyWallpaper(wallpaper.url))
                        case .chatgpt: return try await integrations.applyLiveChatGPT(requested)
                        case .brave: return try await integrations.applyLiveBrave(requested)
                        default: return try integrations.apply(requested, to: destination)
                        }
                    }, progress: { self.statuses[$0] = $1.message })
                if report.results[.wallpaper]?.state == .applied, let wallpaper {
                    wallpaperIDs[theme.id] = wallpaper.id
                    preferences.set(wallpaperIDs, forKey: "wallpaperSelections")
                    previewWallpaperIDs.removeValue(forKey: theme.id)
                }
                previewOnly = !report.allApplied
                message = report.summary(theme.name)
            } catch { message = "Could not record application results: \(error.localizedDescription)" }
            hasBackups = integrations.hasBackups
            busy = false
            refreshAccessibilityPermission()
            if chatGPTLaunchedDuringApply { resumePendingChatGPT() }
        }
    }

    private func resumePendingChatGPT() {
        guard !demo, !busy, !importing, enabled.contains(.chatgpt),
              let integrations, let coordinator, integrations.running(.chatgpt), let pending = integrations.liveChatGPT.pendingTheme else { return }
        chatGPTLaunchedDuringApply = false
        busy = true
        Task { @MainActor in
            do {
                let font = ThemeFont.all.first { $0.family == pending.fontFamily }
                _ = try await coordinator.run(theme: pending, destinations: [.chatgpt],
                    installFont: { try await Task.detached(priority: .utility) { try font?.install() }.value },
                    apply: { _, theme in try await integrations.applyLiveChatGPT(theme) },
                    progress: { self.statuses[$0] = $1.message })
            }
            catch { statuses[.chatgpt] = error.localizedDescription }
            hasBackups = integrations.hasBackups
            message = statuses[.chatgpt] ?? "Check ChatGPT setup."
            busy = false
            refreshAccessibilityPermission()
        }
    }

    func select(_ theme: Theme) {
        guard canApply, !busy else { return }
        selected = theme
        if !demo { preferences.set(theme.id, forKey: "previewThemeID") }
        selectedFont?.registerPreview()
        previewOnly = true
        message = "Previewing \(theme.name). Click Apply theme to use it."
    }

    func selectWallpaper(_ choice: WallpaperChoice) {
        guard !busy, !editingWallpapers else { return }
        previewOnly = true
        previewWallpaperIDs[selected.id] = choice.id
        message = "Previewing background: \(choice.displayName). Click Apply theme to use it."
    }

    func chooseWallpapers() {
        guard canEditWallpapers else { return }
        let themeID = selected.id, name = selected.name
        DispatchQueue.main.async { [weak self] in
            let panel = NSOpenPanel()
            panel.title = "Add wallpapers to \(name)"
            panel.prompt = "Add wallpapers"
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                if response == .OK { self?.addWallpapers(panel.urls, to: themeID) }
            }
            NSApp.activate()
            if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: complete) }
            else { panel.begin(completionHandler: complete) }
        }
    }

    func addWallpapers(_ urls: [URL], to themeID: String? = nil) {
        guard canEditWallpapers, !urls.isEmpty, let wallpaperLibrary else { return }
        let target = themeID ?? selected.id
        editingWallpapers = true
        Task {
            do {
                let ids = try await wallpaperLibrary.add(urls, to: target)
                wallpaperSnapshot = await wallpaperLibrary.snapshot()
                editingWallpapers = false
                if selected.id == target, let first = wallpapers.first(where: { $0.id == ids.first }) { selectWallpaper(first) }
                message = "Added \(ids.count) wallpaper(s). Originals kept."
            } catch { editingWallpapers = false; message = error.localizedDescription }
        }
    }

    func removeWallpaper(_ choice: WallpaperChoice) {
        guard canEditWallpapers, let wallpaperLibrary else { return }
        let target = selected.id, wasSelected = selectedWallpaper?.id == choice.id
        editingWallpapers = true
        Task {
            do {
                try await wallpaperLibrary.setHidden(true, id: choice.id, themeID: target)
                wallpaperSnapshot = await wallpaperLibrary.snapshot()
                removedWallpaper = (target, choice.id)
                editingWallpapers = false
                if selected.id == target, wasSelected, let next = wallpapers.first { selectWallpaper(next) }
                message = "Removed from this theme. Original file kept."
            } catch { editingWallpapers = false; message = error.localizedDescription }
        }
    }

    func undoWallpaperRemoval() {
        guard canEditWallpapers, let wallpaperLibrary else { return }
        let target = selected.id, last = removedWallpaper
        editingWallpapers = true
        Task {
            do {
                if let last, last.themeID == target {
                    try await wallpaperLibrary.setHidden(false, id: last.id, themeID: target)
                } else { try await wallpaperLibrary.restoreRemoved(themeID: target) }
                wallpaperSnapshot = await wallpaperLibrary.snapshot()
                self.removedWallpaper = nil
                editingWallpapers = false
                message = "Removed wallpapers restored to the theme."
            } catch { editingWallpapers = false; message = error.localizedDescription }
        }
    }

    func importTheme() {
        guard !importing, !busy else { return }
        let input = importText
        importing = true
        importMessage = "Downloading palette and backgrounds…"
        Task {
            do {
                let result = try await library.importTheme(input)
                imported = try await library.installedThemes()
                importMessage = "Imported \(result.theme.name) with \(result.wallpapers.count) backgrounds."
                importing = false
                select(result.theme)
            } catch { importMessage = error.localizedDescription; importing = false }
        }
    }

    func updateImportedThemes(onlyCurrent: Bool = false) {
        guard !busy, !importing else { return }
        let items = onlyCurrent ? selectedImport.map { [$0] } ?? [] : imported
        guard !items.isEmpty else { return }
        importing = true
        message = "Checking \(items.count) theme repositories…"
        Task {
            var failures: [String] = []
            var changedCurrent: Theme?
            for item in items {
                do {
                    let updated = try await library.update(item)
                    if updated.id == selected.id { changedCurrent = updated.theme }
                } catch { failures.append("\(item.theme.name): \(error.localizedDescription)") }
            }
            do { imported = try await library.installedThemes() } catch { failures.append(error.localizedDescription) }
            importing = false
            message = failures.isEmpty ? "Imported themes are up to date." : failures.joined(separator: "\n")
            libraryNotice = failures.joined(separator: "\n")
            if let changedCurrent { select(changedCurrent) }
        }
    }

    func restore() {
        guard !busy, !importing, let integrations else { return }
        busy = true
        restoring = true
        Task { @MainActor in
            var failures: [String] = []
            for app in Integration.allCases {
                await Task.yield()
                do { statuses[app] = app == .chatgpt ? try await integrations.restoreLiveChatGPT() : try integrations.restore(app) }
                catch { statuses[app] = error.localizedDescription; failures.append("\(app.name): \(error.localizedDescription)") }
            }
            for app in Self.focusedIntegrations where statuses[app]?.hasPrefix("Restored") == true {
                do { try coordinator?.clear(app) } catch { failures.append(error.localizedDescription) }
            }
            do { try integrations.remember(theme: nil) } catch { failures.append(error.localizedDescription) }
            hasBackups = integrations.hasBackups
            previewOnly = true
            message = Self.restoreSummary(statuses: statuses, failures: failures)
            busy = false
            restoring = false
        }
    }

    static func restoreSummary(statuses: [Integration: String], failures: [String]) -> String {
        let pending = Integration.allCases.compactMap { app -> String? in
            guard let status = statuses[app], status.hasPrefix("Waiting") || status.hasPrefix("Queued") else { return nil }
            return "\(app.name): \(status)"
        }
        let attention = failures + pending
        return attention.isEmpty ? "Previous settings restored. You can preview a look before applying again." : attention.joined(separator: "\n")
    }

    func copyChatGPTTheme() {
        do {
            let text = try ChatGPTConfigEditor.shareString(previewTheme)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            statuses[.chatgpt] = "Copied · paste into Appearance → Import"
            message = "Theme copied. Import it in ChatGPT’s dark Appearance settings."
        } catch { message = error.localizedDescription }
    }

    func showBrowserTheme() {
        do {
            let folder = try ChromiumThemePackage.export(theme: selected, root: root)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            message = "Browser theme exported. Follow the README in its folder."
        } catch { message = error.localizedDescription }
    }

    func applyBrowserTheme() {
        guard !demo, canApply, !busy else { return }
        runApply(destinations: [.brave])
    }

    func chooseObsidianVaults() {
        // Present after the menu has finished tracking. A nested runModal() can leave
        // the file picker hidden behind SwiftUI's still-active menu session.
        DispatchQueue.main.async { [weak self] in self?.presentObsidianVaultPicker() }
    }

    private func presentObsidianVaultPicker() {
        let panel = NSOpenPanel()
        panel.title = "Choose Obsidian vaults to theme"
        panel.prompt = "Use selected vaults"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            self?.saveObsidianVaultSelection(panel.urls)
        }
        NSApp.activate()
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: complete) }
        else { panel.begin(completionHandler: complete) }
    }

    private func saveObsidianVaultSelection(_ urls: [URL]) {
        do {
            guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.appendingPathComponent(".obsidian").path) }) else { throw ThemeError.message("Choose vault folders that contain an .obsidian folder.") }
            let path = root.appendingPathComponent("integration-locations.json")
            var object: [String: Any] = [:]
            if FileManager.default.fileExists(atPath: path.path) {
                guard let current = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any] else { throw ThemeError.message("The application locations file is not a JSON object.") }
                object = current
            }
            object["obsidianVaults"] = urls.map(\.path)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: path, options: .atomic)
            message = "Selected \(urls.count) Obsidian vault(s). Reapply the theme to update them."
        } catch { message = error.localizedDescription }
    }

}
