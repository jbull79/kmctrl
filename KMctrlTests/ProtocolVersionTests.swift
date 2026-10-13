import XCTest
@testable import KMctrl

final class ProtocolVersionTests: XCTestCase {
    func testAckWithoutVersionDecodesAsV1() throws {
        let legacy = Data(#"{"accepted":true,"reason":""}"#.utf8)
        let ack = try JSONDecoder().decode(ControlAck.self, from: legacy)
        XCTAssertEqual(ack.version, 1)
    }

    func testAckCarriesCurrentVersion() throws {
        let ack = ControlAck(accepted: true, version: SessionHello.currentControlVersion)
        let back = try JSONDecoder().decode(ControlAck.self, from: JSONEncoder().encode(ack))
        XCTAssertEqual(back.version, 3)
    }
}
