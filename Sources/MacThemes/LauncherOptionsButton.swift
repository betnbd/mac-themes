import AppKit
import SwiftUI

/// Native first-click handling also works when the launcher window is inactive.
struct LauncherOptionsButton: NSViewRepresentable {
    var expanded: Bool
    var action: () -> Void

    final class Control: NSButton {
        var actionHandler: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        @objc func activateMenu() { actionHandler?() }
    }

    func makeNSView(context: Context) -> Control {
        let button = Control()
        button.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .semibold))
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.showsBorderOnlyWhileMouseInside = true
        button.setButtonType(.momentaryPushIn)
        button.target = button
        button.action = #selector(Control.activateMenu)
        button.toolTip = "Settings and theme library"
        button.setAccessibilityLabel("Settings and theme library")
        return button
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Control, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 34, height: proposal.height ?? 34)
    }

    func updateNSView(_ button: Control, context: Context) {
        button.actionHandler = action
        button.setAccessibilityValue(expanded ? "expanded" : "collapsed")
    }
}
