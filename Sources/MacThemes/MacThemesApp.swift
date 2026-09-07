import AppKit
import SwiftUI
import ThemeCore

@main
@MainActor
struct MacThemesApp: App {
    @StateObject private var store: ThemeStore

    init() {
        // Keep actor-isolated initialization outside StateObject's autoclosure.
        let initialStore = ThemeStore(demo: ThemeStore.isDemo)
        _store = StateObject(wrappedValue: initialStore)
    }
    var body: some Scene {
        MenuBarExtra {
            LauncherMenu(store: store)
        } label: {
            Image(nsImage: BrandIcon.menuBar)
        }.menuBarExtraStyle(.window)
        Window("Mac Themes", id: "preview") {
            LauncherMenu(store: store)
        }.windowResizability(.contentSize)
            .defaultLaunchBehavior(store.shouldOpenSetupWindow ? .presented : .suppressed)
        Window("Import Omarchy Theme", id: "import") {
            ImportThemeView(store: store)
        }.windowResizability(.contentSize).defaultLaunchBehavior(.suppressed)
        Window("Mac Themes · Setup", id: "applications") {
            ApplicationStatusView(store: store)
        }.defaultSize(width: 500, height: 540).defaultLaunchBehavior(store.shouldOpenStatusWindow ? .presented : .suppressed)
    }
}

