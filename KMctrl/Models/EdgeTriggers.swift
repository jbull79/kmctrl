import CoreGraphics
import Foundation

enum EdgeGeometry {
    /// Is `p` on `edge` of `d` — its outermost row/column, *inside* the display — and, if
    /// `span` is given, within that stretch along the edge? A pointer that has moved onto a
    /// neighbouring monitor (e.g. one above) is beyond the edge, not on it. CG global
    /// coordinates: origin top-left, y grows downward.
    static func isOnEdge(_ p: CGPoint, of d: CGRect, edge: ScreenEdge, span: ClosedRange<Double>? = nil) -> Bool {
        let onRow: Bool, along: Double
        switch edge {
        case .right:  onRow = p.x >= d.maxX - 1 && p.x < d.maxX     && p.y >= d.minY && p.y < d.maxY; along = p.y
        case .left:   onRow = p.x >= d.minX     && p.x < d.minX + 1 && p.y >= d.minY && p.y < d.maxY; along = p.y
        case .top:    onRow = p.y >= d.minY     && p.y < d.minY + 1 && p.x >= d.minX && p.x < d.maxX; along = p.x
        case .bottom: onRow = p.y >= d.maxY - 1 && p.y < d.maxY     && p.x >= d.minX && p.x < d.maxX; along = p.x
        }
        return onRow && (span?.contains(along) ?? true)
    }
}

/// Controlling Mac: has the pointer *rested* on the hand-off edge of the chosen display? Fed by
/// polling the pointer position, which needs neither Accessibility nor Input Monitoring (unlike
/// edge mode's event tap). Fires once, then waits for the pointer to leave the edge.
struct EdgeDwell {
    static let dwell: TimeInterval = 0.2
    private var since: TimeInterval?
    private var armed = true

    /// `span` limits it to the stretch of the edge the other Mac's screen touches.
    mutating func update(point: CGPoint, display: CGRect, edge: ScreenEdge,
                         span: ClosedRange<Double>? = nil, now: TimeInterval) -> Bool {
        guard EdgeGeometry.isOnEdge(point, of: display, edge: edge, span: span) else { since = nil; armed = true; return false }
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
    /// `span` limits it to the stretch of the edge that faces the controlling Mac's screen.
    mutating func shouldReturn(cursor: CGPoint, intended: CGPoint, bounds b: CGRect,
                               edge: ScreenEdge, buttonHeld: Bool, span: ClosedRange<Double>? = nil) -> Bool {
        guard !buttonHeld, EdgeGeometry.isOnEdge(cursor, of: b, edge: edge, span: span) else { pushed = 0; return false }
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
