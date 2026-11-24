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
        XCTAssertEqual(back.version, 7)   // v7 (1.0): JSON-only control frames
    }
}

/// 1.0 drops per-feature fallbacks for old releases: both Macs need protocol v7 (1.0) or
/// later, and an older one is refused with a message saying to update.
final class MinimumVersionTests: XCTestCase {
    func testOnly1Point0AndLaterAreSupported() {
        XCTAssertFalse(SessionHello.isSupported(controlVersion: 1))   // 0.7.x sends no version
        XCTAssertFalse(SessionHello.isSupported(controlVersion: 6))   // 0.8.24 may send binary frames
        XCTAssertTrue(SessionHello.isSupported(controlVersion: 7))    // 1.0
        XCTAssertTrue(SessionHello.isSupported(controlVersion: SessionHello.currentControlVersion))
        XCTAssertTrue(SessionHello.isSupported(controlVersion: SessionHello.minimumControlVersion))
    }

    func testAHelloWithoutAVersionIsTooOld() throws {
        let legacy = try JSONDecoder().decode(SessionHello.self, from: Data(#"{"kind":"control"}"#.utf8))
        XCTAssertFalse(SessionHello.isSupported(controlVersion: legacy.version))
    }

    func testRefusalsSayWhatToUpdate() {
        XCTAssertTrue(SessionHello.olderControllerReason(thisMac: "Home").contains("1.0 or later"))
        XCTAssertTrue(SessionHello.olderControlledReason(other: "Work").hasPrefix("Work runs an older KMctrl"))
    }
}
