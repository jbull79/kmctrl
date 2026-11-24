import SwiftUI

/// Hands the hosting `NSWindow` to the caller once the view is in a window. The window is
/// marked not-released-on-close so it can be reopened programmatically later.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { report(v) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { DispatchQueue.main.async { report(v) } }
    private func report(_ v: NSView) {
        guard let w = v.window else { return }
        w.isReleasedWhenClosed = false
        onWindow(w)
    }
}
