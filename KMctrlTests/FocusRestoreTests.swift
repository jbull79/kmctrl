import XCTest
@testable import KMctrl

/// After an edge switch ends, focus goes back to the app you were using. A menu-bar agent
/// (Ice) that grabbed focus because the pointer rested on the menu bar is not that app — use
/// the last ordinary app instead, and never KMctrl itself.
final class FocusRestoreTests: XCTestCase {
    func testOrdinaryFrontAppIsRestored() {
        XCTAssertEqual(FocusRestore.target(front: "Code", frontIsRegular: true, lastRegular: "Mail", me: "KMctrl"), "Code")
    }

    func testMenuBarAgentInFrontFallsBackToLastOrdinaryApp() {
        XCTAssertEqual(FocusRestore.target(front: "Ice", frontIsRegular: false, lastRegular: "Code", me: "KMctrl"), "Code")
    }

    func testKMctrlInFrontFallsBackToLastOrdinaryApp() {
        XCTAssertEqual(FocusRestore.target(front: "KMctrl", frontIsRegular: true, lastRegular: "Code", me: "KMctrl"), "Code")
    }

    func testNothingKnownRestoresNothing() {
        XCTAssertNil(FocusRestore.target(front: "Ice", frontIsRegular: false, lastRegular: nil, me: "KMctrl"))
        XCTAssertNil(FocusRestore.target(front: nil, frontIsRegular: false, lastRegular: "KMctrl", me: "KMctrl"))
    }
}
