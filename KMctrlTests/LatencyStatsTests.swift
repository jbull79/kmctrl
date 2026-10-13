import XCTest
@testable import KMctrl

final class LatencyStatsTests: XCTestCase {
    func testAggregatesSamplesIntoOneLinePerSecond() {
        var s = LatencyStats()
        XCTAssertNil(s.record(rtt: 5, at: 0.0))
        XCTAssertNil(s.record(rtt: 3, at: 0.2))
        XCTAssertNil(s.record(rtt: 9, at: 0.4))
        let line = s.record(rtt: 4, at: 1.05)
        XCTAssertEqual(line, "control latency: RTT min 3.0 / avg 5.2 / max 9.0 ms over 4 probes · session min 3.0 ms")
        XCTAssertNil(s.record(rtt: 2, at: 1.3))                      // new window, nothing yet
        XCTAssertEqual(s.record(rtt: 2, at: 2.4)?.contains("session min 2.0 ms"), true)
    }
}
