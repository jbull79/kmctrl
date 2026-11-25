import XCTest
import Network
@testable import KMctrl

final class TransportOrderTests: XCTestCase {
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
            _ = try await TransportConnector.shared.connect(to: peer, localName: "test", lookupLimit: 0.2)
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

        _ = try? await connector.connect(to: peer, localName: "test")

        XCTAssertTrue(called.value)
        XCTAssertFalse(onMain.value)
    }

    // MARK: Reading the address from Bonjour

    private func sockaddrV4(_ ip: String, port: UInt16 = 51236) -> Data {
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_port = port.bigEndian
        _ = inet_pton(AF_INET, ip, &sa.sin_addr)
        return withUnsafeBytes(of: &sa) { Data($0) }
    }

    private func sockaddrV6(_ ip: String) -> Data {
        var sa = sockaddr_in6()
        sa.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        sa.sin6_family = sa_family_t(AF_INET6)
        _ = inet_pton(AF_INET6, ip, &sa.sin6_addr)
        return withUnsafeBytes(of: &sa) { Data($0) }
    }

    /// The listener takes IPv4 on one LAN address, so only IPv4 addresses are worth dialling,
    /// self-assigned ones last.
    func testOnlyIPv4AddressesAreDialledSelfAssignedLast() {
        let hosts = BonjourResolver.ipv4Hosts([sockaddrV6("fe80::1"), sockaddrV4("169.254.3.4"),
                                               sockaddrV4("192.168.1.249"), sockaddrV4("192.168.1.249"),
                                               Data([16, 2])])
        XCTAssertEqual(hosts, ["192.168.1.249", "169.254.3.4"])
    }

    /// A Mac can advertise more than one address, and one may not answer. Each is tried in
    /// turn; only the last waits the full connect timeout.
    @MainActor
    func testEachAddressIsTriedInTurn() async {
        let tried = LockedStrings()
        let connector = TransportConnector()
        connector.lookup = { _, _ in PeerAddresses(hosts: ["10.0.0.9", "10.0.0.7"], port: 51236) }
        connector.openSocket = { host, port, timeout in
            tried.append("\(host):\(port) \(timeout)")
            throw LinkError.closed
        }
        let peer = Peer.bonjour(endpoint: .service(name: "x", type: "_kmctrl._tcp", domain: "local.", interface: nil))

        do {
            _ = try await connector.connect(to: peer, localName: "test")
            XCTFail("connected with every address failing")
        } catch LinkError.unreachable(let name, let hosts) {
            XCTAssertEqual(name, "x")
            XCTAssertEqual(hosts, ["10.0.0.9", "10.0.0.7"])
        } catch {
            XCTFail("expected unreachable, got \(error)")
        }
        XCTAssertEqual(tried.values, ["10.0.0.9:51236 2.0", "10.0.0.7:51236 6.0"])
    }

    /// Home is on Ethernet (.249, listening) and Wi-Fi (.68) at once, and Bonjour gives both.
    /// The address the listener names goes first; a name that isn't one of them changes nothing.
    func testTheListeningAddressIsDialledFirst() {
        XCTAssertEqual(BonjourResolver.listeningFirst(["192.168.1.68", "192.168.1.249"], listening: "192.168.1.249"),
                       ["192.168.1.249", "192.168.1.68"])
        XCTAssertEqual(BonjourResolver.listeningFirst(["192.168.1.68", "192.168.1.249"], listening: "10.9.9.9"),
                       ["192.168.1.68", "192.168.1.249"])
        XCTAssertEqual(BonjourResolver.listeningFirst(["192.168.1.68"], listening: nil), ["192.168.1.68"])
    }

    /// Found, but nothing answered: say so, rather than "couldn't find".
    func testUnreachableSaysItWasFound() {
        let text = LinkError.unreachable("Joe’s MacBook Pro", ["192.168.1.249"]).localizedDescription
        XCTAssertTrue(text.contains("at 192.168.1.249, but it didn’t answer"), text)
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

final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func append(_ s: String) { lock.lock(); list.append(s); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return list }
}
