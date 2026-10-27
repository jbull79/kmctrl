import Foundation
import CoreGraphics
import AppKit

/// Injects forwarded input on the *controlled* (home) Mac via CGEvent.post. Requires
/// Accessibility (grantable, no admin). Runs off the main actor.
///
/// Mouse moves are *paced*: incoming deltas accumulate in a buffer and are drained on a
/// steady local 120 Hz timer, so bursty network delivery (events arriving clumped with
/// 200–500 ms gaps) is smoothed into even pointer motion instead of stutter. Clicks/keys
/// flush the buffer first so they land at the right position.
final class ControlInjector: @unchecked Sendable {
    private var bounds: CGRect
    private var cursor: CGPoint
    private var flags: CGEventFlags = []
    private var heldKeys: Set<CGKeyCode> = []
    private var mouseDown = false
    private let source = CGEventSource(stateID: .hidSystemState)

    /// When the injected cursor reaches this edge, control should return to the host.
    private var returnEdge: ScreenEdge?
    var onReturn: ((CGPoint) -> Void)?          // with where the pointer left
    /// v4: the display and stretch of its edge that face the controller (nil = whole desktop).
    private var returnArea: CGRect?
    private var returnSpan: ClosedRange<Double>?
    private var returnTrigger = EdgeReturnTrigger()

    // Pacing
    private let lock = NSLock()
    private var pendDX = 0.0, pendDY = 0.0
    private var timer: DispatchSourceTimer?
    // Sub-pixel scroll remainder. High-res trackpad deltas are fractional; truncating each
    // event to an Int floors small swipes to 0 (dead/notchy scroll). Carry the remainder so
    // fractional motion accumulates into whole pixels instead of being lost.
    private var scrollRemX = 0.0, scrollRemY = 0.0
    // Fraction of the remaining buffered movement applied per tick, learned from how the
    // motion arrives (steady vs. bursty). See PaceEstimator.
    private var pace = PaceEstimator()
    private let tickSeconds = 0.008

    init() {
        bounds = EdgeCapture.desktopBounds()   // span all displays on the controlled Mac
        cursor = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func start() {
        // Seed from the real cursor so the first forwarded move continues from where the
        // pointer already is, instead of jumping from the desktop centre.
        if let here = CGEvent(source: nil)?.location { cursor = here }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "netcatch.inject", qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .nanoseconds(0))
        t.setEventHandler { [weak self] in self?.drain() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel(); timer = nil
        flushPendingMove()
        releaseAll()
    }

    /// Arm (or re-arm) the return edge from the controller's setup — at session start, and again
    /// when either Mac's monitors change. The inject timer reads these, hence the lock.
    func configureReturn(_ setup: ControlSetup) {
        let span = setup.returnSpan.flatMap { $0.count == 2 && $0[0] <= $0[1] ? $0[0]...$0[1] : nil }
        lock.lock()
        returnEdge = setup.autoReturn ? setup.hostEdge.opposite : nil
        returnArea = setup.returnArea?.rect
        returnSpan = span
        lock.unlock()
    }

    /// This Mac's monitors changed: re-read the desktop the cursor is kept inside.
    func refreshDesktop() {
        let b = EdgeCapture.desktopBounds()
        lock.lock(); bounds = b; lock.unlock()
    }

    func apply(_ e: ControlEvent) {
        switch e.kind {
        case .enterAt:   // edge switch: start where the pointer crossed over, not where it last was
            lock.lock(); pendDX = 0; pendDY = 0; let bounds = self.bounds; lock.unlock()
            cursor = CGPoint(x: min(max(bounds.minX, e.dx), bounds.maxX - 1),
                             y: min(max(bounds.minY, e.dy), bounds.maxY - 1))
            postMouse(mouseDown ? .leftMouseDragged : .mouseMoved, button: .left)
        case .mouseMove:
            lock.lock()
            pendDX += e.dx; pendDY += e.dy
            pace.noteArrival(at: ControlHost.nowMs() / 1000)
            lock.unlock()
        case .mouseDown:
            flushPendingMove()
            if e.button == 0 { mouseDown = true }
            postMouse(downType(e.button), button: cgButton(e.button))
        case .mouseUp:
            flushPendingMove()
            if e.button == 0 { mouseDown = false }
            postMouse(upType(e.button), button: cgButton(e.button))
        case .scroll:
            scrollRemX += e.scrollX; scrollRemY += e.scrollY
            let iy = (scrollRemY < 0 ? scrollRemY.rounded(.up) : scrollRemY.rounded(.down))
            let ix = (scrollRemX < 0 ? scrollRemX.rounded(.up) : scrollRemX.rounded(.down))
            scrollRemY -= iy; scrollRemX -= ix
            if iy != 0 || ix != 0 {
                CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                        wheel1: Int32(iy), wheel2: Int32(ix), wheel3: 0)?
                    .post(tap: .cghidEventTap)
            }
        case .keyDown:
            flags = CGEventFlags(rawValue: e.flags)
            postKey(CGKeyCode(e.keyCode), down: true, chars: e.chars)
            heldKeys.insert(CGKeyCode(e.keyCode))
        case .keyUp:
            flags = CGEventFlags(rawValue: e.flags)
            postKey(CGKeyCode(e.keyCode), down: false)
            heldKeys.remove(CGKeyCode(e.keyCode))
        case .flagsChanged:
            flags = CGEventFlags(rawValue: e.flags)
        case .releaseAll:
            releaseAll()
        case .mediaKey:
            postMediaKey(MediaKey(key: e.keyCode, isDown: e.button == 1, isRepeat: false))
        case .hostStats, .ping, .wakeDisplay, .clipboard, .edgeSetup:
            break   // control-plane only; never injected (client handles/echoes before apply)
        }
    }

