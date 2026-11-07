import XCTest
@testable import KMctrl

final class SystemEventLogTests: XCTestCase {
    /// `log show` is blocked on a managed Mac, so Diagnostics has to record what the Mac did
    /// around a dropped link: which interfaces it had and what address it was on.
    func testNetworkLineNamesInterfacesAndAddress() {
        XCTAssertEqual(SystemEventLog.networkLine(connected: true, interfaces: ["en9", "en0"], address: "192.168.1.249"),
                       "network: up — en9,en0, address 192.168.1.249")
        XCTAssertEqual(SystemEventLog.networkLine(connected: false, interfaces: [], address: nil),
                       "network: down — no interfaces, address none")
    }

    /// The path monitor fires for changes that don't matter here; repeats would bury the log.
    func testOnlyARealChangeIsLogged() {
        var filter = SystemEventLog.ChangeFilter()
        XCTAssertEqual(filter.changed("a"), "a")
        XCTAssertNil(filter.changed("a"))
        XCTAssertEqual(filter.changed("b"), "b")
        XCTAssertEqual(filter.changed("a"), "a")
    }
}
