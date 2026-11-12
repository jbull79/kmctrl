import XCTest
import CoreGraphics
@testable import KMctrl

/// Joe's desk: a 49" ultrawide on the work Mac with the work Mac's own 24" above its right half,
/// and the home Mac's 24" above its left half — beside the work 24".
enum Desk {
    static let ultrawide = ScreenGeometry(x: 0, y: 0, width: 5120, height: 1440, widthMM: 1190, heightMM: 335)
    static let work24 = ScreenGeometry(x: 2560, y: -1440, width: 2560, height: 1440, widthMM: 527, heightMM: 296)
    static let home24 = ScreenGeometry(x: 0, y: 0, width: 2560, height: 1440, widthMM: 529, heightMM: 300)
    static let monitors = [HandoffMonitor(id: 1, screen: ultrawide, name: "Ultrawide"),
                           HandoffMonitor(id: 2, screen: work24, name: "Work 24")]
    /// Points per mm along the ultrawide's top edge — the tile's density.
    static let k = 5120.0 / 1190

    static func layout(offsetMM: Double? = 0, monitors: [HandoffMonitor] = monitors) -> HandoffLayout {
        HandoffLayout(monitors: monitors, remote: home24, anchorID: 1, edge: .top, offsetMM: offsetMM)
    }
}

/// The anchor edge alone behaves exactly as the single hand-off edge did before.
final class HandoffLayoutAnchorTests: XCTestCase {
    let ultrawideOnly = [HandoffMonitor(id: 1, screen: Desk.ultrawide)]
    func layout(offsetMM: Double) -> HandoffLayout { Desk.layout(offsetMM: offsetMM, monitors: ultrawideOnly) }
    func top(_ l: HandoffLayout) throws -> Int { try XCTUnwrap(l.portal(on: 1, edge: .top)) }

    func testCrossingUnderTheMiddleOfTheHomeScreenEntersItsMiddle() throws {
        let l = layout(offsetMM: 0)
        let p = l.entryPoint(portal: try top(l), along: 1138)                    // 264.5 mm along
        XCTAssertEqual(p.x, 1280, accuracy: 1)                                    // 264.5 mm into the 24"
        XCTAssertEqual(p.y, 1440 - 1 - HandoffLayout.inset, accuracy: 0.001)      // enters at its bottom
    }

    func testNoSwitchUnderTheWorkMacsOwn24() throws {
        let l = Desk.layout()
        let span = l.portals[try XCTUnwrap(l.portal(on: 1, edge: .top))].span
        XCTAssertFalse(span.contains(3000))
    }

    func testReturnLandsUnderTheHomeScreenNotTheMiddleOfTheUltrawide() throws {
        let l = layout(offsetMM: 0)
        let p = l.returnPoint(portal: try top(l), leaving: CGPoint(x: 1280, y: 1439))
        XCTAssertEqual(p.x, 1138, accuracy: 1)
        XCTAssertEqual(p.y, HandoffLayout.inset, accuracy: 0.001)                 // just below the top
    }

    func testSlidingTheHomeScreenMovesTheStretch() throws {
        let l = layout(offsetMM: 200)
        let span = l.portals[try top(l)].span
        XCTAssertEqual(span.lowerBound, 200 / 1190 * 5120, accuracy: 0.5)
        XCTAssertEqual(span.upperBound, 729 / 1190 * 5120, accuracy: 0.5)
    }

    func testHangingOffTheEndUsesOnlyTheOverlap() throws {
        let l = layout(offsetMM: -100)                                            // 100 mm past the left end
        let portal = l.portals[try top(l)]
        XCTAssertEqual(portal.span.lowerBound, 0, accuracy: 0.001)
        XCTAssertEqual(portal.remoteSpan.lowerBound, 100 / 529 * 2560, accuracy: 0.5)
    }

    func testRoundTripIsPhysicallyConsistent() throws {
        let l = layout(offsetMM: 150)
        let entry = l.entryPoint(portal: try top(l), along: 1500)
        XCTAssertEqual(l.returnPoint(portal: try top(l), leaving: entry).x, 1500, accuracy: 1)
    }

