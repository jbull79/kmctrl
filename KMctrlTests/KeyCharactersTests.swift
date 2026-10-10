import XCTest
import CoreGraphics
@testable import KMctrl

final class KeyCharactersTests: XCTestCase {
    func testPlainTypingIsOverridden() {
        XCTAssertEqual(KeyCharacters.override(for: "é", flags: 0), "é")
        XCTAssertEqual(KeyCharacters.override(for: "A", flags: CGEventFlags.maskShift.rawValue), "A")
        XCTAssertEqual(KeyCharacters.override(for: "€", flags: CGEventFlags.maskAlternate.rawValue), "€")
    }

    func testCommandAndControlAreNotOverridden() {
        XCTAssertNil(KeyCharacters.override(for: "c", flags: CGEventFlags.maskCommand.rawValue))
        XCTAssertNil(KeyCharacters.override(for: "c", flags: CGEventFlags.maskControl.rawValue))
    }

    func testControlAndFunctionKeysAreNotOverridden() {
        XCTAssertNil(KeyCharacters.override(for: "\r", flags: 0))
        XCTAssertNil(KeyCharacters.override(for: "\t", flags: 0))
        XCTAssertNil(KeyCharacters.override(for: "\u{7F}", flags: 0))      // delete
        XCTAssertNil(KeyCharacters.override(for: "\u{1B}", flags: 0))      // esc
        XCTAssertNil(KeyCharacters.override(for: "\u{F700}", flags: 0))    // up arrow (PUA)
        XCTAssertNil(KeyCharacters.override(for: "", flags: 0))            // dead key
        XCTAssertNil(KeyCharacters.override(for: nil, flags: 0))
    }

    func testSpaceIsOverridden() {
        XCTAssertEqual(KeyCharacters.override(for: " ", flags: 0), " ")
    }
}
