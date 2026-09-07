import Foundation
import ThemeCore

@MainActor enum BraveThemeNavigation {
    static func isExtensions(_ url: URL?) -> Bool {
        matches(url, hosts: ["extensions"])
    }

    static func isNewTab(_ url: URL?) -> Bool {
        matches(url, hosts: ["newtab", "new-tab-page"])
    }

    private static func matches(_ url: URL?, hosts: Set<String>) -> Bool {
        guard let url, ["brave", "chrome"].contains(url.scheme?.lowercased() ?? ""),
              hosts.contains(url.host?.lowercased() ?? ""),
              url.path.isEmpty || url.path == "/",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return false }
        return true
    }

    static func open(
        checkFocus: () throws -> Void,
        newTab: () throws -> Void,
        newTabReady: () -> Bool,
        enterURL: (String) throws -> Void,
        extensionsReady: () -> Bool,
        now: () -> Date = Date.init,
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) }
    ) async throws {
        func wait(_ ready: () -> Bool, stage: String) async throws {
            let deadline = now().addingTimeInterval(8)
            while now() < deadline {
                try Task.checkCancellation()
                try checkFocus()
                if ready() { return }
                try await pause()
            }
            throw ThemeError.message("Brave needs attention · could not confirm \(stage).")
        }
        try checkFocus()
        try newTab()
        try await wait(newTabReady, stage: "a new empty tab; the existing tab was not edited")
        try checkFocus()
        try enterURL("brave://extensions/")
        try await wait(extensionsReady, stage: "navigation to brave://extensions/")
    }
}
