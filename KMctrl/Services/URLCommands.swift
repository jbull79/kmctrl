import AppKit

/// `kmctrl://logs` saves the diagnostics logs to ~/Library/Logs/KMctrl: this Mac's, plus the
/// other Mac's over any open session. It lets the logs be collected without opening Settings
/// (`open -g -b com.kmctrl.KMctrl kmctrl://logs`). It takes no parameters and does nothing else,
/// and calls less than a few seconds apart are ignored.
@MainActor
final class URLCommands: NSObject {
    static let minInterval = 3.0
    private var pullLogs: (@MainActor () -> Void)?
    private var last = -Double.infinity

    func install(pullLogs: @escaping @MainActor () -> Void) {
        self.pullLogs = pullLogs
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handle(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    /// Only exactly `kmctrl://logs`.
    nonisolated static func isPullLogs(_ raw: String) -> Bool {
        guard let u = URL(string: raw), u.scheme?.lowercased() == "kmctrl", u.host?.lowercased() == "logs" else { return false }
        return (u.path.isEmpty || u.path == "/") && u.query == nil && u.fragment == nil && u.user == nil
    }

    @objc private func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        let raw = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue ?? ""
        guard Self.isPullLogs(raw) else {
            DebugLog.log("url: ignored \(PeerName.sanitize(String(raw.prefix(80))))", .warn); return
        }
        let now = ControlHost.nowMs() / 1000
        guard now - last >= Self.minInterval else { return }
        last = now
        DebugLog.log("url: saving logs")
        pullLogs?()
    }
}
