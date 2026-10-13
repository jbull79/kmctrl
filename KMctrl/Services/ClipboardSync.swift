import AppKit

/// Mirrors text / PNG clipboard changes to the session peer over short-lived `.clipboard`
/// sessions — never on the control stream, so a large image can't stall mouse input.
///
/// Active only while a control session exists (either role). Both directions are pinned to
/// the session peer's identity fingerprint: outbound pushes verify the connected peer's
/// fingerprint before sending, and inbound payloads are accepted only from that fingerprint
/// while the session is active.
@MainActor
final class ClipboardSync {
    /// Deliver `payload` to `peer`, aborting unless the authenticated remote fingerprint
    /// equals the expected one. Injected so tests can run without a network.
    typealias Transport = (ClipboardPayload, Peer, String) async throws -> Void

    private let pasteboard: NSPasteboard
    private let pollInterval: TimeInterval
    private let isEnabled: () -> Bool
    private let transport: Transport

    private var state = ClipboardSyncState()
    private var timer: DispatchSourceTimer?
    /// Polling runs here, never on the main thread: reading the pasteboard change count is
    /// an XPC round-trip that can take ~100 ms on a managed Mac with clipboard monitoring,
    /// and the main thread is where window-mode capture receives mouse events.
    private let pollQueue = DispatchQueue(label: "kmctrl.clipboard.poll", qos: .utility)
    private var peerResolver: (() -> Peer?)?
    private var sessionFingerprint: String?
    private var sending = false
    private var pendingResend = false
    private var generation = 0   // invalidates in-flight completions from a previous session

    init(pasteboard: NSPasteboard = .general, pollInterval: TimeInterval = 0.5,
         isEnabled: @escaping () -> Bool, transport: @escaping Transport) {
        self.pasteboard = pasteboard
        self.pollInterval = pollInterval
        self.isEnabled = isEnabled
        self.transport = transport
    }

    /// Start/stop watching the local pasteboard for a session with the peer whose identity
    /// fingerprint is `sessionFingerprint`; `peerResolver` names the Mac to push to.
    func setActive(_ on: Bool, sessionFingerprint fp: String, peerResolver resolver: @escaping () -> Peer?) {
        timer?.cancel(); timer = nil
        generation += 1
        sending = false; pendingResend = false
        guard on else { peerResolver = nil; sessionFingerprint = nil; return }
        peerResolver = resolver
        sessionFingerprint = fp
        state = ClipboardSyncState()
        _ = state.noteLocalChange(count: pasteboard.changeCount)   // baseline only
        let t = DispatchSource.makeTimerSource(queue: pollQueue)
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(50))
        t.setEventHandler { [weak self, pasteboard] in
            let count = pasteboard.changeCount            // off-main XPC read
            Task { @MainActor in self?.poll(count: count) }
        }
        t.resume()
        timer = t
        DebugLog.log("clipboard: sync active")
    }

    private func poll(count: Int) {
        // Always consume the change count, even while disabled, so a copy made with sync
        // off is never pushed later when sync is turned back on.
        let changed = state.noteLocalChange(count: count)
        guard changed, isEnabled() else { return }
        sendCurrent()
    }

    /// Push whatever is on the pasteboard now. If a send is in flight, remember to re-read
    /// and push again when it finishes (coalesces bursts; never drops the latest copy).
    private func sendCurrent() {
        if sending { pendingResend = true; return }
        guard let payload = Self.readLocal(pasteboard), !payload.isEmpty else { return }
        guard payload.isWithinLimits else { DebugLog.log("clipboard: change too large, skipped", .warn); return }
        guard let peer = peerResolver?(), let fp = sessionFingerprint else {
            DebugLog.log("clipboard: session peer not discovered, skipped", .warn); return
        }
        sending = true
        let gen = generation
        Task { [weak self, transport] in
            do {
                try await transport(payload, peer, fp)
                DebugLog.log("clipboard: sent \(payload.text != nil ? "text" : "image") to \(peer.name)")
            } catch {
                DebugLog.log("clipboard: send failed — \(error.localizedDescription)", .warn)
            }
            await MainActor.run { self?.finishSend(generation: gen) }
        }
    }

    private func finishSend(generation gen: Int) {
        guard gen == generation else { return }   // session changed meanwhile
        sending = false
        if pendingResend { pendingResend = false; sendCurrent() }
    }

    /// Incoming payload → local pasteboard, only from the active session's peer.
    func receive(_ payload: ClipboardPayload, from fingerprint: String) {
        guard let fp = sessionFingerprint, fp == fingerprint else {
            DebugLog.log("clipboard: ignored push from a peer without an active session", .warn); return
        }
        guard isEnabled(), payload.isWithinLimits, !payload.isEmpty else { return }
        pasteboard.clearContents()
        if let t = payload.text, !t.isEmpty { pasteboard.setString(t, forType: .string) }
        if let img = payload.image, !img.isEmpty { pasteboard.setData(img, forType: .png) }
        state.noteOwnWrite(count: pasteboard.changeCount)
        DebugLog.log("clipboard: received \(payload.text != nil ? "text" : "image")")
    }

    /// Text first, else PNG (TIFF converted), else nothing we mirror.
    static func readLocal(_ pb: NSPasteboard) -> ClipboardPayload? {
        if let s = pb.string(forType: .string) { return ClipboardPayload(text: s, image: nil) }
        if let png = pb.data(forType: .png) { return ClipboardPayload(text: nil, image: png) }
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return ClipboardPayload(text: nil, image: png)
        }
        return nil
    }

    /// The real transport: connect, verify the peer is who the session authenticated, push.
    static func push(_ payload: ClipboardPayload, to peer: Peer, expectingFingerprint fp: String,
                     localName: String, allowed: Set<TransportStrategy>) async throws {
        let link = try await TransportConnector.shared.connect(to: peer, localName: localName, allowed: allowed)
        defer { link.cancel() }
        guard link.remoteFingerprint == fp else {
            DebugLog.log("clipboard: '\(peer.name)' is not the session peer (fingerprint mismatch) — not sent", .error)
            throw LinkError.authenticationFailed
        }
        try await link.sendSecureObject(SessionHello(kind: .clipboard))
        try await link.sendSecureObject(payload)
    }
}