/// The menu and preview window deliberately share one view and one rendering path.
struct LauncherMenu: View {
    @ObservedObject var store: ThemeStore
    @Environment(\.openWindow) private var openWindow
    @StateObject private var disclosure = LauncherDisclosure()
    private var accent: Color { Color(hex: store.selected.accent) }
    private let applications: [Integration] = [.ghostty, .obsidian, .brave, .chatgpt]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Mac Themes", systemImage: "paintpalette.fill")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if store.previewOnly {
                    Text(store.demo ? "PREVIEW" : "READY TO APPLY")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                LauncherOptionsButton(expanded: disclosure.open == .actions) {
                    disclosure.open = disclosure.open == .actions ? nil : .actions
                }.frame(width: 34, height: 34)
            }

            ThemeSelector(store: store, disclosure: disclosure)

            ZStack(alignment: .bottomLeading) {
                WallpaperThumbnail(url: store.selectedWallpaper?.url, maxPixelSize: 760)
                    .frame(height: 136).clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .center, endPoint: .bottom)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.selected.name).font(.system(size: 26, weight: .semibold))
                        Text(store.selected.id == "tokyo-night" ? "Deep indigo · soft blue accents" : store.selected.subtitle)
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer()
                    Text(store.selected.isLight ? "LIGHT" : "DARK")
                        .font(.system(size: 9, weight: .bold)).tracking(1)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.black.opacity(0.3), in: Capsule())
                }.foregroundStyle(.white).padding(14)
            }.frame(height: 136).clipShape(RoundedRectangle(cornerRadius: 12))
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(store.selected.name), \(store.selected.isLight ? "light" : "dark") theme, wallpaper preview")

            VStack(alignment: .leading, spacing: 5) {
                Picker("Font", selection: Binding(get: { store.selectedFontID }, set: { store.selectFont($0) })) {
                    Text("Keep unchanged").tag("")
                    Text("Use app default").tag("default")
                    ForEach(ThemeFont.all) { font in
                        Text(font.name + (font.directory == nil ? "" : " · Nerd")).tag(font.id)
                    }
                }.disabled(store.busy || store.importing || store.restoring)
                Text("Ghostty · Obsidian · ChatGPT code")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ThemePreview(theme: store.previewTheme)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Wallpaper").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Button { store.chooseWallpapers() } label: { Label("Add…", systemImage: "plus") }
                        .buttonStyle(.borderless).disabled(!store.canEditWallpapers)
                        .help("Add image files to this theme")
                    Button {
                        if let wallpaper = store.selectedWallpaper { store.removeWallpaper(wallpaper) }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(!store.canEditWallpapers || store.selectedWallpaper == nil)
                        .accessibilityLabel("Remove selected wallpaper")
                        .help("Remove the selected wallpaper from this theme; keep its original file")
                }
                if store.wallpapers.isEmpty {
                    Text("Drop images here or choose Add…")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(store.wallpapers.prefix(8)) { wallpaper in
                        Button { store.selectWallpaper(wallpaper) } label: {
                            WallpaperThumbnail(url: wallpaper.url, maxPixelSize: 180)
                                .frame(height: 38).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .overlay(alignment: .bottomTrailing) {
                                    if wallpaper.id == store.selectedWallpaper?.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 12)).foregroundStyle(.white, accent)
                                            .padding(4)
                                    }
                                }
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(
                                    wallpaper.id == store.selectedWallpaper?.id ? accent : .white.opacity(0.12),
                                    lineWidth: wallpaper.id == store.selectedWallpaper?.id ? 2 : 0.5))
                        }.buttonStyle(.plain).disabled(!store.canEditWallpapers)
                            .contextMenu {
                                Button("Remove from theme", role: .destructive) { store.removeWallpaper(wallpaper) }
                            }
                            .help(wallpaper.displayName)
                            .accessibilityLabel("Wallpaper: \(wallpaper.displayName)")
                            .accessibilityAddTraits(wallpaper.id == store.selectedWallpaper?.id ? .isSelected : [])
                    }
                }
                if store.wallpapers.count > 8 {
                    Menu("More wallpapers") {
                        ForEach(store.wallpapers.dropFirst(8)) { wallpaper in
                            Button(wallpaper.displayName) { store.selectWallpaper(wallpaper) }
                        }
                    }.font(.caption).disabled(!store.canEditWallpapers)
                }
                HStack {
                    if store.editingWallpapers { ProgressView().controlSize(.mini) }
                    Text(store.selectedWallpaper?.displayName ?? "Drop images here to add wallpapers")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if store.hasRemovedWallpapers {
                        Button(store.canUndoWallpaperRemoval ? "Undo removal" : "Restore removed") { store.undoWallpaperRemoval() }
                            .font(.system(size: 10)).buttonStyle(.borderless)
                            .disabled(!store.canEditWallpapers)
                    }
                }
            }.contentShape(Rectangle())
                .dropDestination(for: URL.self) { urls, _ in
                    guard store.canEditWallpapers, !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
                    store.addWallpapers(urls)
                    return true
                }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Apply to").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Button("Setup & status") { showWindow("applications") }
                        .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(accent)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 7) {
                    ForEach(applications) { app in
                        HStack(spacing: 7) {
                            Image(systemName: app.symbol).font(.system(size: 13)).foregroundStyle(accent).frame(width: 17)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).font(.system(size: 11, weight: .medium))
                                Text(shortStatus(app)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Toggle(app.name, isOn: enabled(app)).labelsHidden().toggleStyle(.checkbox).disabled(store.busy)
                        }.padding(6).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                            .help(store.statuses[app] ?? app.detail)
                    }
                }
                HStack {
                    Toggle("Wallpaper", isOn: enabled(.wallpaper))
                    Spacer()
                    Toggle("macOS appearance", isOn: enabled(.macos))
                }.toggleStyle(.checkbox).font(.system(size: 10)).padding(.top, 2).disabled(store.busy)
            }

            Button { store.applySelected() } label: {
                HStack(spacing: 7) {
                    if store.busy { ProgressView().controlSize(.small).tint(Color(hex: store.selected.background)) }
                    else { Image(systemName: store.demo ? "eye" : "paintbrush.pointed.fill") }
                    Text(store.busy ? "Applying…" : store.demo ? "Preview \(store.selected.name)" : "Apply \(store.selected.name)")
                        .fontWeight(.semibold)
                }.frame(maxWidth: .infinity).frame(height: 36)
                    .foregroundStyle(Color(hex: store.selected.background))
                    .background(accent, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).opacity(!store.canApply || store.busy ? 0.5 : 1)
                .disabled(!store.canApply || store.busy)

            Text(store.message).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading).accessibilityLabel("Status: \(store.message)")
        }
        .padding(14).frame(width: 390)
        .foregroundStyle(Color(hex: store.selected.foreground))
        .background(Color(hex: store.selected.background))
        .preferredColorScheme(store.selected.isLight ? .light : .dark)
        .overlay(alignment: .topTrailing) {
            if disclosure.open == .actions {
                ZStack(alignment: .topTrailing) {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { disclosure.open = nil }
                        .accessibilityHidden(true)
                        .padding(.top, 52)
                    actionsMenu.padding(.top, 52).padding(.trailing, 14)
                }
            }
        }
        .onExitCommand { disclosure.open = nil }
        .onDisappear { disclosure.open = nil }
        .onAppear { store.markSetupSeen() }
    }

    private var actionsMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            action("Application setup…") { showWindow("applications") }
            action("Import Omarchy theme…") { showWindow("import") }
            action("Update imported theme") { store.updateImportedThemes(onlyCurrent: true) }
                .disabled(store.selectedImport == nil || store.importing || store.busy)
            Divider().padding(.vertical, 3)
            action("Restore previous appearance") { store.restore() }
                .disabled(!store.hasBackups || store.busy || store.importing)
            action("Show theme library") { NSWorkspace.shared.activateFileViewerSelecting([store.libraryURL]) }
            action("Open preview window") { showWindow("preview") }
            Divider().padding(.vertical, 3)
            action("Quit Mac Themes") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .font(.system(size: 12)).padding(5).frame(width: 246)
        .background(Color(hex: store.selected.background), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.25)))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
    }

    private func action(_ title: String, perform: @escaping () -> Void) -> some View {
        Button {
            disclosure.open = nil
            perform()
        } label: {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func enabled(_ app: Integration) -> Binding<Bool> {
        Binding(get: { store.enabled.contains(app) }, set: { store.toggle(app, enabled: $0) })
    }
    private func showWindow(_ id: String) { openWindow(id: id); NSApp.activate() }
    private func shortStatus(_ app: Integration) -> String {
        let status = store.statuses[app] ?? ""
        if status.hasPrefix("Applied") { return "Applied" }
        if status == "Applying…" { return status }
        if status.hasPrefix("Not installed") { return "Not found" }
        if status.contains("automatically when ChatGPT opens") { return "Waiting for app" }
        if status.hasPrefix("Queued") || status.hasPrefix("Waiting") { return "Restore pending" }
        if status.hasPrefix("Ready") { return "Ready to import" }
        if status.hasPrefix("Theme package ready") { return "Theme package" }
        if status.hasPrefix("Exported") || status.hasPrefix("Saved") { return "Setup required" }
        if status.hasPrefix("Copied") { return "Ready to import" }
        if status.hasPrefix("Restored") { return "Restored" }
        if !status.isEmpty && status != app.detail && !status.hasPrefix("Copy theme") && !status.hasPrefix("No changes") { return "Needs attention" }
        switch app {
        case .ghostty: return "Palette + reload"
        case .obsidian: return "Live CSS snippet"
        case .brave: return "Browser colors"
        case .chatgpt: return "Automatic theme"
        default: return ""
        }
    }
}

extension WallpaperChoice {
    var displayName: String {
        let label = name.replacingOccurrences(of: #"^\d+[\s_-]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return label.prefix(1).uppercased() + label.dropFirst()
    }
}

@MainActor private final class LauncherDisclosure: ObservableObject {
    enum Popup { case themes, actions }
    @Published var open: Popup?
}

/// Expands inside the existing panel; does not start a second native menu session.
private struct ThemeSelector: View {
    @ObservedObject var store: ThemeStore
    @ObservedObject var disclosure: LauncherDisclosure

    var body: some View {
            VStack(spacing: 5) {
                Button { disclosure.open = disclosure.open == .themes ? nil : .themes } label: {
                    HStack {
                        Text("Theme").foregroundStyle(.secondary)
                        Text(store.selected.name).fontWeight(.medium)
                        Spacer()
                        Image(systemName: disclosure.open == .themes ? "chevron.up" : "chevron.down")
                    }.padding(8).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("Choose theme")
                    .accessibilityValue("\(store.selected.name), \(disclosure.open == .themes ? "expanded" : "collapsed")")
            }.font(.system(size: 12))
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                .overlay(alignment: .top) {
                if disclosure.open == .themes {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(store.themes) { theme in
                                Button {
                                    disclosure.open = nil
                                    store.select(theme)
                                } label: {
                                    HStack(spacing: 8) {
                                        Circle().fill(Color(hex: theme.accent)).frame(width: 9, height: 9)
                                        Text(theme.name)
                                        Spacer()
                                        if store.selected.id == theme.id { Image(systemName: "checkmark") }
                                    }.padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(!store.canApply)
                                    .accessibilityLabel("Select \(theme.name)")
                            }
                        }
                    }.frame(height: min(CGFloat(store.themes.count) * 32, 224))
                        .padding(5)
                        .background(Color(hex: store.selected.background), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.25)))
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                        .offset(y: 34)
                }
            }.zIndex(1)
    }
}

