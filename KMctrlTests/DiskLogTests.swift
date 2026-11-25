import XCTest
@testable import KMctrl

/// The log on disk survives a crash or a forced quit, which the in-memory log didn't: the work
/// Mac's log of a dropped link was lost when the app had to be restarted.
final class DiskLogTests: XCTestCase {
    private let utc = DebugLog.stampFormatter(TimeZone(identifier: "UTC")!)
    private let now = Date(timeIntervalSince1970: 1_795_000_000)
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("DiskLogTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func line(_ hoursAgo: Double, _ text: String) -> String {
        "\(utc.string(from: now.addingTimeInterval(-hoursAgo * 3600)))  [INFO]  \(text)"
    }

    private func trimmed(_ lines: [String], maxBytes: Int = 1_000_000) -> String {
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        return String(decoding: DiskLog.trimmed(data, now: now, maxAge: 24 * 3600, maxBytes: maxBytes), as: UTF8.self)
    }

    func testKeepsOnlyTheLastDay() {
        let kept = trimmed([line(30, "old"), line(25, "older than a day"), line(2, "recent"), line(0, "now")])
        XCTAssertEqual(kept, line(2, "recent") + "\n" + line(0, "now") + "\n")
    }

    func testALineWithoutAStampGoesWithTheLineBeforeIt() {
        let kept = trimmed([line(30, "old"), "  continued", line(1, "new"), "  continued too"])
        XCTAssertEqual(kept, line(1, "new") + "\n  continued too\n")
    }

    func testNothingRecentLeavesItEmpty() {
        XCTAssertEqual(trimmed([line(48, "a"), line(30, "b")]), "")
    }

    func testOverTheSizeLimitItKeepsTheNewestWholeLines() {
        let lines = (0..<400).map { line(Double(400 - $0) / 100, "line \($0) " + String(repeating: "x", count: 40)) }
        let kept = trimmed(lines, maxBytes: 10_000)
        XCTAssertLessThanOrEqual(kept.utf8.count, 7_500)
        XCTAssertTrue(kept.hasSuffix(lines.last! + "\n"))
        XCTAssertTrue(lines.contains(String(kept.split(separator: "\n")[0])), "cut mid-line")
    }

    func testWritesLinesAndReadsBackTheNewest() throws {
        let log = DiskLog(directory: dir)
        log.write(line(0.2, "first"), now: now)
        log.write(line(0.1, "second"), now: now)
        log.write(line(0, "third"), now: now)
        log.sync()
        let all = try String(contentsOf: log.url, encoding: .utf8)
        XCTAssertEqual(all, [line(0.2, "first"), line(0.1, "second"), line(0, "third")].joined(separator: "\n") + "\n")
        let tail = try XCTUnwrap(log.tail(maxBytes: line(0, "third").utf8.count + 10))
        XCTAssertEqual(tail, line(0, "third") + "\n")
    }

    func testANewRunAddsToTheFileAndDropsWhatIsTooOld() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(DiskLog.fileName)
        try Data((line(26, "yesterday") + "\n" + line(3, "this morning") + "\n").utf8).write(to: url)
        let log = DiskLog(directory: dir)
        log.write(line(0, "started"), now: now)
        log.sync()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), line(3, "this morning") + "\n" + line(0, "started") + "\n")
    }

    func testTurningItOffDeletesTheFile() {
        let log = DiskLog(directory: dir)
        log.write(line(0, "x"), now: now)
        log.erase()
        log.sync()
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.url.path))
        XCTAssertNil(log.tail(maxBytes: 100))
    }

    func testOnByDefault() {
        XCTAssertTrue(DebugLog.diskDefault(nil))
        XCTAssertFalse(DebugLog.diskDefault(false))
    }

    func testTheFileIsInTheLogsFolder() {
        XCTAssertEqual(DiskLog.shared.url, LogFiles.directory.appendingPathComponent("KMctrl.log"))
    }
}
