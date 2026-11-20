import Foundation

/// Saves this Mac's diagnostics log and swaps logs with the other Mac over the control link
/// (protocol v6), into ~/Library/Logs/KMctrl. Works from either side of a session.
@MainActor
final class LogExchange: ObservableObject {
    static let shared = LogExchange()

    /// What happened last, for Settings → Diagnostics.
    @Published private(set) var status: String?
    @Published private(set) var lastFolder: URL?

    /// This Mac's name, as Settings has it.
    var deviceName: () -> String = { Host.current().localizedName ?? "This Mac" }
    private var policy = LogRequestPolicy()
    private var waiting: Task<Void, Never>?

    private static func now() -> Double { ControlHost.nowMs() / 1000 }

    /// This Mac's log as it stands.
    func bundle() -> LogBundle {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        return LogBundle(device: deviceName(), app: version, os: ProcessInfo.processInfo.operatingSystemVersionString,
                         created: Date().timeIntervalSince1970, diagnosticsOn: DebugLog.shared.enabled,
                         lines: DebugLog.shared.transcript()).sanitized
    }

    /// Writes this Mac's log. Returns false if it couldn't be written.
    @discardableResult
    func saveOwn() -> Bool {
        do {
            let url = try LogFiles.save(bundle(), receivedFrom: nil)
            lastFolder = url.deletingLastPathComponent()
            status = "Saved this Mac’s log to \(Self.tilde(url))."
            return true
        } catch {
            status = "Couldn’t save this Mac’s log: \(error.localizedDescription)"
            DebugLog.log("logs: couldn't save this Mac's log — \(error.localizedDescription)", .error)
            return false
        }
    }

    /// A request went to `peer`: take its answer for a while, and say so if none comes.
    func asked(_ peer: String) {
        policy.asked(at: Self.now())
        DebugLog.log("logs: asked \(peer) for its log")
        status = (status.map { $0 + " " } ?? "") + "Asked \(peer) for its log…"
        waiting?.cancel()
        waiting = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(LogRequestPolicy.answerWindow * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.status = "No log came back from \(peer). Both Macs need KMctrl 0.8.24 or later and an open session."
        }
    }

    /// Nothing to ask: no session, or the other Mac is on an older KMctrl.
    func noPeer() {
        status = (status.map { $0 + " " } ?? "") + "No session with a Mac on KMctrl 0.8.24 or later, so only this Mac’s log was saved."
    }

    /// The other Mac's log arrived.
    func received(_ raw: LogBundle, from peer: String) {
        guard policy.accepts(at: Self.now()) else {
            DebugLog.log("logs: ignored a log from \(peer) that wasn't asked for", .warn); return
        }
        waiting?.cancel()
        let b = raw.sanitized
        do {
            let url = try LogFiles.save(b, receivedFrom: PeerName.sanitize(peer))
            lastFolder = url.deletingLastPathComponent()
            status = "Saved this Mac’s log and \(peer)’s (\(url.lastPathComponent)) to \(Self.tilde(url.deletingLastPathComponent()))."
                + (b.diagnosticsOn ? "" : " Diagnostics logging is off on \(peer), so its log holds little.")
            DebugLog.log("logs: saved \(peer)'s log (\(b.lines.utf8.count) bytes)")
        } catch {
            status = "Couldn’t save \(peer)’s log: \(error.localizedDescription)"
            DebugLog.log("logs: couldn't save \(peer)'s log — \(error.localizedDescription)", .error)
        }
    }

    /// The other Mac asked for this Mac's log: the log to send, or nil if it asked too often.
    func answer(to peer: String) -> LogBundle? {
        guard policy.mayAnswer(at: Self.now()) else {
            DebugLog.log("logs: \(peer) asked again too soon — not sending", .warn); return nil
        }
        DebugLog.log("logs: sending this Mac's log to \(peer)")
        return bundle()
    }

    private static func tilde(_ url: URL) -> String {
        let home = LogFiles.directory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
