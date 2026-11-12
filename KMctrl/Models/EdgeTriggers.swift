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

/// Where the pointer crossed to the other Mac: which portal, and the position along its edge.
struct PortalHit: Equatable {
    var portal: Int
    var along: Double
}

/// Controlling Mac: should the pointer go to the other Mac? Fed by polling the pointer position,
/// which needs neither Accessibility nor Input Monitoring (unlike edge mode's event tap), or by
/// the tap itself with no dwell.
///
/// - On an outer edge the pointer stops, so it has to *rest* on a portal's stretch for `dwell`.
///   That fires once, then waits for the pointer to leave the edge.
/// - On a seam between two monitors the pointer doesn't stop, so *crossing* a portal's stretch
///   into the next monitor fires at once, at the place it crossed.
/// - Never while a mouse button is held: dragging a window to an edge or across a seam stays here.
struct PortalWatch {
    static let defaultDwell: TimeInterval = 0.2
    let dwell: TimeInterval
    private var previous: CGPoint?
    private var restingOn: Int?
    private var restingSince: TimeInterval = 0
    private var armed = true

    init(dwell: TimeInterval = PortalWatch.defaultDwell) { self.dwell = dwell }

    /// Drop the last position — after a session the pointer is warped back, and the point from
    /// before must not read as a crossing.
    mutating func forget() { previous = nil; restingOn = nil; armed = true }

    mutating func update(point p: CGPoint, buttonsHeld: Bool, portals: [HandoffPortal], now: TimeInterval) -> PortalHit? {
        let prev = previous
        previous = p
        guard !buttonsHeld else { restingOn = nil; return nil }
        if let prev, let hit = Self.crossing(from: prev, to: p, portals: portals) {
            restingOn = nil; armed = false
            return hit
        }
        guard let i = portals.firstIndex(where: { EdgeGeometry.isOnEdge(p, of: $0.display, edge: $0.edge, span: $0.span) }) else {
            restingOn = nil; armed = true
            return nil
        }
        guard armed else { return nil }
        if restingOn != i { restingOn = i; restingSince = now }
        guard now - restingSince >= dwell else { return nil }
        armed = false; restingOn = nil
        return PortalHit(portal: i, along: HandoffLayout.alongIsX(portals[i].edge) ? p.x : p.y)
    }

    /// The pointer moved from `a`, inside a portal's monitor, past that portal's edge to `b`:
    /// where along the edge it crossed, if that is on the portal's stretch.
    static func crossing(from a: CGPoint, to b: CGPoint, portals: [HandoffPortal]) -> PortalHit? {
        for (i, p) in portals.enumerated() {
            let d = p.display
            guard d.contains(a), !d.contains(b) else { continue }
            let alongX = HandoffLayout.alongIsX(p.edge)
            let from = alongX ? a.y : a.x, to = alongX ? b.y : b.x
            let line = HandoffLayout.line(d, p.edge)
            let beyond: Bool
            switch p.edge {
            case .right, .bottom: beyond = to >= line
            case .left, .top:     beyond = to < line
            }
            guard beyond, to != from else { continue }
            let t = min(max((line - from) / (to - from), 0), 1)
            let along = alongX ? a.x + t * (b.x - a.x) : a.y + t * (b.y - a.y)
            if p.span.contains(along) { return PortalHit(portal: i, along: along) }
        }
        return nil
    }
}

/// Controlled Mac: every way back to the controller, one `EdgeReturnTrigger` each, answering
/// with the zone the pointer pushed through.
struct ReturnWatch {
    struct Zone: Equatable {
        var edge: ScreenEdge                    // side of this Mac's screen
        var span: ClosedRange<Double>?          // stretch along it (nil = the whole side)
    }
    static let maxZones = 32

    let zones: [Zone]
    /// The controller speaks v5 and wants the zone index with each return.
    let reportsZone: Bool
    private var triggers: [EdgeReturnTrigger]

    init(zones: [Zone], reportsZone: Bool) {
        self.zones = zones
        self.reportsZone = reportsZone
        triggers = Array(repeating: EdgeReturnTrigger(), count: zones.count)
    }

    /// From the controller's setup: its v5 zones, or the single edge an older controller sends.
    /// nil when the controller doesn't want control handed back at an edge (window mode).
    init?(setup: ControlSetup) {
        guard setup.autoReturn else { return nil }
        let v5 = (setup.returnZones ?? []).lazy.compactMap { z in Self.span(z.span).map { Zone(edge: z.edge, span: $0) } }
        let zones = Array(v5.prefix(Self.maxZones))
        if zones.isEmpty {
            self.init(zones: [Zone(edge: setup.hostEdge.opposite, span: setup.returnSpan.flatMap(Self.span))], reportsZone: false)
        } else {
            self.init(zones: zones, reportsZone: true)
        }
    }

    private static func span(_ v: [Double]) -> ClosedRange<Double>? {
        v.count == 2 && v.allSatisfy(\.isFinite) && v[0] <= v[1] ? v[0]...v[1] : nil
    }

    /// `intended` is where the move would have put the cursor before clamping to `bounds`.
    mutating func check(cursor: CGPoint, intended: CGPoint, bounds: CGRect, buttonHeld: Bool) -> Int? {
        var fired: Int?
        for i in zones.indices {
            let hit = triggers[i].shouldReturn(cursor: cursor, intended: intended, bounds: bounds, edge: zones[i].edge,
                                               buttonHeld: buttonHeld, span: zones[i].span)
            if hit, fired == nil { fired = i }
        }
        return fired
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

/// Controlling Mac, while capturing: the pointer is decoupled from the mouse and must stay at
/// `anchor`. If it moves, macOS dropped the lock (seen when an edge switch activates KMctrl just
/// as capture starts), so capture puts it back and re-locks — at most every `relockGap`, since a
/// warp briefly suppresses the hardware mouse. After `maxRelocks` tries in one capture it gives
/// up (`.gaveUp`, once): when re-locking doesn't stick — seen after the controlling Mac switched
/// Space — a pointer yanked back twice a second is worse than one that drifts.
struct PointerLock {
    enum State: Equatable { case held, drifted, relock, gaveUp }
    static let tolerance = 2.0
    static let relockGap = 0.5
    static let maxRelocks = 3
    let anchor: CGPoint
    private var lastRelock = -Double.infinity
    private var relocks = 0
    private var gaveUp = false

    init(anchor: CGPoint) { self.anchor = anchor }

    mutating func check(_ p: CGPoint, now: Double) -> State {
        guard abs(p.x - anchor.x) > Self.tolerance || abs(p.y - anchor.y) > Self.tolerance else { return .held }
        guard !gaveUp, now - lastRelock >= Self.relockGap else { return .drifted }
        guard relocks < Self.maxRelocks else { gaveUp = true; return .gaveUp }
        relocks += 1
        lastRelock = now
        return .relock
    }
}

/// Which app gets focus back when an edge switch ends: the app in front when it began, unless
/// that was KMctrl or a menu-bar agent (Ice grabs focus when the pointer rests on the menu bar,
/// which is where a top-edge switch waits) — then the last ordinary app used.
enum FocusRestore {
    static func target<App: Equatable>(front: App?, frontIsRegular: Bool, lastRegular: App?, me: App) -> App? {
        if let front, front != me, frontIsRegular { return front }
        if let lastRegular, lastRegular != me { return lastRegular }
        return nil
    }
}
