import XCTest
@testable import KMctrl

/// Control events travel as JSON (1.0 dropped the experimental binary codec).
final class ControlCodecTests: XCTestCase {
    func testAPlainMoveCarriesOnlyItsFields() throws {
        // No optional field leaks into the hot path.
        let data = try JSONEncoder().encode(ControlEvent(kind: .mouseMove, dx: 1, dy: 2))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["kind", "dx", "dy", "button", "scrollX", "scrollY", "keyCode", "flags"])
    }

    func testEveryKindRoundTrips() throws {
        for kind in [ControlEventKind.mouseMove, .mouseDown, .mouseUp, .scroll, .keyDown, .keyUp, .flagsChanged,
                     .releaseAll, .hostStats, .ping, .mediaKey, .wakeDisplay, .clipboard, .enterAt, .edgeSetup,
                     .logRequest, .log] {
            let e = ControlEvent(kind: kind, dx: -12.5, dy: 3.25, button: 2, scrollX: 0.125, scrollY: -7, keyCode: 126, flags: 0x120008)
            let back = try JSONDecoder().decode(ControlEvent.self, from: JSONEncoder().encode(e))
            XCTAssertEqual(back.kind, kind)
            XCTAssertEqual(back.dx, -12.5); XCTAssertEqual(back.dy, 3.25)
            XCTAssertEqual(back.button, 2); XCTAssertEqual(back.keyCode, 126); XCTAssertEqual(back.flags, 0x120008)
        }
    }

    func testJSONOmitsCharsWhenNil() throws {
        let data = try JSONEncoder().encode(ControlEvent(kind: .keyDown))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("chars"))
    }

    func testJSONRoundTripsChars() throws {
        var e = ControlEvent(kind: .keyDown); e.chars = "ß"
        XCTAssertEqual(try JSONDecoder().decode(ControlEvent.self, from: JSONEncoder().encode(e)).chars, "ß")
    }

    func testClipboardPayloadRoundTripsInJSONAndIsOmittedWhenNil() throws {
        var e = ControlEvent(kind: .clipboard)
        e.clipboard = ClipboardPayload(text: "hello", image: Data([1, 2]))
        let back = try JSONDecoder().decode(ControlEvent.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(back.clipboard?.text, "hello"); XCTAssertEqual(back.clipboard?.image, Data([1, 2]))
        let plain = try JSONEncoder().encode(ControlEvent(kind: .mouseMove))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("clipboard"))
    }

    func testAnUnknownKindIsRejected() {
        XCTAssertThrowsError(try JSONDecoder().decode(ControlEvent.self, from: Data(#"{"kind":"teleport"}"#.utf8)))
    }

    func testControlReturnCarriesClipboard() throws {
        let r = ControlReturn(clipboard: ClipboardPayload(text: "back", image: nil))
        let back = try JSONDecoder().decode(ControlReturn.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back.clipboard?.text, "back"); XCTAssertNil(back.pong); XCTAssertTrue(back.ok)
        XCTAssertNil(try JSONDecoder().decode(ControlReturn.self, from: Data(#"{"ok":true}"#.utf8)).clipboard)
    }
}
