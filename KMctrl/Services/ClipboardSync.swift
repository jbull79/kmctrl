import AppKit

/// Clipboard follows the keyboard. Nothing is polled: the controlling Mac hands its
/// clipboard over when it starts controlling, and the controlled Mac hands its clipboard
/// back when control is released. Both travel over the existing, authenticated control
/// link (no extra connections — a managed Mac's firewall may refuse inbound ones).
///
/// Inbound payloads are accepted only from the fingerprint of the session peer while the
/// session is active (plus a short grace after it ends, for the release hand-back).
@MainActor
final class ClipboardSync {
    /// Deliver `payload` to the session peer whose fingerprint is given. Wired by the app to
    /// the control link (either direction); injected so tests can run without a network.
    typealias Transport = (ClipboardPayload, String) async throws -> Void

    private let pasteboard: NSPasteboard
    private let isEnabled: () -> Bool
    private let receiveGrace: TimeInterval
    var transport: Transport

    private var active = false
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
    func setActive(_ on: Bool, sessionFingerprint fp: String) {
        if on {
            active = true
            sessionFingerprint = fp
            acceptUntil = nil
            lastPushed = nil
        } else {
            // Grace starts only on the transition from active; a repeated deactivate must
            // not restart the clock, and a never-active instance accepts nothing.
            if active { acceptUntil = Date().addingTimeInterval(receiveGrace) }
            active = false
        }
    }

    /// Hand-off: push the current clipboard to the session peer, unless it is unchanged
    /// since the last push or is what the peer gave us.
    func pushNow(reason: String) {
        guard isEnabled(), active, let fp = sessionFingerprint else { return }
        let count = pasteboard.changeCount
        guard count != lastOwnWrite, count != lastPushed else { return }
        guard let payload = Self.readLocal(pasteboard), !payload.isEmpty else { return }
        guard payload.isWithinLimits else { DebugLog.log("clipboard: too large to hand off, skipped", .warn); return }
        lastPushed = count
        Task { [transport] in
            do {
                try await transport(payload, fp)
                DebugLog.log("clipboard: handed \(payload.text != nil ? "text" : "image") over (\(reason))")
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
        if !active {               // session over: only within grace
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
}
