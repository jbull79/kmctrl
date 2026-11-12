import CoreGraphics
import Foundation

/// The controller's monitor arrangement as the controlled Mac receives it (protocol v5): its
/// monitors (global points + physical size + name), where the controlled Mac's screen sits among
/// them, and the stretches of edge that hand off. Shown read-only on the controlled Mac. It comes
/// from the other Mac, so it is sanitised before it is drawn or saved.
struct ArrangementSnapshot: Codable, Equatable {
    struct Monitor: Codable, Equatable {
        var screen: ScreenGeometry
        var name: String
    }

    /// A stretch of one monitor's edge (the controller's points, along the edge) that leads here.
    struct Link: Codable, Equatable {
        var monitor: Int
        var edge: ScreenEdge
        var span: [Double]
    }

    static let maxMonitors = 16
    static let maxLinks = 32

    var monitors: [Monitor]
    /// x, y, width, height of the controlled Mac's screen, in the controller's global points.
    var tile: [Double]
    var links: [Link]
    /// It sits on a seam, between two of the controller's monitors (links[0] is the edge it was
    /// dropped on).
    var between: Bool? = nil

    var tileRect: CGRect? {
        guard tile.count == 4, tile.allSatisfy(\.isFinite), tile.allSatisfy({ abs($0) <= 1_000_000 }),
              tile[2] > 0, tile[3] > 0 else { return nil }
        return CGRect(x: tile[0], y: tile[1], width: tile[2], height: tile[3])
    }

    /// nil when it can't be a real arrangement; otherwise with names cleaned up and links that
    /// point nowhere or have an impossible stretch dropped.
    var sanitized: ArrangementSnapshot? {
        guard (1...Self.maxMonitors).contains(monitors.count),
              monitors.allSatisfy({ $0.screen.isPlausible }), tileRect != nil else { return nil }
        var out = self
        out.monitors = monitors.map { Monitor(screen: $0.screen, name: $0.name.isEmpty ? "" : PeerName.sanitize($0.name)) }
        out.links = Array(links.filter { l in
            monitors.indices.contains(l.monitor) && l.span.count == 2 && l.span.allSatisfy(\.isFinite)
                && l.span[0] <= l.span[1] && l.span.allSatisfy { abs($0) <= 1_000_000 }
        }.prefix(Self.maxLinks))
        return out
    }
}
