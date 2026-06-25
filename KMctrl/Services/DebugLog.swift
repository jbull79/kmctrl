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

    private func append(_ message: String, _ level: Level) {
        entries.append(Entry(time: Date(), level: level, message: message))
        if entries.count > 1000 { entries.removeFirst(entries.count - 1000) }
    }

    func clear() { entries = [] }

    func transcript() -> String {
        entries.map { "\(Self.stamp.string(from: $0.time))  [\($0.level.rawValue.uppercased())]  \($0.message)" }
            .joined(separator: "\n")
    }
}
