import AppKit

/// Clipboard follows the keyboard. Nothing is polled: the controlling Mac pushes its
/// clipboard when it starts controlling, and the controlled Mac pushes its clipboard back
/// when control is released (chord, hotkey, Disconnect, or the link dropping). Each push is
/// a short-lived `.clipboard` session — never on the control stream.
///
/// Both directions are pinned to the session peer's identity fingerprint: pushes verify the
/// connected peer before sending, and inbound payloads are accepted only from that peer
/// while the session is active (plus a short grace after it ends, for the release push).
@MainActor
final class ClipboardSync {
    /// Deliver `payload` to `peer`, aborting unless the authenticated remote fingerprint
    /// equals the expected one. Injected so tests can run without a network.
    typealias Transport = (ClipboardPayload, Peer, String) async throws -> Void

    private let pasteboard: NSPasteboard
    private let isEnabled: () -> Bool
    private let receiveGrace: TimeInterval
    private let transport: Transport

    private var peerResolver: (() -> Peer?)?
    private var sessionFingerprint: String?
    private var acceptUntil: Date?        // after the session ends, accept the peer's release push until here
    private var lastOwnWrite: Int?        // changeCount produced by writing a received payload
    private var lastPushed: Int?          // changeCount of the last payload we pushed

    init(pasteboard: NSPasteboard = .general, isEnabled: @escaping () -> Bool,
         receiveGrace: TimeInterval = 5, transport: @escaping Transport) {
        self.pasteboard = pasteboard
        self.isEnabled = isEnabled
        self.receiveGrace = receiveGrace
        self.transport = transport
    }

    /// Bind to a session with the peer whose identity fingerprint is `fp`. Deactivating
    /// keeps accepting that peer's push for `receiveGrace` seconds.
    func setActive(_ on: Bool, sessionFingerprint fp: String, peerResolver resolver: @escaping () -> Peer?) {
        if on {
            peerResolver = resolver
            sessionFingerprint = fp
            acceptUntil = nil
            lastPushed = nil
        } else {
            // Grace starts only on the transition from active; a repeated deactivate must
            // not restart the clock, and a never-active instance accepts nothing.
            if peerResolver != nil { acceptUntil = Date().addingTimeInterval(receiveGrace) }
            peerResolver = nil
        }
    }

    /// Hand-off: push the current clipboard to the session peer, unless it is unchanged
    /// since the last push or is what the peer gave us.
    func pushNow(reason: String) {
        guard isEnabled(), let peer = peerResolver?(), let fp = sessionFingerprint else { return }
        let count = pasteboard.changeCount
        guard count != lastOwnWrite, count != lastPushed else { return }
        guard let payload = Self.readLocal(pasteboard), !payload.isEmpty else { return }
        guard payload.isWithinLimits else { DebugLog.log("clipboard: too large to hand off, skipped", .warn); return }
        lastPushed = count
        Task { [transport] in
            do {
                try await transport(payload, peer, fp)
                DebugLog.log("clipboard: handed \(payload.text != nil ? "text" : "image") to \(peer.name) (\(reason))")
            } catch {
                DebugLog.log("clipboard: hand-off failed — \(error.localizedDescription)", .warn)
            }
        }
    }

    /// Incoming payload → local pasteboard, only from the session peer (or within the
    /// post-session grace for its release push).
    func receive(_ payload: ClipboardPayload, from fingerprint: String) {
        guard let fp = sessionFingerprint, fp == fingerprint else {
            DebugLog.log("clipboard: ignored push from a peer without an active session", .warn); return
        }
        if peerResolver == nil {   // session over: only within grace
            guard let until = acceptUntil, Date() < until else {
                sessionFingerprint = nil; acceptUntil = nil   // grace over: forget the peer entirely
                DebugLog.log("clipboard: ignored push after session grace", .warn); return
            }
        }
        guard isEnabled(), payload.isWithinLimits, !payload.isEmpty else { return }
        pasteboard.clearContents()
        if let t = payload.text, !t.isEmpty { pasteboard.setString(t, forType: .string) }
        if let img = payload.image, !img.isEmpty { pasteboard.setData(img, forType: .png) }
        lastOwnWrite = pasteboard.changeCount
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
