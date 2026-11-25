import Foundation

/// KMctrl's log on disk, written as it happens, so a crash, a forced quit or a restart doesn't
/// lose it: ~/Library/Logs/KMctrl/KMctrl.log. It keeps the last day, and never more than
/// `maxBytes`, whichever is less.
final class DiskLog: @unchecked Sendable {
    static let shared = DiskLog()
    static let fileName = "KMctrl.log"
    static let maxAge: TimeInterval = 24 * 60 * 60
    static let maxBytes = 20_000_000
    /// How often the age limit is applied. The size limit is checked on every write.
    static let trimInterval: TimeInterval = 60 * 60

    let url: URL
    private let queue = DispatchQueue(label: "kmctrl.disklog", qos: .utility)
    // Only touched on `queue`, which is what makes the unchecked Sendable safe.
    private var handle: FileHandle?
    private var size = 0
    private var nextTrim = Date.distantPast

    init(directory: URL = LogFiles.directory) {
        url = directory.appendingPathComponent(Self.fileName)
    }

    /// Appends one line (without its newline).
    func write(_ line: String, now: Date = Date()) {
        let data = Data((line + "\n").utf8)
        queue.async { [self] in
            if now >= nextTrim || size + data.count > Self.maxBytes { trim(now: now) }
            guard let h = openIfNeeded() else { return }
            do { try h.write(contentsOf: data); size += data.count } catch { close() }
        }
    }

    /// Stops writing and deletes the file.
    func erase() {
        queue.async { [self] in
            close()
            try? FileManager.default.removeItem(at: url)
            nextTrim = .distantPast
        }
    }

    /// The newest `maxBytes` of the file, starting at a whole line; nil if there's no file.
    func tail(maxBytes: Int) -> String? {
        queue.sync {
            guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? h.close() }
            guard let end = try? h.seekToEnd() else { return nil }
            let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
            guard (try? h.seek(toOffset: start)) != nil, var data = try? h.readToEnd() else { return nil }
            if start > 0 {
                guard let nl = data.firstIndex(of: 0x0A) else { return "" }
                data = Data(data[data.index(after: nl)...])
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Waits for the writes queued so far.
    func sync() { queue.sync {} }

    private func openIfNeeded() -> FileHandle? {
        if let handle { return handle }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url), let end = try? h.seekToEnd() else { return nil }
        handle = h
        size = Int(end)
        return h
    }

    private func close() {
        try? handle?.close()
        handle = nil
    }

    private func trim(now: Date) {
        nextTrim = now.addingTimeInterval(Self.trimInterval)
        close()
        guard let data = try? Data(contentsOf: url) else { return }
        let kept = Self.trimmed(data, now: now, maxAge: Self.maxAge, maxBytes: Self.maxBytes)
        if kept.count != data.count { try? kept.write(to: url, options: .atomic) }
    }

    /// The part of the log to keep: the lines from the last `maxAge`. Over `maxBytes`, it is
    /// first cut to three quarters of that, so a full log isn't rewritten on every line.
    static func trimmed(_ data: Data, now: Date, maxAge: TimeInterval, maxBytes: Int) -> Data {
        var d = data
        if d.count > maxBytes {
            d = d.suffix(maxBytes * 3 / 4)
            guard let nl = d.firstIndex(of: 0x0A) else { return Data() }
            d = d[d.index(after: nl)...]
        }
        let cutoff = now.addingTimeInterval(-maxAge)
        let stamp = DebugLog.stampFormatter(.current)
        let stampLength = 29   // "2026-11-25 10:06:43.502 +0000"
        var start = d.startIndex
        while start < d.endIndex {
            let end = d[start...].firstIndex(of: 0x0A) ?? d.endIndex
            let head = d[start..<min(start + stampLength, end)]
            if let t = stamp.date(from: String(decoding: head, as: UTF8.self)), t >= cutoff {
                return Data(d[start...])
            }
            start = end < d.endIndex ? d.index(after: end) : d.endIndex
        }
        return Data()
    }
}
