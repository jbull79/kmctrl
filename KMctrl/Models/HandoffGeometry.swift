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

/// Where the other Mac's screen sits along this Mac's hand-off edge — measured in millimetres,
/// so a 24" beside a 49" lines up physically — and the mapping of pointer positions across
/// that shared edge in both directions.
struct HandoffGeometry: Equatable {
    var local: ScreenGeometry      // this Mac's hand-off display
    var remote: ScreenGeometry     // the other Mac's display beside it, in that Mac's coordinates
    var edge: ScreenEdge           // edge of `local` the remote sits on
    var offsetMM: Double           // remote's start along that edge, from the edge's left/top end

    /// Land this far inside an edge so the pointer isn't sitting on it.
    static let inset = 4.0

    static func centredOffsetMM(local: ScreenGeometry, remote: ScreenGeometry, edge: ScreenEdge) -> Double {
        let along = edge == .top || edge == .bottom
        return ((along ? local.widthMM : local.heightMM) - (along ? remote.widthMM : remote.heightMM)) / 2
    }

    private var alongIsX: Bool { edge == .top || edge == .bottom }
    private func axis(_ r: CGRect) -> (min: Double, len: Double) { alongIsX ? (r.minX, r.width) : (r.minY, r.height) }
    private func mm(_ g: ScreenGeometry) -> Double { alongIsX ? g.widthMM : g.heightMM }

    /// The stretch of the local edge (points, along the edge) that the remote touches.
    var localSpan: ClosedRange<Double>? {
        let l = axis(local.rect), lo = max(0, offsetMM), hi = min(mm(local), offsetMM + mm(remote))
        guard hi > lo else { return nil }
        return (l.min + lo / mm(local) * l.len)...(l.min + hi / mm(local) * l.len)
    }

    /// The stretch of the remote's facing edge (its points, along the edge) that touches us.
    var remoteSpan: ClosedRange<Double>? {
        let r = axis(remote.rect), lo = max(0, -offsetMM), hi = min(mm(remote), mm(local) - offsetMM)
        guard hi > lo else { return nil }
        return (r.min + lo / mm(remote) * r.len)...(r.min + hi / mm(remote) * r.len)
    }

    /// The pointer leaves `local` at `p` on the hand-off edge → where it enters the remote, or
    /// nil if `p` isn't on the stretch the remote touches.
    func entryPoint(leaving p: CGPoint) -> CGPoint? {
        guard let span = localSpan, span.contains(alongIsX ? p.x : p.y) else { return nil }
        let l = axis(local.rect), r = axis(remote.rect)
        let millimetres = ((alongIsX ? p.x : p.y) - l.min) / l.len * mm(local) - offsetMM
        let a = min(max(r.min + millimetres / mm(remote) * r.len, r.min), r.min + r.len - 1)
        let R = remote.rect, i = Self.inset
        switch edge {   // the remote lies beyond `edge`, so the pointer enters on its opposite side
        case .top:    return CGPoint(x: a, y: R.maxY - 1 - i)
        case .bottom: return CGPoint(x: a, y: R.minY + i)
        case .left:   return CGPoint(x: R.maxX - 1 - i, y: a)
        case .right:  return CGPoint(x: R.minX + i, y: a)
        }
    }

    /// The pointer leaves the remote at `q` → where it lands back on `local`, just inside the
    /// hand-off edge and within the shared stretch.
    func returnPoint(leaving q: CGPoint) -> CGPoint {
        let l = axis(local.rect), r = axis(remote.rect)
        let millimetres = ((alongIsX ? q.x : q.y) - r.min) / r.len * mm(remote) + offsetMM
        var a = l.min + millimetres / mm(local) * l.len
        if let s = localSpan { a = min(max(a, s.lowerBound), s.upperBound) }
        a = min(max(a, l.min), l.min + l.len - 1)
        let L = local.rect, i = Self.inset
        switch edge {
        case .top:    return CGPoint(x: a, y: L.minY + i)
        case .bottom: return CGPoint(x: a, y: L.maxY - 1 - i)
        case .left:   return CGPoint(x: L.minX + i, y: a)
        case .right:  return CGPoint(x: L.maxX - 1 - i, y: a)
        }
    }
}
