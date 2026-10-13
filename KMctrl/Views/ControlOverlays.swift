import SwiftUI
import AppKit

// On-screen overlays for the KVM core: a persistent badge on the *controlled* Mac while a
// remote is driving it (with a one-click kill switch), and a brief hint on the *controlling*
// Mac showing how to release. Both are borderless, non-activating floating panels that join
// every Space so they stay visible over full-screen apps.

/// A floating, non-activating panel that never steals key focus from the app being driven.
private final class OverlayPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: content.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = content
    }
    override var canBecomeKey: Bool { false }   // never take focus from the controlled app
    override var canBecomeMain: Bool { false }
}

private extension OverlayPanel {
    /// Place the panel centred horizontally, a little below the top of the main screen.
    func positionTopCentre() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let v = screen.visibleFrame
        contentView?.layoutSubtreeIfNeeded()
        let size = contentView?.fittingSize ?? frame.size
        setContentSize(size)
        let x = v.midX - size.width / 2
        let y = v.maxY - size.height - 12
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Bottom-right of the screen, clear of title bars and the Dock.
    func positionBottomRight() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        contentView?.layoutSubtreeIfNeeded()
        let size = contentView?.fittingSize ?? frame.size
        setContentSize(size)
        setFrameOrigin(BadgePlacement.origin(size: size, visibleFrame: screen.visibleFrame, saved: nil))
    }
}

// MARK: - Controlled-side badge

/// Shows "🔒 Controlled by <name>" with a Disconnect button while this Mac is being driven.
/// Always-visible kill switch + clear signal that input is coming from elsewhere. Sits
/// bottom-right, clear of title bars, and can be hidden in Settings — the menu-bar item
/// still shows who is controlling and offers Disconnect.
///
/// Deliberately NOT draggable: an injected click-and-move over a movable panel starts a
/// window drag, and macOS then clamps the pointer so the window stays on screen — the
/// remote pointer could no longer reach the bottom of the display.
@MainActor
final class ControlBadgeController {
    private var panel: OverlayPanel?

    func show(controller name: String, onDisconnect: @escaping () -> Void) {
        hide()
        guard UserDefaults.standard.object(forKey: AppSettings.Keys.showControlledBadge) as? Bool ?? true else { return }
        let view = ControlBadgeView(peerName: name, onDisconnect: onDisconnect)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let panel = OverlayPanel(content: host)
        panel.positionBottomRight()
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct ControlBadgeView: View {
    let peerName: String
    let onDisconnect: () -> Void
    @State private var pulse = false

    var body: some View {
        HStack(spacing: Theme.s3) {
            Image(systemName: "lock.laptopcomputer")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.orange)
                .opacity(pulse ? 0.5 : 1)
                .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulse)
            VStack(alignment: .leading, spacing: 0) {
                Text("Controlled by \(peerName)")
                    .font(.system(.callout, weight: .semibold))
                Text("Hide in Settings → Control")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button(role: .destructive, action: onDisconnect) {
                Text("Disconnect").font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s2 + 2)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.orange.opacity(0.5), lineWidth: 1))
        .fixedSize()
        .onAppear { pulse = true }
    }
}

// MARK: - Controlling-side release hint

/// A brief, auto-fading hint on the controlling Mac when window-mode capture begins, telling
/// the user how to release. Hidden again on capture end. Non-interactive.
@MainActor
final class CaptureHintController {
    private var panel: OverlayPanel?
    private var hideWork: DispatchWorkItem?

    func flash() {
        show()
        let work = DispatchWorkItem { [weak self] in self?.fade() }
        hideWork?.cancel(); hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    func show() {
        guard panel == nil else { return }
        let host = NSHostingView(rootView: CaptureHintView())
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let panel = OverlayPanel(content: host)
        panel.ignoresMouseEvents = true
        panel.positionTopCentre()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        self.panel = panel
    }

    func hide() {
        hideWork?.cancel(); hideWork = nil
        panel?.orderOut(nil); panel = nil
    }

    private func fade() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.4; panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.panel?.orderOut(nil); self?.panel = nil
        }
    }
}

private struct CaptureHintView: View {
    var body: some View {
        HStack(spacing: Theme.s2) {
            Image(systemName: "keyboard")
            Text("Controlling — press ")
                + Text("⌃⌥⌘").font(.callout.weight(.bold).monospaced())
                + Text(" to release")
        }
        .font(.callout)
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s2 + 1)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
        .fixedSize()
    }
}
