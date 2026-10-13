import XCTest
@testable import KMctrl

final class ReceiveStatsTests: XCTestCase {
    func testOneLinePerSecondWithCountAndMaxGap() {
        var s = ReceiveStats()
        XCTAssertNil(s.record(isMove: true, at: 0.000))
        XCTAssertNil(s.record(isMove: true, at: 0.008))
        XCTAssertNil(s.record(isMove: false, at: 0.300))   // click: counts toward gap, not moves
        XCTAssertNil(s.record(isMove: true, at: 0.310))
        let line = s.record(isMove: true, at: 1.010)
        XCTAssertEqual(line, "control: 4 moves/s received, 5 events, max gap 700 ms")
        XCTAssertNil(s.record(isMove: true, at: 1.020))      // new window
    }

    func testSilentSecondProducesNothing() {
        var s = ReceiveStats()
        XCTAssertNil(s.record(isMove: true, at: 0))
        XCTAssertNotNil(s.record(isMove: true, at: 1.5))
    }
}
