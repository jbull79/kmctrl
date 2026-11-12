import AppKit
import CoreGraphics
import Foundation

/// One display as the other Mac needs it for edge switching: where it sits in its own Mac's
/// global coordinates (points, top-left origin) and its physical size.
struct ScreenGeometry: Codable, Equatable {
    var x: Double, y: Double, width: Double, height: Double
    var widthMM: Double, heightMM: Double

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    /// A display's geometry from CoreGraphics. Displays that don't report a physical size
    /// (some projectors/adapters) fall back to 96 dpi.
    static func display(_ id: CGDirectDisplayID) -> ScreenGeometry {
        let b = CGDisplayBounds(id), mm = CGDisplayScreenSize(id)
        let fallback = 25.4 / 96
        return ScreenGeometry(x: b.minX, y: b.minY, width: b.width, height: b.height,
                              widthMM: mm.width > 0 ? mm.width : b.width * fallback,
                              heightMM: mm.height > 0 ? mm.height : b.height * fallback)
    }

    /// This Mac's main display — the one the other Mac's pointer arrives on.
    static func mainDisplay() -> ScreenGeometry { display(CGMainDisplayID()) }

    /// Assumed until the other Mac has told us its real screen (a 24" 2560×1440).
    static let assumedRemote = ScreenGeometry(x: 0, y: 0, width: 2560, height: 1440, widthMM: 527, heightMM: 296)
}

/// One of this Mac's monitors, for laying out the hand-off.
struct HandoffMonitor: Equatable {
    var id: UInt32
    var screen: ScreenGeometry
    var name: String = ""

    /// Every active monitor, in CoreGraphics order, named as System Settings names them.
    static func current() -> [HandoffMonitor] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let names = Dictionary(NSScreen.screens.compactMap { s in
            (s.deviceDescription[key] as? NSNumber).map { ($0.uint32Value, s.localizedName) }
        }, uniquingKeysWith: { a, _ in a })
        return ids.prefix(Int(count)).map { HandoffMonitor(id: $0, screen: .display($0), name: names[$0] ?? "") }
    }
}

/// A stretch of one of this Mac's monitor edges that leads to the other Mac's screen.
struct HandoffPortal: Equatable {
    var displayID: UInt32
    var display: CGRect                     // that monitor, in global points
    var edge: ScreenEdge                    // the edge the pointer leaves it through
    var span: ClosedRange<Double>           // along that edge, in this Mac's points
    var remoteSpan: ClosedRange<Double>     // along the other screen's facing side, in its points
    /// The side of the other Mac's screen this leads into, and back out of.
    var remoteSide: ScreenEdge { edge.opposite }
}

/// Where the other Mac's screen sits among this Mac's monitors, and every way across.
///
/// The screen is placed as in Settings: beside an *anchor* monitor's edge, slid along it in
/// millimetres, at the anchor's physical density (so a 24" beside a 49" lines up as on the
/// desk). That gives a *tile* in this Mac's global points. Every monitor edge facing the tile
/// (across a bezel-sized gap) is a *portal*, minus stretches that lead straight into another
/// monitor. Dropped on the seam between two monitors, the tile sits *between* them: both seam
/// edges lead to it. Positions along a portal map through the tile, so each crossing lands at
/// the matching place.
struct HandoffLayout: Equatable {
    /// Land this far inside an edge so the pointer isn't sitting on it.
    static let inset = 4.0
    /// A monitor this close to a side of the other screen (physically) is its neighbour —
    /// room for bezels and desk space, since macOS display positions aren't physical.
    static let maxGapMM = 150.0
    /// Shorter stretches (points) don't hand off.
    static let minStretch = 8.0
    /// Edges this close (points) touch.
    static let touch = 2.0

    let monitors: [HandoffMonitor]
    let remote: ScreenGeometry
    let anchorID: UInt32
    let edge: ScreenEdge
    let offsetMM: Double
    /// The other Mac's screen, placed in this Mac's global points.
    let tile: CGRect
    /// Anchor portals first.
    let portals: [HandoffPortal]
    /// The tile sits on a seam, between two of this Mac's monitors.
    let isBetweenMonitors: Bool

