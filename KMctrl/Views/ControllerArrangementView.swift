import SwiftUI

/// Controlled Mac: the controlling Mac's monitors and where this Mac sits among them, as that Mac
/// last sent it (protocol v5). Read-only — the arrangement is set on the controlling Mac.
struct ControllerArrangementView: View {
    let arrangement: ArrangementSnapshot

    var body: some View {
        GeometryReader { geo in
            ArrangementDrawing(canvas: canvas(in: geo.size), tileLabel: "This Mac", tileIcon: "laptopcomputer")
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: 150)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }

    private var summary: String {
        let names = arrangement.monitors.enumerated().map { $1.name.isEmpty ? "screen \($0 + 1)" : $1.name }
        let ways = arrangement.links.compactMap { l in
            names.indices.contains(l.monitor) ? "\(names[l.monitor]) \(l.edge.label.lowercased()) edge" : nil
        }
        return "This Mac sits next to: " + (ways.isEmpty ? "no edge" : ways.joined(separator: ", "))
    }

    private func canvas(in size: CGSize) -> ArrangementCanvas {
        let monitors = arrangement.monitors.enumerated().map { i, m in
            ArrangementCanvas.Monitor(id: UInt32(i), screen: m.screen,
                                      label: m.name.isEmpty ? "Screen \(i + 1)" : m.name, highlighted: false)
        }
        let links = arrangement.links.compactMap { l -> ArrangementCanvas.Link? in
            guard arrangement.monitors.indices.contains(l.monitor), l.span.count == 2, l.span[0] <= l.span[1] else { return nil }
            return .init(monitor: l.monitor, edge: l.edge, span: l.span[0]...l.span[1])
        }
        // The first link is the edge it was dropped on: on a seam, the monitors beyond go that way.
        return ArrangementCanvas(size: size, world: nil, monitors: monitors, tile: arrangement.tileRect, links: links,
                                 insertedToward: arrangement.between == true ? arrangement.links.first?.edge : nil)
    }
}
