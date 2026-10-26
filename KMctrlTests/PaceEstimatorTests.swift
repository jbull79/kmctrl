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

    /// A clean wired link delivers a 60 Hz mouse as evenly spaced single moves with ±1–2 ms
    /// jitter. That is already smooth — pacing it only adds lag and makes the speed wobble.
    func testSteady60HzStreamWithJitterAppliesInstantly() {
        var p = PaceEstimator()
        let gaps = [0.0145, 0.0189, 0.0167]                          // jitter straddling 15 ms
        var t = 0.0
        for i in 0..<60 { p.noteArrival(at: t); t += gaps[i % gaps.count] }
        XCTAssertEqual(p.drainFraction(tick: 0.008), 1.0, accuracy: 0.001)
    }

    /// Stopping the mouse for a moment is not a network burst and must not throttle the
    /// stroke that follows.
    func testPauseDoesNotThrottleTheNextStroke() {
        var p = PaceEstimator()
        var t = 0.0
        for _ in 0..<20 { p.noteArrival(at: t); t += 1.0 / 60 }       // stroke
        t += 0.25                                                       // user pauses 250 ms
        for _ in 0..<5 { p.noteArrival(at: t); t += 1.0 / 60 }        // next stroke
        XCTAssertEqual(p.drainFraction(tick: 0.008), 1.0, accuracy: 0.001)
    }

    /// Wi-Fi power-save delivers moves in tight clumps every ~100 ms — still spread out.
    func testWiFiClumpsAreStillPaced() {
        var p = PaceEstimator()
        for burst in 0..<10 {
            for k in 0..<6 { p.noteArrival(at: Double(burst) * 0.100 + Double(k) * 0.0004) }
        }
        XCTAssertEqual(p.drainFraction(tick: 0.008), 0.08, accuracy: 0.02)
    }
}
