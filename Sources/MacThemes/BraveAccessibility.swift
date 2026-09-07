import AppKit
import ApplicationServices
import ThemeCore

/// Operates Brave's native theme loader only during an explicit Apply.
/// No injected browser code, executable extension, policy service or timer.
@MainActor final class BraveAccessibility {
    private var app: NSRunningApplication?
    private var root: AXUIElement?

    func apply(_ theme: Theme, root support: URL) async throws -> String {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: Integration.brave.bundleID).first else {
            return "Waiting · open Brave, then choose Apply theme"
        }
        guard AXIsProcessTrusted() else {
            throw failure("Mac Themes needs app-control permission in Privacy & Security → \(ChatGPTAccessibility.permissionPane).")
        }
        let folder = try ChromiumThemePackage.exportForActivation(theme: theme, root: support)
        let previous = NSWorkspace.shared.frontmostApplication
        var restorePreviousFocus = true
        app = running
        root = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(root!, 0.25)
        defer {
            if restorePreviousFocus,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier,
               previous?.processIdentifier != running.processIdentifier { previous?.activate() }
            app = nil; root = nil
        }
        running.activate()
        let focusDeadline = Date().addingTimeInterval(2)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != running.processIdentifier, Date() < focusDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try checkFocus()
        try await WebAccessibilitySession.prepare(
            engine: .chromium, appName: "Brave",
            setAttribute: { name, enabled in AXUIElementSetAttributeValue(self.root!, name as CFString, enabled ? kCFBooleanTrue : kCFBooleanFalse) },
            checkFocus: checkFocus,
            contentReady: {
                guard let web = self.find(role: "AXWebArea", name: nil, identifier: nil, value: nil, url: nil) else { return false }
                return !(self.attribute(web, kAXChildrenAttribute) as? [AXUIElement] ?? []).isEmpty
            }
        )
        // Launch Services brought Brave forward without navigating to its
        // internal URL in the live test. Navigate through its own address field
        // in a new tab and verify the resulting web-area URL before proceeding.
        let previousWeb = webArea
        try await BraveThemeNavigation.open(
            checkFocus: checkFocus,
            newTab: { try self.key(17, flags: [.maskCommand]) },
            newTabReady: {
                guard let web = self.webArea,
                      previousWeb.map({ !CFEqual($0, web) }) ?? true,
                      BraveThemeNavigation.isNewTab(self.elementURL(web)),
                      let address = self.addressField,
                      (self.attribute(address, kAXValueAttribute) as? String)?.isEmpty == true else { return false }
                return true
            },
            enterURL: { url in
                guard let address = self.addressField else { throw self.failure("The new tab's address field is unavailable.") }
                try self.checkFocus()
                guard AXUIElementSetAttributeValue(address, kAXValueAttribute as CFString, url as CFString) == .success else {
                    throw self.failure("Brave did not accept the Extensions address.")
                }
                try self.key(36)
            },
            extensionsReady: { self.webArea.map { BraveThemeNavigation.isExtensions(self.elementURL($0)) } ?? false }
        )
        let ownedExtensionsWeb = webArea
        // Developer mode is a one-time user setting. Never toggle unrelated
        // switches or silently alter browser security preferences here.
        let load = try await waitForLoader()
        try click(load)
        _ = try await wait(identifier: "open-panel")
        // The standard macOS file panel's Go to Folder shortcut, followed by
        // its identified path field. No clipboard use or text typed into tabs.
        try key(5, flags: [.maskCommand, .maskShift]) // G
        let path = try await wait(identifier: "PathTextField")
        try checkFocus()
        guard AXUIElementSetAttributeValue(path, kAXValueAttribute as CFString, folder.path as CFString) == .success else {
            throw failure("The theme folder could not be entered in Brave's file picker.")
        }
        try key(36) // Return: navigate, without accepting the outer file panel.
        _ = try await wait(identifier: "where popup", value: folder.lastPathComponent)
        // Confirm the exact generated folder, not just a similarly named item.
        _ = try await wait(url: folder.appendingPathComponent("manifest.json"))
        try press(await wait(identifier: "OKButton"))
        _ = try await wait(name: "Installed theme \"Mac Themes · \(theme.name)\"")
        // Release only the tab created for this successful operation. Errors
        // keep their UI available for inspection; cleanup is never required for
        // theme correctness. If focus or the selected document changed, leave
        // it alone rather than closing a user's tab.
        if let ownedExtensionsWeb, let currentWeb = webArea,
           CFEqual(ownedExtensionsWeb, currentWeb),
           BraveThemeNavigation.isExtensions(elementURL(currentWeb)),
           NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier {
            // CGEvent posting is asynchronous. Do not activate another app
            // until Brave has consumed Cmd+W and selected a different document.
            restorePreviousFocus = false
            do {
                try key(13, flags: [.maskCommand]) // W
                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline {
                    try checkFocus()
                    if let selectedWeb = webArea, !CFEqual(selectedWeb, ownedExtensionsWeb) {
                        restorePreviousFocus = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch {
                // Retain the verified theme result, but never move focus while
                // a posted close shortcut might still be queued.
            }
        }
        return "Applied · Brave confirmed \(theme.name)"
    }

    private var webArea: AXUIElement? {
        find(role: "AXWebArea", name: nil, identifier: nil, value: nil, url: nil)
    }

    private var addressField: AXUIElement? {
        find(role: kAXTextFieldRole, name: "Address and search bar", identifier: nil, value: nil, url: nil, nativeOnly: true)
    }

    private func elementURL(_ element: AXUIElement) -> URL? {
        let value = attribute(element, kAXURLAttribute)
        return (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
    }

    private func waitForLoader() async throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            // In particular, never replace a focus/cancellation error with an
            // unverified assertion that Developer mode is switched off.
            try checkFocus()
            if let load = find(role: kAXButtonRole, name: "Load unpacked", identifier: nil, value: nil, url: nil) { return load }
            if let toggle = find(role: kAXCheckBoxRole, name: "Developer mode", identifier: nil, value: nil, url: nil),
               let enabled = attribute(toggle, kAXValueAttribute) as? NSNumber, !enabled.boolValue {
                throw failure("Developer mode is off in Brave's current profile. Enable it in brave://extensions, then choose Apply again.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw failure("The Extensions page did not expose its Load unpacked button. Developer mode could not be confirmed off; app-control permission is already granted.")
    }

    private func checkFocus() throws {
        try Task.checkCancellation()
        guard let app, !app.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw failure("Theme update paused because focus changed. Choose Apply again when ready.")
        }
    }

    private func key(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
        try checkFocus()
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            throw failure("The file picker shortcut could not be sent.")
        }
        down.flags = flags; up.flags = flags
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }

    private func click(_ element: AXUIElement) throws {
        try checkFocus()
        guard let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
            throw failure("Brave's Load unpacked button has no screen position.")
        }
        var origin = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0 else { throw failure("Brave's theme button is not visible.") }
        let point = CGPoint(x: origin.x + dimensions.width / 2, y: origin.y + dimensions.height / 2)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw failure("Brave's theme button could not be clicked.")
        }
        // Chromium's file chooser did not open after AXPress in the live test.
        // Derive this click from the matched control's current geometry; never
        // use fixed coordinates or click another application's surface.
        try checkFocus()
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }

