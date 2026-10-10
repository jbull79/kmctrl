import XCTest
@testable import KMctrl

final class AppVersionTests: XCTestCase {
    func testParsesWithAndWithoutV() {
        XCTAssertEqual(AppVersion("v0.8.0")?.parts, [0, 8, 0])
        XCTAssertEqual(AppVersion("1.2")?.parts, [1, 2])
    }

    func testUnparseableTagIsNotNewer() {
        XCTAssertNil(AppVersion("nightly"))
        XCTAssertNil(AppVersion("v0.8.0-beta"))
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("1..2"))
    }

    func testComparison() {
        XCTAssertTrue(AppVersion("0.7.1")! < AppVersion("0.8.0")!)
        XCTAssertTrue(AppVersion("0.8")! < AppVersion("0.8.1")!)
        XCTAssertFalse(AppVersion("0.8.0")! < AppVersion("0.8")!)
        XCTAssertEqual(AppVersion("1.0.0")!, AppVersion("1.0")!)
        XCTAssertTrue(AppVersion("0.10.0")! > AppVersion("0.9.9")!)
    }

    func testReleaseInfoPicksAppZipAsset() throws {
        let json = """
        {"tag_name":"v0.9.0","html_url":"https://example/r","assets":[
          {"name":"KMctrl-0.9.0.dSYM.zip","browser_download_url":"https://example/d.zip"},
          {"name":"KMctrl-0.9.0.zip","browser_download_url":"https://example/a.zip"}]}
        """
        let r = try JSONDecoder().decode(ReleaseInfo.self, from: Data(json.utf8))
        XCTAssertEqual(r.downloadURL?.absoluteString, "https://example/a.zip")
    }

    func testReleaseInfoFallsBackToReleasePage() throws {
        let json = #"{"tag_name":"v0.9.0","html_url":"https://example/r","assets":[]}"#
        let r = try JSONDecoder().decode(ReleaseInfo.self, from: Data(json.utf8))
        XCTAssertEqual(r.downloadURL?.absoluteString, "https://example/r")
    }

    @MainActor
    func testEvaluateIgnoresOlderAndUnparseable() {
        let url = URL(string: "https://example/a.zip")!
        XCTAssertNil(UpdateChecker.evaluate(tag: "v0.0.1", url: url))
        XCTAssertNil(UpdateChecker.evaluate(tag: "nightly", url: url))
        XCTAssertEqual(UpdateChecker.evaluate(tag: "v99.0", url: url)?.version, "99.0")
    }

    func testUpdateErrorsAreExplained() {
        XCTAssertEqual(UpdateCheckError.notFound.errorDescription, "No release found — the GitHub repo may be private.")
        XCTAssertEqual(UpdateCheckError.httpStatus(503).errorDescription, "GitHub answered HTTP 503.")
    }
}
