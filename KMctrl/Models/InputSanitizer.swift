import Foundation
import CoreGraphics

/// Bounds on what the other Mac may send. Everything that arrives over a link is checked here
/// before it reaches CGEvent, the screen arrangement or a log line: a single out-of-range value
/// (a key code above 65535, a scroll of 1e300, a NaN screen size) used to crash the app.
extension ControlEvent {
    /// Largest per-event pointer or scroll delta accepted. Real deltas are a few hundred at most.
    static let maxDelta = 10_000.0
    /// Modifier bits worth forwarding: the device-dependent left/right bits and the standard
    /// modifier masks. Anything above is not a modifier.
    static let flagsMask: UInt64 = 0x00FF_FFFF

    /// This event made safe to inject, or nil to drop it. Control-plane kinds pass through
    /// (they are handled before injection), but their numbers must still be finite.
    func sanitizedForInjection() -> ControlEvent? {
        guard dx.isFinite, dy.isFinite, scrollX.isFinite, scrollY.isFinite else { return nil }
        var e = self
        e.flags = flags & Self.flagsMask
        switch kind {
        case .mouseMove:
            e.dx = Self.clampDelta(dx); e.dy = Self.clampDelta(dy)
        case .scroll:
            e.scrollX = Self.clampDelta(scrollX); e.scrollY = Self.clampDelta(scrollY)
        case .mouseDown, .mouseUp:
            guard (0...2).contains(button) else { return nil }
        case .keyDown, .keyUp:
            guard (0...0xFF).contains(keyCode) else { return nil }
            if let c = chars, c.utf8.count > KeyCharacters.maxBytes { e.chars = nil }
        case .mediaKey:
            // Same list the controller forwards: never power, eject or caps lock.
            guard MediaKey.forwarded.contains(keyCode), button == 0 || button == 1 else { return nil }
        case .enterAt, .flagsChanged, .releaseAll, .hostStats, .ping, .wakeDisplay, .clipboard, .edgeSetup:
            break
        }
        return e
    }

    private static func clampDelta(_ v: Double) -> Double { min(max(v, -maxDelta), maxDelta) }
}

extension ScreenGeometry {
    /// A screen the other Mac could really have: finite, positive and of sane size. Anything
    /// else is ignored instead of being drawn, persisted or used for the hand-off.
    var isPlausible: Bool {
        let values = [x, y, width, height, widthMM, heightMM]
        guard values.allSatisfy(\.isFinite) else { return false }
        return abs(x) <= 1_000_000 && abs(y) <= 1_000_000
            && (1...100_000).contains(width) && (1...100_000).contains(height)
            && (1...10_000).contains(widthMM) && (1...10_000).contains(heightMM)
    }
}

/// The other Mac chooses its own name, so it is display text from a stranger until the
/// fingerprint is trusted: strip control, format (bidi override, zero-width) and line-break
/// characters, collapse whitespace and cap the length, so it can't fake extra lines in the
/// Allow prompt or the Diagnostics log.
enum PeerName {
    static let maxLength = 64

    static func sanitize(_ raw: String) -> String {
        var out = ""
        var lastWasSpace = false
        for scalar in raw.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned:
                continue
            case .spaceSeparator:
                if !lastWasSpace, !out.isEmpty { out.unicodeScalars.append(" ") }
                lastWasSpace = true
            default:
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        let trimmed = String(out.trimmingCharacters(in: .whitespaces).prefix(maxLength))
        return trimmed.isEmpty ? "Unknown" : trimmed
    }
}
