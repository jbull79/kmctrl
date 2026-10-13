import XCTest
@testable import KMctrl

final class ClipboardSessionPolicyTests: XCTestCase {
    func testConnectThenCaptureThenRelease() {
        XCTAssertEqual(ClipboardSessionPolicy.action(from: .idle, to: .connecting), .none)
        XCTAssertEqual(ClipboardSessionPolicy.action(from: .connecting, to: .connected), .activate)
        XCTAssertEqual(ClipboardSessionPolicy.action(from: .connected, to: .capturing), .push)
        XCTAssertEqual(ClipboardSessionPolicy.action(from: .capturing, to: .connected), .none)   // release: peer pushes
        XCTAssertEqual(ClipboardSessionPolicy.action(from: .connected, to: .capturing), .push)   // re-grab pushes again
        XCTAssertEqual(ClipboardSessionPolicy.action(from: .connected, to: .idle), .deactivate)
    }

    func testDropWhileCapturingDeactivates() {
        XCTAssertEqual(ClipboardSessionPolicy.action(from: .capturing, to: .idle), .deactivate)
    }

    func testFailedConnectDoesNothing() {
        XCTAssertEqual(ClipboardSessionPolicy.action(from: .connecting, to: .idle), .none)
    }
}
