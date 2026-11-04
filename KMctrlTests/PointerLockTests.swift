import XCTest
@testable import KMctrl

/// While capturing, the controlling Mac's pointer must stay put. With the edge switch, macOS
/// sometimes dropped the lock (the work pointer moved along with the home one), so capture
/// watches for drift and puts the pointer back — not more than every half second, because a
/// warp briefly suppresses the hardware mouse.
final class PointerLockTests: XCTestCase {
    let anchor = CGPoint(x: 500, y: 0)

    func testStillPointerIsNotDrift() {
        var lock = PointerLock(anchor: anchor)
        XCTAssertEqual(lock.check(CGPoint(x: 501, y: 1), now: 0), .held)
    }

    func testDriftIsRelockedAtMostEveryHalfSecond() {
        var lock = PointerLock(anchor: anchor)
        XCTAssertEqual(lock.check(CGPoint(x: 540, y: 30), now: 10.0), .relock)
        XCTAssertEqual(lock.check(CGPoint(x: 560, y: 40), now: 10.1), .drifted)
        XCTAssertEqual(lock.check(CGPoint(x: 560, y: 40), now: 10.5), .relock)
    }

    /// If putting it back doesn't stick (seen after the work Mac switched Space), stop warping:
    /// a pointer yanked back every half second is worse than one that drifts.
    func testGivesUpAfterThreeFailedRelocks() {
        var lock = PointerLock(anchor: anchor)
        let away = CGPoint(x: 600, y: 50)
        XCTAssertEqual(lock.check(away, now: 1.0), .relock)
        XCTAssertEqual(lock.check(away, now: 1.5), .relock)
        XCTAssertEqual(lock.check(away, now: 2.0), .relock)
        XCTAssertEqual(lock.check(away, now: 2.5), .gaveUp)
        XCTAssertEqual(lock.check(away, now: 3.0), .drifted)
        XCTAssertEqual(lock.check(away, now: 9.0), .drifted)
    }

    func testHeldPointerDoesNotResetTheBudget() {
        var lock = PointerLock(anchor: anchor)
        let away = CGPoint(x: 600, y: 50)
        XCTAssertEqual(lock.check(away, now: 1.0), .relock)
        XCTAssertEqual(lock.check(anchor, now: 1.2), .held)
        XCTAssertEqual(lock.check(away, now: 1.5), .relock)
        XCTAssertEqual(lock.check(anchor, now: 1.7), .held)
        XCTAssertEqual(lock.check(away, now: 2.0), .relock)
        XCTAssertEqual(lock.check(away, now: 2.5), .gaveUp)
    }
}
