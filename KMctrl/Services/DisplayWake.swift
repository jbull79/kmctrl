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
}
