import XCTest
import Darwin
@testable import KMctrl

final class TransportKeepaliveTests: XCTestCase {
    /// A link whose peer — or whose own address — vanishes (e.g. Wi-Fi switched off while
    /// on Ethernet) must fail within ~20 s instead of waiting on recv forever, otherwise its
    /// session, injector and timer leak for the life of the app.
    func testPOSIXStreamTurnsOnTCPKeepalive() {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let stream = POSIXByteStream(fd: fd)
        defer { stream.close() }
        func option(_ level: Int32, _ name: Int32) -> Int32 {
            var value: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, level, name, &value, &len)
            return value
        }
        XCTAssertNotEqual(option(SOL_SOCKET, SO_KEEPALIVE), 0)
        XCTAssertEqual(option(IPPROTO_TCP, TCP_KEEPALIVE), 10)   // idle seconds before probing
        XCTAssertEqual(option(IPPROTO_TCP, TCP_KEEPINTVL), 3)
        XCTAssertEqual(option(IPPROTO_TCP, TCP_KEEPCNT), 3)
    }
}
