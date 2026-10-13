import XCTest
@testable import KMctrl

final class IdentityKeyCacheTests: XCTestCase {
    /// Every outgoing connection used to hit the Keychain, which can raise a password
    /// prompt on a managed Mac mid-capture. The key must be read at most once per launch.
    func testIdentityKeyIsReadFromKeychainAtMostOnce() {
        let a = CryptoService.identitySigningKey()
        let loadsAfterFirst = CryptoService.keychainLoadCount
        let b = CryptoService.identitySigningKey()
        let c = CryptoService.identitySigningKey()
        XCTAssertEqual(CryptoService.keychainLoadCount, loadsAfterFirst)
        XCTAssertLessThanOrEqual(loadsAfterFirst, 1)
        XCTAssertEqual(a.rawRepresentation, b.rawRepresentation)
        XCTAssertEqual(b.rawRepresentation, c.rawRepresentation)
    }
}
