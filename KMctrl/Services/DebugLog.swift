import Foundation

/// Lightweight in-app diagnostic log, gated by a user toggle. When diagnostics are off,
/// `DebugLog.log(...)` is a no-op (nothing buffered or written). Surfaced in Settings →
/// Diagnostics with an enable switch + Copy/Clear, so users can capture and share a
/// transcript only when troubleshooting.
@MainActor
final class DebugLog: ObservableObject {
    static let shared = DebugLog()

    enum Level: String { case info, warn, error }

    struct Entry: Identifiable {
        let id = UUID()
        let time: Date
        let level: Level
        let message: String
    }

    private static let key = "kmctrl.diagnosticsEnabled"
    /// Nonisolated mirror so the `log(...)` fast path can check it from any thread.
    nonisolated(unsafe) private static var capture = UserDefaults.standard.bool(forKey: key)

    @Published private(set) var entries: [Entry] = []
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.key)
            Self.capture = enabled
        }
    }

    private init() { enabled = UserDefaults.standard.bool(forKey: Self.key) }

    /// Saved and copied logs span days and get read next to the other Mac's, so each line carries
    /// the date, a 24-hour time (whatever the user's clock setting) and the time zone.
    static func stampFormatter(_ zone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS xx"
        return f
    }
    private static let stamp = stampFormatter(.current)

    static func line(_ e: Entry, formatter: DateFormatter? = nil) -> String {
        "\((formatter ?? stamp).string(from: e.time))  [\(e.level.rawValue.uppercased())]  \(e.message)"
    }

    /// Safe to call from any context. No-op unless diagnostics are enabled.
    nonisolated static func log(_ message: String, _ level: Level = .info) {
        guard capture else { return }
        NSLog("KMctrl [%@] %@", level.rawValue, message)
        Task { @MainActor in shared.append(message, level) }
    }

    /// Lines wait here and are published at most twice a second: each publish makes an open
    /// Diagnostics view re-diff up to 1000 rows on the main thread, the thread input runs on.
    private var pending: [Entry] = []
    private var flushScheduled = false

    private func append(_ message: String, _ level: Level) {
        pending.append(Entry(time: Date(), level: level, message: message))
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        var next = entries
        next.append(contentsOf: pending)
        pending.removeAll()
        if next.count > 1000 { next.removeFirst(next.count - 1000) }
        entries = next
    }

    func clear() { pending.removeAll(); entries = [] }

    func transcript() -> String {
        flush()
        return entries.map { Self.line($0) }.joined(separator: "\n")
    }
}