    func testSideBySideOnTheRightEdge() throws {
        let laptop = ScreenGeometry(x: 0, y: 0, width: 1920, height: 1080, widthMM: 527, heightMM: 297)
        let l = HandoffLayout(monitors: [HandoffMonitor(id: 9, screen: laptop)], remote: Desk.home24,
                              anchorID: 9, edge: .right, offsetMM: 0)
        let p = l.entryPoint(portal: try XCTUnwrap(l.portal(on: 9, edge: .right)), along: 540)
        XCTAssertEqual(p.x, HandoffLayout.inset, accuracy: 0.001)                 // enters its left edge
        XCTAssertEqual(p.y, 148.5 / 300 * 1440, accuracy: 1)
    }

    func testNoOverlapMeansNoSwitch() {
        XCTAssertTrue(layout(offsetMM: 2000).portals.isEmpty)
    }

    func testCentredDefault() {
        XCTAssertEqual(HandoffLayout.centredOffsetMM(local: Desk.ultrawide, remote: Desk.home24, edge: .top),
                       (1190 - 529) / 2, accuracy: 0.001)
        XCTAssertEqual(Desk.layout(offsetMM: nil, monitors: ultrawideOnly).offsetMM, (1190 - 529) / 2, accuracy: 0.001)
    }

    func testAnUnknownAnchorFallsBackToTheFirstMonitor() {
        let l = HandoffLayout(monitors: ultrawideOnly, remote: Desk.home24, anchorID: 77, edge: .top, offsetMM: 0)
        XCTAssertNotNil(l.portal(on: 1, edge: .top))
    }

    func testNoMonitorsMeansNoPortals() {
        XCTAssertTrue(HandoffLayout(monitors: [], remote: Desk.home24, anchorID: 1, edge: .top, offsetMM: 0).portals.isEmpty)
    }

    func testScreenGeometryRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(Desk.home24)
        XCTAssertEqual(try JSONDecoder().decode(ScreenGeometry.self, from: data), Desk.home24)
    }
}

/// Every monitor edge next to the home screen hands off — not just the one it was dropped on.
final class HandoffLayoutPortalTests: XCTestCase {
    func testJoesDeskHasTwoWaysIn() {
        let l = Desk.layout()
        XCTAssertEqual(l.portals.count, 2)
        XCTAssertNotNil(l.portal(on: 1, edge: .top))     // up from the ultrawide
        XCTAssertNotNil(l.portal(on: 2, edge: .left))    // left from the work 24"
        XCTAssertEqual(l.anchorPortal, l.portal(on: 1, edge: .top))
    }

    func testTheTileSitsFlushAboveTheAnchorAtItsPhysicalSize() {
        let t = Desk.layout().tile
        XCTAssertEqual(t.minX, 0, accuracy: 0.001)
        XCTAssertEqual(t.maxY, 0, accuracy: 0.001)
        XCTAssertEqual(t.width, 529 * Desk.k, accuracy: 0.01)
        XCTAssertEqual(t.height, 300 * Desk.k, accuracy: 0.01)
    }

    func testTheWork24sLeftEdgeEntersTheHomeScreensRightSide() throws {
        let l = Desk.layout()
        let i = try XCTUnwrap(l.portal(on: 2, edge: .left))
        let p = l.entryPoint(portal: i, along: l.tile.midY)
        XCTAssertEqual(p.x, 2560 - 1 - HandoffLayout.inset, accuracy: 0.001)
        XCTAssertEqual(p.y, 720, accuracy: 1)
    }

    func testPushingOutOfTheHomeScreensRightSideLandsOnTheWork24() throws {
        let l = Desk.layout()
        let i = try XCTUnwrap(l.portal(on: 2, edge: .left))
        let p = l.returnPoint(portal: i, leaving: CGPoint(x: 2559, y: 720))
        XCTAssertEqual(p.x, 2560 + HandoffLayout.inset, accuracy: 0.001)          // just inside its left edge
        XCTAssertEqual(p.y, l.tile.midY, accuracy: 1)
    }

