import XCTest
@testable import KMctrl

final class MediaKeyTests: XCTestCase {
    // NX_KEYTYPE_SOUND_UP = 0; key-down state 0x0A, key-up 0x0B; bit 0 = autorepeat.
    func testDecodeVolumeUpDown() {
        let down = MediaKey.decode(data1: (0 << 16) | (0x0A << 8))
        XCTAssertEqual(down, MediaKey(key: 0, isDown: true, isRepeat: false))
        let up = MediaKey.decode(data1: (0 << 16) | (0x0B << 8))
        XCTAssertEqual(up, MediaKey(key: 0, isDown: false, isRepeat: false))
    }

    func testDecodeRepeatBit() {
        XCTAssertEqual(MediaKey.decode(data1: (16 << 16) | (0x0A << 8) | 1)?.isRepeat, true)
    }

    func testUnknownStateIsNil() {
        XCTAssertNil(MediaKey.decode(data1: (0 << 16) | (0x05 << 8)))
    }

    func testRoundTrip() {
        let k = MediaKey(key: 7, isDown: true, isRepeat: false)
        XCTAssertEqual(MediaKey.decode(data1: k.data1), k)
    }

    func testForwardedSet() {
        XCTAssertTrue(MediaKey.forwarded.contains(16))   // play/pause
        XCTAssertTrue(MediaKey.forwarded.contains(0))    // volume up
        XCTAssertFalse(MediaKey.forwarded.contains(10))  // NX_POWER_KEY — never forward power
        XCTAssertFalse(MediaKey.forwarded.contains(6))   // NX_KEYTYPE_EJECT — never eject remotely
    }

    func testMediaKeyWireByte() {
        XCTAssertEqual(ControlEventKind.mediaKey.wireByte, 10)
        XCTAssertEqual(ControlEventKind(wireByte: 10), .mediaKey)
    }

    func testWakeDisplayWireByte() {
        XCTAssertEqual(ControlEventKind.wakeDisplay.wireByte, 11)
        XCTAssertEqual(ControlEventKind(wireByte: 11), .wakeDisplay)
    }
}
