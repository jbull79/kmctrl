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
}
