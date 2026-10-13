import XCTest
@testable import KMctrl

final class BadgePlacementTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 877)   // visibleFrame (Dock/menu bar excluded)
    let size = CGSize(width: 320, height: 44)

    func testDefaultIsBottomRightWithMargin() {
        let o = BadgePlacement.origin(size: size, visibleFrame: screen, saved: nil)
        XCTAssertEqual(o, CGPoint(x: 1440 - 320 - 16, y: 16))
    }

    func testSavedPositionIsKeptWhenOnScreen() {
        let o = BadgePlacement.origin(size: size, visibleFrame: screen, saved: CGPoint(x: 100, y: 500))
        XCTAssertEqual(o, CGPoint(x: 100, y: 500))
    }

    func testSavedPositionIsClampedBackOntoScreen() {
        let o = BadgePlacement.origin(size: size, visibleFrame: screen, saved: CGPoint(x: 5000, y: -40))
        XCTAssertEqual(o, CGPoint(x: 1440 - 320 - 16, y: 16))
    }
}