/// ImageIO decodes only display-sized thumbnails; a status update never reloads them.
private struct WallpaperThumbnail: View {
    let url: URL?
    let maxPixelSize: Int
    @StateObject private var thumbnail = WallpaperThumbnailImage()
    var body: some View {
        GeometryReader { bounds in
            Group {
                if let image = thumbnail.image { Image(nsImage: image).resizable().scaledToFill() }
                else { Color(hex: "#24283b").overlay(Image(systemName: "photo").foregroundStyle(.secondary)) }
            }.frame(width: bounds.size.width, height: bounds.size.height).clipped()
        }.contentShape(Rectangle())
            .task(id: url) { thumbnail.load(url, maxPixelSize: maxPixelSize) }
            .onDisappear { thumbnail.clear() }
    }
}

@MainActor
private final class WallpaperThumbnailImage: ObservableObject {
    @Published var image: NSImage?
    private var loadedURL: URL?
    private var loadedSize = 0
    func clear() {
        image = nil
        loadedURL = nil
        loadedSize = 0
    }
    func load(_ url: URL?, maxPixelSize: Int) {
        guard loadedURL != url || loadedSize != maxPixelSize else { return }
        loadedURL = url
        loadedSize = maxPixelSize
        image = url.flatMap { WallpaperImage.preview($0, maxPixelSize: maxPixelSize) }
    }
}

