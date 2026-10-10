import AppKit

/// Mirrors text / PNG clipboard changes to the session peer over short-lived `.clipboard`
/// sessions — never on the control stream, so a large image can't stall mouse input. Active
/// only while a control session exists (either role); trusted peers only on the receiving end.
@MainActor
final class ClipboardSync {
    private let settings: AppSettings
    private let localName: () -> String
    private var state = ClipboardSyncState()
    private var timer: Timer?
    private var peerResolver: (() -> Peer?)?
    private var sending = false
    private var pendingResend = false

    init(settings: AppSettings, localName: @escaping () -> String) {
        self.settings = settings
        self.localName = localName
    }

    /// Start/stop watching the local pasteboard. `peerResolver` names the Mac to push to.
    func setActive(_ on: Bool, peerResolver: @escaping () -> Peer?) {
        self.peerResolver = on ? peerResolver : nil
        timer?.invalidate(); timer = nil
        guard on else { return }
        state = ClipboardSyncState()
        _ = state.noteLocalChange(count: NSPasteboard.general.changeCount)   // baseline only
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        DebugLog.log("clipboard: sync active")
    }

    private func poll() {
        guard settings.clipboardSyncEnabled,
              state.noteLocalChange(count: NSPasteboard.general.changeCount) else { return }
        guard let payload = Self.readLocal(), !payload.isEmpty else { return }
        guard payload.isWithinLimits else { DebugLog.log("clipboard: change too large, skipped", .warn); return }
        send(payload)
    }

    private func send(_ payload: ClipboardPayload) {
        guard !sending else { pendingResend = true; return }
        guard let peer = peerResolver?() else {
            DebugLog.log("clipboard: peer not discovered, skipped", .warn); return
        }
        sending = true
        let name = localName()
        let allowed = settings.enabledTransportStrategies
        Task { [weak self] in
            do {
                let link = try await TransportConnector.shared.connect(to: peer, localName: name, allowed: allowed)
                defer { link.cancel() }
                try await link.sendSecureObject(SessionHello(kind: .clipboard))
                try await link.sendSecureObject(payload)
                DebugLog.log("clipboard: sent \(payload.text != nil ? "text" : "image") to \(peer.name)")
            } catch {
                DebugLog.log("clipboard: send failed — \(error.localizedDescription)", .warn)
            }
            await MainActor.run { self?.finishSend() }
        }
    }

    private func finishSend() {
        sending = false
        if pendingResend { pendingResend = false; poll() }
    }

    /// Incoming payload from a trusted peer → write to the local pasteboard.
    func receive(_ payload: ClipboardPayload) {
        guard settings.clipboardSyncEnabled, payload.isWithinLimits, !payload.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if let t = payload.text, !t.isEmpty { pb.setString(t, forType: .string) }
        if let img = payload.image, !img.isEmpty { pb.setData(img, forType: .png) }
        state.noteOwnWrite(count: pb.changeCount)
        DebugLog.log("clipboard: received \(payload.text != nil ? "text" : "image")")
    }

    /// Text first, else PNG (TIFF converted), else nothing we mirror.
    static func readLocal() -> ClipboardPayload? {
        let pb = NSPasteboard.general
        if let s = pb.string(forType: .string) { return ClipboardPayload(text: s, image: nil) }
        if let png = pb.data(forType: .png) { return ClipboardPayload(text: nil, image: png) }
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return ClipboardPayload(text: nil, image: png)
        }
        return nil
    }
}
