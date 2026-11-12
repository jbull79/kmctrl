import XCTest
import CoreGraphics
@testable import KMctrl

/// The permission-free edge switch on the controlling Mac: rest on an outer edge, or cross a
/// seam between two monitors, wherever a portal leads to the other Mac.
final class PortalWatchTests: XCTestCase {
    let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let atRight = CGPoint(x: 1919, y: 500), inside = CGPoint(x: 1500, y: 500)
    func portal(_ edge: ScreenEdge, on d: CGRect? = nil, id: UInt32 = 1, span: ClosedRange<Double>? = nil) -> HandoffPortal {
        let d = d ?? display
        let full = edge == .top || edge == .bottom ? Double(d.minX)...Double(d.maxX) : Double(d.minY)...Double(d.maxY)
        return HandoffPortal(displayID: id, display: d, edge: edge, span: span ?? full, remoteSpan: 0...1440)
    }
    var right: [HandoffPortal] { [portal(.right)] }

    func testFiresAfterThePointerRestsOnTheEdge() {
        var w = PortalWatch()
        XCTAssertNil(w.update(point: atRight, buttonsHeld: false, portals: right, now: 0.00))
        XCTAssertNil(w.update(point: atRight, buttonsHeld: false, portals: right, now: 0.10))
        XCTAssertEqual(w.update(point: atRight, buttonsHeld: false, portals: right, now: 0.21),
                       PortalHit(portal: 0, along: 500))
    }

    func testPassingThroughDoesNotFire() {
        var w = PortalWatch()
        _ = w.update(point: atRight, buttonsHeld: false, portals: right, now: 0.00)
        _ = w.update(point: inside, buttonsHeld: false, portals: right, now: 0.10)     // left again
        XCTAssertNil(w.update(point: atRight, buttonsHeld: false, portals: right, now: 0.15))
        XCTAssertNil(w.update(point: atRight, buttonsHeld: false, portals: right, now: 0.30))
        XCTAssertNotNil(w.update(point: atRight, buttonsHeld: false, portals: right, now: 0.36))
    }

    func testFiresOnceUntilThePointerLeavesTheEdge() {
        var w = PortalWatch()
        _ = w.update(point: atRight, buttonsHeld: false, portals: right, now: 0.0)
        XCTAssertNotNil(w.update(point: atRight, buttonsHeld: false, portals: right, now: 0.25))
        XCTAssertNil(w.update(point: atRight, buttonsHeld: false, portals: right, now: 1.0))   // still resting
        _ = w.update(point: inside, buttonsHeld: false, portals: right, now: 1.1)
        _ = w.update(point: atRight, buttonsHeld: false, portals: right, now: 1.2)
        XCTAssertNotNil(w.update(point: atRight, buttonsHeld: false, portals: right, now: 1.41))
    }

    func testOnlyThePortalsDisplayCounts() {
        var w = PortalWatch()
        let belowDisplay = CGPoint(x: 1919, y: 1500)                  // on another monitor
        _ = w.update(point: belowDisplay, buttonsHeld: false, portals: right, now: 0)
        XCTAssertNil(w.update(point: belowDisplay, buttonsHeld: false, portals: right, now: 1))
    }

    func testEveryEdge() {
        for (edge, p) in [(ScreenEdge.left, CGPoint(x: 0, y: 500)), (.top, CGPoint(x: 900, y: 0)),
                          (.bottom, CGPoint(x: 900, y: 1079))] {
            var w = PortalWatch()
            let ps = [portal(edge)]
            _ = w.update(point: p, buttonsHeld: false, portals: ps, now: 0)
            XCTAssertNotNil(w.update(point: p, buttonsHeld: false, portals: ps, now: 0.25), "\(edge)")
        }
    }

    func testOnlyOnTheStretchThatLeadsToTheOtherMac() {
        var w = PortalWatch()
        let ultrawide = CGRect(x: 0, y: 0, width: 5120, height: 1440)
        let ps = [portal(.top, on: ultrawide, span: 0...2276)]
        _ = w.update(point: CGPoint(x: 3000, y: 0), buttonsHeld: false, portals: ps, now: 0)
        XCTAssertNil(w.update(point: CGPoint(x: 3000, y: 0), buttonsHeld: false, portals: ps, now: 1))
        _ = w.update(point: CGPoint(x: 1000, y: 0), buttonsHeld: false, portals: ps, now: 2)   // slid along
        XCTAssertEqual(w.update(point: CGPoint(x: 1000, y: 0), buttonsHeld: false, portals: ps, now: 2.25),
                       PortalHit(portal: 0, along: 1000))
    }

