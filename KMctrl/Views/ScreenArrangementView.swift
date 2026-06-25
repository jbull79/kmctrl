import SwiftUI
import AppKit

/// Visual hand-off arrangement: draws this Mac's real monitor layout and a draggable
/// "Remote Mac" tile. Drag the remote to a side of your desktop — the adjacent edge becomes
/// the hand-off edge (no need to pick left/right/top/bottom by hand). Multi-monitor aware.
struct ScreenArrangementView: View {
    @Binding var edge: ScreenEdge

    @State private var dragEdge: ScreenEdge?      // live during a drag
    private var current: ScreenEdge { dragEdge ?? edge }

    var body: some View {
        GeometryReader { geo in
            let L = layout(in: geo.size)
            ZStack {
                // This Mac's monitors
                ForEach(Array(L.monitors.enumerated()), id: \.offset) { i, m in
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.cardFill)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairline))
                        .overlay(Text(L.monitors.count == 1 ? "This Mac" : "Screen \(i + 1)")
                            .font(.caption2).foregroundStyle(.secondary))
                        .frame(width: m.width, height: m.height)
                        .position(x: m.midX, y: m.midY)
                }
                // Remote Mac tile on the chosen side
                let r = remoteRect(in: geo.size, edge: current)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.85))
                    .overlay(Image(systemName: "desktopcomputer").foregroundStyle(.white))
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                    .shadow(radius: 2)
                    .gesture(
                        DragGesture(coordinateSpace: .local)
                            .onChanged { v in dragEdge = sideOf(point: v.location, desktop: L.desktop) }
                            .onEnded { _ in if let e = dragEdge { edge = e }; dragEdge = nil }
                    )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: 150)
        .padding(.vertical, 4)
    }

    // MARK: Geometry

    private struct Layout { var desktop: CGRect; var monitors: [CGRect] }

    /// Map the real NSScreen arrangement into the canvas, leaving a margin on every side so
    /// the remote tile has somewhere to sit.
    private func layout(in size: CGSize) -> Layout {
        let screens = NSScreen.screens.map(\.frame)
        let union = screens.reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull, union.width > 0, union.height > 0 else {
            let d = CGRect(x: size.width * 0.32, y: size.height * 0.3, width: size.width * 0.36, height: size.height * 0.4)
            return Layout(desktop: d, monitors: [d])
        }
        let margin: CGFloat = 0.30   // fraction reserved around the desktop for the remote
        let availW = size.width * (1 - margin), availH = size.height * (1 - margin)
        let scale = min(availW / union.width, availH / union.height)
        let drawnW = union.width * scale, drawnH = union.height * scale
        let ox = (size.width - drawnW) / 2, oy = (size.height - drawnH) / 2
        // NSScreen is y-up; flip so the top monitor draws at the top.
        func map(_ f: CGRect) -> CGRect {
            let x = (f.minX - union.minX) * scale + ox
            let y = (union.maxY - f.maxY) * scale + oy
            return CGRect(x: x, y: y, width: f.width * scale, height: f.height * scale)
        }
        return Layout(desktop: map(union), monitors: screens.map(map))
    }

    private func remoteRect(in size: CGSize, edge: ScreenEdge) -> CGRect {
        let L = layout(in: size)
        let d = L.desktop
        let w = min(d.width, size.width * 0.22), h = min(d.height, size.height * 0.22)
        let gap: CGFloat = 10
        switch edge {
        case .right:  return CGRect(x: min(size.width - w, d.maxX + gap), y: d.midY - h / 2, width: w, height: h)
        case .left:   return CGRect(x: max(0, d.minX - gap - w), y: d.midY - h / 2, width: w, height: h)
        case .top:    return CGRect(x: d.midX - w / 2, y: max(0, d.minY - gap - h), width: w, height: h)
        case .bottom: return CGRect(x: d.midX - w / 2, y: min(size.height - h, d.maxY + gap), width: w, height: h)
        }
    }

    /// Which side of the desktop a dragged point falls on (canvas y grows downward).
    private func sideOf(point p: CGPoint, desktop d: CGRect) -> ScreenEdge {
        let dx = p.x - d.midX, dy = p.y - d.midY
        if abs(dx) >= abs(dy) { return dx >= 0 ? .right : .left }
        return dy < 0 ? .top : .bottom
    }
}
