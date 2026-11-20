import XCTest
@testable import KMctrl

/// Either Mac can ask the other for its KMctrl diagnostics log over the control link (protocol
/// v6) and save both under ~/Library/Logs/KMctrl.
final class LogExchangeProtocolTests: XCTestCase {
    private let bundle = LogBundle(device: "Work Mac", app: "0.8.24 (38)", os: "Version 26.1", created: 1_800_000_000,
                                   diagnosticsOn: true, lines: "12:00:00.000  [INFO]  control: session started\n")

    func testProtocolIsV6() {
        XCTAssertEqual(SessionHello.currentControlVersion, 6)
    }

    func testOnlyV6PeersAreAskedOrAnswered() {
        XCTAssertFalse(ControlHost.sendsLogRequest(peerVersion: 5))   // a v5 peer drops the session on the unknown kind
        XCTAssertTrue(ControlHost.sendsLogRequest(peerVersion: 6))
    }

    func testLogKindsAreAppendedToTheWireOrder() {
        let order = ControlEventKind.wireOrder
        XCTAssertEqual(Array(order.suffix(2)), [.logRequest, .log])
        XCTAssertEqual(order.firstIndex(of: .edgeSetup), 14)           // nothing before them moved
    }

    func testTheControllersLogTravelsAsJSONOnly() throws {
        let e = ControlEvent(kind: .log, log: bundle)
        XCTAssertFalse(e.isBinaryEncodable)
        let back = try JSONDecoder().decode(ControlEvent.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(back.kind, .log)
        XCTAssertEqual(back.log, bundle)
    }

    func testARequestIsAPlainEvent() throws {
        let e = ControlEvent(kind: .logRequest)
        XCTAssertNotNil(e.sanitizedForInjection())
        let json = String(decoding: try JSONEncoder().encode(e), as: UTF8.self)
        XCTAssertFalse(json.contains("\"log\""))                       // omitted, not null
    }

    func testLogFramesFromTheControlledMacAreNeverAReturnOfControl() throws {
        XCTAssertFalse(ControlReturn(log: bundle).isReturnSignal)
        XCTAssertFalse(ControlReturn(logRequest: true).isReturnSignal)
        XCTAssertTrue(ControlReturn(at: [1, 2]).isReturnSignal)
        let back = try JSONDecoder().decode(ControlReturn.self, from: JSONEncoder().encode(ControlReturn(log: bundle)))
        XCTAssertEqual(back.log, bundle)
        let asked = try JSONDecoder().decode(ControlReturn.self, from: JSONEncoder().encode(ControlReturn(logRequest: true)))
        XCTAssertEqual(asked.logRequest, true)
    }
}

final class LogBundleTests: XCTestCase {
    func testAHugeLogKeepsItsNewestLines() {
        let line = String(repeating: "x", count: 99) + "\n"
        let lines = (0..<20_000).map { "\($0) " + line }.joined()
        let b = LogBundle(device: "Mac", app: "1", os: "x", created: 0, diagnosticsOn: true, lines: lines).sanitized
        XCTAssertLessThanOrEqual(b.lines.utf8.count, LogBundle.maxBytes + 100)
        XCTAssertTrue(b.lines.hasSuffix("19999 " + line))
        XCTAssertTrue(b.lines.hasPrefix("…"))
    }

    func testControlCharactersAreStrippedButLinesKept() {
        let b = LogBundle(device: "Ma\u{1B}[31mc", app: "1", os: "x", created: 0, diagnosticsOn: true,
                          lines: "a\u{1B}[2Jb\tc\nd\u{7}\n").sanitized
        XCTAssertEqual(b.lines, "a[2Jb\tc\nd\n")
        XCTAssertFalse(b.device.contains("\u{1B}"))
    }

    func testFileNamesAreSafe() {
        XCTAssertEqual(LogFiles.fileName(device: "Joe's Mac/Pro"), "Joe-s Mac-Pro.log")
        XCTAssertEqual(LogFiles.fileName(device: "../../etc"), "etc.log")
        XCTAssertEqual(LogFiles.fileName(device: ""), "Mac.log")
        XCTAssertEqual(LogFiles.fileName(device: "Work Mac", received: true), "Work Mac (received).log")
        XCTAssertLessThanOrEqual(LogFiles.fileName(device: String(repeating: "a", count: 500)).count, 80)
    }

    func testTheSavedFileSaysWhichMacAndWhetherLoggingWasOn() {
        let b = LogBundle(device: "Work Mac", app: "0.8.24 (38)", os: "Version 26.1", created: 0,
                          diagnosticsOn: false, lines: "")
        let text = LogFiles.render(b, receivedFrom: "UK-WORK")
        XCTAssertTrue(text.contains("Work Mac"))
        XCTAssertTrue(text.contains("0.8.24 (38)"))
        XCTAssertTrue(text.contains("received from UK-WORK"))
        XCTAssertTrue(text.contains("Diagnostics logging was off"))
    }

    func testSavingWritesAndReplacesTheFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kmctrl-logs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let b = LogBundle(device: "Home", app: "1", os: "x", created: 0, diagnosticsOn: true, lines: "first\n")
        let url = try LogFiles.save(b, receivedFrom: nil, in: dir)
        XCTAssertEqual(url.lastPathComponent, "Home.log")
        var c = b; c.lines = "second\n"
        _ = try LogFiles.save(c, receivedFrom: nil, in: dir)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("second"))
        XCTAssertFalse(text.contains("first"))
    }

    func testTheLogsFolderIsInTheRealHomeNotTheSandbox() {
        let path = LogFiles.directory.path
        XCTAssertTrue(path.hasSuffix("/Library/Logs/KMctrl"))
        XCTAssertFalse(path.contains("/Library/Containers/"))
    }
}

final class LogRequestPolicyTests: XCTestCase {
    func testALogIsOnlyTakenShortlyAfterAsking() {
        var p = LogRequestPolicy()
        XCTAssertFalse(p.accepts(at: 100))                 // never asked: ignore
        p.asked(at: 100)
        XCTAssertTrue(p.accepts(at: 110))
        XCTAssertFalse(p.accepts(at: 100 + LogRequestPolicy.answerWindow + 1))
    }

    func testAnsweringIsRateLimited() {
        var p = LogRequestPolicy()
        XCTAssertTrue(p.mayAnswer(at: 50))
        XCTAssertFalse(p.mayAnswer(at: 50.5))
        XCTAssertTrue(p.mayAnswer(at: 50 + LogRequestPolicy.answerInterval))
    }
}

final class URLCommandTests: XCTestCase {
    func testOnlyThePlainLogsURLIsAccepted() {
        XCTAssertTrue(URLCommands.isPullLogs("kmctrl://logs"))
        XCTAssertTrue(URLCommands.isPullLogs("KMctrl://Logs/"))
        XCTAssertFalse(URLCommands.isPullLogs("kmctrl://logs?to=evil"))
        XCTAssertFalse(URLCommands.isPullLogs("kmctrl://logs/../../x"))
        XCTAssertFalse(URLCommands.isPullLogs("kmctrl://other"))
        XCTAssertFalse(URLCommands.isPullLogs("https://logs"))
        XCTAssertFalse(URLCommands.isPullLogs(""))
    }
}