    init(monitors: [HandoffMonitor], remote: ScreenGeometry, anchorID: UInt32, edge: ScreenEdge, offsetMM: Double?) {
        self.monitors = monitors
        self.remote = remote
        self.edge = edge
        guard let anchor = monitors.first(where: { $0.id == anchorID }) ?? monitors.first else {
            self.anchorID = anchorID; self.offsetMM = offsetMM ?? 0
            tile = .zero; portals = []; isBetweenMonitors = false
            return
        }
        self.anchorID = anchor.id
        let offset = offsetMM ?? Self.centredOffsetMM(local: anchor.screen, remote: remote, edge: edge)
        self.offsetMM = offset
        let tile = Self.tile(beside: anchor.screen, edge: edge, offsetMM: offset, remote: remote)
        self.tile = tile
        let found = Self.portals(monitors: monitors, anchor: anchor, edge: edge, tile: tile, remote: remote)
        portals = found.portals
        isBetweenMonitors = found.between
    }

    static func centredOffsetMM(local: ScreenGeometry, remote: ScreenGeometry, edge: ScreenEdge) -> Double {
        let along = alongIsX(edge)
        return ((along ? local.widthMM : local.heightMM) - (along ? remote.widthMM : remote.heightMM)) / 2
    }

    /// Points per millimetre along a monitor's edge.
    static func pointsPerMM(_ g: ScreenGeometry, along edge: ScreenEdge) -> Double {
        alongIsX(edge) ? g.width / g.widthMM : g.height / g.heightMM
    }

    /// The other screen beside monitor `g`, flush against `edge`, in global points at `g`'s density.
    static func tile(beside g: ScreenGeometry, edge: ScreenEdge, offsetMM: Double, remote: ScreenGeometry) -> CGRect {
        let along = alongIsX(edge), k = pointsPerMM(g, along: edge)
        let len = (along ? remote.widthMM : remote.heightMM) * k
        let depth = (along ? remote.heightMM : remote.widthMM) * k
        let start = (along ? g.x : g.y) + offsetMM * k
        switch edge {
        case .top:    return CGRect(x: start, y: g.y - depth, width: len, height: depth)
        case .bottom: return CGRect(x: start, y: g.y + g.height, width: len, height: depth)
        case .left:   return CGRect(x: g.x - depth, y: start, width: depth, height: len)
        case .right:  return CGRect(x: g.x + g.width, y: start, width: depth, height: len)
        }
    }

    // MARK: Lookup

    func portal(on displayID: UInt32, edge: ScreenEdge) -> Int? {
        portals.firstIndex { $0.displayID == displayID && $0.edge == edge }
    }

    /// The first stretch of the edge the screen was dropped on (what v4 peers know about).
    var anchorPortal: Int? { portal(on: anchorID, edge: edge) }

    /// The portal a return came back through: the zone the other Mac named (v5), else the
    /// anchor edge (all a v4 Mac knows), else the first. nil when nothing leads across.
    func returnPortal(zone: Int?) -> Int? {
        if let zone, portals.indices.contains(zone) { return zone }
        return anchorPortal ?? (portals.isEmpty ? nil : 0)
    }

    /// One way back per portal, in the same order: the side of the other screen and its stretch.
    var returnZones: [ReturnZone] {
        portals.map { ReturnZone(edge: $0.remoteSide, span: [$0.remoteSpan.lowerBound, $0.remoteSpan.upperBound]) }
    }

    // MARK: Crossing

