import XCTest
@testable import KMctrl

@MainActor
final class AppSettingsTests: XCTestCase {
    func testFlushIntervalClamp() {
        XCTAssertEqual(AppSettings.clampedFlushInterval(4), 4)
        XCTAssertEqual(AppSettings.clampedFlushInterval(16), 16)
        XCTAssertEqual(AppSettings.clampedFlushInterval(0), AppSettings.defaultFlushInterval)
        XCTAssertEqual(AppSettings.clampedFlushInterval(5), AppSettings.defaultFlushInterval)
    }

    func testControlReturnPongRoundTrip() throws {
        let plain = try JSONDecoder().decode(ControlReturn.self, from: JSONEncoder().encode(ControlReturn()))
        XCTAssertNil(plain.pong); XCTAssertTrue(plain.ok)
        let pong = try JSONDecoder().decode(ControlReturn.self, from: JSONEncoder().encode(ControlReturn(pong: 42)))
        XCTAssertEqual(pong.pong, 42)
    }

    func testMouseSensitivityClamp() {
        XCTAssertEqual(AppSettings.clampedMouseSensitivity(0), 1.0)      // unset default
        XCTAssertEqual(AppSettings.clampedMouseSensitivity(0.1), 0.25)
        XCTAssertEqual(AppSettings.clampedMouseSensitivity(10), 3.0)
        XCTAssertEqual(AppSettings.clampedMouseSensitivity(1.5), 1.5)
    }
}