    func testTwoWaysInEachFireForTheirOwnPortal() {
        var w = PortalWatch()
        let ultrawide = CGRect(x: 0, y: 0, width: 5120, height: 1440)
        let work24 = CGRect(x: 2560, y: -1440, width: 2560, height: 1440)
        let ps = [portal(.top, on: ultrawide, span: 0...2276), portal(.left, on: work24, id: 2, span: -1290...0)]
        let side = CGPoint(x: 2560, y: -600)
        _ = w.update(point: side, buttonsHeld: false, portals: ps, now: 0)
        XCTAssertEqual(w.update(point: side, buttonsHeld: false, portals: ps, now: 0.25), PortalHit(portal: 1, along: -600))
    }

    func testNeverWhileAButtonIsHeld() {
        var w = PortalWatch()
        _ = w.update(point: atRight, buttonsHeld: true, portals: right, now: 0)
        XCTAssertNil(w.update(point: atRight, buttonsHeld: true, portals: right, now: 1))      // dragging a window
        _ = w.update(point: atRight, buttonsHeld: false, portals: right, now: 1.1)
        XCTAssertNotNil(w.update(point: atRight, buttonsHeld: false, portals: right, now: 1.35))
    }

    func testNoDwellForTheEventTap() {
        var w = PortalWatch(dwell: 0)
        XCTAssertNotNil(w.update(point: atRight, buttonsHeld: false, portals: right, now: 0))
    }

    // MARK: Seams

    let a = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    let b = CGRect(x: 2560, y: 0, width: 2560, height: 1440)
    var seam: [HandoffPortal] { [portal(.right, on: a, span: 0...1285), portal(.left, on: b, id: 2, span: 0...1285)] }

    func testCrossingTheSeamSwitchesAtOnce() throws {
        var w = PortalWatch()
        _ = w.update(point: CGPoint(x: 2550, y: 600), buttonsHeld: false, portals: seam, now: 0)
        let hit = try XCTUnwrap(w.update(point: CGPoint(x: 2575, y: 610), buttonsHeld: false, portals: seam, now: 0.016))
        XCTAssertEqual(hit.portal, 0)
        XCTAssertEqual(hit.along, 604, accuracy: 0.01)                 // where it crossed, not where it ended up
    }

    func testCrossingTheOtherWay() throws {
        var w = PortalWatch()
        _ = w.update(point: CGPoint(x: 2570, y: 600), buttonsHeld: false, portals: seam, now: 0)
        XCTAssertEqual(try XCTUnwrap(w.update(point: CGPoint(x: 2550, y: 600), buttonsHeld: false, portals: seam, now: 0.016)).portal, 1)
    }

    func testCrossingBesideTheHomeScreenJustMovesOn() {
        var w = PortalWatch()
        _ = w.update(point: CGPoint(x: 2550, y: 1400), buttonsHeld: false, portals: seam, now: 0)
        XCTAssertNil(w.update(point: CGPoint(x: 2575, y: 1400), buttonsHeld: false, portals: seam, now: 0.016))
    }

    func testDraggingAWindowAcrossTheSeamDoesNotSwitch() {
        var w = PortalWatch()
        _ = w.update(point: CGPoint(x: 2550, y: 600), buttonsHeld: true, portals: seam, now: 0)
        XCTAssertNil(w.update(point: CGPoint(x: 2575, y: 600), buttonsHeld: true, portals: seam, now: 0.016))
    }

    /// After a session the pointer is warped back; the last point from before must not count
    /// as a crossing.
    func testForgetDropsTheLastPoint() {
        var w = PortalWatch()
        _ = w.update(point: CGPoint(x: 2575, y: 600), buttonsHeld: false, portals: seam, now: 0)
        w.forget()
        XCTAssertNil(w.update(point: CGPoint(x: 2555, y: 600), buttonsHeld: false, portals: seam, now: 5))
    }
}

/// The edge geometry shared by both Macs.
final class EdgeSpanTests: XCTestCase {
    let ultrawide = CGRect(x: 0, y: 0, width: 5120, height: 1440)

    /// Moving up into the work Mac's own 24" puts the pointer *above* the ultrawide — that is
    /// not resting on its top edge.
    func testPointerOnTheMonitorAboveIsNotOnTheEdge() {
        XCTAssertFalse(EdgeGeometry.isOnEdge(CGPoint(x: 3000, y: -10), of: ultrawide, edge: .top))
        XCTAssertTrue(EdgeGeometry.isOnEdge(CGPoint(x: 3000, y: 0), of: ultrawide, edge: .top))
    }

    func testReturnOnlyAlongTheSharedStretch() {
        let home = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        var t = EdgeReturnTrigger()
        func push(x: Double) -> Bool {
            t.shouldReturn(cursor: CGPoint(x: x, y: 1439), intended: CGPoint(x: x, y: 1439 + 50),
                           bounds: home, edge: .bottom, buttonHeld: false, span: 500...2560)
        }
        XCTAssertFalse(push(x: 200))     // pushing down where nothing is below
        XCTAssertTrue(push(x: 1000))
    }
}

