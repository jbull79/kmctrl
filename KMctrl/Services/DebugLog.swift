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

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

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
        return entries.map { "\(Self.stamp.string(from: $0.time))  [\($0.level.rawValue.uppercased())]  \($0.message)" }
            .joined(separator: "\n")
    }
}
