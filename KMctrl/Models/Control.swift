import Foundation

/// One input event forwarded host → client over a `.control` session. Mouse moves are
/// relative deltas (the client keeps its own virtual cursor), so both capture modes
/// (edge-tap and focused-window) feed the same stream.
enum ControlEventKind: String, Codable {
    case mouseMove
    case mouseDown
    case mouseUp
    case scroll
    case keyDown
    case keyUp
    case flagsChanged
    case releaseAll   // disconnect / focus loss — client releases everything held
    case hostStats    // host→client diagnostics (dx=moves/s sent, dy=timer ticks/s); not injected
    case ping         // host→client latency probe; client echoes dx (host timestamp) in ControlReturn.pong; not injected
    case mediaKey     // host→client media/aux key (keyCode = NX key type, button = 1 down / 0 up); protocol v2
    case wakeDisplay  // host→client: wake a sleeping display (IOPM user activity); not injected; protocol v2
    case clipboard    // host→client clipboard hand-off (payload in `clipboard`); protocol v2
    case enterAt      // host→client: edge switch entered here (dx, dy = controlled Mac's global points); protocol v4
    case edgeSetup    // host→client: updated return edge/stretch after a monitor change (payload in `setup`); protocol v4
    case logRequest   // host→client: send me your diagnostics log (answered in ControlReturn.log); protocol v6
    case log          // host→client: this Mac's diagnostics log, asked for by ControlReturn.logRequest (payload in `log`); protocol v6
}

/// Which screen edge of the controller hands off to the other Mac.
enum ScreenEdge: String, Codable, CaseIterable, Identifiable {
    case right, left, top, bottom
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var opposite: ScreenEdge {
        switch self {
        case .right: return .left
        case .left: return .right
        case .top: return .bottom
        case .bottom: return .top
        }
    }
}

/// Controlled Mac's reply to a control request: whether it will accept input.
struct ControlAck: Codable {
    var accepted: Bool
    var reason: String = ""
    /// Control protocol version the controlled Mac speaks. Absent from 0.7.x peers → 1, which
    /// the controller refuses (see `SessionHello.minimumControlVersion`).
    var version: Int = 1
    /// The controlled Mac's main display (v4), so the controller can line up the edge switch.
    var screen: ScreenGeometry? = nil

    init(accepted: Bool, reason: String = "", version: Int = 1, screen: ScreenGeometry? = nil) {
        self.accepted = accepted; self.reason = reason; self.version = version; self.screen = screen
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accepted = try c.decode(Bool.self, forKey: .accepted)
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        screen = try c.decodeIfPresent(ScreenGeometry.self, forKey: .screen)
    }
}

/// Sent host→client right after accept: tells the client which of ITS edges means
/// "give control back" (the opposite of the host's hand-off edge).
struct ControlSetup: Codable {
    var hostEdge: ScreenEdge
    /// Only edge (bump) mode auto-returns control when the client cursor hits its edge.
    /// Window (click-to-capture) mode must NOT — otherwise dragging to a screen edge
    /// silently drops control. Defaults false so older hosts don't arm auto-return.
    var autoReturn: Bool = false
    /// The controlled Mac's display that faces the controller (its points); returns are watched
    /// inside it. Absent → the whole desktop.
    var returnArea: ScreenGeometry? = nil
    /// Every way back: one zone per stretch of the controller's monitor edges that leads to the
    /// controlled Mac. None → the whole side opposite `hostEdge`, so control can always come back.
    var returnZones: [ReturnZone]? = nil
    /// v5: the controller's monitors and where the controlled Mac sits among them, shown
    /// read-only on the controlled Mac. Sanitised before use.
    var arrangement: ArrangementSnapshot? = nil
}

/// v5: one way back to the controller — a side of the controlled Mac's screen and the stretch
/// along it (its points) that faces one of the controller's monitors.
struct ReturnZone: Codable, Equatable {
    var edge: ScreenEdge
    var span: [Double]
}

/// Sent client→host when the client's cursor hits its return edge → host takes back.
/// Also carries latency-probe echoes: when `pong` is set it is the host timestamp from a
/// `.ping`, bounced straight back so the host can compute round-trip time (not a return).
struct ControlReturn: Codable {
    var ok: Bool = true
    var pong: Double? = nil   // echoed host timestamp (ms) for the latency probe; nil = real return
    /// Controlled Mac's clipboard handed back when control is released (never a return).
    var clipboard: ClipboardPayload? = nil

    /// v4: where the pointer left the controlled Mac (its global points) on a return, so the
    /// controller can land its pointer at the matching place.
    var at: [Double]? = nil
    /// v4: the controlled Mac's screen, re-sent when its monitors change (never a return).
    var screen: ScreenGeometry? = nil
    /// Which of the setup's `returnZones` the pointer pushed through on a return, so the
    /// controller lands on the matching monitor. Absent or unknown → the anchor edge.
    var zone: Int? = nil
    /// v6: the controlled Mac's diagnostics log, answering a `.logRequest` (never a return).
    var log: LogBundle? = nil
    /// v6: the controlled Mac asks for the controller's log, answered with a `.log` event (never a return).
    var logRequest: Bool? = nil

    init(ok: Bool = true, pong: Double? = nil, clipboard: ClipboardPayload? = nil, at: [Double]? = nil,
         screen: ScreenGeometry? = nil, zone: Int? = nil, log: LogBundle? = nil, logRequest: Bool? = nil) {
        self.ok = ok; self.pong = pong; self.clipboard = clipboard; self.at = at; self.screen = screen; self.zone = zone
        self.log = log; self.logRequest = logRequest
    }
    /// A frame with a payload is not a return-of-control signal.
    var isReturnSignal: Bool { pong == nil && clipboard == nil && screen == nil && log == nil && logRequest == nil }
}

struct ControlEvent: Codable {
    var kind: ControlEventKind
    var dx: Double = 0
    var dy: Double = 0
    var button: Int = 0          // 0 left, 1 right, 2 other
    var scrollX: Double = 0
    var scrollY: Double = 0
    var keyCode: Int = 0         // virtual keycode
    var flags: UInt64 = 0        // CGEventFlags raw (modifier state)
    /// Typed characters for a `.keyDown` (layout-independent typing). nil = keycode only.
    /// Omitted from JSON when nil, keeping plain frames small.
    var chars: String? = nil
    /// Clipboard hand-off payload for `.clipboard` events.
    var clipboard: ClipboardPayload? = nil
    /// Updated return setup for `.edgeSetup` events (v4).
    var setup: ControlSetup? = nil
    /// The controller's diagnostics log for `.log` events (v6).
    var log: LogBundle? = nil


    enum CodingKeys: String, CodingKey { case kind, dx, dy, button, scrollX, scrollY, keyCode, flags, chars, clipboard, setup, log }

    // Custom encode so `chars` is omitted (not `null`) when nil; decode stays synthesized.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(dx, forKey: .dx)
        try c.encode(dy, forKey: .dy)
        try c.encode(button, forKey: .button)
        try c.encode(scrollX, forKey: .scrollX)
        try c.encode(scrollY, forKey: .scrollY)
        try c.encode(keyCode, forKey: .keyCode)
        try c.encode(flags, forKey: .flags)
        try c.encodeIfPresent(chars, forKey: .chars)
        try c.encodeIfPresent(clipboard, forKey: .clipboard)
        try c.encodeIfPresent(setup, forKey: .setup)
        try c.encodeIfPresent(log, forKey: .log)
    }
}
