import XCTest
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