    func testTheSideStretchCoversOnlyWhereTheyOverlap() throws {
        let l = Desk.layout()
        let side = l.portals[try XCTUnwrap(l.portal(on: 2, edge: .left))]
        XCTAssertEqual(side.span.lowerBound, -300 * Desk.k, accuracy: 0.5)       // the tile's top
        XCTAssertEqual(side.span.upperBound, 0, accuracy: 0.5)
        XCTAssertEqual(side.remoteSpan.lowerBound, 0, accuracy: 0.5)
        XCTAssertEqual(side.remoteSpan.upperBound, 1440, accuracy: 0.5)
    }

    func testOneReturnZonePerWayIn() throws {
        let l = Desk.layout()
        let zones = l.returnZones
        XCTAssertEqual(zones.count, 2)
        let bottom = try XCTUnwrap(zones.first { $0.edge == .bottom })
        XCTAssertEqual(bottom.span[0], 0, accuracy: 0.5)
        XCTAssertEqual(bottom.span[1], 2560, accuracy: 0.5)
        XCTAssertNotNil(zones.first { $0.edge == .right })
        XCTAssertEqual(zones[try XCTUnwrap(l.portal(on: 2, edge: .left))].edge, .right)
    }

    func testAReturnLandsWhereTheOtherMacSaysElseOnTheAnchor() throws {
        let l = Desk.layout()
        let side = try XCTUnwrap(l.portal(on: 2, edge: .left))
        XCTAssertEqual(l.returnPortal(zone: side), side)
        XCTAssertEqual(l.returnPortal(zone: nil), l.anchorPortal)        // a v4 Mac names no zone
        XCTAssertEqual(l.returnPortal(zone: 99), l.anchorPortal)         // nor a made-up one
        XCTAssertNil(Desk.layout(offsetMM: 5000).returnPortal(zone: nil))
    }

    func testAMonitorFarAwayIsNotANeighbour() {
        var far = Desk.work24
        far.x = 4000                                     // 400 mm from the home screen's side
        let l = Desk.layout(monitors: [HandoffMonitor(id: 1, screen: Desk.ultrawide), HandoffMonitor(id: 2, screen: far)])
        XCTAssertEqual(l.portals.count, 1)
        XCTAssertNil(l.portal(on: 2, edge: .left))
    }

    /// Slid partly over the work 24": where the pointer would move straight up into the work
    /// 24", it keeps doing that — only the stretch under the home screen alone hands off.
    func testTheStretchUnderAnotherMonitorIsCutOut() throws {
        let l = Desk.layout(offsetMM: 150)
        XCTAssertFalse(l.isBetweenMonitors)
        let top = l.portals[try XCTUnwrap(l.portal(on: 1, edge: .top))]
        XCTAssertEqual(top.span.lowerBound, 150 * Desk.k, accuracy: 0.5)
        XCTAssertEqual(top.span.upperBound, 2560, accuracy: 0.5)
        XCTAssertNil(l.portal(on: 2, edge: .bottom))
    }
}

/// The home screen dropped on the seam between two work monitors sits *between* them.
final class HandoffLayoutBetweenTests: XCTestCase {
    let left = ScreenGeometry(x: 0, y: 0, width: 2560, height: 1440, widthMM: 597, heightMM: 336)
    let right = ScreenGeometry(x: 2560, y: 0, width: 2560, height: 1440, widthMM: 597, heightMM: 336)
    var layout: HandoffLayout {
        HandoffLayout(monitors: [HandoffMonitor(id: 1, screen: left), HandoffMonitor(id: 2, screen: right)],
                      remote: Desk.home24, anchorID: 1, edge: .right, offsetMM: 0)
    }

    func testBothSidesOfTheSeamHandOff() throws {
        let l = layout
        XCTAssertTrue(l.isBetweenMonitors)
        let a = l.portals[try XCTUnwrap(l.portal(on: 1, edge: .right))]
        let b = l.portals[try XCTUnwrap(l.portal(on: 2, edge: .left))]
        XCTAssertEqual(a.span.upperBound, 300 * 1440 / 336, accuracy: 0.5)     // not cut out by the neighbour
        XCTAssertEqual(b.span, a.span)
    }

