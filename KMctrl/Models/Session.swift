import Foundation

/// What a connection is for, negotiated right after the (authenticated) handshake.
/// This is the start of the multiplexing layer: today `transfer` and `status`, with
/// `sync` (workbook) and `control` (KVM) to follow.
enum SessionKind: String, Codable {
    case transfer
    case status
    case control   // keyboard/mouse (KVM) input stream
    case sync      // workbook sync
    case clipboard // clipboard mirroring (text/image)
}

/// One clipboard update pushed to trusted peers. Text and/or a PNG image.
struct ClipboardPayload: Codable {
    var text: String?
    var image: Data?
}

/// Sent by the initiator immediately after the handshake to select the session kind.
struct SessionHello: Codable {
    var kind: SessionKind
    var version: Int = 1
}

/// Responder's reply to a `.sync` hello: whether it will sync with this peer. Sent before
/// any workbook data is exchanged, so an untrusted/declined peer never receives note
/// metadata.
struct SyncAck: Codable {
    var accepted: Bool
    var reason: String = ""
}

/// A device's capability/readiness, exchanged over the authenticated, encrypted link
/// (user-/app-initiated between trusted peers — not a background service).
struct StatusReport: Codable {
    var deviceName: String
    var appVersion: String
    /// Keyboard/mouse control (KVM) readiness — all input permissions granted.
    var control: Bool
    var controlAccessibility: Bool
    var controlInputMonitoring: Bool
    var controlEventTap: Bool
    /// Workbook sync working. False until the feature is built.
    var workbook: Bool
    /// Clipboard sync enabled on that device. Optional so reports from older peers (which
    /// don't send it) decode as "unknown".
    var clipboard: Bool?
}