    /// The pointer leaves through portal `i` at `along` → where it enters the other screen.
    func entryPoint(portal i: Int, along a: Double) -> CGPoint {
        let r = remote.rect
        guard portals.indices.contains(i) else { return CGPoint(x: r.midX, y: r.midY) }
        let p = portals[i], alongX = Self.alongIsX(p.edge)
        let (rMin, rLen) = alongX ? (Double(r.minX), Double(r.width)) : (Double(r.minY), Double(r.height))
        let b = min(max(toRemote(a, alongX: alongX), rMin), rMin + rLen - 1)
        let n = Self.inset
        switch p.remoteSide {
        case .left:   return CGPoint(x: r.minX + n, y: b)
        case .right:  return CGPoint(x: r.maxX - 1 - n, y: b)
        case .top:    return CGPoint(x: b, y: r.minY + n)
        case .bottom: return CGPoint(x: b, y: r.maxY - 1 - n)
        }
    }

    /// The pointer leaves the other screen at `q` through portal `i`'s side → where it lands
    /// back here, just inside that portal's edge and within its stretch.
    func returnPoint(portal i: Int, leaving q: CGPoint) -> CGPoint {
        guard portals.indices.contains(i) else { return CGPoint(x: tile.midX, y: tile.midY) }
        let p = portals[i], alongX = Self.alongIsX(p.edge), d = p.display
        let r = remote.rect, t = Self.extent(tile, alongX: alongX)
        let (rMin, rLen) = alongX ? (Double(r.minX), Double(r.width)) : (Double(r.minY), Double(r.height))
        var a = t.lowerBound + ((alongX ? q.x : q.y) - rMin) / rLen * (t.upperBound - t.lowerBound)
        a = min(max(a, p.span.lowerBound), p.span.upperBound)
        let e = Self.extent(d, alongX: alongX)
        a = min(max(a, e.lowerBound), e.upperBound - 1)
        let n = Self.inset
        switch p.edge {
        case .top:    return CGPoint(x: a, y: d.minY + n)
        case .bottom: return CGPoint(x: a, y: d.maxY - 1 - n)
        case .left:   return CGPoint(x: d.minX + n, y: a)
        case .right:  return CGPoint(x: d.maxX - 1 - n, y: a)
        }
    }

    /// For the controlled Mac: this Mac's monitors, the tile and the portals.
    func snapshot() -> ArrangementSnapshot {
        ArrangementSnapshot(
            monitors: monitors.map { .init(screen: $0.screen, name: $0.name) },
            tile: [tile.minX, tile.minY, tile.width, tile.height],
            links: portals.compactMap { p in
                monitors.firstIndex { $0.id == p.displayID }.map {
                    .init(monitor: $0, edge: p.edge, span: [p.span.lowerBound, p.span.upperBound])
                }
            },
            between: isBetweenMonitors ? true : nil)
    }

    // MARK: Building

    private func toRemote(_ a: Double, alongX: Bool) -> Double {
        Self.toRemote(a, alongX: alongX, tile: tile, remote: remote)
    }

    private static func toRemote(_ a: Double, alongX: Bool, tile: CGRect, remote: ScreenGeometry) -> Double {
        let t = extent(tile, alongX: alongX)
        let (rMin, rLen) = alongX ? (remote.x, remote.width) : (remote.y, remote.height)
        return rMin + (a - t.lowerBound) / (t.upperBound - t.lowerBound) * rLen
    }

    static func alongIsX(_ e: ScreenEdge) -> Bool { e == .top || e == .bottom }

    static func extent(_ r: CGRect, alongX: Bool) -> ClosedRange<Double> {
        alongX ? Double(r.minX)...Double(r.maxX) : Double(r.minY)...Double(r.maxY)
    }

    /// Where an edge of `r` lies (x for left/right, y for top/bottom).
    static func line(_ r: CGRect, _ e: ScreenEdge) -> Double {
        switch e {
        case .left: return r.minX
        case .right: return r.maxX
        case .top: return r.minY
        case .bottom: return r.maxY
        }
    }

    /// `n` lies directly beyond `r`'s edge `e`, touching it.
    static func touchesBeyond(_ n: CGRect, _ r: CGRect, _ e: ScreenEdge) -> Bool {
        abs(line(n, e.opposite) - line(r, e)) <= touch
    }

