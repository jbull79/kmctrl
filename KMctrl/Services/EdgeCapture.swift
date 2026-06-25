import Foundation
import CoreGraphics

/// Edge-bump capture for KVM, using a global CGEventTap. Requires Accessibility + Input
/// Monitoring (grantable on non-managed Macs). While idle it passes events through and
/// watches for the cursor reaching the right edge of the main display → begins capture.
/// While capturing it forwards and consumes events; ⌃⌥⌘ releases control.
///
/// Forwarding goes through caller-supplied closures (which feed the same coalesce buffer
/// + sync send path as window mode), so this class stays off the main actor.
final class EdgeCapture: @unchecked Sendable {
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    /// The display whose edge hands off (or the whole-desktop union when 0). Multi-monitor:
    /// the bump fires only on this display's chosen edge, within that display's extent.
    private let bounds: CGRect
    private let lock = NSLock()
    private var capturing = false

    static func desktopBounds() -> CGRect {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return CGDisplayBounds(CGMainDisplayID()) }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
    }

    /// CG bounds for a chosen display id (0 / inactive → whole-desktop union).
    static func bounds(forDisplay id: UInt32) -> CGRect {
        guard id != 0 else { return desktopBounds() }
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.contains(id) ? CGDisplayBounds(id) : desktopBounds()
    }

    private let edge: ScreenEdge
    private let forwardMove: @Sendable (Double, Double, UInt64) -> Void
    private let forwardDiscrete: @Sendable (ControlEvent) -> Void
    private let onBegin: @Sendable () -> Void
    private let onEnd: @Sendable () -> Void

    init(edge: ScreenEdge,
         displayID: UInt32 = 0,
         forwardMove: @escaping @Sendable (Double, Double, UInt64) -> Void,
         forwardDiscrete: @escaping @Sendable (ControlEvent) -> Void,
         onBegin: @escaping @Sendable () -> Void,
         onEnd: @escaping @Sendable () -> Void) {
        self.bounds = EdgeCapture.bounds(forDisplay: displayID)
        self.edge = edge
        self.forwardMove = forwardMove
        self.forwardDiscrete = forwardDiscrete
        self.onBegin = onBegin
        self.onEnd = onEnd
    }

    private func atEdge(_ p: CGPoint) -> Bool {
        let b = bounds
        switch edge {                                   // constrain the perpendicular axis to
        case .right:  return p.x >= b.maxX - 2 && p.y >= b.minY && p.y <= b.maxY   // this display's
        case .left:   return p.x <= b.minX + 1 && p.y >= b.minY && p.y <= b.maxY   // extent, so the
        case .top:    return p.y <= b.minY + 1 && p.x >= b.minX && p.x <= b.maxX   // bump fires only
        case .bottom: return p.y >= b.maxY - 2 && p.x >= b.minX && p.x <= b.maxX   // on that monitor
        }
    }

    /// Create + start the tap on its own run-loop thread. Returns false if the tap can't
    /// be created (permissions not granted).
    func start() -> Bool {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                    .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: edgeTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let sem = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            sem.signal()
            CFRunLoopRun()
        }
        thread.name = "netcatch.edge.tap"
        thread.start()
        sem.wait()
        return true
    }

    func stop() {
        setCapturing(false)
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil; runLoop = nil
    }

    private func setCapturing(_ v: Bool) { lock.lock(); capturing = v; lock.unlock() }
    private var isCapturing: Bool { lock.lock(); defer { lock.unlock() }; return capturing }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables the tap on timeout/user input; re-enable and pass through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if !isCapturing {
            if atEdge(event.location) {                   // hit the hand-off edge → take control
                setCapturing(true)
                onBegin()
                return nil
            }
            return Unmanaged.passUnretained(event)        // not at edge → leave host alone
        }
        // Capturing: ⌃⌥⌘ releases.
        if type == .flagsChanged {
            let f = event.flags
            if f.contains(.maskControl), f.contains(.maskAlternate), f.contains(.maskCommand) {
                setCapturing(false); onEnd(); return nil
            }
        }
        if let ce = translate(type, event) {
            if ce.kind == .mouseMove { forwardMove(ce.dx, ce.dy, ce.flags) }
            else { forwardDiscrete(ce) }
        }
        return nil   // consume so it doesn't act on the host
    }

    private func translate(_ type: CGEventType, _ e: CGEvent) -> ControlEvent? {
        let flags = e.flags.rawValue
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return ControlEvent(kind: .mouseMove,
                                dx: Double(e.getIntegerValueField(.mouseEventDeltaX)),
                                dy: Double(e.getIntegerValueField(.mouseEventDeltaY)), flags: flags)
        case .leftMouseDown:  return ControlEvent(kind: .mouseDown, button: 0, flags: flags)
        case .leftMouseUp:    return ControlEvent(kind: .mouseUp, button: 0, flags: flags)
        case .rightMouseDown: return ControlEvent(kind: .mouseDown, button: 1, flags: flags)
        case .rightMouseUp:   return ControlEvent(kind: .mouseUp, button: 1, flags: flags)
        case .otherMouseDown: return ControlEvent(kind: .mouseDown, button: 2, flags: flags)
        case .otherMouseUp:   return ControlEvent(kind: .mouseUp, button: 2, flags: flags)
        case .scrollWheel:
            return ControlEvent(kind: .scroll,
                                scrollX: Double(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)),
                                scrollY: Double(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)), flags: flags)
        case .keyDown:        return ControlEvent(kind: .keyDown, keyCode: Int(e.getIntegerValueField(.keyboardEventKeycode)), flags: flags)
        case .keyUp:          return ControlEvent(kind: .keyUp, keyCode: Int(e.getIntegerValueField(.keyboardEventKeycode)), flags: flags)
        case .flagsChanged:   return ControlEvent(kind: .flagsChanged, flags: flags)
        default: return nil
        }
    }
}

private func edgeTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                             event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<EdgeCapture>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}
