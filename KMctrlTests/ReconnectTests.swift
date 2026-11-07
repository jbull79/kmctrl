import XCTest
import CryptoKit
import Darwin
@testable import KMctrl

/// One end of an in-memory connection. A link needs no socket or Keychain to run the real
/// handshake and session code, and a test can end it the way a network would.
private final class MemoryStream: ByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var ended: Error?
    private var waiter: (max: Int, cont: CheckedContinuation<Data, Error>)?
    weak var other: MemoryStream?

    static func pair() -> (MemoryStream, MemoryStream) {
        let a = MemoryStream(), b = MemoryStream()
        a.other = b; b.other = a
        return (a, b)
    }

    func open() async throws {}
    func setReadTimeout(_ seconds: TimeInterval) {}

    func sendBytes(_ data: Data) async throws {
        guard let other else { throw LinkError.closed }
        other.deliver(data)
    }

    func receiveBytes(max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if !buffer.isEmpty {
                let chunk = buffer.prefix(max); buffer.removeFirst(chunk.count)
                lock.unlock()
                cont.resume(returning: Data(chunk))
            } else if let ended {
                lock.unlock()
                cont.resume(throwing: ended)
            } else {
                waiter = (max, cont)
                lock.unlock()
            }
        }
    }

    func close() { end(with: LinkError.closed) }

    /// Ends this side's receive with `error`, as the transport would.
    func end(with error: Error) {
        lock.lock()
        if ended == nil { ended = error }
        let w = waiter; waiter = nil
        lock.unlock()
        w?.cont.resume(throwing: error)
    }

    private func deliver(_ data: Data) {
        lock.lock()
        if let w = waiter {
            waiter = nil
            let chunk = data.prefix(w.max)
            buffer.append(data.dropFirst(chunk.count))
            lock.unlock()
            w.cont.resume(returning: Data(chunk))
        } else {
            buffer.append(data)
            lock.unlock()
        }
    }
}

/// Stands in for the other Mac: answers each dial with a real handshake and the ack it was told
/// to give. A real `PeerLink` on the near end, so everything above the transport is the app's.
@MainActor
private final class FakeMac {
    let identity = Curve25519.Signing.PrivateKey()
    let hostIdentity = Curve25519.Signing.PrivateKey()
    var dials = 0
    var hellos: [SessionHello] = []
    var streams: [MemoryStream] = []
    /// Dials that fail outright before the other Mac answers (the network is still down).
    var failingDials = 0
    var refusal: String?

    var dial: @MainActor (Peer, String) async throws -> PeerLink {
        { [unowned self] _, localName in
            self.dials += 1
            if self.failingDials > 0 { self.failingDials -= 1; throw LinkError.addressNotFound("Home") }
            let (near, far) = MemoryStream.pair()
            self.streams.append(near)
            let remote = PeerLink(stream: far)
            let refusal = self.refusal
            let identity = self.identity
            Task.detached {
                try await remote.handshake(localName: "Home", identity: identity)
                let hello = try await remote.receiveSecureObject(SessionHello.self)
                await MainActor.run { self.hellos.append(hello) }
                try await remote.sendSecureObject(ControlAck(accepted: refusal == nil, reason: refusal ?? "",
                                                             version: SessionHello.currentControlVersion))
                if refusal == nil { _ = try await remote.receiveSecureObject(ControlSetup.self) }
                _ = remote     // held until the far end goes away
            }
            let link = PeerLink(stream: near)
            try await link.handshake(localName: localName, identity: self.hostIdentity)
            return link
        }
    }
}

@MainActor
final class ReconnectTests: XCTestCase {
    private let peer = Peer.manual(host: "192.0.2.1", port: 7)!

    private func makeHost(_ mac: FakeMac) -> ControlHost {
        let host = ControlHost()
        host.dial = mac.dial
        return host
    }

