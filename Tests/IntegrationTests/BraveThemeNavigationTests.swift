import Foundation
import Testing
@testable import MacThemes

@MainActor @Test func braveNavigationWaitsForFreshTabThenConfirmsExtensionsURL() async throws {
    var time = Date(timeIntervalSince1970: 0)
    var opened = false
    var entered: String?
    try await BraveThemeNavigation.open(
        checkFocus: {}, newTab: { opened = true },
        newTabReady: { opened && time.timeIntervalSince1970 >= 1 },
        enterURL: { url in
            #expect(time.timeIntervalSince1970 >= 1)
            entered = url
        },
        extensionsReady: { entered != nil && time.timeIntervalSince1970 >= 2 },
        now: { time }, pause: { time.addTimeInterval(0.1) }
    )
    #expect(entered == "brave://extensions/")
    #expect(time.timeIntervalSince1970 >= 2)
}

@MainActor @Test func braveNavigationDoesNotWriteIntoAnUnconfirmedExistingTab() async {
    var time = Date(timeIntervalSince1970: 0)
    var entered = false
    await #expect(throws: (any Error).self) {
        try await BraveThemeNavigation.open(
            checkFocus: {}, newTab: {}, newTabReady: { false },
            enterURL: { _ in entered = true }, extensionsReady: { false },
            now: { time }, pause: { time.addTimeInterval(0.1) }
        )
    }
    #expect(!entered)
}

@MainActor @Test func braveNavigationAcceptsOnlyExactInternalPageURLs() {
    for string in ["brave://extensions", "brave://extensions/", "chrome://extensions/"] {
        #expect(BraveThemeNavigation.isExtensions(URL(string: string)))
    }
    for string in ["https://extensions/", "brave://extensions/shortcuts", "brave://extensions/?query=x", "brave://extensions.example/", "https://google.com/"] {
        #expect(!BraveThemeNavigation.isExtensions(URL(string: string)))
    }
    #expect(BraveThemeNavigation.isNewTab(URL(string: "brave://newtab/")))
    #expect(BraveThemeNavigation.isNewTab(URL(string: "chrome://new-tab-page/")))
    #expect(!BraveThemeNavigation.isNewTab(URL(string: "brave://extensions/")))
}
