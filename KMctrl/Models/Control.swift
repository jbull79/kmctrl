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
    /// Control protocol version the controlled Mac speaks. Absent from 0.7.x peers → 1.
    /// The host only sends v2 features (`chars`, `.mediaKey`, `.wakeDisplay`) when ≥ 2.
    var version: Int = 1

    init(accepted: Bool, reason: String = "", version: Int = 1) {
        self.accepted = accepted; self.reason = reason; self.version = version
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accepted = try c.decode(Bool.self, forKey: .accepted)
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
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
}

/// Sent client→host when the client's cursor hits its return edge → host takes back.
/// Also carries latency-probe echoes: when `pong` is set it is the host timestamp from a
/// `.ping`, bounced straight back so the host can compute round-trip time (not a return).
struct ControlReturn: Codable {
    var ok: Bool = true
    var pong: Double? = nil   // echoed host timestamp (ms) for the latency probe; nil = real return
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
}

// MARK: - Binary wire codec (feature-flagged fast path)

/// Thrown when a binary control frame is the wrong size or names an unknown kind.
enum ControlCodecError: Error { case malformed }

extension ControlEventKind {
    /// Stable 1-byte wire codes for the binary codec. APPEND-ONLY — never reorder or
    /// remove, or you break decoding of frames from other app versions.
    static let wireOrder: [ControlEventKind] = [
        .mouseMove, .mouseDown, .mouseUp, .scroll,
        .keyDown, .keyUp, .flagsChanged, .releaseAll, .hostStats, .ping
    ]
    var wireByte: UInt8 { UInt8(ControlEventKind.wireOrder.firstIndex(of: self) ?? 0) }
    init?(wireByte: UInt8) {
        let i = Int(wireByte)
        guard i < ControlEventKind.wireOrder.count else { return nil }
        self = ControlEventKind.wireOrder[i]
    }
}

private func appendBE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
    var be = value.bigEndian
    withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
}

private func readBE<T: FixedWidthInteger>(_ bytes: [UInt8], _ offset: Int, _: T.Type) -> T {
    var v: T = 0
    for i in 0..<MemoryLayout<T>.size { v = (v << 8) | T(bytes[offset + i]) }
    return v
}

extension ControlEvent {
    /// Fixed 44-byte layout (big-endian; Doubles as their IEEE-754 bit pattern):
    /// kind[1] button[1] keyCode[2] flags[8] dx[8] dy[8] scrollX[8] scrollY[8].
    static let binarySize = 44

    /// Encode without JSON reflection or per-event heap churn — the whole point of the
    /// binary control flag. Paired with `init(binary:)`; round-trip is exact.
    func encodedBinary() -> Data {
        var d = Data(capacity: ControlEvent.binarySize)
        d.append(kind.wireByte)
        d.append(UInt8(truncatingIfNeeded: button))
        appendBE(&d, UInt16(truncatingIfNeeded: keyCode))
        appendBE(&d, flags)
        appendBE(&d, dx.bitPattern)
        appendBE(&d, dy.bitPattern)
        appendBE(&d, scrollX.bitPattern)
        appendBE(&d, scrollY.bitPattern)
        return d
    }

    init(binary data: Data) throws {
        guard data.count == ControlEvent.binarySize else { throw ControlCodecError.malformed }
        let b = [UInt8](data)
        guard let kind = ControlEventKind(wireByte: b[0]) else { throw ControlCodecError.malformed }
        self.init(kind: kind)
        button  = Int(b[1])
        keyCode = Int(readBE(b, 2, UInt16.self))
        flags   = readBE(b, 4, UInt64.self)
        dx      = Double(bitPattern: readBE(b, 12, UInt64.self))
        dy      = Double(bitPattern: readBE(b, 20, UInt64.self))
        scrollX = Double(bitPattern: readBE(b, 28, UInt64.self))
        scrollY = Double(bitPattern: readBE(b, 36, UInt64.self))
    }
}
