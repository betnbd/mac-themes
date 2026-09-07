import AppKit
import ApplicationServices
import ThemeCore

/// Event-driven UI automation for the user-installed launcher. No private IPC,
/// injected JavaScript, app modifications, keystrokes, or idle polling.
@MainActor final class ChatGPTAccessibility: ChatGPTAppearanceClient {
    private var application: NSRunningApplication?
    private var root: AXUIElement?
    private var previousApplication: NSRunningApplication?
    private var lastControlSummary = "No Appearance snapshot completed"
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Integration.chatgpt.bundleID).isEmpty }

    static var hasPermission: Bool { AXIsProcessTrusted() }
    static var permissionPane: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "Device Control and Data Access" : "Accessibility"
    }
    static func openPermissionSettings() {
        // Called only by the user's explicit Setup button, never from Apply.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func prepare() async throws {
        lastControlSummary = "No Appearance snapshot completed"
        guard Self.hasPermission else {
            throw ThemeError.message("Permission not recognized · macOS is denying this app access despite any saved switch. Check Privacy & Security → \(Self.permissionPane). If Mac Themes is enabled there, leave it enabled; this needs diagnosis rather than repeated permission changes.")
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Integration.chatgpt.bundleID).first else {
            throw ThemeError.message("ChatGPT closed before its theme could be applied.")
        }
        guard let bundleURL = app.bundleURL,
              let info = Bundle(url: bundleURL)?.infoDictionary,
              let engine = WebAccessibilitySession.Engine.forApplication(info: info) else {
            throw ThemeError.message("ChatGPT setup needs attention · its installed application runtime is not supported by this Accessibility adapter.")
        }
        previousApplication = NSWorkspace.shared.frontmostApplication
        application = app
        root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root!, 0.25)
        let launchDeadline = Date().addingTimeInterval(8)
        while !app.isFinishedLaunching, !app.isTerminated, Date() < launchDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        app.activate()
        let focusDeadline = Date().addingTimeInterval(2)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier, Date() < focusDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try checkFocus()
        try await WebAccessibilitySession.prepare(
            engine: engine, appName: "ChatGPT",
            setAttribute: { name, enabled in AXUIElementSetAttributeValue(self.root!, name as CFString, enabled ? kCFBooleanTrue : kCFBooleanFalse) },
            checkFocus: checkFocus,
            contentReady: hasWebContent
        )
        if (try? hasThemeControls()) == true { return }
        guard let menuValue = attribute(root!, kAXMenuBarAttribute), CFGetTypeID(menuValue) == AXUIElementGetTypeID() else { throw unavailable("Settings menu") }
        let menu = menuValue as! AXUIElement
        if let first = children(menu).first { try press(first) }
        guard let settings = find(in: [menu], names: ["Settings…", "Settings...", "Settings", "Preferences…"], roles: [kAXMenuItemRole]) else {
            throw unavailable("Settings menu item")
        }
        try press(settings)
        let deadline = Date().addingTimeInterval(6)
        var openedAppearance = false
        while Date() < deadline {
            try checkFocus()
            if try hasThemeControls() { return }
            if !openedAppearance, let appearance = appearanceNavigation() {
                try press(appearance); openedAppearance = true
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw unavailable((openedAppearance ? "Appearance selected, but neither Light nor Dark theme import controls were found" : "Appearance navigation in Settings") + ". Control summary: " + lastControlSummary)
    }

    private func hasThemeControls() throws -> Bool {
        let tree = try themeControlTree()
        return tree.themeButton("Import", variant: "light") != nil || tree.themeButton("Import", variant: "dark") != nil
    }

    private func waitForThemeButton(_ action: String, variant: String) async throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            try checkFocus()
            if let button = try themeControlTree().themeButton(action, variant: variant) { return button }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw unavailable("\(action) in the \(variant.capitalized) theme section")
    }

    private var searchWindows: [AXUIElement] {
        guard let root else { return [] }
        // The active Settings window gets the entire search budget. Unrelated
        // chat windows must not consume it or supply an ambiguous button.
        if let focused = attribute(root, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
            return [focused as! AXUIElement]
        }
        return Array((attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []).prefix(1))
    }

    private func themeControlTree() throws -> AppearanceControlTree<AXUIElement> {
        var queue = searchWindows.map { ($0, Optional<Int>.none) }
        var nodes: [AppearanceControlTree<AXUIElement>.Node] = []
        var index = 0
        var truncated = false
        let deadline = Date().addingTimeInterval(6)
        while index < queue.count, index < 5_000, Date() < deadline {
            let (element, parent) = queue[index]
            let info = controlInfo(element)
            nodes.append(.init(element: element, role: info.role, names: info.names, parent: parent))
            let remaining = max(0, 5_000 - queue.count)
            if info.children.count > remaining { truncated = true }
            queue.append(contentsOf: info.children.prefix(remaining).map { ($0, Optional(index)) })
            index += 1
        }
        guard !truncated, index == queue.count else {
            throw ThemeError.message("ChatGPT's Appearance control search reached its limit before finishing. No importer was selected.")
        }
        let tree = AppearanceControlTree(nodes: nodes)
        lastControlSummary = tree.diagnosticSummary
        return tree
    }

    private func hasWebContent() -> Bool {
        var queue = searchWindows, index = 0
        let deadline = Date().addingTimeInterval(2)
        while index < queue.count, index < 2_000, Date() < deadline {
            let info = controlInfo(queue[index]); index += 1
            if info.role == "AXWebArea", !info.children.isEmpty { return true }
            queue.append(contentsOf: info.children.prefix(max(0, 2_000 - queue.count)))
        }
        return false
    }

    private func appearanceNavigation() -> AXUIElement? {
        if let control = find("Appearance", roles: ["AXLink", kAXButtonRole, kAXRowRole, kAXRadioButtonRole]) { return control }
        // Some web-backed sidebars put the label on a static-text child of the
        // actionable row. Walk only its immediate ancestors, never unrelated UI.
        guard var element = find("Appearance", roles: [kAXStaticTextRole]) else { return nil }
        for _ in 0..<3 {
            var actions: CFArray?
            if AXUIElementCopyActionNames(element, &actions) == .success,
               (actions as? [String])?.contains(kAXPressAction) == true { return element }
            guard let parent = attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            element = parent as! AXUIElement
        }
        return nil
    }

    func mode() throws -> String {
        for mode in ["light", "dark", "system"] {
            if let control = find(mode.capitalized, roles: [kAXRadioButtonRole]),
               (attribute(control, kAXValueAttribute) as? NSNumber)?.boolValue == true { return mode }
        }
        throw unavailable("selected appearance mode")
    }

    func setMode(_ mode: String) async throws {
        guard ["light", "dark", "system"].contains(mode) else { throw ChatGPTThemeShare.invalid }
        try checkFocus()
        try press(await waitFor(mode.capitalized, roles: [kAXRadioButtonRole]))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if try self.mode() == mode { return }
            try await Task.sleep(for: .milliseconds(75))
        }
        throw unavailable("appearance mode confirmation")
    }

    func copyTheme(_ variant: String) async throws -> String {
        guard ["light", "dark"].contains(variant) else { throw ChatGPTThemeShare.invalid }
        try checkFocus()
        let button = try await waitForThemeButton("Copy", variant: variant)
        let clipboard = NSPasteboard.general
        let original = clipboard.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        } ?? []
        let before = clipboard.changeCount
        var ourChange: Int?
        defer {
            // Never overwrite a new clipboard value created by the user meanwhile.
            if let ourChange, clipboard.changeCount == ourChange {
                clipboard.clearContents()
                let items = original.map { values in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                }
                clipboard.writeObjects(items)
            }
        }
        try press(button)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            try checkFocus()
            if clipboard.changeCount != before {
                guard let value = clipboard.string(forType: .string),
                      let share = try? ChatGPTThemeShare(value), share.variant == variant else {
                    throw ThemeError.message("The clipboard changed during theme capture. Try Apply again.")
                }
                ourChange = clipboard.changeCount
                return value
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw unavailable("Copy \(variant.capitalized) theme result")
    }

    func importTheme(_ share: String, variant: String) async throws {
        guard try ChatGPTThemeShare(share).variant == variant else { throw ChatGPTThemeShare.invalid }
        try checkFocus()
        try press(await waitForThemeButton("Import", variant: variant))
        let field = try await waitFor("\(variant.capitalized) theme share string", roles: [kAXTextAreaRole, kAXTextFieldRole])
        guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, share as CFString) == .success else {
            throw unavailable("theme import text field")
        }
        // The native Import button is disabled until the app accepts the schema.
        let submit = try await waitFor("Import theme", roles: [kAXButtonRole], enabled: true)
        try press(submit)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            try checkFocus()
            if find("\(variant.capitalized) theme share string", roles: [kAXTextAreaRole, kAXTextFieldRole]) == nil { return }
            try await Task.sleep(for: .milliseconds(75))
        }
        throw ThemeError.message("ChatGPT kept its import dialog open. Check its message; the previous theme backup is retained.")
    }

    func finish() {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == application?.processIdentifier,
           let previousApplication, previousApplication.processIdentifier != application?.processIdentifier {
            previousApplication.activate()
        }
        previousApplication = nil; application = nil; root = nil
    }

    private func checkFocus() throws {
        try Task.checkCancellation()
        guard let application, !application.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
            throw ThemeError.message("ChatGPT theme update paused because focus changed. Choose Apply again when ready.")
        }
    }
    private func waitFor(_ name: String, roles: [String], enabled: Bool = false) async throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            try checkFocus()
            if let element = find(name, roles: roles), !enabled || (attribute(element, kAXEnabledAttribute) as? NSNumber)?.boolValue == true { return element }
            try await Task.sleep(for: .milliseconds(75))
        }
        throw unavailable(name)
    }
    private func find(_ name: String, roles: [String]) -> AXUIElement? {
        return find(in: searchWindows, names: [name], roles: roles)
    }
    private func find(in roots: [AXUIElement], names: [String], roles: [String]) -> AXUIElement? {
        var queue = roots, index = 0
        let deadline = Date().addingTimeInterval(4)
        while index < queue.count, index < 2_000, Date() < deadline {
            let element = queue[index]; index += 1
            let info = controlInfo(element)
            if roles.contains(info.role), info.names.contains(where: { names.contains($0) }) { return element }
            if queue.count < 2_000 { queue.append(contentsOf: info.children.prefix(2_000 - queue.count)) }
        }
        return nil
    }
    private func controlInfo(_ element: AXUIElement) -> (role: String, names: [String], children: [AXUIElement]) {
        // One IPC round trip per node, instead of separate requests for each
        // attribute. Long settings pages otherwise exhaust the search before
        // reaching the theme cards, then restart from the same prefix.
        let keys = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXChildrenAttribute]
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, keys as CFArray, [], &result) == .success,
              let values = result as? [Any], values.count == keys.count else {
            return ("", [], children(element))
        }
        return (values[0] as? String ?? "", values[1...3].compactMap { $0 as? String }, values[4] as? [AXUIElement] ?? [])
    }
    private func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func press(_ element: AXUIElement) throws {
        try checkFocus()
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { throw unavailable("appearance control") }
    }
    private func unavailable(_ control: String) -> ThemeError {
        .message("ChatGPT setup needs attention · could not use \(control). This adapter requires the English Appearance controls with theme import.")
    }
}
