import CoreGraphics
import Foundation

enum EdgeGeometry {
    /// Is `p` on `edge` of `d` (the last pixel row/column), within `d`'s span on the other axis?
    /// CG global coordinates: origin top-left, y grows downward.
    static func isOnEdge(_ p: CGPoint, of d: CGRect, edge: ScreenEdge) -> Bool {
        switch edge {
        case .right:  return p.x >= d.maxX - 1 && p.y >= d.minY && p.y < d.maxY
        case .left:   return p.x <= d.minX     && p.y >= d.minY && p.y < d.maxY
        case .top:    return p.y <= d.minY     && p.x >= d.minX && p.x < d.maxX
        case .bottom: return p.y >= d.maxY - 1 && p.x >= d.minX && p.x < d.maxX
        }
    }
}

/// Controlling Mac: has the pointer *rested* on the hand-off edge of the chosen display? Fed by
/// polling the pointer position, which needs neither Accessibility nor Input Monitoring (unlike
/// edge mode's event tap). Fires once, then waits for the pointer to leave the edge.
struct EdgeDwell {
    static let dwell: TimeInterval = 0.2
    private var since: TimeInterval?
    private var armed = true

    mutating func update(point: CGPoint, display: CGRect, edge: ScreenEdge, now: TimeInterval) -> Bool {
        guard EdgeGeometry.isOnEdge(point, of: display, edge: edge) else { since = nil; armed = true; return false }
        guard armed else { return false }
        let start = since ?? now
        since = start
        guard now - start >= Self.dwell else { return false }
        armed = false; since = nil
        return true
    }
}

/// Controlled Mac: hand control back only after a deliberate push past the return edge, and never
/// while a button is held — so dragging a window to the edge or reaching for the Dock doesn't drop
/// control.
struct EdgeReturnTrigger {
    static let pushNeeded = 40.0
    private var pushed = 0.0

    /// `intended` is where the move would have put the cursor before clamping to `bounds`.
    mutating func shouldReturn(cursor: CGPoint, intended: CGPoint, bounds b: CGRect,
                               edge: ScreenEdge, buttonHeld: Bool) -> Bool {
        guard !buttonHeld, EdgeGeometry.isOnEdge(cursor, of: b, edge: edge) else { pushed = 0; return false }
        let over: Double
        switch edge {
        case .right:  over = intended.x - (b.maxX - 1)
        case .left:   over = b.minX - intended.x
        case .top:    over = b.minY - intended.y
        case .bottom: over = intended.y - (b.maxY - 1)
        }
        pushed += max(0, over)
        guard pushed >= Self.pushNeeded else { return false }
        pushed = 0
        return true
    }
}