/// The controlled Mac: one return zone per way in, each answering with its own index.
final class ReturnWatchTests: XCTestCase {
    let home = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    var watch: ReturnWatch {
        ReturnWatch(zones: [.init(edge: .bottom, span: 0...2560), .init(edge: .right, span: 0...700)], reportsZone: true)
    }
    func pushRight(_ w: inout ReturnWatch, y: Double, by d: Double, held: Bool = false) -> Int? {
        w.check(cursor: CGPoint(x: 2559, y: y), intended: CGPoint(x: 2559 + d, y: y), bounds: home, buttonHeld: held)
    }

    func testPushingThroughEachSideNamesItsZone() {
        var w = watch
        XCTAssertNil(pushRight(&w, y: 300, by: 20))
        XCTAssertEqual(pushRight(&w, y: 300, by: 25), 1)
        var v = watch
        XCTAssertEqual(v.check(cursor: CGPoint(x: 900, y: 1439), intended: CGPoint(x: 900, y: 1439 + 50),
                               bounds: home, buttonHeld: false), 0)
    }

    func testOutsideTheZonesStretchNothingHappens() {
        var w = watch
        XCTAssertNil(pushRight(&w, y: 900, by: 100))
    }

    func testNeverWhileAButtonIsHeld() {
        var w = watch
        XCTAssertNil(pushRight(&w, y: 300, by: 100, held: true))
    }

    func testV5SetupGivesOneZonePerWayIn() throws {
        var setup = ControlSetup(hostEdge: .top, autoReturn: true)
        setup.returnZones = [ReturnZone(edge: .bottom, span: [0, 2560]), ReturnZone(edge: .right, span: [0, 1440])]
        let w = try XCTUnwrap(ReturnWatch(setup: setup))
        XCTAssertEqual(w.zones, [.init(edge: .bottom, span: 0...2560), .init(edge: .right, span: 0...1440)])
        XCTAssertTrue(w.reportsZone)
    }

    func testV4SetupGivesTheSingleOppositeEdge() throws {
        let w = try XCTUnwrap(ReturnWatch(setup: ControlSetup(hostEdge: .top, autoReturn: true, returnSpan: [10, 20])))
        XCTAssertEqual(w.zones, [.init(edge: .bottom, span: 10...20)])
        XCTAssertFalse(w.reportsZone)
    }

    func testNoAutoReturnNoWatch() {
        XCTAssertNil(ReturnWatch(setup: ControlSetup(hostEdge: .top, autoReturn: false)))
    }

    func testBadZonesAreDropped() throws {
        var setup = ControlSetup(hostEdge: .top, autoReturn: true)
        setup.returnZones = [ReturnZone(edge: .bottom, span: [.nan, 1]), ReturnZone(edge: .left, span: [5, 1]),
                             ReturnZone(edge: .right, span: [0, 1440])]
        XCTAssertEqual(try XCTUnwrap(ReturnWatch(setup: setup)).zones, [.init(edge: .right, span: 0...1440)])
        setup.returnZones = Array(repeating: ReturnZone(edge: .right, span: [0, 1]), count: 100)
        XCTAssertEqual(try XCTUnwrap(ReturnWatch(setup: setup)).zones.count, ReturnWatch.maxZones)
    }
}

final class EdgeReturnTriggerTests: XCTestCase {
    let desk = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    func push(_ t: inout EdgeReturnTrigger, by dx: Double, held: Bool = false) -> Bool {
        t.shouldReturn(cursor: CGPoint(x: 1919, y: 500), intended: CGPoint(x: 1919 + dx, y: 500),
                       bounds: desk, edge: .right, buttonHeld: held)
    }

    func testDeliberatePushPastTheEdgeReturns() {
        var t = EdgeReturnTrigger()
        XCTAssertFalse(push(&t, by: 15))
        XCTAssertFalse(push(&t, by: 15))
        XCTAssertTrue(push(&t, by: 15))
    }

    func testJustReachingTheEdgeIsNotEnough() {
        var t = EdgeReturnTrigger()
        XCTAssertFalse(t.shouldReturn(cursor: CGPoint(x: 1919, y: 500), intended: CGPoint(x: 1924, y: 500),
                                      bounds: desk, edge: .right, buttonHeld: false))
    }

    func testNeverWhileAButtonIsHeld() {
        var t = EdgeReturnTrigger()
        XCTAssertFalse(push(&t, by: 100, held: true))                 // dragging to the edge
        XCTAssertFalse(push(&t, by: 30))                              // released: starts from zero
        XCTAssertTrue(push(&t, by: 15))
    }

    func testMovingAwayResetsThePush() {
        var t = EdgeReturnTrigger()
        _ = push(&t, by: 30)
        _ = t.shouldReturn(cursor: CGPoint(x: 1800, y: 500), intended: CGPoint(x: 1800, y: 500),
                           bounds: desk, edge: .right, buttonHeld: false)
        XCTAssertFalse(push(&t, by: 30))
        XCTAssertTrue(push(&t, by: 15))
    }
}
