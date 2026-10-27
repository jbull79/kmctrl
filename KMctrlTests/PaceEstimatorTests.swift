import XCTest
@testable import KMctrl

final class PaceEstimatorTests: XCTestCase {
    func testCleanLinkDrainsAlmostEverythingPerTick() {
        var p = PaceEstimator()
        for i in 0..<20 { p.noteArrival(at: Double(i) * 0.008) }     // 125 Hz arrivals
        XCTAssertGreaterThanOrEqual(p.drainFraction(tick: 0.008), 0.5)
    }

    func testBurstyLinkSpreadsMotionOverTheBurstPeriod() {
        var p = PaceEstimator()
        for i in 0..<10 { p.noteArrival(at: Double(i) * 0.100) }     // bursts every 100 ms
        // ~12 ticks per period → drain ≈ 1/12 per tick so the burst lasts the whole period.
        XCTAssertEqual(p.drainFraction(tick: 0.008), 0.08, accuracy: 0.02)
    }

    func testPeriodIsClampedToSaneRange() {
        var p = PaceEstimator()
        for i in 0..<5 { p.noteArrival(at: Double(i) * 2.0) }        // 2 s gaps (idle), not a pace
        XCTAssertGreaterThanOrEqual(p.drainFraction(tick: 0.008), 0.05)   // never slower than 160 ms period
        var q = PaceEstimator()
        for i in 0..<50 { q.noteArrival(at: Double(i) * 0.001) }     // 1 kHz
        XCTAssertLessThanOrEqual(q.drainFraction(tick: 0.008), 1.0)
    }

    func testFirstSamplesUseDefault() {
        let p = PaceEstimator()
        XCTAssertEqual(p.drainFraction(tick: 0.008), 0.25, accuracy: 0.001)   // today's constant
    }
}
