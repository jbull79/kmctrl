import XCTest
import CoreGraphics
@testable import KMctrl

/// Joe's desk: a 49" ultrawide on the work Mac with the work Mac's own 24" above its right half,
/// and the home Mac's 24" above its left half.
final class HandoffGeometryTests: XCTestCase {
    let ultrawide = ScreenGeometry(x: 0, y: 0, width: 5120, height: 1440, widthMM: 1190, heightMM: 335)
    let home24 = ScreenGeometry(x: 0, y: 0, width: 2560, height: 1440, widthMM: 529, heightMM: 300)
    func geometry(offsetMM: Double) -> HandoffGeometry {
        HandoffGeometry(local: ultrawide, remote: home24, edge: .top, offsetMM: offsetMM)
    }

    func testCrossingUnderTheMiddleOfTheHomeScreenEntersItsMiddle() throws {
        let g = geometry(offsetMM: 0)
        let p = try XCTUnwrap(g.entryPoint(leaving: CGPoint(x: 1138, y: 0)))     // 264.5 mm along
        XCTAssertEqual(p.x, 1280, accuracy: 1)                                    // 264.5 mm into the 24"
        XCTAssertEqual(p.y, 1440 - 1 - HandoffGeometry.inset, accuracy: 0.001)    // enters at its bottom
    }

    func testNoSwitchUnderTheWorkMacsOwn24() {
        XCTAssertNil(geometry(offsetMM: 0).entryPoint(leaving: CGPoint(x: 3000, y: 0)))
    }

    func testReturnLandsUnderTheHomeScreenNotTheMiddleOfTheUltrawide() {
        let p = geometry(offsetMM: 0).returnPoint(leaving: CGPoint(x: 1280, y: 1439))
        XCTAssertEqual(p.x, 1138, accuracy: 1)
        XCTAssertEqual(p.y, HandoffGeometry.inset, accuracy: 0.001)               // just below the top
    }

    func testSlidingTheHomeScreenMovesTheStretch() throws {
        let span = try XCTUnwrap(geometry(offsetMM: 200).localSpan)
        XCTAssertEqual(span.lowerBound, 200 / 1190 * 5120, accuracy: 0.5)
        XCTAssertEqual(span.upperBound, 729 / 1190 * 5120, accuracy: 0.5)
    }

    func testHangingOffTheEndUsesOnlyTheOverlap() throws {
        let g = geometry(offsetMM: -100)                                          // 100 mm past the left end
        XCTAssertEqual(try XCTUnwrap(g.localSpan).lowerBound, 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(g.remoteSpan).lowerBound, 100 / 529 * 2560, accuracy: 0.5)
    }

    func testRoundTripIsPhysicallyConsistent() throws {
        let g = geometry(offsetMM: 150)
        let entry = try XCTUnwrap(g.entryPoint(leaving: CGPoint(x: 1500, y: 0)))
        XCTAssertEqual(g.returnPoint(leaving: entry).x, 1500, accuracy: 1)
    }

    func testSideBySideOnTheRightEdge() throws {
        let laptop = ScreenGeometry(x: 0, y: 0, width: 1920, height: 1080, widthMM: 527, heightMM: 297)
        let g = HandoffGeometry(local: laptop, remote: home24, edge: .right, offsetMM: 0)
        let p = try XCTUnwrap(g.entryPoint(leaving: CGPoint(x: 1919, y: 540)))
        XCTAssertEqual(p.x, HandoffGeometry.inset, accuracy: 0.001)               // enters its left edge
        XCTAssertEqual(p.y, 148.5 / 300 * 1440, accuracy: 1)
    }

    func testNoOverlapMeansNoSwitch() {
        XCTAssertNil(geometry(offsetMM: 2000).localSpan)
    }

    func testCentredDefault() {
        XCTAssertEqual(HandoffGeometry.centredOffsetMM(local: ultrawide, remote: home24, edge: .top),
                       (1190 - 529) / 2, accuracy: 0.001)
    }

    func testScreenGeometryRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(home24)
        XCTAssertEqual(try JSONDecoder().decode(ScreenGeometry.self, from: data), home24)
    }
}

final class EdgeSpanTests: XCTestCase {
    let ultrawide = CGRect(x: 0, y: 0, width: 5120, height: 1440)

    /// Moving up into the work Mac's own 24" puts the pointer *above* the ultrawide — that is
    /// not resting on its top edge.
    func testPointerOnTheMonitorAboveIsNotOnTheEdge() {
        XCTAssertFalse(EdgeGeometry.isOnEdge(CGPoint(x: 3000, y: -10), of: ultrawide, edge: .top))
        XCTAssertTrue(EdgeGeometry.isOnEdge(CGPoint(x: 3000, y: 0), of: ultrawide, edge: .top))
    }

    func testDwellOnlyOnTheStretchUnderTheHomeScreen() {
        var d = EdgeDwell()
        let span = 0.0...2276.0
        _ = d.update(point: CGPoint(x: 3000, y: 0), display: ultrawide, edge: .top, span: span, now: 0)
        XCTAssertFalse(d.update(point: CGPoint(x: 3000, y: 0), display: ultrawide, edge: .top, span: span, now: 1))
        _ = d.update(point: CGPoint(x: 1000, y: 0), display: ultrawide, edge: .top, span: span, now: 2)   // slid along
        XCTAssertTrue(d.update(point: CGPoint(x: 1000, y: 0), display: ultrawide, edge: .top, span: span, now: 2.25))
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
