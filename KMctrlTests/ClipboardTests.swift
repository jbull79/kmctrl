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
/// Clipboard follows the keyboard: pushed on hand-off, never polled.
@MainActor
final class ClipboardSyncBehaviourTests: XCTestCase {
    private var pb: NSPasteboard!
    private var sent: [(ClipboardPayload, String)] = []
    private var enabled = true
    private let peer = Peer(id: "p", name: "Other", endpoint: .hostPort(host: "127.0.0.1", port: 1))

    override func setUp() {
        pb = NSPasteboard(name: NSPasteboard.Name("kmctrl.tests.\(UUID().uuidString)"))
        sent = []; enabled = true
    }
    override func tearDown() { pb.releaseGlobally() }

    private func makeSync(graceSeconds: Double = 5) -> ClipboardSync {
        ClipboardSync(pasteboard: pb, isEnabled: { [unowned self] in self.enabled }, receiveGrace: graceSeconds) {
            [unowned self] payload, _, fingerprint in self.sent.append((payload, fingerprint))
        }
    }

    private func copy(_ text: String) { pb.clearContents(); pb.setString(text, forType: .string) }
    private func settle(_ ms: UInt64 = 80) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    func testHandoffPushesCurrentClipboardWithSessionFingerprint() async {
        let sync = makeSync()
        sync.setActive(true, sessionFingerprint: "fp-1") { [peer] in peer }
        copy("hello")
        sync.pushNow(reason: "test"); await settle()
        XCTAssertEqual(sent.map { $0.0.text }, ["hello"])
        XCTAssertEqual(sent.map { $0.1 }, ["fp-1"])
    }

    func testNothingIsSentWithoutAHandoff() async {
        let sync = makeSync()
        sync.setActive(true, sessionFingerprint: "fp-1") { [peer] in peer }
        copy("a"); await settle(); copy("b"); await settle(300)
        XCTAssertTrue(sent.isEmpty)
    }

    func testUnchangedClipboardIsNotPushedTwice() async {
        let sync = makeSync()
        sync.setActive(true, sessionFingerprint: "fp-1") { [peer] in peer }
        copy("same")
        sync.pushNow(reason: "a"); await settle()
        sync.pushNow(reason: "b"); await settle()
        XCTAssertEqual(sent.count, 1)
        copy("new")
        sync.pushNow(reason: "c"); await settle()
        XCTAssertEqual(sent.map { $0.0.text }, ["same", "new"])
    }

    func testReceivedContentIsNotPushedBack() async {
        let sync = makeSync()
        sync.setActive(true, sessionFingerprint: "fp-1") { [peer] in peer }
        sync.receive(ClipboardPayload(text: "from-peer", image: nil), from: "fp-1")
        sync.pushNow(reason: "release"); await settle()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(pb.string(forType: .string), "from-peer")
    }

    func testDisabledMacNeitherPushesNorAccepts() async {
        let sync = makeSync()
        sync.setActive(true, sessionFingerprint: "fp-1") { [peer] in peer }
        enabled = false
        copy("mine")
        sync.pushNow(reason: "x"); await settle()
        XCTAssertTrue(sent.isEmpty)
        sync.receive(ClipboardPayload(text: "theirs", image: nil), from: "fp-1")
        XCTAssertEqual(pb.string(forType: .string), "mine")
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

    func testReceiveAcceptedBrieflyAfterSessionEndsThenRejected() async {
        // The controlled Mac pushes its clipboard back as the session ends; the controller
        // may already have torn down the link, so accept from that peer for a short grace.
        let sync = makeSync(graceSeconds: 0.2)
        sync.setActive(true, sessionFingerprint: "abc") { [peer] in peer }
        sync.setActive(false, sessionFingerprint: "") { nil }
        copy("mine")
        sync.receive(ClipboardPayload(text: "late", image: nil), from: "abc")
        XCTAssertEqual(pb.string(forType: .string), "late")
        await settle(300)
        sync.receive(ClipboardPayload(text: "too-late", image: nil), from: "abc")
        XCTAssertEqual(pb.string(forType: .string), "late")
    }

    func testReceiveIgnoredWhenNoSessionEver() {
        let sync = makeSync()
        copy("mine")
        sync.receive(ClipboardPayload(text: "theirs", image: nil), from: "abc")
        XCTAssertEqual(pb.string(forType: .string), "mine")
    }
}