struct ImportThemeView: View {
    @ObservedObject var store: ThemeStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Import an Omarchy theme", systemImage: "square.and.arrow.down").font(.title2.bold())
            Text("Paste an Omarchy install command or a GitHub repository URL.")
            TextField("omarchy-theme-install https://github.com/owner/theme", text: $store.importText, axis: .vertical)
                .lineLimit(3...5).textFieldStyle(.roundedBorder)
            Text("Palettes and backgrounds are converted locally. Repository scripts are never run.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if store.importing { ProgressView().controlSize(.small) }
                Text(store.importMessage).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            HStack {
                Spacer()
                Button("Import and select") { store.importTheme() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.importing || store.busy)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 500)
    }
}

struct ApplicationStatusView: View {
    @ObservedObject var store: ThemeStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Make it yours").font(.title2.bold())
            Text("Choose what follows your theme. ChatGPT and Brave use app-control permission once and briefly open their theme controls. Enable Developer mode once in Brave’s Extensions page to load the browser themes.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(ThemeStore.focusedIntegrations) { app in
                        VStack(alignment: .leading, spacing: 5) {
                            Toggle(isOn: Binding(get: { store.enabled.contains(app) }, set: { store.toggle(app, enabled: $0) })) {
                                Label(app.name, systemImage: app.symbol).font(.headline)
                            }.disabled(store.busy)
                            Text(store.statuses[app] ?? app.detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            if app == .obsidian {
                                Button("Choose Obsidian vaults…") { store.chooseObsidianVaults() }.font(.caption)
                            } else if app == .brave {
                                Button("Apply in Brave") { store.applyBrowserTheme() }
                                    .font(.caption).disabled(store.demo || store.busy || store.importing)
                                Button("Show browser theme files…") { store.showBrowserTheme() }.font(.caption)
                            } else if app == .chatgpt {
                                Text(store.demo ? "Preview only" : store.chatGPTAuthorized ? "Accessibility granted" : "Accessibility not granted to this app copy")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button(store.chatGPTAuthorized ? "Review Accessibility permission…" : "Repair Accessibility permission…") {
                                    if !store.demo { ChatGPTAccessibility.openPermissionSettings() }
                                }.font(.caption)
                                Button("Copy theme for manual import") { store.copyChatGPTTheme() }.font(.caption)
                            }
                        }
                        Divider()
                    }
                }
            }
            Text(store.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Refresh detection") { store.refreshAvailability() }
                Spacer()
                Button("Apply theme") { store.applySelected() }.disabled(!store.canApply || store.busy)
                    .buttonStyle(.borderedProminent)
            }
        }.padding(24)
            .onAppear { store.markStatusSeen(); store.refreshAccessibilityPermission() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                store.refreshAccessibilityPermission()
            }
    }
}

struct ThemePreview: View {
    let theme: Theme
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                ForEach(["#ff5f57", "#febc2e", "#28c840"], id: \.self) { color in
                    Circle().fill(Color(hex: color).opacity(0.85)).frame(width: 5, height: 5)
                }
                Spacer()
                Text("PALETTE").font(.system(size: 8, weight: .medium)).tracking(1.2).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                Text("~ ").foregroundStyle(Color(hex: theme.accent))
                Text("❯ ").foregroundStyle(Color(hex: theme.palette[2]))
                Text("make yourself at home").foregroundStyle(Color(hex: theme.foreground))
            }.font(theme.fontFamily.map { .custom($0, size: 11) } ?? .system(size: 11, design: .monospaced))
            HStack(spacing: 5) {
                ForEach(1..<7) { index in
                    RoundedRectangle(cornerRadius: 3).fill(Color(hex: theme.palette[index])).frame(height: 11)
                        .help(theme.palette[index]).accessibilityLabel("Palette color \(theme.palette[index])")
                }
            }
        }.padding(10)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.06)))
    }
}

extension Color {
    init(hex: String) {
        let rgb = ScriptLiteral.rgb(hex)
        self.init(.sRGB, red: Double(rgb[0]) / 65535, green: Double(rgb[1]) / 65535, blue: Double(rgb[2]) / 65535, opacity: 1)
    }
}