    static func overlap(_ a: ClosedRange<Double>, _ b: ClosedRange<Double>) -> ClosedRange<Double>? {
        let lo = max(a.lowerBound, b.lowerBound), hi = min(a.upperBound, b.upperBound)
        return hi > lo ? lo...hi : nil
    }

    /// `base` minus `cuts`, keeping pieces long enough to hand off.
    static func subtract(_ base: ClosedRange<Double>, _ cuts: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var pieces = [base]
        for c in cuts {
            pieces = pieces.flatMap { p -> [ClosedRange<Double>] in
                guard overlap(p, c) != nil else { return [p] }
                var out: [ClosedRange<Double>] = []
                if c.lowerBound > p.lowerBound { out.append(p.lowerBound...c.lowerBound) }
                if c.upperBound < p.upperBound { out.append(c.upperBound...p.upperBound) }
                return out
            }
        }
        return pieces.filter { $0.upperBound - $0.lowerBound >= minStretch }
    }

    private static func portals(monitors: [HandoffMonitor], anchor: HandoffMonitor, edge: ScreenEdge,
                                tile: CGRect, remote: ScreenGeometry) -> (portals: [HandoffPortal], between: Bool) {
        let tileAlong = { (alongX: Bool) in extent(tile, alongX: alongX) }
        let a = anchor.screen.rect
        let anchorAlongX = alongIsX(edge)
        let tileLen = tileAlong(anchorAlongX).upperBound - tileAlong(anchorAlongX).lowerBound

        // Dropped on a seam: another monitor lies directly beyond the anchor edge, across most of
        // the tile. Those monitors' facing edges lead to the tile too, and don't block the anchor's.
        let seamNeighbours = monitors.filter { m in
            guard m.id != anchor.id, touchesBeyond(m.screen.rect, a, edge),
                  let o = overlap(extent(m.screen.rect, alongX: anchorAlongX), tileAlong(anchorAlongX)) else { return false }
            return o.upperBound - o.lowerBound >= tileLen / 2
        }
        let between = !seamNeighbours.isEmpty
        let seamIDs = Set(seamNeighbours.map(\.id))

        func make(_ m: HandoffMonitor, _ e: ScreenEdge, _ span: ClosedRange<Double>) -> HandoffPortal {
            let x = alongIsX(e)
            return HandoffPortal(displayID: m.id, display: m.screen.rect, edge: e, span: span,
                                 remoteSpan: toRemote(span.lowerBound, alongX: x, tile: tile, remote: remote)
                                    ... toRemote(span.upperBound, alongX: x, tile: tile, remote: remote))
        }

        let maxGap = maxGapMM * pointsPerMM(anchor.screen, along: edge)
        var found: [HandoffPortal] = []
        for m in monitors {
            let r = m.screen.rect
            for side in [ScreenEdge.top, .bottom, .left, .right] {          // the tile's side m may face
                let gap = side == .right || side == .bottom ? line(r, side.opposite) - line(tile, side)
                                                            : line(tile, side) - line(r, side.opposite)
                guard gap >= -touch, gap <= maxGap else { continue }
                let e = side.opposite                                         // m's edge facing the tile
                let x = alongIsX(e)
                guard let shared = overlap(extent(r, alongX: x), tileAlong(x)) else { continue }
                let exempt = between && m.id == anchor.id && e == edge
                let cuts = monitors.filter { n in
                    n.id != m.id && touchesBeyond(n.screen.rect, r, e) && !(exempt && seamIDs.contains(n.id))
                }.map { extent($0.screen.rect, alongX: x) }
                for piece in subtract(shared, cuts) { found.append(make(m, e, piece)) }
            }
        }
        for n in seamNeighbours {
            let e = edge.opposite
            if let shared = overlap(extent(n.screen.rect, alongX: anchorAlongX), tileAlong(anchorAlongX)),
               shared.upperBound - shared.lowerBound >= minStretch {
                found.append(make(n, e, shared))
            }
        }
        let isAnchor = { (p: HandoffPortal) in p.displayID == anchor.id && p.edge == edge }
        return (found.filter(isAnchor) + found.filter { !isAnchor($0) }, between)
    }
}
