import XCTest
@testable import KMctrl

final class TransportOrderTests: XCTestCase {
    /// Control frames can only be written to a raw socket, so a control link must never be
    /// opened over Network.framework — not even when a fallback was cached as last-known-good
    /// (that produced "connected", then an instant drop on Start controlling).
    func testCachedFallbackCannotHijackAControlLink() {
        let order = TransportConnector.attemptOrder(allowed: ControlHost.controlTransports,
                                                    preferred: .nwProhibitOther)
        XCTAssertEqual(order, [.posix])
    }

    func testControlIsRawSocketOnly() {
        XCTAssertEqual(ControlHost.controlTransports, [.posix])
    }

    func testOtherSessionsStillTryLastKnownGoodFirst() {
        let order = TransportConnector.attemptOrder(allowed: Set(TransportStrategy.allCases), preferred: .nwDefault)
        XCTAssertEqual(order, [.nwDefault, .posix, .nwProhibitOther])
    }

    func testEmptyAllowedSetFallsBackToEverything() {
        XCTAssertEqual(TransportConnector.attemptOrder(allowed: [], preferred: nil), TransportStrategy.allCases)
    }
}
