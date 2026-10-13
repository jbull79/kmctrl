import XCTest
@testable import KMctrl

final class ControlCodecTests: XCTestCase {
    func testWireOrderIsStable() {
        // APPEND-ONLY table: changing any existing byte breaks cross-version decoding.
        let expected: [ControlEventKind] = [
            .mouseMove, .mouseDown, .mouseUp, .scroll,
            .keyDown, .keyUp, .flagsChanged, .releaseAll, .hostStats, .ping
        ]
        XCTAssertEqual(Array(ControlEventKind.wireOrder.prefix(expected.count)), expected)
    }

    func testBinaryRoundTripEveryKind() throws {
        for kind in ControlEventKind.wireOrder {
            let e = ControlEvent(kind: kind, dx: -12.5, dy: 3.25, button: 2,
                                 scrollX: 0.125, scrollY: -7, keyCode: 126, flags: 0x120008)
            let back = try ControlEvent(binary: e.encodedBinary())
            XCTAssertEqual(back.kind, kind)
            XCTAssertEqual(back.dx, -12.5); XCTAssertEqual(back.dy, 3.25)
            XCTAssertEqual(back.button, 2); XCTAssertEqual(back.keyCode, 126)
            XCTAssertEqual(back.scrollX, 0.125); XCTAssertEqual(back.scrollY, -7)
            XCTAssertEqual(back.flags, 0x120008)
        }
    }

    func testUnknownWireByteIsNil() {
        XCTAssertNil(ControlEventKind(wireByte: 200))
    }

    func testWrongSizeFrameThrows() {
        XCTAssertThrowsError(try ControlEvent(binary: Data(repeating: 0, count: 10)))
    }

    func testUnknownKindFrameThrows() {
        var d = Data(repeating: 0, count: ControlEvent.binarySize)
        d[0] = 200
        XCTAssertThrowsError(try ControlEvent(binary: d))
    }

    func testJSONKeysMatchLegacyProtocol() throws {
        // A plain move encodes exactly the 0.7.1 keys (no new optional fields leak in).
        let data = try JSONEncoder().encode(ControlEvent(kind: .mouseMove, dx: 1, dy: 2))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["kind", "dx", "dy", "button", "scrollX", "scrollY", "keyCode", "flags"])
    }

    func testBinaryTrailerRoundTripsChars() throws {
        var e = ControlEvent(kind: .keyDown, keyCode: 0); e.chars = "ñ"
        let data = e.encodedBinary()
        XCTAssertEqual(data.count, ControlEvent.binarySize + 1 + 2)   // ñ is 2 UTF-8 bytes
        XCTAssertEqual(try ControlEvent(binary: data).chars, "ñ")
    }

    func testLegacy44ByteFrameDecodes() throws {
        let data = ControlEvent(kind: .keyDown, keyCode: 5).encodedBinary()
        XCTAssertEqual(data.count, ControlEvent.binarySize)
        XCTAssertNil(try ControlEvent(binary: data).chars)
    }

    func testOversizeCharsDroppedInBinary() throws {
        var e = ControlEvent(kind: .keyDown); e.chars = String(repeating: "x", count: 40)
        let data = e.encodedBinary()
        XCTAssertEqual(data.count, ControlEvent.binarySize)
        XCTAssertNil(try ControlEvent(binary: data).chars)
    }

    func testTruncatedTrailerThrows() {
        var d = ControlEvent(kind: .keyDown).encodedBinary()
        d.append(5); d.append(contentsOf: [0x61, 0x62])   // claims 5 bytes, provides 2
        XCTAssertThrowsError(try ControlEvent(binary: d))
    }

    func testJSONOmitsCharsWhenNil() throws {
        let data = try JSONEncoder().encode(ControlEvent(kind: .keyDown))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("chars"))
    }

    func testJSONRoundTripsChars() throws {
        var e = ControlEvent(kind: .keyDown); e.chars = "ß"
        XCTAssertEqual(try JSONDecoder().decode(ControlEvent.self, from: JSONEncoder().encode(e)).chars, "ß")
    }

    func testClipboardEventKindWireByte() {
        XCTAssertEqual(ControlEventKind.clipboard.wireByte, 12)
    }

    func testClipboardPayloadRoundTripsInJSONAndIsOmittedWhenNil() throws {
        var e = ControlEvent(kind: .clipboard)
        e.clipboard = ClipboardPayload(text: "hello", image: Data([1, 2]))
        let back = try JSONDecoder().decode(ControlEvent.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(back.clipboard?.text, "hello"); XCTAssertEqual(back.clipboard?.image, Data([1, 2]))
        let plain = try JSONEncoder().encode(ControlEvent(kind: .mouseMove))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("clipboard"))
    }

    func testClipboardEventNeverUsesBinaryCodec() {
        var e = ControlEvent(kind: .clipboard); e.clipboard = ClipboardPayload(text: "x", image: nil)
        XCTAssertFalse(e.isBinaryEncodable)
        XCTAssertTrue(ControlEvent(kind: .mouseMove).isBinaryEncodable)
    }

    func testControlReturnCarriesClipboard() throws {
        let r = ControlReturn(clipboard: ClipboardPayload(text: "back", image: nil))
        let back = try JSONDecoder().decode(ControlReturn.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back.clipboard?.text, "back"); XCTAssertNil(back.pong); XCTAssertTrue(back.ok)
        let legacy = try JSONDecoder().decode(ControlReturn.self, from: Data(#"{"ok":true}"#.utf8))
        XCTAssertNil(legacy.clipboard)
    }
}
