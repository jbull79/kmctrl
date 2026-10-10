import SwiftUI

/// Simple empty-state view. Replaces `ContentUnavailableView` (macOS 14+) so the app
/// runs on Ventura (13).
struct EmptyPlaceholder: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3).fontWeight(.semibold)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

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