    func releaseAll() {
        for key in heldKeys { postKey(key, down: false) }
        heldKeys.removeAll()
        if mouseDown { postMouse(.leftMouseUp, button: .left); mouseDown = false }
        flags = []
    }

    // MARK: Paced mouse motion

    /// Drain a fraction of the buffered movement (called on the local timer) → smooth.
    private func drain() {
        lock.lock()
        guard pendDX != 0 || pendDY != 0 else { lock.unlock(); return }
        let stepX: Double, stepY: Double
        if abs(pendDX) < 2 && abs(pendDY) < 2 {       // finish off the remainder
            stepX = pendDX; stepY = pendDY
        } else {
            let f = pace.drainFraction(tick: tickSeconds)
            stepX = pendDX * f; stepY = pendDY * f
        }
        pendDX -= stepX; pendDY -= stepY
        lock.unlock()
        moveBy(stepX, stepY)
    }

    /// Apply all buffered movement immediately (before a click/key, or at stop).
    private func flushPendingMove() {
        lock.lock(); let dx = pendDX, dy = pendDY; pendDX = 0; pendDY = 0; lock.unlock()
        if dx != 0 || dy != 0 { moveBy(dx, dy) }
    }

    private func moveBy(_ dx: Double, _ dy: Double) {
        lock.lock()
        let bounds = self.bounds, returnEdge = self.returnEdge, returnArea = self.returnArea, returnSpan = self.returnSpan
        lock.unlock()
        let intended = CGPoint(x: cursor.x + dx, y: cursor.y + dy)
        cursor.x = min(max(bounds.minX, intended.x), bounds.maxX - 1)
        cursor.y = min(max(bounds.minY, intended.y), bounds.maxY - 1)
        postMouse(mouseDown ? .leftMouseDragged : .mouseMoved, button: .left)
        // Return control after a deliberate push past the return edge, never mid-drag.
        if let e = returnEdge, returnTrigger.shouldReturn(cursor: cursor, intended: intended,
                                                          bounds: returnArea ?? bounds, edge: e,
                                                          buttonHeld: mouseDown, span: returnSpan) {
            onReturn?(cursor)
        }
    }

    // MARK: CGEvent helpers

    private func postMouse(_ type: CGEventType, button: CGMouseButton) {
        let event = CGEvent(mouseEventSource: source, mouseType: type,
                            mouseCursorPosition: cursor, mouseButton: button)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    /// `chars` (key down only) overrides the characters the controlled Mac's own layout would
    /// derive from `code`, so typing follows the controller's layout.
    private func postKey(_ code: CGKeyCode, down: Bool, chars: String? = nil) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        event?.flags = flags
        if down, let chars {
            var units = Array(chars.utf16)
            event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        }
        event?.post(tap: .cghidEventTap)
    }

    /// Media keys are not plain keyboard events: they travel as NX system-defined events, so
    /// build one via NSEvent and post its CGEvent.
    private func postMediaKey(_ k: MediaKey) {
        guard let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                          context: nil, subtype: Int16(MediaKey.subtypeAuxControl),
                                          data1: k.data1, data2: -1) else { return }
        ev.cgEvent?.post(tap: .cghidEventTap)
    }

    private func cgButton(_ b: Int) -> CGMouseButton { b == 1 ? .right : (b == 2 ? .center : .left) }
    private func downType(_ b: Int) -> CGEventType { b == 1 ? .rightMouseDown : (b == 2 ? .otherMouseDown : .leftMouseDown) }
    private func upType(_ b: Int) -> CGEventType { b == 1 ? .rightMouseUp : (b == 2 ? .otherMouseUp : .leftMouseUp) }
}
