import AppKit

/// Every 10 s while connected, one Diagnostics line with what could make input lag once
/// KMctrl has been running a long time: main-thread stalls, piled-up windows, leaked links or
/// open sockets. Restarting the controlling Mac's KMctrl has cleared that lag twice (27 Oct,
/// 5 Nov) without a cause being found; compare these lines from a fresh launch and a laggy one.
final class HealthMonitor: @unchecked Sendable {   // timer and fields: main queue only
    static let appStarted = Date()
    private static let tickMs = 100.0
    private static let ticksPerReport = 100
    private var timer: DispatchSourceTimer?
    private var last = DispatchTime.now()
    private var maxLateMs = 0.0
    private var ticks = 0

    func start() {
        stop()
        last = .now(); maxLateMs = 0; ticks = 0
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(Int(Self.tickMs)), repeating: .milliseconds(Int(Self.tickMs)),
                   leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    private func tick() {
        let now = DispatchTime.now()
        let late = Double(now.uptimeNanoseconds - last.uptimeNanoseconds) / 1_000_000 - Self.tickMs
        maxLateMs = max(maxLateMs, late)
        last = now
        ticks += 1
        guard ticks >= Self.ticksPerReport else { return }
        let lateMs = Int(maxLateMs)
        ticks = 0; maxLateMs = 0
        Task { @MainActor in Self.report(lateMs: lateMs) }
    }

    @MainActor private static func report(lateMs: Int) {
        let windows = NSApp.windows
        let files = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
        DebugLog.log("health: main thread late up to \(lateMs) ms, \(windows.count) windows (\(windows.filter(\.isVisible).count) visible), \(PeerLink.liveCount) links, \(files) open files, up \(Int(Date().timeIntervalSince(appStarted) / 60)) min")
    }
}
