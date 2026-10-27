import SwiftUI
import AppKit

/// Visual hand-off arrangement: this Mac's real monitor layout plus the other Mac's screen, all
/// drawn to physical size (mm), so a 24" beside a 49" looks — and maps — the way the desk does.
/// Drop the other Mac next to the **specific monitor** and edge it sits beside, then slide it
/// along that edge to where it really is. Sets the edge, the display id and the offset (mm).
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
        GeometryReader { geo in
            let L = layout(in: geo.size)
            ZStack {
                ForEach(L.monitors) { m in
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.cardFill)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(m.id == liveDisplay ? Color.accentColor : Theme.hairline,
                                          lineWidth: m.id == liveDisplay ? 2 : 1))
                        .overlay(Text(m.label).font(.caption2).foregroundStyle(.secondary))
                        .frame(width: m.rect.width, height: m.rect.height)
                        .position(x: m.rect.midX, y: m.rect.midY)
                }
                if L.target != nil {
                    let r = L.remote
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.85))
                        .overlay(VStack(spacing: 1) {
                            Image(systemName: "desktopcomputer")
                            Text(remote == nil ? "\(Self.inches(other))″?" : "\(Self.inches(other))″").font(.caption2)
                        }.foregroundStyle(.white))
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .shadow(radius: 2)
                        .gesture(
                            DragGesture(coordinateSpace: .local)
                                .onChanged { v in
                                    guard let hit = nearest(to: v.location, in: L.monitors) else { return }
                                    let e = edgeOf(point: v.location, rect: hit.rect)
                                    dragDisplay = hit.id; dragEdge = e
                                    dragOffset = offset(draggedTo: v.location, beside: hit, edge: e, scale: L.scale)
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
        .padding(.vertical, 4)
    }

    // MARK: Model

    private struct Monitor: Identifiable {
        let id: UInt32
        let screen: ScreenGeometry          // global points + physical size
        var rect: CGRect = .zero            // on the canvas
        let label: String
    }

    private static func inches(_ g: ScreenGeometry) -> Int {
        Int((hypot(g.widthMM, g.heightMM) / 25.4).rounded())
    }

    private func cgID(_ s: NSScreen) -> UInt32 {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Points per mm along the given edge of a monitor (its own density).
    private func pointsPerMM(_ g: ScreenGeometry, along edge: ScreenEdge) -> Double {
        edge == .top || edge == .bottom ? g.width / g.widthMM : g.height / g.heightMM
    }

    private func liveOffset(beside g: ScreenGeometry) -> Double {
        dragOffset ?? offsetMM ?? HandoffGeometry.centredOffsetMM(local: g, remote: other, edge: liveEdge)
    }

    /// The other Mac's screen beside monitor `g`, in global points at `g`'s physical density.
    private func remoteRect(beside g: ScreenGeometry, edge: ScreenEdge, offsetMM: Double) -> CGRect {
        let along = edge == .top || edge == .bottom
        let k = pointsPerMM(g, along: edge)
        let len = (along ? other.widthMM : other.heightMM) * k
        let depth = (along ? other.heightMM : other.widthMM) * k
        let start = (along ? g.x : g.y) + offsetMM * k
        let gap = 40.0
        switch edge {
        case .top:    return CGRect(x: start, y: g.y - gap - depth, width: len, height: depth)
        case .bottom: return CGRect(x: start, y: g.y + g.height + gap, width: len, height: depth)
        case .left:   return CGRect(x: g.x - gap - depth, y: start, width: depth, height: len)
        case .right:  return CGRect(x: g.x + g.width + gap, y: start, width: depth, height: len)
        }
    }

    private func layout(in size: CGSize) -> (monitors: [Monitor], target: Monitor?, remote: CGRect, scale: Double) {
        let screens = NSScreen.screens
        var mons = screens.enumerated().map { i, s in
            Monitor(id: cgID(s), screen: ScreenGeometry.display(cgID(s)),
                    label: screens.count == 1 ? "This Mac" : "Screen \(i + 1)")
        }
        guard let target = mons.first(where: { $0.id == liveDisplay }) ?? mons.first else {
            return ([], nil, .zero, 1)
        }
        let tile = remoteRect(beside: target.screen, edge: liveEdge, offsetMM: liveOffset(beside: target.screen))
        // Scale from the monitors padded by the tile's largest possible size on every side, so
        // the canvas doesn't rescale (and jump under the cursor) as the tile is dragged around.
        let union = mons.reduce(CGRect.null) { $0.union($1.screen.rect) }
        let k = mons.map { max(pointsPerMM($0.screen, along: .top), pointsPerMM($0.screen, along: .left)) }.max() ?? 1
        let pad = max(other.widthMM, other.heightMM) * k + 60
        let world = union.insetBy(dx: -pad, dy: -pad)
        let scale = min(size.width / world.width, size.height / world.height)
        let ox = (size.width - world.width * scale) / 2, oy = (size.height - world.height * scale) / 2
        func map(_ r: CGRect) -> CGRect {          // global points are already y-down, like the canvas
            CGRect(x: (r.minX - world.minX) * scale + ox, y: (r.minY - world.minY) * scale + oy,
                   width: r.width * scale, height: r.height * scale)
        }
        for i in mons.indices { mons[i].rect = map(mons[i].screen.rect) }
        return (mons, mons.first { $0.id == target.id }, map(tile), scale)
    }

    /// Offset (mm along the edge) for the tile centred on the drag location, kept so at least a
    /// fifth of it still touches the monitor.
    private func offset(draggedTo p: CGPoint, beside m: Monitor, edge: ScreenEdge, scale: Double) -> Double {
        let along = edge == .top || edge == .bottom
        let pxPerMM = pointsPerMM(m.screen, along: edge) * scale
        let lenMM = along ? other.widthMM : other.heightMM
        let monitorMM = along ? m.screen.widthMM : m.screen.heightMM
        let start = along ? m.rect.minX : m.rect.minY
        let raw = ((along ? p.x : p.y) - lenMM * pxPerMM / 2 - start) / pxPerMM
        return min(max(raw, -lenMM * 0.8), monitorMM - lenMM * 0.2)
    }

    /// Monitor whose rect is nearest the point (by clamped distance).
    private func nearest(to p: CGPoint, in monitors: [Monitor]) -> Monitor? {
        monitors.min {
            dist(p, $0.rect) < dist(p, $1.rect)
        }
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
