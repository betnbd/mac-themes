import ApplicationServices
import Foundation
import Testing
@testable import MacThemes

@MainActor private final class ColdRenderer {
    var date = Date(timeIntervalSince1970: 0)
    var activatedAt: Date?
    var requests: [(String, Bool)] = []
    var reads = 0
    var focus = true
    var exposesContent = true
    var setResult = AXError.success
    var deliversRequestDespiteResult = false

    func set(_ name: String, _ enabled: Bool) -> AXError {
        requests.append((name, enabled))
        if setResult == .success || deliversRequestDespiteResult { activatedAt = date }
        return setResult
    }
    func ready() -> Bool {
        reads += 1
        guard exposesContent, let activatedAt else { return false }
        // Match Chromium's documented debounce. Repeated enables reset this
        // clock, reproducing a renderer that never becomes available.
        return date.timeIntervalSince(activatedAt) >= 2
    }
    func checkFocus() throws {
        if !focus { throw FixtureError.focusChanged }
    }
    enum FixtureError: Error { case focusChanged }

    func prepare(_ engine: WebAccessibilitySession.Engine, loseFocus: Bool = false) async throws {
        try await WebAccessibilitySession.prepare(
            engine: engine, appName: "Fixture",
            setAttribute: set, checkFocus: checkFocus, contentReady: ready,
            now: { self.date },
            pause: {
                self.date.addTimeInterval(0.1)
                if loseFocus { self.focus = false }
            }
        )
    }
}

@MainActor @Test func coldChromiumRendererIsEnabledOnceAndWaitsForContent() async throws {
    let renderer = ColdRenderer()
    #expect(!renderer.ready())
    try await renderer.prepare(.chromium)
    #expect(renderer.requests.count == 1)
    #expect(renderer.requests[0].0 == "AXEnhancedUserInterface")
    #expect(renderer.requests[0].1)
    #expect(renderer.reads > 2)
    #expect(renderer.ready())
}

@MainActor @Test func coldElectronRendererUsesItsDocumentedActivationAttribute() async throws {
    let renderer = ColdRenderer()
    try await renderer.prepare(.electron)
    #expect(renderer.requests.count == 1)
    #expect(renderer.requests[0].0 == "AXManualAccessibility")
    #expect(renderer.ready())
}

@MainActor @Test func activationFailureStopsBeforeReadingWebControls() async {
    let renderer = ColdRenderer()
    renderer.setResult = .apiDisabled
    do {
        try await renderer.prepare(.electron)
        Issue.record("Expected failed activation")
    } catch {
        #expect(error.localizedDescription.contains("AXManualAccessibility"))
        #expect(error.localizedDescription.contains(String(AXError.apiDisabled.rawValue)))
    }
    #expect(renderer.reads == 0)
}

@MainActor @Test func activationDoesNotMaskFocusLossAsMissingControls() async {
    let renderer = ColdRenderer()
    await #expect(throws: ColdRenderer.FixtureError.self) {
        try await renderer.prepare(.chromium, loseFocus: true)
    }
    #expect(renderer.requests.count == 1)
}

@MainActor @Test func successfulAXSetterAloneDoesNotProveWebContentReady() async {
    let renderer = ColdRenderer()
    renderer.exposesContent = false
    do {
        try await renderer.prepare(.chromium)
        Issue.record("Expected timeout for absent renderer content")
    } catch {
        #expect(error.localizedDescription.contains("page controls did not become available"))
        #expect(!error.localizedDescription.contains("Developer mode"))
    }
    #expect(renderer.requests.count == 1)
    #expect(renderer.date.timeIntervalSince1970 >= 8)
    #expect(renderer.date.timeIntervalSince1970 < 8.2)
}

@MainActor @Test func activationDoesNotTouchAnAppAfterFocusHasAlreadyChanged() async {
    let renderer = ColdRenderer()
    renderer.focus = false
    await #expect(throws: ColdRenderer.FixtureError.self) { try await renderer.prepare(.electron) }
    #expect(renderer.requests.isEmpty)
    #expect(renderer.reads == 0)
}

@MainActor @Test func legacyAXSetterResultDoesNotOverrideObservedRendererReadiness() async throws {
    for result in [AXError.notImplemented, AXError.attributeUnsupported] {
        let renderer = ColdRenderer()
        renderer.setResult = result
        renderer.deliversRequestDespiteResult = true
        try await renderer.prepare(.chromium)
        #expect(renderer.ready())
        #expect(renderer.requests.count == 1)
    }
}

@MainActor @Test func unsupportedAXSetterStillFailsIfNoRendererContentAppears() async {
    let renderer = ColdRenderer()
    renderer.setResult = .notImplemented
    do {
        try await renderer.prepare(.chromium)
        Issue.record("No renderer became available")
    } catch {
        #expect(error.localizedDescription.contains("page controls did not become available"))
        #expect(error.localizedDescription.contains("AX result -25208"))
    }
    #expect(renderer.requests.count == 1)
    #expect(renderer.reads > 1)
}

@MainActor @Test func owlChromiumRuntimeTakesPrecedenceOverElectronPackagingMetadata() async throws {
    let info: [String: Any] = [
        "NSPrincipalClass": "BrowserCrApplication",
        "CFBundleIconFile": "electron.icns",
        "ElectronAsarIntegrity": ["Resources/app.asar": ["algorithm": "SHA256"]],
        "ChromiumBaseVersion": "152.0.7977.83"
    ]
    let engine = try #require(WebAccessibilitySession.Engine.forApplication(info: info))
    let renderer = ColdRenderer()
    try await renderer.prepare(engine)
    #expect(renderer.requests.first?.0 == "AXEnhancedUserInterface")
    #expect(renderer.ready())
}

@MainActor @Test func stockElectronRuntimeSelectsItsManualAccessibilityBridge() throws {
    let engine = try #require(WebAccessibilitySession.Engine.forApplication(info: ["NSPrincipalClass": "AtomApplication"]))
    #expect(engine.attribute == "AXManualAccessibility")
}

@MainActor @Test func unknownRuntimeDoesNotGuessFromElectronPackagingOrChromiumVersion() {
    #expect(WebAccessibilitySession.Engine.forApplication(info: [:]) == nil)
    #expect(WebAccessibilitySession.Engine.forApplication(info: [
        "NSPrincipalClass": "NSApplication", "ElectronAsarIntegrity": [:],
        "ChromiumBaseVersion": "152.0.7977.83"
    ]) == nil)
}
