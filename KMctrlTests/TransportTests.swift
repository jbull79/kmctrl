import XCTest
import Darwin
@testable import KMctrl

final class TransportTests: XCTestCase {
    /// A peer that closes its socket must not take this process down with SIGPIPE: the
    /// write has to fail (return false) so the caller can disconnect cleanly.
    func testWriteToClosedPeerFailsInsteadOfSIGPIPE() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let stream = POSIXByteStream(fd: fds[0])
        Darwin.close(fds[1])                       // peer goes away
        // First write may succeed into the buffer; keep writing until the kernel notices.
        var ok = true
        for _ in 0..<64 where ok { ok = stream.sendFrameSync(Data(repeating: 0x41, count: 4096)) }
        XCTAssertFalse(ok)                         // reaching here at all means no SIGPIPE
        stream.close()
    }
}
