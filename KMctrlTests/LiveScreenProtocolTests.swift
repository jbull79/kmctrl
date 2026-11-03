import XCTest
@testable import KMctrl

/// Monitors change mid-session (a display sleeps, a resolution changes, a lid opens): each Mac
/// re-sends its screen and the controller re-sends the return stretch, over the open link.
final class LiveScreenProtocolTests: XCTestCase {
    let laptop = ScreenGeometry(x: 0, y: 0, width: 1512, height: 982, widthMM: 302, heightMM: 196)

    func testScreenUpdateIsNotAReturnSignal() {
        XCTAssertFalse(ControlReturn(screen: laptop).isReturnSignal)
        XCTAssertTrue(ControlReturn(at: [10, 20]).isReturnSignal)
    }

    func testScreenReportRoundTrips() throws {
        let back = try JSONDecoder().decode(ControlReturn.self, from: JSONEncoder().encode(ControlReturn(screen: laptop)))
        XCTAssertEqual(back.screen, laptop)
    }

    func testUpdatedReturnStretchTravelsAsJSON() throws {
        let setup = ControlSetup(hostEdge: .top, autoReturn: true, returnArea: laptop, returnSpan: [0, 1512])
        let e = ControlEvent(kind: .edgeSetup, setup: setup)
        XCTAssertFalse(e.isBinaryEncodable)                       // payload can't ride the binary codec
        let back = try JSONDecoder().decode(ControlEvent.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(back.kind, .edgeSetup)
        XCTAssertEqual(back.setup?.returnSpan, [0, 1512])
        XCTAssertEqual(back.setup?.returnArea, laptop)
    }

    func testOlderAckWithoutAScreenStillDecodes() throws {
        let json = Data(#"{"accepted":true,"version":3}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ControlAck.self, from: json).screen)
    }
}

/// Sliding the other screen or changing the edge in Settings applies to an open session.
@MainActor
final class LiveArrangementTests: XCTestCase {
    func testOnlyV4PeersAreSentEdgeSetup() {
        XCTAssertFalse(ControlHost.sendsEdgeSetup(peerVersion: 3))   // v3 drops the session on an unknown kind
        XCTAssertTrue(ControlHost.sendsEdgeSetup(peerVersion: 4))
    }

    func testIdleHostTakesTheNewArrangement() {
        let host = ControlHost()
        host.arrangementChanged(edge: .top, displayID: 7, offsetMM: 120)
        XCTAssertEqual(host.controlEdge, .top)
        XCTAssertEqual(host.controlDisplayID, 7)
        XCTAssertEqual(host.handoffOffsetMM, 120)
        host.arrangementChanged(edge: .top, displayID: 7, offsetMM: nil)   // back to centred
        XCTAssertNil(host.handoffOffsetMM)
    }
}

/// "Use edge mode" needs Accessibility + Input Monitoring, which an MDM Mac can't grant. Without
/// them the session must fall back to the permission-free edge switch, not do nothing.
final class EdgeSwitchChoiceTests: XCTestCase {
    func testEdgeModeWithoutPermissionsFallsBackToThePointerWatcher() {
        XCTAssertEqual(ControlHost.edgeSwitch(edgeMode: true, permitted: false, pointerWatch: true), .pointerWatch)
    }

    func testEdgeModeWithPermissionsUsesTheTap() {
        XCTAssertEqual(ControlHost.edgeSwitch(edgeMode: true, permitted: true, pointerWatch: true), .tap)
    }

    func testWindowModeUsesThePointerWatcherWhenOn() {
        XCTAssertEqual(ControlHost.edgeSwitch(edgeMode: false, permitted: true, pointerWatch: true), .pointerWatch)
        XCTAssertEqual(ControlHost.edgeSwitch(edgeMode: false, permitted: false, pointerWatch: false), .off)
    }

    func testEdgeModeWithoutPermissionsOrWatcherIsOff() {
        XCTAssertEqual(ControlHost.edgeSwitch(edgeMode: true, permitted: false, pointerWatch: false), .off)
    }
}
