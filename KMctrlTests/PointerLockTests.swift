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
}