    private func wait(_ what: String, timeout: TimeInterval = 5,
                      until condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for: \(what)"); return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private struct NeverConnected: Error {}

    /// Throws rather than carrying on, because the tests go on to end the link it opened.
    private func connected(_ host: ControlHost) async throws {
        host.connect(to: peer, localName: "Work")
        await wait("first connection") { host.state == .connected }
        guard host.state == .connected else { throw NeverConnected() }
    }

    // MARK: Pacing

    /// Most faults are brief, so the first try is at once; after that it backs off, and it never
    /// waits long once the network is back.
    func testRetriesStartAtOnceAndBackOffToTenSeconds() {
        XCTAssertEqual((1...7).map(ControlHost.reconnectDelay(attempt:)), [0, 1, 2, 4, 8, 10, 10])
        XCTAssertEqual(ControlHost.reconnectDelay(attempt: 1_000), 10)
    }

    // MARK: When it reconnects

    func testALostLinkComesBack() async throws {
        let mac = FakeMac()
        let host = makeHost(mac)
        try await connected(host)

        mac.streams[0].end(with: LinkError.lost)

        await wait("the second connection") { mac.dials == 2 && host.state == .connected }
        XCTAssertFalse(host.reconnecting)
        XCTAssertNil(host.lastError)
        XCTAssertEqual(host.peerName, peer.name)
        host.disconnect()
    }

    func testTheCardSaysItIsReconnectingWhileTheNetworkIsDown() async throws {
        let mac = FakeMac()
        let host = makeHost(mac)
        try await connected(host)
        mac.failingDials = 1

        mac.streams[0].end(with: LinkError.lost)

        await wait("the first failed attempt") { mac.dials == 2 }
        XCTAssertTrue(host.reconnecting)
        XCTAssertEqual(host.state, .connecting)
        XCTAssertNil(host.lastError)          // not an error yet: it is still trying
        host.disconnect()
    }

    func testFailedAttemptsKeepTrying() async throws {
        let mac = FakeMac()
        let host = makeHost(mac)
        try await connected(host)
        mac.failingDials = 2

        mac.streams[0].end(with: LinkError.lost)

        await wait("the third attempt to work") { mac.dials == 4 && host.state == .connected }
        XCTAssertFalse(host.reconnecting)
        host.disconnect()
    }

    /// The next loss starts its back-off from the beginning, not from where the last one ended.
    func testASuccessfulReconnectResetsTheBackOff() async throws {
        let mac = FakeMac()
        let host = makeHost(mac)
        try await connected(host)
        mac.failingDials = 1
        mac.streams[0].end(with: LinkError.lost)
        await wait("the first reconnect") { mac.dials == 3 && host.state == .connected }

        let start = Date()
        mac.streams.last?.end(with: LinkError.lost)
        await wait("the second reconnect") { mac.dials == 4 && host.state == .connected }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.9)
        host.disconnect()
    }

    /// The other Mac can only tell a retry from a deliberate connect if the hello says so.
    func testOnlyAnAutomaticReconnectIsMarkedAsOne() async throws {
        let mac = FakeMac()
        let host = makeHost(mac)
        try await connected(host)
        await wait("the first hello") { mac.hellos.count == 1 }
        XCTAssertNotEqual(mac.hellos.first?.reconnect, true)

        mac.streams[0].end(with: LinkError.lost)

        await wait("the second hello") { mac.hellos.count == 2 }
        XCTAssertEqual(mac.hellos.dropFirst().first?.reconnect, true)
        host.disconnect()
    }

    /// A socket write can be the first thing to notice a dead link (control sends all the time).
    func testAFailedSendReconnects() async throws {
        let mac = FakeMac()
        let host = makeHost(mac)
        try await connected(host)

        host.wakeRemoteDisplay()     // the sync send only works on a raw socket, so this one fails

        await wait("the reconnect") { mac.dials == 2 && host.state == .connected }
        host.disconnect()
    }

    /// Writes already queued on the old link fail after its session is gone. They used to call
    /// disconnect(), which would now end the reconnect or the new session.
    func testALateSendFailureCannotEndTheNewSession() async throws {
        let mac = FakeMac()
        let host = makeHost(mac)
        try await connected(host)
        let old = PeerLink(stream: mac.streams[0])
        mac.streams[0].end(with: LinkError.lost)
        await wait("the reconnect") { mac.dials == 2 && host.state == .connected }

        host.sendFailed(on: old)

        XCTAssertEqual(host.state, .connected)
        XCTAssertEqual(mac.dials, 2)
        host.disconnect()
    }

    // MARK: When it must not

    /// The other Mac chose to end it, or KMctrl quit there. Coming back would undo that.
    func testALinkClosedOnPurposeStaysClosed() async throws {
        let mac = FakeMac()
        let host = makeHost(mac)
        try await connected(host)

        mac.streams[0].end(with: LinkError.closed)

        await wait("the session to end") { host.state == .idle }
        XCTAssertFalse(host.reconnecting)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(mac.dials, 1)
    }

    func testDisconnectStopsTheRetries() async throws {
        let mac = FakeMac()
        let host = makeHost(mac)
        try await connected(host)
        mac.failingDials = .max

        mac.streams[0].end(with: LinkError.lost)
        await wait("the first failed attempt") { mac.dials == 2 }
        host.disconnect()

        XCTAssertEqual(host.state, .idle)
        XCTAssertFalse(host.reconnecting)
        try await Task.sleep(nanoseconds: 1_500_000_000)    // past the next attempt's delay
        XCTAssertEqual(mac.dials, 2)
        XCTAssertEqual(host.state, .idle)
    }

