import XCTest
@testable import KMctrl

final class LocalNetworkTests: XCTestCase {
    func testVPNAndTailscaleTunnelsAreNeverTheLAN() {
        XCTAssertTrue(LocalNetwork.isTunnelOrVirtual(name: "utun10", ip: "100.94.250.55"))  // Tailscale
        XCTAssertTrue(LocalNetwork.isTunnelOrVirtual(name: "en7", ip: "100.101.2.3"))       // Tailscale range, any name
        XCTAssertTrue(LocalNetwork.isTunnelOrVirtual(name: "ipsec0", ip: "10.8.0.2"))       // IKEv2 VPN
        XCTAssertTrue(LocalNetwork.isTunnelOrVirtual(name: "ppp0", ip: "10.9.0.2"))         // L2TP/PPTP VPN
        XCTAssertTrue(LocalNetwork.isTunnelOrVirtual(name: "awdl0", ip: "169.254.1.1"))     // AirDrop link
        XCTAssertFalse(LocalNetwork.isTunnelOrVirtual(name: "en9", ip: "192.168.1.249"))    // USB Ethernet
        XCTAssertFalse(LocalNetwork.isTunnelOrVirtual(name: "en0", ip: "192.168.1.68"))     // Wi-Fi
        XCTAssertFalse(LocalNetwork.isTunnelOrVirtual(name: "en0", ip: "100.63.255.1"))     // just below 100.64/10
        XCTAssertFalse(LocalNetwork.isTunnelOrVirtual(name: "en0", ip: "100.128.0.1"))      // just above 100.64/10
    }

    func testFollowsSystemOrderSoPluggedInEthernetBeatsWiFi() {
        let wifi = (name: "en0", ip: "192.168.1.68"), ethernet = (name: "en9", ip: "192.168.1.249")
        let ranked = LocalNetwork.ranked([wifi, ethernet], systemOrder: ["utun10", "en9", "en0"])
        XCTAssertEqual(ranked.map(\.name), ["en9", "en0"])
    }

    func testWithoutSystemOrderWiFiStillComesFirst() {
        let ethernet = (name: "en9", ip: "192.168.1.249"), wifi = (name: "en0", ip: "192.168.1.68")
        XCTAssertEqual(LocalNetwork.ranked([ethernet, wifi], systemOrder: []).map(\.name), ["en0", "en9"])
    }
}
