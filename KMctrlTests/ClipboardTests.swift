import XCTest
import AppKit
import Network
@testable import KMctrl

final class ClipboardTests: XCTestCase {
    func testLimits() {
        XCTAssertTrue(ClipboardPayload(text: "hi", image: nil).isWithinLimits)
        XCTAssertFalse(ClipboardPayload(text: String(repeating: "a", count: ClipboardPayload.maxTextBytes + 1), image: nil).isWithinLimits)
        XCTAssertFalse(ClipboardPayload(text: nil, image: Data(count: ClipboardPayload.maxImageBytes + 1)).isWithinLimits)
        XCTAssertTrue(ClipboardPayload(text: nil, image: nil).isEmpty)
        XCTAssertTrue(ClipboardPayload(text: "", image: Data()).isEmpty)
        XCTAssertFalse(ClipboardPayload(text: "x", image: nil).isEmpty)
    }

    func testEchoSuppressionIgnoresOwnWrite() {
        var s = ClipboardSyncState()
        XCTAssertFalse(s.noteLocalChange(count: 5))   // first observation = baseline, not a change
        XCTAssertTrue(s.noteLocalChange(count: 6))    // user copied → send
        s.noteOwnWrite(count: 7)                      // we wrote a remote payload
        XCTAssertFalse(s.noteLocalChange(count: 7))   // echo → ignore
        XCTAssertTrue(s.noteLocalChange(count: 8))    // next real copy → send
        XCTAssertFalse(s.noteLocalChange(count: 8))   // unchanged → nothing
    }

    func testPayloadRoundTrip() throws {
        let p = ClipboardPayload(text: "x", image: Data([1, 2, 3]))
        let back = try JSONDecoder().decode(ClipboardPayload.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.text, "x"); XCTAssertEqual(back.image, Data([1, 2, 3]))
    }
}

/// Behavioural tests against a private pasteboard and an injected transport (no network).
@MainActor
final class ClipboardSyncBehaviourTests: XCTestCase {
    private var pb: NSPasteboard!
    private var sent: [(ClipboardPayload, String)] = []
    private var enabled = true
    private var delay: UInt64 = 0
    private let peer = Peer(id: "p", name: "Other", endpoint: .hostPort(host: "127.0.0.1", port: 1))

    override func setUp() {
        pb = NSPasteboard(name: NSPasteboard.Name("kmctrl.tests.\(UUID().uuidString)"))
        sent = []; enabled = true; delay = 0
    }
    override func tearDown() { pb.releaseGlobally() }

    private func makeSync() -> ClipboardSync {
        ClipboardSync(pasteboard: pb, pollInterval: 0.02, isEnabled: { [unowned self] in self.enabled }) {
            [unowned self] payload, _, fingerprint in
            if self.delay > 0 { try await Task.sleep(nanoseconds: self.delay) }
            self.sent.append((payload, fingerprint))
        }
    }

    private func copy(_ text: String) { pb.clearContents(); pb.setString(text, forType: .string) }
    private func settle(_ ms: UInt64 = 120) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    func testCopyDuringInFlightSendIsDeliveredAfterwards() async {
        delay = 150_000_000                                   // first send takes 150 ms
        let sync = makeSync()
        sync.setActive(true, sessionFingerprint: "abc") { [peer] in peer }
        copy("A"); await settle(60)
        copy("B"); await settle(400)
        XCTAssertEqual(sent.map { $0.0.text }, ["A", "B"])
    }

    func testSendCarriesSessionFingerprint() async {
        let sync = makeSync()
        sync.setActive(true, sessionFingerprint: "fp-123") { [peer] in peer }
        copy("hello"); await settle()
        XCTAssertEqual(sent.map { $0.1 }, ["fp-123"])
    }

    func testChangesWhileDisabledAreNotSentOnReenable() async {
        let sync = makeSync()
        sync.setActive(true, sessionFingerprint: "abc") { [peer] in peer }
        enabled = false
        copy("secret"); await settle()
        enabled = true
        await settle()
        XCTAssertTrue(sent.isEmpty)
        copy("public"); await settle()
        XCTAssertEqual(sent.map { $0.0.text }, ["public"])
    }

    func testReceiveIgnoredFromNonSessionPeer() {
        let sync = makeSync()
        sync.setActive(true, sessionFingerprint: "abc") { [peer] in peer }
        copy("mine")
        sync.receive(ClipboardPayload(text: "theirs", image: nil), from: "someone-else")
        XCTAssertEqual(pb.string(forType: .string), "mine")
        sync.receive(ClipboardPayload(text: "theirs", image: nil), from: "abc")
        XCTAssertEqual(pb.string(forType: .string), "theirs")
    }

    func testReceiveIgnoredWhenNoSession() {
        let sync = makeSync()
        copy("mine")
        sync.receive(ClipboardPayload(text: "theirs", image: nil), from: "abc")
        XCTAssertEqual(pb.string(forType: .string), "mine")
    }

    func testReceivedPayloadIsNotEchoedBack() async {
        let sync = makeSync()
        sync.setActive(true, sessionFingerprint: "abc") { [peer] in peer }
        sync.receive(ClipboardPayload(text: "from-peer", image: nil), from: "abc")
        await settle()
        XCTAssertTrue(sent.isEmpty)
    }
}
