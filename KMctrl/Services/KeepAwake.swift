import Foundation
import CoreGraphics

/// Keeps *this* Mac marked "active" so presence apps (Teams, Slack, …) don't flip to Away,
/// by posting a harmless `F15` key event on an interval. F15 is unmapped on Mac keyboards —
/// it types nothing and moves nothing — but it still counts as user input, resetting the
/// system idle timer that presence apps read.
///
/// Local-only: runs on this Mac and is unrelated to any remote control session. Posting a
/// synthetic event needs Accessibility (same gate as control injection); on a personal Mac
/// that's granted freely. Without it, the post is silently dropped.
@MainActor
final class KeepAwake: ObservableObject {
    @Published private(set) var running = false

    private var timer: Timer?
    private let interval: TimeInterval
    private let source = CGEventSource(stateID: .hidSystemState)
    private let f15: CGKeyCode = 0x71   // kVK_F15 — unmapped, no visible effect

    /// Default 240 s — under Teams' ~5 min Away threshold.
    init(interval: TimeInterval = 240) { self.interval = interval }

    func setEnabled(_ on: Bool) { on ? start() : stop() }

    func start() {
        guard !running else { return }
        running = true
        nudge()   // reset the idle timer immediately
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.nudge() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DebugLog.log("keep-awake: on (every \(Int(interval))s)")
    }

    func stop() {
        guard running else { return }
        timer?.invalidate(); timer = nil
        running = false
        DebugLog.log("keep-awake: off")
    }

    /// Post F15 down+up — no user-visible effect, resets the idle timer.
    private func nudge() {
        CGEvent(keyboardEventSource: source, virtualKey: f15, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: f15, keyDown: false)?.post(tap: .cghidEventTap)
    }
}
