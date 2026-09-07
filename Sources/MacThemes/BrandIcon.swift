import AppKit

@MainActor enum BrandIcon {
    /// An 18-point template mark: stacked theme cards and a customization sparkle.
    /// AppKit supplies the correct menu-bar color in light, dark and selected states.
    static let menuBar: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            for (x, y) in [(2.0, 3.0), (5.0, 5.0), (8.0, 7.0)] {
                let card = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 7, height: 9), xRadius: 1.5, yRadius: 1.5)
                NSColor.white.setFill()
                // Clear the cards behind this one while retaining template alpha.
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.compositingOperation = .clear
                card.fill()
                NSGraphicsContext.restoreGraphicsState()
                card.lineWidth = 1.3
                card.stroke()
            }
            NSColor.black.setFill()
            let sparkle = NSBezierPath()
            sparkle.move(to: NSPoint(x: 14, y: 2))
            for point in [NSPoint(x: 15, y: 4), NSPoint(x: 17, y: 5), NSPoint(x: 15, y: 6), NSPoint(x: 14, y: 8), NSPoint(x: 13, y: 6), NSPoint(x: 11, y: 5), NSPoint(x: 13, y: 4)] { sparkle.line(to: point) }
            sparkle.close()
            sparkle.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Mac Themes"
        return image
    }()
}
