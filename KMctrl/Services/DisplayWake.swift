import Foundation
import IOKit.pwr_mgt

enum DisplayWake {
    /// Declare local user activity: wakes a sleeping display and resets the idle timer.
    /// Used on the controlled Mac when the controller starts capturing or asks explicitly.
    static func wake() {
        var id: IOPMAssertionID = 0
        let r = IOPMAssertionDeclareUserActivity("KMctrl remote input" as CFString, kIOPMUserActiveLocal, &id)
        if r == kIOReturnSuccess {
            DebugLog.log("control: display wake requested")
        } else {
            DebugLog.log("control: display wake failed (\(r))", .warn)
        }
    }

    /// Count remote input as local use. Injected CGEvents don't reset macOS's idle-sleep timers,
    /// so without this a Mac being driven sleeps one display-sleep period into the session.
    /// Re-declares on the same assertion `id`, so it stays one assertion and one quiet call.
    static func noteActivity(_ id: inout IOPMAssertionID) {
        _ = IOPMAssertionDeclareUserActivity("KMctrl remote input" as CFString, kIOPMUserActiveLocal, &id)
    }
}

/// Throttles `DisplayWake.noteActivity` to once per `interval` seconds of remote input — the
/// declaration lasts a whole display-sleep period, so per-event calls would be wasted IPC.
struct ActivityPulse {
    var interval: Double = 30
    private var last = -Double.infinity

    init(interval: Double = 30) { self.interval = interval }

    mutating func due(at now: Double) -> Bool {
        guard now - last >= interval else { return false }
        last = now
        return true
    }
}