    /// "Control is turned off", "you ended this session": a real answer, so asking again is wrong.
    func testARefusalStopsTheRetriesAndSaysWhy() async throws {
        let mac = FakeMac()
        let host = makeHost(mac)
        try await connected(host)
        mac.refusal = "Home ended the session"

        mac.streams[0].end(with: LinkError.lost)

        await wait("the refusal") { host.state == .idle }
        XCTAssertEqual(host.lastError, "Home ended the session")
        XCTAssertFalse(host.reconnecting)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(mac.dials, 2)
    }

    /// Every key typed would go to whichever Mac answers, so the pin check holds on a retry too.
    func testADifferentMacAnsweringStopsTheRetries() async throws {
        let mac = FakeMac()
        let host = makeHost(mac)
        try await connected(host)
        host.hostCheck = { _, _ in .mismatch(expected: "pinned") }

        mac.streams[0].end(with: LinkError.lost)

        await wait("the refusal") { host.state == .idle }
        XCTAssertTrue(host.lastError?.contains("not the one you paired with") == true)
        XCTAssertFalse(host.reconnecting)
        XCTAssertNil(host.peerFingerprint)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(mac.dials, 2)
    }
}

/// What a raw socket reports when a link ends, using a real TCP connection on this Mac.
final class LinkEndingTests: XCTestCase {
    private func tcpPair() throws -> (client: Int32, server: Int32) {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(listener) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, len) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &len) }
        }
        let client = socket(AF_INET, SOCK_STREAM, 0)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(client, $0, len) }
        }
        XCTAssertEqual(connected, 0)
        let server = accept(listener, nil, nil)
        XCTAssertGreaterThanOrEqual(server, 0)
        return (client, server)
    }

    private func ending(of stream: POSIXByteStream) async -> Error? {
        do { _ = try await stream.receiveBytes(max: 16); return nil } catch { return error }
    }

    /// A reset, like a keepalive timeout, means the connection failed rather than was ended.
    func testAnErrorFromTheSocketMeansLost() async throws {
        let (client, server) = try tcpPair()
        let stream = POSIXByteStream(fd: client)
        defer { stream.close() }
        var abort = linger(l_onoff: 1, l_linger: 0)
        setsockopt(server, SOL_SOCKET, SO_LINGER, &abort, socklen_t(MemoryLayout<linger>.size))
        Darwin.close(server)      // an abortive close sends a reset
        guard case LinkError.lost? = await ending(of: stream) else { return XCTFail("expected lost") }
    }

    func testAnOrderlyCloseFromTheOtherMacMeansClosed() async throws {
        let (client, server) = try tcpPair()
        let stream = POSIXByteStream(fd: client)
        defer { stream.close() }
        Darwin.close(server)
        guard case LinkError.closed? = await ending(of: stream) else { return XCTFail("expected closed") }
    }

    /// Disconnect closes our own socket under a blocked receive. That must never look like a loss.
    func testClosingOurOwnSocketMeansClosed() async throws {
        let (client, server) = try tcpPair()
        defer { Darwin.close(server) }
        let stream = POSIXByteStream(fd: client)
        async let end = ending(of: stream)
        try await Task.sleep(nanoseconds: 50_000_000)
        stream.close()
        guard case LinkError.closed? = await end else { return XCTFail("expected closed") }
    }
}

/// The controlled Mac's kill switch has to survive automatic reconnects.
final class ControllerKickListTests: XCTestCase {
    func testAReconnectFromAKickedMacIsRefused() {
        var list = ControllerKickList()
        list.kick("work")
        XCTAssertFalse(list.allows("work", isReconnect: true))
        XCTAssertFalse(list.allows("work", isReconnect: true))     // and stays refused
    }

    func testConnectingOnPurposeLiftsTheKick() {
        var list = ControllerKickList()
        list.kick("work")
        XCTAssertTrue(list.allows("work", isReconnect: false))
        XCTAssertTrue(list.allows("work", isReconnect: true))
    }

    func testAKickOnlyAppliesToThatMac() {
        var list = ControllerKickList()
        list.kick("work")
        XCTAssertTrue(list.allows("laptop", isReconnect: true))
    }

    /// The other Mac may not have noticed the old link died yet. The same Mac coming back makes
    /// that session dead for certain; another Mac's session is not its to end.
    func testOnlyTheSameMacReplacesItsOldSession() {
        XCTAssertTrue(ControlManager.replacesSession(of: "work", with: "work"))
        XCTAssertFalse(ControlManager.replacesSession(of: "laptop", with: "work"))
        XCTAssertFalse(ControlManager.replacesSession(of: nil, with: "work"))
    }
}
