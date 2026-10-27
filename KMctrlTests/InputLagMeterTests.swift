import XCTest
@testable import KMctrl

final class InputLagMeterTests: XCTestCase {
    func testReportsWorstLagSinceLastReadThenResets() {
        let m = InputLagMeter()
        m.note(eventTime: 100.000, now: 100.004)   // 4 ms
        m.note(eventTime: 100.010, now: 100.130)   // 120 ms main-thread stall
        m.note(eventTime: 100.200, now: 100.202)   // 2 ms
        XCTAssertEqual(m.takeMax(), 120, accuracy: 0.5)
        XCTAssertEqual(m.takeMax(), 0, accuracy: 0.001)
    }

    func testClockSkewNeverReportsNegativeLag() {
        let m = InputLagMeter()
        m.note(eventTime: 50.010, now: 50.000)
        XCTAssertEqual(m.takeMax(), 0, accuracy: 0.001)
    }
}
