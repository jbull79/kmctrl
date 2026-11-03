import XCTest
import IOKit.pwr_mgt
@testable import KMctrl

/// macOS doesn't count CGEvent-injected input as user activity for display/system sleep, so a
/// Mac being driven remotely slept 10 minutes into a session, and Keep awake (an F15 nudge)
/// never stopped sleep at all.
final class ActivityPulseTests: XCTestCase {
    func testDeclaresOnFirstInputThenAtMostEveryInterval() {
        var p = ActivityPulse(interval: 30)
        XCTAssertTrue(p.due(at: 100))
        XCTAssertFalse(p.due(at: 110))
        XCTAssertFalse(p.due(at: 129.9))
        XCTAssertTrue(p.due(at: 130))
        XCTAssertFalse(p.due(at: 131))
    }
}

@MainActor
final class KeepAwakeTests: XCTestCase {
    /// The test host is KMctrl itself, whose own Keep awake may already be on — so count.
    private func displaySleepAssertions() -> Int {
        var byPid: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byPid) == kIOReturnSuccess,
              let all = byPid?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return 0 }
        let mine = all[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] ?? []
        return mine.filter { ($0[kIOPMAssertionTypeKey] as? String) == kIOPMAssertPreventUserIdleDisplaySleep }.count
    }

    func testKeepAwakeHoldsAPowerAssertionWhileOn() {
        let before = displaySleepAssertions()
        let k = KeepAwake(interval: 3600)
        k.start()
        XCTAssertEqual(displaySleepAssertions(), before + 1)
        k.stop()
        XCTAssertEqual(displaySleepAssertions(), before)
    }
}
