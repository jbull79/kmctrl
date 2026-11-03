import Foundation
import CoreGraphics
import IOKit.pwr_mgt

/// Keeps *this* Mac awake and marked "active":
/// - a power assertion stops the display (and so the system) idle-sleeping. Needs no
///   permission. The F15 below can't do this — macOS ignores synthetic input for sleep.
/// - a harmless `F15` key event on an interval keeps presence apps (Teams, Slack, …) from
///   flipping to Away. F15 is unmapped on Mac keyboards — it types nothing and moves
///   nothing — but it resets the input idle time those apps read. Posting it needs
///   Accessibility; without it the post is silently dropped (the Mac still stays awake).
///
/// Local-only: runs on this Mac and is unrelated to any remote control session.
@MainActor
final class KeepAwake: ObservableObject {
    @Published private(set) var running = false

    private var timer: Timer?
    private var assertion: IOPMAssertionID = 0
    private let interval: TimeInterval
    private let source = CGEventSource(stateID: .hidSystemState)
    private let f15: CGKeyCode = 0x71   // kVK_F15 — unmapped, no visible effect

    /// Default 240 s — under Teams' ~5 min Away threshold.
    init(interval: TimeInterval = 240) { self.interval = interval }

    func setEnabled(_ on: Bool) { on ? start() : stop() }

    func start() {
        guard !running else { return }
        running = true
        let r = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                            "KMctrl keep awake" as CFString, &assertion)
        if r != kIOReturnSuccess { DebugLog.log("keep-awake: sleep assertion failed (\(r))", .warn) }
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
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        running = false
        DebugLog.log("keep-awake: off")
    }

    /// Post F15 down+up — no user-visible effect, resets the idle timer.
    private func nudge() {
        CGEvent(keyboardEventSource: source, virtualKey: f15, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: f15, keyDown: false)?.post(tap: .cghidEventTap)
    }
}
