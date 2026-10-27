import XCTest
import CoreGraphics
@testable import KMctrl

final class EdgeDwellTests: XCTestCase {
    let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let atRight = CGPoint(x: 1919, y: 500), inside = CGPoint(x: 1500, y: 500)

    func testFiresAfterThePointerRestsOnTheEdge() {
        var d = EdgeDwell()
        XCTAssertFalse(d.update(point: atRight, display: display, edge: .right, now: 0.00))
        XCTAssertFalse(d.update(point: atRight, display: display, edge: .right, now: 0.10))
        XCTAssertTrue(d.update(point: atRight, display: display, edge: .right, now: 0.21))
    }

    func testPassingThroughDoesNotFire() {
        var d = EdgeDwell()
        _ = d.update(point: atRight, display: display, edge: .right, now: 0.00)
        _ = d.update(point: inside, display: display, edge: .right, now: 0.10)     // left again
        XCTAssertFalse(d.update(point: atRight, display: display, edge: .right, now: 0.15))
        XCTAssertFalse(d.update(point: atRight, display: display, edge: .right, now: 0.30))
        XCTAssertTrue(d.update(point: atRight, display: display, edge: .right, now: 0.36))
    }

    func testFiresOnceUntilThePointerLeavesTheEdge() {
        var d = EdgeDwell()
        _ = d.update(point: atRight, display: display, edge: .right, now: 0.0)
        XCTAssertTrue(d.update(point: atRight, display: display, edge: .right, now: 0.25))
        XCTAssertFalse(d.update(point: atRight, display: display, edge: .right, now: 1.0))   // still resting
        _ = d.update(point: inside, display: display, edge: .right, now: 1.1)
        _ = d.update(point: atRight, display: display, edge: .right, now: 1.2)
        XCTAssertTrue(d.update(point: atRight, display: display, edge: .right, now: 1.41))
    }

    func testOnlyTheChosenDisplaysEdgeCounts() {
        var d = EdgeDwell()
        let belowDisplay = CGPoint(x: 1919, y: 1500)                  // on another monitor
        _ = d.update(point: belowDisplay, display: display, edge: .right, now: 0)
        XCTAssertFalse(d.update(point: belowDisplay, display: display, edge: .right, now: 1))
    }

    func testEveryEdge() {
        for (edge, p) in [(ScreenEdge.left, CGPoint(x: 0, y: 500)), (.top, CGPoint(x: 900, y: 0)),
                          (.bottom, CGPoint(x: 900, y: 1079))] {
            var d = EdgeDwell()
            _ = d.update(point: p, display: display, edge: edge, now: 0)
            XCTAssertTrue(d.update(point: p, display: display, edge: edge, now: 0.25), "\(edge)")
        }
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