    func testTheSnapshotSaysItSitsBetween() {
        XCTAssertEqual(layout.snapshot().between, true)
        XCTAssertNil(Desk.layout().snapshot().between)
    }

    /// Drawn in the gap: the right monitor moves out of the way, the left one stays.
    func testTheDrawingMakesRoomOnTheSeam() {
        let l = layout
        let moved = ArrangementCanvas.spread([left.rect, right.rect], around: l.tile, toward: .right)
        XCTAssertEqual(moved[0], left.rect)
        XCTAssertEqual(moved[1].minX, l.tile.maxX, accuracy: 0.001)
        XCTAssertFalse(moved[1].intersects(l.tile.insetBy(dx: 1, dy: 1)))
    }

    func testFromTheRightMonitorYouEnterTheHomeScreensRightSide() throws {
        let l = layout
        let p = l.entryPoint(portal: try XCTUnwrap(l.portal(on: 2, edge: .left)), along: 300)
        XCTAssertEqual(p.x, 2560 - 1 - HandoffLayout.inset, accuracy: 0.001)
    }

    func testLeavingTheFarSideLandsOnTheFarMonitor() throws {
        let l = layout
        let toRight = l.returnPoint(portal: try XCTUnwrap(l.portal(on: 2, edge: .left)), leaving: CGPoint(x: 2559, y: 600))
        XCTAssertEqual(toRight.x, 2560 + HandoffLayout.inset, accuracy: 0.001)
        let toLeft = l.returnPoint(portal: try XCTUnwrap(l.portal(on: 1, edge: .right)), leaving: CGPoint(x: 0, y: 600))
        XCTAssertEqual(toLeft.x, 2559 - HandoffLayout.inset, accuracy: 0.001)
    }
}

/// The controller's arrangement as the controlled Mac receives it.
final class ArrangementSnapshotTests: XCTestCase {
    func testSnapshotDescribesTheDesk() throws {
        let s = Desk.layout().snapshot()
        XCTAssertEqual(s.monitors.map(\.name), ["Ultrawide", "Work 24"])
        XCTAssertEqual(s.links.count, 2)
        XCTAssertEqual(s.tile.count, 4)
        let back = try JSONDecoder().decode(ArrangementSnapshot.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.sanitized, s)
    }

    func testAnImpossibleTileIsRejected() {
        var s = Desk.layout().snapshot()
        s.tile = [0, .nan, 10, 10]
        XCTAssertNil(s.sanitized)
    }

    func testAnImpossibleMonitorIsRejected() {
        var s = Desk.layout().snapshot()
        s.monitors[0].screen.width = -5
        XCTAssertNil(s.sanitized)
    }

    func testTooManyMonitorsIsRejected() {
        var s = Desk.layout().snapshot()
        s.monitors = Array(repeating: s.monitors[0], count: ArrangementSnapshot.maxMonitors + 1)
        XCTAssertNil(s.sanitized)
    }

    func testLinksToMissingMonitorsOrBadSpansAreDropped() throws {
        var s = Desk.layout().snapshot()
        s.links.append(.init(monitor: 9, edge: .top, span: [0, 10]))
        s.links.append(.init(monitor: 0, edge: .top, span: [10, 0]))
        XCTAssertEqual(try XCTUnwrap(s.sanitized).links.count, 2)
    }

    func testNamesAreCleanedUp() throws {
        var s = Desk.layout().snapshot()
        s.monitors[0].name = "Evil\u{202E}\nName" + String(repeating: "x", count: 200)
        let name = try XCTUnwrap(s.sanitized).monitors[0].name
        XCTAssertFalse(name.contains("\n"))
        XCTAssertFalse(name.unicodeScalars.contains("\u{202E}"))
        XCTAssertLessThanOrEqual(name.count, PeerName.maxLength)
    }
}
