import ApplicationServices
import Foundation
import ThemeCore

/// Request the renderer's accessibility tree, separately from macOS's grant
/// allowing this process to use AX. A native menu can exist without web content.
/// Chromium: chromium.org/developers/design-documents/accessibility/
/// Electron: electronjs.org/docs/latest/tutorial/accessibility
@MainActor struct WebAccessibilitySession {
    enum Engine {
        case chromium, electron

        static func forApplication(info: [String: Any]) -> Self? {
            // OWL retains Electron packaging metadata but runs Chromium's
            // BrowserCrApplication. The actual application class determines
            // which accessibility attribute its native bridge implements.
            switch info["NSPrincipalClass"] as? String {
            case "BrowserCrApplication": return .chromium
            case "AtomApplication": return .electron
            default: return nil
            }
        }

        var attribute: String {
            switch self {
            case .chromium: return "AXEnhancedUserInterface"
            case .electron: return "AXManualAccessibility"
            }
        }
    }

    static func prepare(
        engine: Engine,
        appName: String,
        setAttribute: (String, Bool) -> AXError,
        checkFocus: () throws -> Void,
        contentReady: () throws -> Bool,
        now: () -> Date = Date.init,
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) }
    ) async throws {
        try Task.checkCancellation()
        try checkFocus()
        // Request once. Chromium debounces this for two seconds; repeating the
        // request in a polling loop can postpone activation indefinitely.
        let result = setAttribute(engine.attribute, true)
        // Chromium handles this legacy attribute then forwards the setter to
        // NSApplication. The AX bridge may report notImplemented even when the
        // request reached that handler. These capability results are therefore
        // advisory; actual renderer content is the success criterion. Permission
        // and invalid-object failures still stop immediately.
        guard result == .success || result == .notImplemented || result == .attributeUnsupported else {
            throw ThemeError.message("\(appName) needs attention · could not enable web accessibility (\(engine.attribute), AX error \(result.rawValue)).")
        }
        let deadline = now().addingTimeInterval(8)
        while now() < deadline {
            try Task.checkCancellation()
            try checkFocus()
            if try contentReady() { return }
            try await pause()
        }
        throw ThemeError.message("\(appName) needs attention · web accessibility was requested, but its page controls did not become available within 8 seconds (\(engine.attribute), AX result \(result.rawValue)).")
    }
}
