import XCTest
import Network
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

    // MARK: Finding the other Mac

    /// A control link needs the raw socket, so it can't start without the address. The lookup
    /// ran past the old 4 s limit on the work Mac (Connect failed, the retry worked at once)
    /// and took 8.5 s in a test on the home Mac.
    func testAControlConnectWaitsPastTheSlowestLookupSeen() {
        XCTAssertGreaterThan(ControlHost.connectLookupLimit, 8.5)
    }

    /// Running out of time looking for the address has to say so, not "Connection closed."
    @MainActor
    func testFailedLookupIsReportedAsNotFound() async {
        let peer = Peer.bonjour(endpoint: .service(name: "kmctrl-test-\(UUID().uuidString)", type: "_kmctrl._tcp",
                                                   domain: "local.", interface: nil))
        do {
            _ = try await TransportConnector.shared.connect(to: peer, localName: "test",
                                                            allowed: ControlHost.controlTransports, lookupLimit: 0.2)
            XCTFail("connected to a Mac that doesn't exist")
        } catch LinkError.addressNotFound(let name) {
            XCTAssertEqual(name, peer.name)
        } catch {
            XCTFail("expected addressNotFound, got \(error)")
        }
    }

    /// Reconnecting dials over and over while the network is down, with Disconnect as the only
    /// way out. A connect that waits on the main thread would freeze the app for every try.
    @MainActor
    func testTheSocketIsNotOpenedOnTheMainThread() async throws {
        let called = LockedFlag(), onMain = LockedFlag()
        let connector = TransportConnector()
        connector.openSocket = { _, _, _ in
            called.value = true
            onMain.value = Thread.isMainThread
            throw LinkError.closed
        }
        let peer = try XCTUnwrap(Peer.manual(host: "127.0.0.1", port: 9))

        _ = try? await connector.connect(to: peer, localName: "test", allowed: ControlHost.controlTransports)

        XCTAssertTrue(called.value)
        XCTAssertFalse(onMain.value)
    }

    // MARK: Why a link ended

    /// "Connection closed." covers every ending; the log has to tell them apart.
    func testTheLogSaysWhyALinkEnded() {
        XCTAssertEqual(POSIXByteStream.endReason(received: 0, error: 0), "link: the other Mac closed the connection")
        XCTAssertEqual(POSIXByteStream.endReason(received: -1, error: ETIMEDOUT),
                       "link: connection lost — Operation timed out (errno 60)")
        XCTAssertEqual(POSIXByteStream.endReason(received: -1, error: ECONNRESET),
                       "link: connection lost — Connection reset by peer (errno 54)")
    }
}
