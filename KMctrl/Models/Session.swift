import Foundation

/// What a connection is for, sent right after the (authenticated) handshake. KMctrl has one
/// kind: the keyboard/mouse control stream, which also carries the clipboard hand-off,
/// arrangement and logs. Anything else is refused.
enum SessionKind: String, Codable {
    case control
}

/// One clipboard update pushed to trusted peers. Text and/or a PNG image.
struct ClipboardPayload: Codable {
    var text: String?
    var image: Data?

    static let maxTextBytes = 1_048_576
    static let maxImageBytes = 8_388_608

    var isEmpty: Bool { (text ?? "").isEmpty && (image ?? Data()).isEmpty }
    var isWithinLimits: Bool {
        (text?.utf8.count ?? 0) <= Self.maxTextBytes && (image?.count ?? 0) <= Self.maxImageBytes
    }
}

/// Sent by the initiator immediately after the handshake to select the session kind.
struct SessionHello: Codable {
    var kind: SessionKind
    var version: Int = 1
    /// True when the controller is reconnecting by itself after losing the link, not because
    /// someone clicked Control. Absent from older peers, which read as a deliberate connect.
    var reconnect: Bool? = nil

    /// Control-stream protocol version this build speaks. v2 (0.8.0) adds typed characters on
    /// key downs (`ControlEvent.chars`), `.mediaKey` and `.wakeDisplay`; v3 (0.8.13) adds the
    /// clipboard hand-off on the control link (`.clipboard` event, `ControlReturn.clipboard`);
    /// v4 (0.8.16) adds edge-switch geometry (`ControlAck.screen`, `ControlSetup.returnArea/
    /// returnSpan` (dropped in 1.0), `.enterAt`, `ControlReturn.at`); v5 (0.8.23) adds a hand-off at every edge
    /// touching the other Mac (`ControlSetup.returnZones/arrangement`, `ControlReturn.zone`) —
    /// optional JSON fields that v4 peers ignore. v6 (0.8.24) lets either Mac ask the other for
    /// its diagnostics log (`.logRequest`/`.log`, `ControlReturn.log/logRequest`) — sent only to
    /// v6 peers, since an older one drops the session on the unknown kind or reads the reply as
    /// a return of control.
    /// v7 (1.0) drops the experimental binary codec: control frames are JSON only, so 1.0 and
    /// 0.8.x don't mix.
    /// The controlled Mac echoes its own version in `ControlAck.version`.
    static let currentControlVersion = 7
    /// The oldest protocol a session runs with. Below it the two Macs refuse each other with a
    /// message asking to update, instead of carrying per-feature fallbacks for old releases.
    /// Raise it (with `minimumAppVersion`) when a protocol change can't be optional.
    static let minimumControlVersion = 7
    static let minimumAppVersion = "1.0"

    static func isSupported(controlVersion v: Int) -> Bool { v >= minimumControlVersion }

    init(kind: SessionKind, version: Int = 1, reconnect: Bool? = nil) {
        self.kind = kind; self.version = version; self.reconnect = reconnect
    }
    /// A hello without a version (0.7.x) reads as v1, so it gets the "update" refusal rather
    /// than a dropped connection.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(SessionKind.self, forKey: .kind)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        reconnect = try c.decodeIfPresent(Bool.self, forKey: .reconnect)
    }

    /// What the controlled Mac tells a controller that is too old to connect.
    static func olderControllerReason(thisMac: String) -> String {
        "\(thisMac) needs KMctrl \(minimumAppVersion) or later on the Mac controlling it. Update KMctrl on this Mac, then connect again."
    }
    /// What the controller says when the Mac it reached is too old.
    static func olderControlledReason(other: String) -> String {
        "\(other) runs an older KMctrl. Update it to \(minimumAppVersion) or later, then connect again."
    }
}

