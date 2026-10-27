import AppKit

/// Invisible full-screen panel that receives captured input for the experimental edge switch.
/// Non-activating, so it can take keyboard focus without KMctrl becoming the active app.
final class EdgeCapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    static func make(on screen: NSScreen) -> EdgeCapturePanel {
        let p = EdgeCapturePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        p.level = .screenSaver
        p.isOpaque = false
        p.backgroundColor = NSColor.black.withAlphaComponent(0.01)   // invisible but still hit-testable
        p.ignoresMouseEvents = false
        p.acceptsMouseMovedEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.setFrame(screen.frame, display: false)
        return p
    }
}
