import SwiftUI
import AppKit

/// Visual hand-off arrangement: draws this Mac's real monitor layout and a draggable
/// "Remote Mac" tile. Drop the remote next to the **specific monitor** (and edge) the other
/// Mac physically sits beside — that monitor's edge becomes the hand-off, in the right place
/// for a multi-monitor setup. Sets both the edge and the display id.
struct ScreenArrangementView: View {
    @Binding var edge: ScreenEdge
    @Binding var displayID: UInt32

    @State private var dragEdge: ScreenEdge?
    @State private var dragDisplay: UInt32?
    private var liveEdge: ScreenEdge { dragEdge ?? edge }
    private var liveDisplay: UInt32 { dragDisplay ?? displayID }

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
                if let target = L.monitors.first(where: { $0.id == liveDisplay }) ?? L.monitors.first {
                    let r = remoteRect(beside: target.rect, edge: liveEdge, in: geo.size)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.85))
                        .overlay(Image(systemName: "desktopcomputer").foregroundStyle(.white))
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .shadow(radius: 2)
                        .gesture(
                            DragGesture(coordinateSpace: .local)
                                .onChanged { v in
                                    if let hit = nearest(to: v.location, in: L.monitors) {
                                        dragDisplay = hit.id
                                        dragEdge = edgeOf(point: v.location, rect: hit.rect)
                                    }
                                }
                                .onEnded { _ in
                                    if let e = dragEdge { edge = e }
                                    if let d = dragDisplay { displayID = d }
                                    dragEdge = nil; dragDisplay = nil
                                }
                        )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: 160)
        .padding(.vertical, 4)
    }

    // MARK: Model

    private struct Monitor: Identifiable { let id: UInt32; let rect: CGRect; let label: String }

    private func cgID(_ s: NSScreen) -> UInt32 {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func layout(in size: CGSize) -> (monitors: [Monitor], desktop: CGRect) {
        let screens = NSScreen.screens
        let union = screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull, union.width > 0, union.height > 0 else {
            let d = CGRect(x: size.width * 0.32, y: size.height * 0.3, width: size.width * 0.36, height: size.height * 0.4)
            return ([Monitor(id: 0, rect: d, label: "This Mac")], d)
        }
        let margin: CGFloat = 0.34
        let scale = min(size.width * (1 - margin) / union.width, size.height * (1 - margin) / union.height)
        let dw = union.width * scale, dh = union.height * scale
        let ox = (size.width - dw) / 2, oy = (size.height - dh) / 2
        func map(_ f: CGRect) -> CGRect {                 // NSScreen is y-up; flip for the canvas
            CGRect(x: (f.minX - union.minX) * scale + ox,
                   y: (union.maxY - f.maxY) * scale + oy,
                   width: f.width * scale, height: f.height * scale)
        }
        let mons = screens.enumerated().map { i, s in
            Monitor(id: cgID(s), rect: map(s.frame), label: screens.count == 1 ? "This Mac" : "Screen \(i + 1)")
        }
        return (mons, map(union))
    }

    private func remoteRect(beside m: CGRect, edge: ScreenEdge, in size: CGSize) -> CGRect {
        let w = min(m.width, size.width * 0.2), h = min(m.height, size.height * 0.2)
        let gap: CGFloat = 8
        switch edge {
        case .right:  return CGRect(x: min(size.width - w, m.maxX + gap), y: m.midY - h / 2, width: w, height: h)
        case .left:   return CGRect(x: max(0, m.minX - gap - w), y: m.midY - h / 2, width: w, height: h)
        case .top:    return CGRect(x: m.midX - w / 2, y: max(0, m.minY - gap - h), width: w, height: h)
        case .bottom: return CGRect(x: m.midX - w / 2, y: min(size.height - h, m.maxY + gap), width: w, height: h)
        }
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
