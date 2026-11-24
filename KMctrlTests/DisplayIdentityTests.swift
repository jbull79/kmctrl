import XCTest
@testable import KMctrl

/// The hand-off arrangement is saved against the monitor itself, not its CGDirectDisplayID:
/// macOS renumbers displays after sleep, a dock reconnect or a restart, and the arrangement used
/// to jump to the main display whenever that happened.
final class DisplayIdentityTests: XCTestCase {
    private let dell = DisplayIdentity(uuid: "AAAA-DELL", vendor: 0x10AC, model: 0xA0C3, serial: 0x4C4C, name: "DELL P2418D")
    private let samsung = DisplayIdentity(uuid: "BBBB-C49", vendor: 0x4C2D, model: 0x0F7E, serial: 0x5A5A, name: "C49RG9x")

    private func monitor(_ id: UInt32, _ identity: DisplayIdentity?) -> HandoffMonitor {
        HandoffMonitor(id: id, screen: Desk.work24, name: identity?.name ?? "", identity: identity)
    }

    func testTheSavedMonitorIsFoundAfterMacOSRenumbersIt() {
        // Saved as display 3; after a dock reconnect the DELL came back as display 5.
        let now = [monitor(1, samsung), monitor(5, dell)]
        XCTAssertEqual(HandoffAnchor.resolve(saved: dell, savedID: 3, among: now), 5)
    }

    func testAnOldIDNowWornByAnotherMonitorIsNotUsed() {
        // The ultrawide took the DELL's old number: the identity wins, not the number.
        let now = [monitor(3, samsung), monitor(4, dell)]
        XCTAssertEqual(HandoffAnchor.resolve(saved: dell, savedID: 3, among: now), 4)
    }

    func testAMissingMonitorResolvesToNothingSoTheSettingIsKept() {
        XCTAssertNil(HandoffAnchor.resolve(saved: dell, savedID: 3, among: [monitor(1, samsung)]))
    }

    func testWithoutAUUIDTheVendorModelAndSerialStillMatch() {
        var saved = dell; saved.uuid = nil
        let now = [monitor(1, samsung), monitor(7, dell)]
        XCTAssertEqual(HandoffAnchor.resolve(saved: saved, savedID: 3, among: now), 7)
    }

    func testTwoIdenticalMonitorsPreferTheSavedNumber() {
        // Same model, no serial and no distinct UUID: nothing tells them apart but the number.
        let twin = DisplayIdentity(uuid: nil, vendor: 0x10AC, model: 0xA0C3, serial: 0, name: "DELL P2418D")
        let now = [monitor(4, twin), monitor(6, twin)]
        XCTAssertEqual(HandoffAnchor.resolve(saved: twin, savedID: 6, among: now), 6)
        XCTAssertEqual(HandoffAnchor.resolve(saved: twin, savedID: 9, among: now), 4)
    }

    func testNothingPlacedYetMeansTheMainDisplay() {
        XCTAssertNil(HandoffAnchor.resolve(saved: nil, savedID: 3, among: [monitor(3, dell)]))
    }

    func testIdentityRoundTripsThroughSettingsJSON() throws {
        let back = try JSONDecoder().decode(DisplayIdentity.self, from: JSONEncoder().encode(dell))
        XCTAssertEqual(back, dell)
    }

    func testTheLiveMainDisplayHasAnIdentity() {
        let main = CGMainDisplayID()
        let id = DisplayIdentity.of(main, name: "main")
        XCTAssertEqual(id.vendor, CGDisplayVendorNumber(main))
        XCTAssertEqual(HandoffAnchor.resolve(saved: id, savedID: 0, among: HandoffMonitor.current()), main)
    }
}
