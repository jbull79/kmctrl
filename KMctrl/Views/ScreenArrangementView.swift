import SwiftUI
import AppKit

/// Visual hand-off arrangement: this Mac's real monitor layout plus the other Mac's screen, the
/// other screen drawn to physical size (mm) at the monitor it sits beside, so a 24" beside a 49"
/// looks — and maps — the way the desk does. Drop the other Mac next to the **specific monitor**
/// and edge it sits beside (or on the seam between two monitors), then slide it along that edge
/// to where it really is. Sets the edge, the display id and the offset (mm). Every monitor edge
/// that ends up next to it is highlighted: each one hands off.
struct ScreenArrangementView: View {
    @Binding var edge: ScreenEdge
    @Binding var displayID: UInt32
    @Binding var offsetMM: Double?
    /// The other Mac's screen as last reported (nil → assumed 24" until it connects once).
    var remote: ScreenGeometry?

    @State private var dragEdge: ScreenEdge?
    @State private var dragDisplay: UInt32?
    @State private var dragOffset: Double?
    private var liveEdge: ScreenEdge { dragEdge ?? edge }
    private var liveDisplay: UInt32 { dragDisplay ?? displayID }
    private var other: ScreenGeometry { remote ?? .assumedRemote }

    var body: some View {
        let monitors = Self.monitors()
        let layout = HandoffLayout(monitors: monitors, remote: other, anchorID: liveDisplay, edge: liveEdge,
                                   offsetMM: liveOffset(monitors))
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let c = canvas(layout, in: geo.size)
                ZStack {
                    ArrangementDrawing(canvas: c, tileLabel: remote == nil ? "\(Self.inches(other))″?" : "\(Self.inches(other))″",
                                       tileIcon: "desktopcomputer")
                    if let t = c.tile {
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: t.width, height: t.height)
                            .position(x: t.midX, y: t.midY)
                            .gesture(
                                DragGesture(coordinateSpace: .local)
                                    .onChanged { v in
                                        guard let hit = nearest(to: v.location, in: c.monitors) else { return }
                                        let e = edgeOf(point: v.location, rect: hit.rect)
                                        dragDisplay = hit.id; dragEdge = e
                                        dragOffset = offset(draggedTo: v.location, beside: hit, edge: e, scale: c.scale)
                                    }
                                    .onEnded { _ in
                                        if let e = dragEdge { edge = e }
                                        if let d = dragDisplay { displayID = d }
                                        if let o = dragOffset { offsetMM = o }
                                        dragEdge = nil; dragDisplay = nil; dragOffset = nil
                                    }
                            )
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(height: 170)
            Text(caption(layout))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: Model

    /// This Mac's monitors, in NSScreen order (labels match "Screen 1, 2…" there).
    private static func monitors() -> [HandoffMonitor] {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.compactMap { s in
            guard let id = (s.deviceDescription[key] as? NSNumber)?.uint32Value else { return nil }
            return HandoffMonitor(id: id, screen: .display(id), name: s.localizedName)
        }
    }

    private static func inches(_ g: ScreenGeometry) -> Int {
        let d = (hypot(g.widthMM, g.heightMM) / 25.4).rounded()
        return d.isFinite && d >= 0 && d < 10_000 ? Int(d) : 0   // never trap on a bad size
    }

    private func label(_ i: Int, _ m: HandoffMonitor, count: Int) -> String {
        count == 1 ? "This Mac" : (m.name.isEmpty ? "Screen \(i + 1)" : m.name)
    }

    private func liveOffset(_ monitors: [HandoffMonitor]) -> Double {
        if let o = dragOffset ?? offsetMM { return o }
        let g = (monitors.first { $0.id == liveDisplay } ?? monitors.first)?.screen ?? .assumedRemote
        return HandoffLayout.centredOffsetMM(local: g, remote: other, edge: liveEdge)
    }

    private func caption(_ layout: HandoffLayout) -> String {
        guard !layout.portals.isEmpty else {
            return "The other Mac doesn't touch any edge here — drag it next to a monitor."
        }
        let names = Dictionary(layout.monitors.enumerated().map { ($1.id, label($0, $1, count: layout.monitors.count)) },
                               uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        let ways = layout.portals.compactMap { p -> String? in
            let s = "\(names[p.displayID] ?? "a screen")’s \(p.edge.label.lowercased()) edge"
            return seen.insert(s).inserted ? s : nil
        }
        let between = layout.isBetweenMonitors ? " It sits between two screens: crossing that seam switches." : ""
        return "Move off the highlighted edge\(ways.count == 1 ? "" : "s") (\(ways.joined(separator: ", "))) to take control; ⌃⌥⌘ releases.\(between)"
    }

    private func canvas(_ layout: HandoffLayout, in size: CGSize) -> ArrangementCanvas {
        // Pad the monitors by the tile's largest possible size on every side, so the canvas
        // doesn't rescale (and jump under the cursor) as the tile is dragged around.
        let union = layout.monitors.reduce(CGRect.null) { $0.union($1.screen.rect) }
        let k = layout.monitors.map { max(HandoffLayout.pointsPerMM($0.screen, along: .top),
                                          HandoffLayout.pointsPerMM($0.screen, along: .left)) }.max() ?? 1
        let pad = max(other.widthMM, other.heightMM) * k + 60
        return ArrangementCanvas(
            size: size, world: union.isNull ? .zero : union.insetBy(dx: -pad, dy: -pad),
            monitors: layout.monitors.enumerated().map { i, m in
                .init(id: m.id, screen: m.screen, label: label(i, m, count: layout.monitors.count),
                      highlighted: m.id == layout.anchorID)
            },
            tile: layout.monitors.isEmpty ? nil : layout.tile,
            links: layout.portals.compactMap { p in
                layout.monitors.firstIndex { $0.id == p.displayID }.map { .init(monitor: $0, edge: p.edge, span: p.span) }
            },
            insertedToward: layout.isBetweenMonitors ? layout.edge : nil)
    }

    /// Offset (mm along the edge) for the tile centred on the drag location, kept so at least a
    /// fifth of it still touches the monitor.
    private func offset(draggedTo p: CGPoint, beside m: ArrangementCanvas.Monitor, edge: ScreenEdge, scale: Double) -> Double {
        let along = HandoffLayout.alongIsX(edge)
        let pxPerMM = HandoffLayout.pointsPerMM(m.screen, along: edge) * scale
        let lenMM = along ? other.widthMM : other.heightMM
        let monitorMM = along ? m.screen.widthMM : m.screen.heightMM
        let start = along ? m.rect.minX : m.rect.minY
        let raw = ((along ? p.x : p.y) - lenMM * pxPerMM / 2 - start) / pxPerMM
        return min(max(raw, -lenMM * 0.8), monitorMM - lenMM * 0.2)
    }

    /// Monitor whose rect is nearest the point (by clamped distance).
    private func nearest(to p: CGPoint, in monitors: [ArrangementCanvas.Monitor]) -> ArrangementCanvas.Monitor? {
        monitors.min { dist(p, $0.rect) < dist(p, $1.rect) }
    }
    private func dist(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let cx = min(max(p.x, r.minX), r.maxX), cy = min(max(p.y, r.minY), r.maxY)
        return hypot(p.x - cx, p.y - cy)
    }

    /// Which edge of `rect` the point is closest to.
    private func edgeOf(point p: CGPoint, rect r: CGRect) -> ScreenEdge {
        let d: [(ScreenEdge, CGFloat)] = [
            (.left, abs(p.x - r.minX)), (.right, abs(p.x - r.maxX)),
            (.top, abs(p.y - r.minY)), (.bottom, abs(p.y - r.maxY)),
        ]
        return d.min { $0.1 < $1.1 }!.0
    }
}

/// Monitors, the other Mac's screen and the edges between them, fitted to a canvas. Global points
/// are y-down, like the canvas.
struct ArrangementCanvas {
    struct Monitor: Identifiable {
        let id: UInt32
        let screen: ScreenGeometry          // global points + physical size
        var rect: CGRect = .zero            // on the canvas, where it really is (for dragging)
        var drawn: CGRect = .zero           // on the canvas, moved aside for an inserted tile
        let label: String
        let highlighted: Bool

        init(id: UInt32, screen: ScreenGeometry, label: String, highlighted: Bool) {
            self.id = id; self.screen = screen; self.label = label; self.highlighted = highlighted
        }
    }
    /// A stretch of monitor `monitor`'s edge that hands off, in global points.
    struct Link {
        let monitor: Int
        let edge: ScreenEdge
        let span: ClosedRange<Double>
    }

    private(set) var monitors: [Monitor]
    private(set) var tile: CGRect?
    /// Each link as a segment on the canvas.
    private(set) var segments: [(CGPoint, CGPoint)] = []
    let scale: Double

    /// `world` (global points) is what fits the canvas; nil → the monitors and tile, padded.
    /// `insertedToward`: the tile sits on a seam between monitors, pushing those beyond it this
    /// way — drawn moved aside so it shows in the gap (dragging still uses the real places).
    init(size: CGSize, world: CGRect?, monitors: [Monitor], tile: CGRect?, links: [Link], insertedToward: ScreenEdge? = nil) {
        let real = monitors.map { $0.screen.rect }
        let placed = tile.flatMap { t in insertedToward.map { Self.spread(real, around: t, toward: $0) } } ?? real
        let fit: CGRect = world ?? {
            let u = placed.reduce(tile ?? .null) { $0.union($1) }
            let pad = max(u.width, u.height) * 0.04
            return u.isNull ? .zero : u.insetBy(dx: -pad, dy: -pad)
        }()
        let w = fit.width > 0 && fit.height > 0 ? fit : CGRect(x: 0, y: 0, width: 1, height: 1)
        let scale = min(size.width / w.width, size.height / w.height)
        let ox = (size.width - w.width * scale) / 2, oy = (size.height - w.height * scale) / 2
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: (x - w.minX) * scale + ox, y: (y - w.minY) * scale + oy)
        }
        func map(_ r: CGRect) -> CGRect {
            let o = point(r.minX, r.minY)
            return CGRect(x: o.x, y: o.y, width: r.width * scale, height: r.height * scale)
        }
        self.scale = scale
        self.monitors = monitors.enumerated().map { i, m in
            var m = m; m.rect = map(real[i]); m.drawn = map(placed[i]); return m
        }
        self.tile = tile.map(map)
        segments = links.compactMap { l in
            guard placed.indices.contains(l.monitor) else { return nil }
            let d = placed[l.monitor], s = Self.shifted(l.span, by: l.edge, real[l.monitor], placed[l.monitor])
            switch l.edge {
            case .top:    return (point(s.lowerBound, d.minY), point(s.upperBound, d.minY))
            case .bottom: return (point(s.lowerBound, d.maxY), point(s.upperBound, d.maxY))
            case .left:   return (point(d.minX, s.lowerBound), point(d.minX, s.upperBound))
            case .right:  return (point(d.maxX, s.lowerBound), point(d.maxX, s.upperBound))
            }
        }
    }

    /// A stretch along a monitor's edge, following the monitor where it was moved aside.
    private static func shifted(_ s: ClosedRange<Double>, by edge: ScreenEdge, _ from: CGRect, _ to: CGRect) -> ClosedRange<Double> {
        let d = HandoffLayout.alongIsX(edge) ? to.minX - from.minX : to.minY - from.minY
        return (s.lowerBound + d)...(s.upperBound + d)
    }

    /// Move the monitors the tile overlaps — and every monitor beyond them — `toward` far enough
    /// to clear it.
    static func spread(_ rects: [CGRect], around t: CGRect, toward e: ScreenEdge) -> [CGRect] {
        let hit = rects.filter { let i = $0.intersection(t); return !i.isNull && i.width > 1 && i.height > 1 }
        guard !hit.isEmpty else { return rects }
        let touch = HandoffLayout.touch
        switch e {
        case .right:
            let from = hit.map(\.minX).min()!, by = hit.map { t.maxX - $0.minX }.max()!
            return rects.map { $0.minX >= from - touch ? $0.offsetBy(dx: by, dy: 0) : $0 }
        case .left:
            let upTo = hit.map(\.maxX).max()!, by = hit.map { $0.maxX - t.minX }.max()!
            return rects.map { $0.maxX <= upTo + touch ? $0.offsetBy(dx: -by, dy: 0) : $0 }
        case .bottom:
            let from = hit.map(\.minY).min()!, by = hit.map { t.maxY - $0.minY }.max()!
            return rects.map { $0.minY >= from - touch ? $0.offsetBy(dx: 0, dy: by) : $0 }
        case .top:
            let upTo = hit.map(\.maxY).max()!, by = hit.map { $0.maxY - t.minY }.max()!
            return rects.map { $0.maxY <= upTo + touch ? $0.offsetBy(dx: 0, dy: -by) : $0 }
        }
    }
}

/// Draws an `ArrangementCanvas`: monitors, the other screen (inset a little so a flush tile still
/// reads as its own screen) and the edges that hand off.
struct ArrangementDrawing: View {
    let canvas: ArrangementCanvas
    let tileLabel: String
    let tileIcon: String

    var body: some View {
        ZStack {
            ForEach(canvas.monitors) { m in
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.cardFill)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(m.highlighted ? Color.accentColor : Theme.hairline,
                                      lineWidth: m.highlighted ? 2 : 1))
                    .overlay(Text(m.label).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.5).padding(.horizontal, 3))
                    .frame(width: m.drawn.width, height: m.drawn.height)
                    .position(x: m.drawn.midX, y: m.drawn.midY)
            }
            if let t = canvas.tile {
                let r = t.insetBy(dx: min(3, t.width / 4), dy: min(3, t.height / 4))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.85))
                    .overlay(VStack(spacing: 1) {
                        Image(systemName: tileIcon)
                        Text(tileLabel).font(.caption2).lineLimit(1).minimumScaleFactor(0.5)
                    }.foregroundStyle(.white))
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                    .shadow(radius: 2)
            }
            Path { path in
                for (a, b) in canvas.segments { path.move(to: a); path.addLine(to: b) }
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }
}
