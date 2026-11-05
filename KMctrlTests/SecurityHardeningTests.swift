import XCTest
import Security
@testable import KMctrl

/// 0.8.21 hardening: values from the other Mac are bounded before use, names are display text,
/// the controller pins the Mac it controls, Keychain failures never replace the identity, and
/// the update link only ever points at this project's releases.
final class SecurityHardeningTests: XCTestCase {

    // MARK: Control events

    func testKeyCodesOutsideTheKeyboardAreDropped() {
        var e = ControlEvent(kind: .keyDown); e.keyCode = 70_000      // used to trap in CGKeyCode(_:)
        XCTAssertNil(e.sanitizedForInjection())
        e.keyCode = -1
        XCTAssertNil(e.sanitizedForInjection())
        e.keyCode = 0x24                                                 // Return
        XCTAssertEqual(e.sanitizedForInjection()?.keyCode, 0x24)
    }

    func testHugeScrollAndMovesAreClampedAndNonFiniteDropped() {
        var s = ControlEvent(kind: .scroll); s.scrollY = 1e300           // used to trap in Int32(_:)
        XCTAssertEqual(s.sanitizedForInjection()?.scrollY, ControlEvent.maxDelta)
        s.scrollY = .nan
        XCTAssertNil(s.sanitizedForInjection())
        var m = ControlEvent(kind: .mouseMove); m.dx = -1e12; m.dy = 3
        XCTAssertEqual(m.sanitizedForInjection()?.dx, -ControlEvent.maxDelta)
        XCTAssertEqual(m.sanitizedForInjection()?.dy, 3)
        m.dx = .infinity
        XCTAssertNil(m.sanitizedForInjection())
    }

    func testUnknownMouseButtonsAreDropped() {
        var e = ControlEvent(kind: .mouseDown); e.button = 7
        XCTAssertNil(e.sanitizedForInjection())
        e.button = 1
        XCTAssertNotNil(e.sanitizedForInjection())
    }

    func testPowerAndEjectMediaKeysAreDropped() {
        var e = ControlEvent(kind: .mediaKey); e.button = 1
        e.keyCode = 10   // power
        XCTAssertNil(e.sanitizedForInjection())
        e.keyCode = 6    // eject
        XCTAssertNil(e.sanitizedForInjection())
        e.keyCode = 16   // play/pause
        XCTAssertNotNil(e.sanitizedForInjection())
    }

    func testFlagsKeepOnlyModifierBitsAndLongCharsAreDropped() {
        var e = ControlEvent(kind: .keyDown); e.keyCode = 0
        e.flags = 0xFFFF_FFFF_FFFF_FFFF
        e.chars = String(repeating: "é", count: 40)
        let s = e.sanitizedForInjection()
        XCTAssertEqual(s?.flags, ControlEvent.flagsMask)
        XCTAssertNil(s?.chars)
    }

    // MARK: Screens

    func testOnlyPlausibleScreensAreAccepted() {
        XCTAssertTrue(ScreenGeometry.assumedRemote.isPlausible)
        var g = ScreenGeometry.assumedRemote
        g.widthMM = 1e300                                                 // crashed Settings on every open
        XCTAssertFalse(g.isPlausible)
        g = .assumedRemote; g.height = .nan
        XCTAssertFalse(g.isPlausible)
        g = .assumedRemote; g.width = 0
        XCTAssertFalse(g.isPlausible)
    }

    // MARK: Peer names

    func testPeerNamesCannotFakeLinesOrDirection() {
        XCTAssertEqual(PeerName.sanitize("Joe's Mac\n12:00 control host: connected"), "Joe's Mac12:00 control host: connected")
        XCTAssertEqual(PeerName.sanitize("evil\u{202E}cam"), "evilcam")          // right-to-left override
        XCTAssertEqual(PeerName.sanitize("  a \t  b  "), "a b")
        XCTAssertEqual(PeerName.sanitize("\u{0}\u{7}"), "Unknown")
        XCTAssertEqual(PeerName.sanitize(String(repeating: "x", count: 70_000)).count, PeerName.maxLength)
    }

    // MARK: Pinning the controlled Mac

    func testControllerPinsTheFirstFingerprintAndRefusesAnother() {
        var pins = HostPins()
        XCTAssertEqual(pins.check(name: "Home", fingerprint: "AAAA"), .firstUse)
        pins.pin(name: "Home", fingerprint: "AAAA")
        XCTAssertEqual(pins.check(name: "Home", fingerprint: "AAAA"), .match)
        XCTAssertEqual(pins.check(name: "Home", fingerprint: "BBBB"), .mismatch(expected: "AAAA"))
        pins.forget(name: "Home")
        XCTAssertEqual(pins.check(name: "Home", fingerprint: "BBBB"), .firstUse)
    }

    // MARK: Keychain

    func testOnlyAMissingItemCountsAsNoIdentity() {
        let d = Data([1, 2, 3])
        XCTAssertEqual(CryptoService.classify(status: errSecSuccess, data: d), .found(d))
        XCTAssertEqual(CryptoService.classify(status: errSecItemNotFound, data: nil), .notFound)
        // A denied or cancelled prompt must not be taken as "no key" (that replaced the identity).
        XCTAssertEqual(CryptoService.classify(status: errSecAuthFailed, data: nil), .failed(errSecAuthFailed))
        XCTAssertEqual(CryptoService.classify(status: errSecUserCanceled, data: nil), .failed(errSecUserCanceled))
        XCTAssertEqual(CryptoService.classify(status: errSecInteractionNotAllowed, data: nil), .failed(errSecInteractionNotAllowed))
    }

    // MARK: Update link

    func testUpdateLinkMustBeThisProjectsReleases() {
        XCTAssertTrue(UpdateChecker.isReleaseURL(URL(string: "https://github.com/jbull79/kmctrl/releases/tag/v9.9.9")!))
        XCTAssertFalse(UpdateChecker.isReleaseURL(URL(string: "http://github.com/jbull79/kmctrl/releases")!))
        XCTAssertFalse(UpdateChecker.isReleaseURL(URL(string: "https://github.com.evil.example/jbull79/kmctrl")!))
        XCTAssertFalse(UpdateChecker.isReleaseURL(URL(string: "https://github.com@evil.example/jbull79/kmctrl")!))
        XCTAssertFalse(UpdateChecker.isReleaseURL(URL(string: "https://github.com/someone/else")!))
    }

    // MARK: Allow prompt

    @MainActor
    func testApprovalAnswersOnlyOnce() {
        var answers: [Bool] = []
        let r = ControlApprovalRequest(peerName: "x", fingerprint: "y") { answers.append($0) }
        r.resolve(true)
        r.resolve(false)    // the timeout firing after a click
        XCTAssertEqual(answers, [true])
    }
}