    private func wait(role: String? = nil, name: String? = nil, identifier: String? = nil, value: String? = nil, url: URL? = nil) async throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            try checkFocus()
            if let result = find(role: role, name: name, identifier: identifier, value: value, url: url) { return result }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw failure("Could not confirm \(name ?? identifier ?? url?.lastPathComponent ?? "the theme control").")
    }

    private func find(role: String?, name: String?, identifier: String?, value: String?, url: URL?, nativeOnly: Bool = false) -> AXUIElement? {
        guard let root else { return nil }
        // Include the focused field first so macOS Go to Folder sheets do not
        // require walking every file column to reach their path input.
        var queue: [AXUIElement] = []
        let rootAttributes = nativeOnly ? [kAXFocusedWindowAttribute] : [kAXFocusedUIElementAttribute, kAXFocusedWindowAttribute]
        for key in rootAttributes {
            if let element = attribute(root, key), CFGetTypeID(element) == AXUIElementGetTypeID() { queue.append(element as! AXUIElement) }
        }
        if queue.isEmpty { queue = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? [] }
        let keys = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXIdentifierAttribute, kAXURLAttribute, kAXChildrenAttribute]
        var index = 0
        let deadline = Date().addingTimeInterval(3)
        while index < queue.count, index < 5_000, Date() < deadline {
            let element = queue[index]; index += 1
            var result: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, keys as CFArray, [], &result) == .success,
                  let values = result as? [Any], values.count == keys.count else { continue }
            let names = values[1...3].compactMap { $0 as? String }
            if nativeOnly, values[0] as? String == "AXWebArea" { continue }
            let actualURL = (values[5] as? URL) ?? (values[5] as? String).flatMap(URL.init(string:))
            if (role == nil || values[0] as? String == role),
               (name == nil || names.contains(name!)),
               (identifier == nil || values[4] as? String == identifier),
               (value == nil || values[3] as? String == value),
               (url == nil || actualURL?.standardizedFileURL == url?.standardizedFileURL) { return element }
            let children = values[6] as? [AXUIElement] ?? []
            queue.append(contentsOf: children.prefix(max(0, 5_000 - queue.count)))
        }
        return nil
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func press(_ element: AXUIElement) throws {
        try checkFocus()
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { throw failure("Brave did not accept the theme control.") }
    }
    private func failure(_ message: String) -> ThemeError { .message("Brave needs attention · \(message)") }
}
