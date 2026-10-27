import Foundation
import AppKit
import CoreGraphics

/// The *controlling* (work) side of KVM. Opens a `.control` session to a peer and, while
/// capturing, forwards local keyboard/mouse to it. Capture uses an in-window `NSEvent`
/// local monitor — no Accessibility / Input Monitoring needed, so it works on a
/// locked-down Mac. Press the release hotkey (⌃⌥⌘) or switch away to drop control.
@MainActor
final class ControlHost: ObservableObject {
    enum State: Equatable { case idle, connecting, connected, capturing }

    /// Control frames are written synchronously to a raw socket (`sendControlEventSync`), so a
    /// control link must be POSIX. A Network.framework link would connect and then drop on
    /// the first frame.
    nonisolated static let controlTransports: Set<TransportStrategy> = [.posix]

    @Published var state: State = .idle
    @Published var peerName: String?
    /// The peer of the open session (for side channels such as clipboard sync).
    @Published private(set) var currentPeer: Peer?
    /// Identity fingerprint of the connected peer (authenticated at handshake).
    @Published private(set) var peerFingerprint: String?
    /// Supplies the main window for hotkey re-grab (set by AppModel; nil = not shown yet).
    var mainWindowProvider: () -> NSWindow? = { nil }
    /// The controlled Mac handed its clipboard back (over the control link, on release).
    var onClipboardReceived: (ClipboardPayload, String) -> Void = { _, _ in }

    /// Hand our clipboard to the controlled Mac over the control link (outbound only — no
    /// inbound connection to this Mac is ever needed). v2 peers only.
    func sendClipboard(_ payload: ClipboardPayload) throws {
        guard state == .connected || state == .capturing, link != nil else { throw LinkError.closed }
        guard peerVersion >= 3 else { throw LinkError.rejected }   // older peers can't decode .clipboard
        var e = ControlEvent(kind: .clipboard); e.clipboard = payload
        sendOnQueue(e)
    }
    @Published var lastError: String?
    /// Control protocol version of the connected peer (from its `ControlAck`); 1 until known.
    @Published private(set) var peerVersion = 1
    /// Round-trip samples aggregated to one Diagnostics line per second.
    private var latency = LatencyStats()

    /// Monotonic clock in ms. `nonisolated` so the off-main flush timer can stamp pings.
    /// Latency probes / host stats use event kinds that 0.5–0.7 peers don't know; an old
    /// peer drops the whole session on the first one, so only v2 peers get them.
    nonisolated static func sendsProbes(peerVersion: Int) -> Bool { peerVersion >= 2 }
    /// `.edgeSetup` is v4; an older peer drops the session on the unknown kind.
    nonisolated static func sendsEdgeSetup(peerVersion: Int) -> Bool { peerVersion >= 4 }

    nonisolated static func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000.0 }

    private func recordLatency(_ rtt: Double) {
        if let line = latency.record(rtt: rtt, at: ControlHost.nowMs() / 1000) { DebugLog.log(line) }
    }

    private var link: PeerLink?
    private var monitor: Any?
    private let linkBox = LinkBox()        // lets off-main capture threads send
    private var edge: EdgeCapture?
    /// Set by the UI before connecting. Edge mode uses a global tap (needs Accessibility
    /// + Input Monitoring); window mode (click-to-capture) needs no permissions.
    var edgeModeEnabled = false
    var controlEdge: ScreenEdge = .right     // which edge hands off (set by UI)
    var controlDisplayID: UInt32 = 0         // which monitor's edge (0 = whole desktop)
    /// EXPERIMENTAL, set by the UI before `connect`: switch on the pointer resting at the
    /// hand-off edge (window-mode capture, no event tap), and ask the peer to return control
    /// when its pointer is pushed past the opposite edge.
    var edgeHandoffSpike = false
    var returnAtEdge = false
    private var edgeWatcher: DispatchSourceTimer?
    private var edgePanel: EdgeCapturePanel?
    private var edgePanelResign: NSObjectProtocol?
    private var previousApp: NSRunningApplication?
    private var capturedViaEdge = false
    private var edgeModeStale = false           // edge-mode tap is on the old edge until capture ends
    /// Arrangement, set by the UI before `connect`: where the other screen sits on the edge
    /// (mm, nil = centred), and its last-known size. `onRemoteScreen` reports the real size.
    var handoffOffsetMM: Double?
    var remoteScreenFallback: ScreenGeometry?
    var onRemoteScreen: ((ScreenGeometry) -> Void)?
    private var handoff: HandoffGeometry?       // this session's edge mapping
    private var remoteScreen: ScreenGeometry?   // the other Mac's screen, as last reported
    private let screens = ScreenChangeWatcher() // re-lays the edge out when our monitors change
    private var pendingEntry: CGPoint?          // where to put the remote pointer on an edge switch
    private var returnLanding: CGPoint?         // where to put ours when the peer hands back
    /// EXPERIMENTAL flags, set by the UI before `connect` (read at capture setup, so a
    /// change takes effect on the next connection — reconnect to A/B them).
    var useBinaryControl = false             // binary vs JSON control-event codec
    var flushIntervalMs = AppSettings.defaultFlushInterval   // mouse-move coalescing cadence
    /// Live multiplier on forwarded mouse deltas (mirrors AppSettings.mouseSensitivity).
    var mouseSensitivity = 1.0

    // Mouse-move coalescing — accumulate deltas in a lock-guarded buffer, flushed on a
    // precise off-main timer so the cursor stream has a steady cadence (no Task.sleep /
    // main-actor jitter, which caused stutter).
    private let moveBuffer = MoveBuffer()
    private let inputLag = InputLagMeter()   // main-thread delivery lag of captured input
    private let flushQueue = DispatchQueue(label: "netcatch.control.flush", qos: .userInteractive)
    private var flushTimer: DispatchSourceTimer?

    /// Brief on-screen "press ⌃⌥⌘ to release" hint shown when capture begins.
    private let hint = CaptureHintController()

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleResignActive() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .capturing else { return }
                DebugLog.log("control host: active Space changed during capture (system swipe gesture?)", .warn)
            }
        }
    }

    /// Window mode needs focus; edge mode uses a global tap, so it never drops on deactivate.
    /// A Magic Mouse / trackpad *system* swipe can switch Space and briefly deactivate us —
    /// only end capture if we are still inactive after a short grace period, so a gesture
    /// flicker keeps control while a real ⌘-Tab away still releases it.
    private func handleResignActive() {
        guard state == .capturing, !edgeModeEnabled else { return }
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        DebugLog.log("control host: resigned active during capture (front: \(front)) — grace check in 250 ms", .warn)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.state == .capturing else { return }
            if NSApp.isActive {
                DebugLog.log("control host: re-activated within grace — capture kept")
            } else {
                DebugLog.log("control host: still inactive after grace — releasing", .warn)
                self.endCapture()
            }
        }
    }

    /// Pin our ordinary windows to every Space for the duration of capture so a system
    /// swipe that switches Space does not leave the window (and our active status) behind.
    private var savedCollectionBehavior: [(NSWindow, NSWindow.CollectionBehavior)] = []
    private func pinWindowsToAllSpaces(_ pin: Bool) {
        if pin {
            savedCollectionBehavior = NSApp.windows
                .filter { !($0 is NSPanel) && $0.isVisible }
                .map { ($0, $0.collectionBehavior) }
            for (w, _) in savedCollectionBehavior {
                // Only the all-Spaces bit. `.fullScreenAuxiliary` conflicts with the
                // `.fullScreenPrimary` SwiftUI windows carry and older AppKit raises on the
                // combination (suspected 0.8.0 crash on capture). `.moveToActiveSpace` is
                // mutually exclusive with `.canJoinAllSpaces`, so clear it first.
                var b = w.collectionBehavior
                b.remove(.moveToActiveSpace)
                b.insert(.canJoinAllSpaces)
                w.collectionBehavior = b
            }
        } else {
            for (w, b) in savedCollectionBehavior { w.collectionBehavior = b }
            savedCollectionBehavior = []
        }
    }

    // MARK: Connect

    func connect(to peer: Peer, localName: String) {
        guard state == .idle else { return }
        state = .connecting; peerName = peer.name; currentPeer = peer; lastError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let link = try await TransportConnector.shared.connect(to: peer, localName: localName,
                                                                       allowed: Self.controlTransports)
                try await link.sendSecureObject(SessionHello(kind: .control, version: SessionHello.currentControlVersion))
                // Wait for the peer to accept before we ever capture / hijack the cursor.
                let ack = try await link.receiveSecureObject(ControlAck.self)
                guard ack.accepted else {
                    link.cancel()
                    self.lastError = ack.reason.isEmpty ? "\(peer.name) is not accepting control." : ack.reason
                    self.state = .idle
                    DebugLog.log("control host: peer refused — \(self.lastError ?? "")", .warn)
                    return
                }
                self.peerVersion = ack.version
                self.peerFingerprint = link.remoteFingerprint
                link.setLowLatency()        // ask Wi-Fi not to batch our input frames
                link.useBinaryControl = self.useBinaryControl   // codec fixed for this session
                if let s = ack.screen { self.onRemoteScreen?(s) }
                try await link.sendSecureObject(self.layOutHandoff(remote: ack.screen ?? self.remoteScreenFallback ?? .assumedRemote))
                self.link = link
                self.linkBox.link = link
                self.state = .connected
                if self.edgeModeEnabled { self.startEdgeMode() }
                else if self.edgeHandoffSpike { self.startEdgeWatcher() }
                self.startReturnReader(link: link)
                if ack.version >= 4 { self.screens.start { [weak self] in self?.screensChanged(remote: nil) } }
                DebugLog.log("control host: connected to \(peer.name) (protocol v\(ack.version))")
            } catch {
                self.lastError = error.localizedDescription
                self.state = .idle
                DebugLog.log("control host: connect failed — \(error.localizedDescription)", .error)
            }
        }
    }

    func disconnect() {
        if state != .idle { DebugLog.log("control host: disconnect (was \(state))") }
        let wasCapturing = state == .capturing
        endCapture()
        edge?.stop(); edge = nil; edgeModeStale = false
        stopEdgeWatcher()
        screens.stop()
        if edgePanel != nil { tearDownEdgePanel(restoreFocus: false) }
        handoff = nil; remoteScreen = nil; pendingEntry = nil; returnLanding = nil
        let old = link
        link = nil
        linkBox.link = nil
        state = .idle; peerName = nil; peerVersion = 1; currentPeer = nil; peerFingerprint = nil
        latency = LatencyStats()
        if wasCapturing, let old {
            // Let the queued releaseAll go out and give the peer a moment to hand its
            // clipboard back over the same link before we tear it down.
            flushQueue.async { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { old.cancel() } }
        } else {
            old?.cancel()
        }
    }

    /// Send a discrete event (click/key/releaseAll) on the flush queue, flushing any
    /// pending mouse move first so it stays correctly positioned. Synchronous write — no
    /// async send-task that would batch frames and clump them on the wire.
    private func sendOnQueue(_ event: ControlEvent) {
        let buf = moveBuffer; let box = linkBox
        flushQueue.async { [weak self] in
            guard let link = box.link else { return }
            if let move = buf.takeEvent() { _ = link.sendControlEventSync(move) }
            if !link.sendControlEventSync(event) {
                DebugLog.log("control host: send of \(event.kind.rawValue) failed — disconnecting", .error)
                Task { @MainActor in self?.disconnect() }
            }
        }
    }

    /// Line the two screens up physically along the hand-off edge (arrangement + sizes) and
    /// return the setup that arms the other Mac's matching return stretch.
    private func layOutHandoff(remote: ScreenGeometry) -> ControlSetup {
        // A hand-off monitor that has been unplugged falls back to the main display.
        let id = controlDisplayID != 0 && CGDisplayIsOnline(controlDisplayID) != 0 ? controlDisplayID : CGMainDisplayID()
        let local = ScreenGeometry.display(id)
        let geo = HandoffGeometry(local: local, remote: remote, edge: controlEdge,
                                  offsetMM: handoffOffsetMM ?? HandoffGeometry.centredOffsetMM(
                                    local: local, remote: remote, edge: controlEdge))
        handoff = geo
        remoteScreen = remote
        if let span = geo.localSpan {
            DebugLog.log(String(format: "control host: hand-off stretch %.0f–%.0f pt of the %@ edge (other screen %.0f×%.0f mm)",
                                span.lowerBound, span.upperBound, controlEdge.rawValue, remote.widthMM, remote.heightMM))
        }
        let armReturn = edgeModeEnabled || returnAtEdge
        return ControlSetup(hostEdge: controlEdge, autoReturn: armReturn,
                            returnArea: armReturn ? remote : nil,
                            returnSpan: armReturn ? geo.remoteSpan.map { [$0.lowerBound, $0.upperBound] } : nil)
    }

    /// Either Mac's monitors changed mid-session (`remote` = the other Mac's new screen, nil =
    /// ours changed).
    private func screensChanged(remote: ScreenGeometry?) {
        if let remote { onRemoteScreen?(remote) }
        relayOut(remote: remote, because: remote == nil ? "this Mac's screens changed"
                                                        : "\(peerName ?? "the other Mac")'s screens changed")
    }

    /// The arrangement was edited in Settings (screen slid along the edge, edge or monitor
    /// changed): take it now, and re-lay out an open session with it.
    func arrangementChanged(edge: ScreenEdge, displayID: UInt32, offsetMM: Double?) {
        guard edge != controlEdge || displayID != controlDisplayID || offsetMM != handoffOffsetMM else { return }
        controlEdge = edge; controlDisplayID = displayID; handoffOffsetMM = offsetMM
        relayOut(because: "arrangement changed in Settings")
    }

    /// Re-lay the hand-off edge out mid-session (`remote` = the other Mac's new screen, nil = as
    /// before), re-arm the other Mac's return stretch, and move the edge watcher / tap to it.
    private func relayOut(remote: ScreenGeometry? = nil, because why: String) {
        guard state != .idle, let current = remoteScreen else { return }
        DebugLog.log("control host: \(why) — re-laying out the hand-off edge")
        let setup = layOutHandoff(remote: remote ?? current)
        if Self.sendsEdgeSetup(peerVersion: peerVersion) { sendOnQueue(ControlEvent(kind: .edgeSetup, setup: setup)) }
        if edgeModeEnabled {
            if state == .capturing { edgeModeStale = true } else { restartEdgeMode() }
        } else if edgeHandoffSpike {
            startEdgeWatcher()
        }
    }

    private func restartEdgeMode() {
        edgeModeStale = false
        edge?.stop(); edge = nil
        startEdgeMode()
    }

    /// Read return signals from the client (its cursor reached the return edge) → take
    /// control back to this Mac.
    private func startReturnReader(link: PeerLink) {
        Task { [weak self] in
            while true {
                let r: ControlReturn
                do {
                    r = try await link.receiveSecureObject(ControlReturn.self)
                } catch let e as DecodingError {
                    DebugLog.log("control host: ignoring undecodable frame from peer — \(e)", .warn)
                    continue                                              // link is fine, frame wasn't
                } catch {
                    DebugLog.log("control host: return reader ended — \(error.localizedDescription)", .warn)
                    break
                }
                if let sent = r.pong {
                    let rtt = ControlHost.nowMs() - sent                 // same host clock → no sync needed
                    await MainActor.run { self?.recordLatency(rtt) }
                } else if let screen = r.screen {
                    await MainActor.run { self?.screensChanged(remote: screen) }
                } else if let payload = r.clipboard {
                    await MainActor.run {
                        guard let self else { return }
                        self.onClipboardReceived(payload, link.remoteFingerprint)
                    }
                } else {
                    DebugLog.log("control host: peer signalled return of control")
                    let at = r.at.flatMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
                    await MainActor.run {
                        // Land our pointer where theirs crossed back, on the matching stretch.
                        if let at, let g = self?.handoff { self?.returnLanding = g.returnPoint(leaving: at) }
                        self?.endCapture()                               // real return-of-control signal
                    }
                }
            }
            // The peer is gone: release capture and the cursor now, don't wait for the next
            // mouse move to discover the dead socket.
            await MainActor.run { if self?.state != .idle { self?.disconnect() } }
        }
    }

    /// Start edge-bump capture (global tap). Forwarding feeds the same buffer + sync send
    /// path as window mode.
    private func startEdgeMode() {
        let buf = moveBuffer; let box = linkBox; let q = flushQueue
        let edge = EdgeCapture(
            edge: controlEdge,
            displayID: controlDisplayID,
            forwardMove: { dx, dy, flags in buf.add(dx: dx, dy: dy, flags: flags) },
            forwardDiscrete: { ce in
                q.async {
                    guard let link = box.link else { return }
                    if let move = buf.takeEvent() { _ = link.sendControlEventSync(move) }
                    _ = link.sendControlEventSync(ce)
                }
            },
            onBegin: { [weak self] in Task { @MainActor in self?.enterCapture() } },
            onEnd:   { [weak self] in Task { @MainActor in self?.endCapture() } }
        )
        if edge.start() {
            self.edge = edge
            DebugLog.log("control host: edge mode active — bump the right screen edge to control")
        } else {
            self.lastError = "Edge mode needs Accessibility + Input Monitoring (grant them in Settings → Control)."
            DebugLog.log("control host: edge tap failed (permissions?)", .error)
        }
    }

    // MARK: Capture

    /// Window mode: user clicked the capture area.
    func beginCapture() {
        guard state == .connected, link != nil else { return }   // never hijack without a live session
        installMonitor()
        enterCapture()
    }

    func endCapture() {
        guard state == .capturing else { return }
        leaveCapture(warpInsideEdge: edgeModeEnabled || capturedViaEdge)
        if edgeModeStale { restartEdgeMode() }   // arrangement changed while we were away
    }

    /// Ask the controlled Mac to wake its display (v2 peers only). Sent automatically when
    /// capture begins and on demand from the UI.
    func wakeRemoteDisplay() {
        guard state == .connected || state == .capturing, peerVersion >= 2 else { return }
        sendOnQueue(ControlEvent(kind: .wakeDisplay))
    }

    private var lastCaptureEnd: Date?

    /// Hotkey entry point: re-enter capture on an open session. Ignored for 400 ms after a
    /// release, because ⌃⌥⌘K pressed *while* capturing releases on the modifiers first and
    /// the K would otherwise immediately re-capture.
    func regrab() {
        // While capturing, the hotkey is a guaranteed release: Carbon hotkeys fire at system
        // level even when a Keychain/security dialog has stolen keyboard focus and the
        // ⌃⌥⌘ chord can no longer reach our event monitor.
        if state == .capturing {
            DebugLog.log("control host: release via \(HotkeyMonitor.label)")
            endCapture(); return
        }
        guard state == .connected else { return }
        if let t = lastCaptureEnd, Date().timeIntervalSince(t) < 0.4 { return }
        guard let window = mainWindowProvider() else {
            DebugLog.log("control host: re-grab ignored — main window not available", .warn); return
        }
        // Bring the main window back (it stays alive when closed) and activate. Activation
        // is asynchronous, so capture only once the app is actually active.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        waitForActivation(attempts: 10) { [weak self] active in
            guard let self, self.state == .connected else { return }
            guard active else {
                DebugLog.log("control host: re-grab aborted — app did not become active", .warn); return
            }
            // Put the cursor inside our window so mouse events are routed to KMctrl, like a
            // click on the capture area would. AppKit → CG coordinates (flip on the primary).
            let f = window.frame
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            CGWarpMouseCursorPosition(CGPoint(x: f.midX, y: primaryHeight - f.midY))
            self.beginCapture()
            DebugLog.log("control host: re-grab via \(HotkeyMonitor.label)")
        }
    }

    // MARK: Edge hand-off spike (no event tap)

    /// Poll the pointer (readable with no permissions) and switch when it rests on the
    /// hand-off edge of the chosen display.
    private func startEdgeWatcher() {
        stopEdgeWatcher()
        guard let geo = handoff, let span = geo.localSpan else {
            DebugLog.log("control host: edge switch off — the other screen doesn't touch the hand-off edge in the arrangement", .warn)
            return
        }
        let edge = controlEdge, display = geo.local.rect
        var dwell = EdgeDwell()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "kmctrl.edge-watch", qos: .userInitiated))
        t.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            guard let p = CGEvent(source: nil)?.location else { return }
            if dwell.update(point: p, display: display, edge: edge, span: span, now: ProcessInfo.processInfo.systemUptime) {
                let entry = geo.entryPoint(leaving: p)
                Task { @MainActor in self?.edgeHandoff(entry: entry) }
            }
        }
        t.resume()
        edgeWatcher = t
        DebugLog.log("control host: edge switch (experimental) watching the \(edge.rawValue) edge")
    }

    private func stopEdgeWatcher() { edgeWatcher?.cancel(); edgeWatcher = nil }

    /// The pointer rested on the hand-off edge: take input focus with an invisible full-screen
    /// panel and start window-mode capture. A non-activating panel can take keyboard focus
    /// without KMctrl becoming the active app (which macOS may refuse to a background app);
    /// app activation is the fallback. Logs which path worked, and skips the switch — leaving
    /// the pointer alone — if neither did.
    private func edgeHandoff(entry: CGPoint?) {
        guard state == .connected, edgePanel == nil else { return }
        pendingEntry = entry
        let panel = EdgeCapturePanel.make(on: handoffScreen())
        previousApp = NSWorkspace.shared.frontmostApplication
        edgePanel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.edgePanel === panel else { return }
            if panel.isKeyWindow { self.beginEdgeCapture(panel, via: "non-activating panel"); return }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.edgePanel === panel else { return }
                if panel.isKeyWindow { self.beginEdgeCapture(panel, via: "app activation"); return }
                let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                DebugLog.log("control host: edge switch skipped — macOS did not give KMctrl focus (front: \(front))", .warn)
                self.tearDownEdgePanel(restoreFocus: false)
            }
        }
    }

    private func beginEdgeCapture(_ panel: EdgeCapturePanel, via path: String) {
        guard state == .connected else { tearDownEdgePanel(restoreFocus: true); return }
        DebugLog.log("control host: edge switch — focus via \(path) (app active: \(NSApp.isActive))")
        capturedViaEdge = true
        // If the panel loses focus (e.g. ⌘-Tab), keys would go elsewhere: release.
        edgePanelResign = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .capturing, self.capturedViaEdge else { return }
                DebugLog.log("control host: edge capture lost focus — releasing", .warn)
                self.endCapture()
            }
        }
        // Put the other Mac's pointer where ours crossed the edge (v4 peers), before any moves.
        if let e = pendingEntry, peerVersion >= 4 { sendOnQueue(ControlEvent(kind: .enterAt, dx: e.x, dy: e.y)) }
        pendingEntry = nil
        installMonitor()
        enterCapture()
    }

    private func tearDownEdgePanel(restoreFocus: Bool) {
        if let o = edgePanelResign { NotificationCenter.default.removeObserver(o); edgePanelResign = nil }
        edgePanel?.orderOut(nil); edgePanel = nil
        capturedViaEdge = false
        if restoreFocus, NSApp.isActive, let prev = previousApp, prev != NSRunningApplication.current {
            prev.activate(options: [])                  // give focus back to what you were using
        }
        previousApp = nil
    }

    /// The hand-off display as an NSScreen (falls back to the screen under the pointer).
    private func handoffScreen() -> NSScreen {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if controlDisplayID != 0,
           let s = NSScreen.screens.first(where: { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == controlDisplayID }) {
            return s
        }
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func waitForActivation(attempts: Int, _ done: @escaping (Bool) -> Void) {
        if NSApp.isActive || attempts == 0 { done(NSApp.isActive); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitForActivation(attempts: attempts - 1, done)
        }
    }

    private func enterCapture() {
        guard state == .connected else { return }
        CGDisplayHideCursor(CGMainDisplayID())
        CGAssociateMouseAndMouseCursorPosition(0)   // decouple hardware mouse from cursor
        if !edgeModeEnabled { pinWindowsToAllSpaces(true) }
        state = .capturing
        startFlushTimer()
        hint.flash()                                // remind how to release
        wakeRemoteDisplay()                         // in case the remote display is asleep
        DebugLog.log("control host: capture begin")
    }

    private func leaveCapture(warpInsideEdge: Bool) {
        state = .connected                          // set first — prevents reentrancy
        lastCaptureEnd = Date()
        hint.hide()
        if !edgeModeEnabled { pinWindowsToAllSpaces(false) }
        flushTimer?.cancel(); flushTimer = nil
        CGAssociateMouseAndMouseCursorPosition(1)   // always restore the cursor
        CGDisplayShowCursor(CGMainDisplayID())
        if let landing = returnLanding {            // handed back at the edge: cross at the matching place
            CGWarpMouseCursorPosition(landing)
        } else if warpInsideEdge, let g = handoff, let rs = g.remoteSpan {
            // Released another way: land in the middle of the shared stretch, off the edge.
            let mid = (rs.lowerBound + rs.upperBound) / 2
            CGWarpMouseCursorPosition(g.returnPoint(leaving: CGPoint(x: mid, y: mid)))
        } else if warpInsideEdge {                  // move off the edge so it won't re-trigger
            let b = EdgeCapture.bounds(forDisplay: controlDisplayID)  // the chosen monitor's edge
            let p: CGPoint
            switch controlEdge {
            case .right:  p = CGPoint(x: b.maxX - 60, y: b.midY)
            case .left:   p = CGPoint(x: b.minX + 60, y: b.midY)
            case .top:    p = CGPoint(x: b.midX, y: b.minY + 60)
            case .bottom: p = CGPoint(x: b.midX, y: b.maxY - 60)
            }
            CGWarpMouseCursorPosition(p)
        }
        returnLanding = nil
        sendOnQueue(ControlEvent(kind: .releaseAll))   // flushes pending move + releaseAll
        if capturedViaEdge { tearDownEdgePanel(restoreFocus: true) }
        DebugLog.log("control host: capture end")
    }

    private func startFlushTimer() {
        flushTimer?.cancel()
        let buf = moveBuffer; let box = linkBox; let lag = inputLag
        let intervalMs = flushIntervalMs   // already validated by AppSettings
        let probes = ControlHost.sendsProbes(peerVersion: peerVersion)
        let timer = DispatchSource.makeTimerSource(queue: flushQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(intervalMs), leeway: .nanoseconds(0))
        var sent = 0, ticks = 0
        var window = DispatchTime.now()
        var lastPing = DispatchTime.now()
        timer.setEventHandler { [weak self] in
            guard let link = box.link else { return }
            ticks += 1
            if let move = buf.takeEvent() {
                if link.sendControlEventSync(move) {
                    sent += 1
                } else {
                    DebugLog.log("control host: send of mouseMove failed — disconnecting", .error)
                    Task { @MainActor in self?.disconnect() }
                }
            }
            let now = DispatchTime.now()
            // Latency probe: ~5×/sec, host stamps its own clock; client bounces it back.
            if probes, now.uptimeNanoseconds - lastPing.uptimeNanoseconds >= 200_000_000 {
                if !link.sendControlEventSync(ControlEvent(kind: .ping, dx: ControlHost.nowMs())) {
                    DebugLog.log("control host: send of ping failed — disconnecting", .error)
                    Task { @MainActor in self?.disconnect() }
                }
                lastPing = now
            }
            if now.uptimeNanoseconds - window.uptimeNanoseconds >= 1_000_000_000 {
                DebugLog.log("control host: \(sent) moves/s sent (\(ticks) timer ticks/s, \(intervalMs)ms, \(link.useBinaryControl ? "binary" : "json")), input lag max \(Int(lag.takeMax())) ms")
                if probes { _ = link.sendControlEventSync(ControlEvent(kind: .hostStats, dx: Double(sent), dy: Double(ticks))) }
                sent = 0; ticks = 0; window = now
            }
        }
        timer.resume()
        flushTimer = timer
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .keyDown, .keyUp, .flagsChanged,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel,
            .systemDefined,   // media keys (volume / brightness / playback)
            // Gestures are swallowed while capturing (never forwarded) so a horizontal
            // swipe can't trigger in-app navigation or steal the capture.
            .swipe, .gesture, .magnify, .rotate, .smartMagnify, .pressure
        ]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self, self.state == .capturing else { return event }
            // Release hotkey: control + option + command held together.
            if event.type == .flagsChanged {
                let f = event.modifierFlags
                if f.contains(.control), f.contains(.option), f.contains(.command) {
                    DebugLog.log("control host: release chord pressed")
                    self.endCapture(); return nil
                }
            }
            guard let ce = self.translate(event) else {
                // Only consume what we forward: unrelated system-defined events pass through.
                return event.type == .systemDefined ? event : nil
            }
            if ce.kind == .mouseMove {
                self.inputLag.note(eventTime: event.timestamp, now: ProcessInfo.processInfo.systemUptime)
                self.moveBuffer.add(dx: ce.dx, dy: ce.dy, flags: ce.flags)   // coalesced, flushed by timer
            } else {
                self.sendOnQueue(ce)                    // flushes pending move, keeps clicks positioned
            }
            return nil   // consume so the work Mac doesn't also act on it
        }
    }

    private func translate(_ e: NSEvent) -> ControlEvent? {
        let flags = cgFlags(e.modifierFlags)
        switch e.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return ControlEvent(kind: .mouseMove, dx: e.deltaX * mouseSensitivity, dy: e.deltaY * mouseSensitivity, flags: flags)
        case .leftMouseDown:  return ControlEvent(kind: .mouseDown, button: 0, flags: flags)
        case .leftMouseUp:    return ControlEvent(kind: .mouseUp, button: 0, flags: flags)
        case .rightMouseDown: return ControlEvent(kind: .mouseDown, button: 1, flags: flags)
        case .rightMouseUp:   return ControlEvent(kind: .mouseUp, button: 1, flags: flags)
        case .otherMouseDown: return ControlEvent(kind: .mouseDown, button: 2, flags: flags)
        case .otherMouseUp:   return ControlEvent(kind: .mouseUp, button: 2, flags: flags)
        case .scrollWheel:    return ControlEvent(kind: .scroll, scrollX: e.scrollingDeltaX, scrollY: e.scrollingDeltaY, flags: flags)
        case .keyDown:
            var ce = ControlEvent(kind: .keyDown, keyCode: Int(e.keyCode), flags: flags)
            // v2 peers get the typed characters so typing is layout-independent.
            if peerVersion >= 2 { ce.chars = KeyCharacters.override(for: e.characters, flags: flags) }
            return ce
        case .keyUp:          return ControlEvent(kind: .keyUp, keyCode: Int(e.keyCode), flags: flags)
        case .flagsChanged:   return ControlEvent(kind: .flagsChanged, flags: flags)
        case .systemDefined:
            guard peerVersion >= 2, e.subtype.rawValue == MediaKey.subtypeAuxControl,
                  let mk = MediaKey.decode(data1: e.data1), MediaKey.forwarded.contains(mk.key)
            else { return nil }
            return ControlEvent(kind: .mediaKey, button: mk.isDown ? 1 : 0, keyCode: mk.key, flags: flags)
        default: return nil   // gestures (.swipe etc.) are swallowed during capture, never forwarded
        }
    }

    // Thread-safe accumulator for coalesced mouse deltas (written on main, drained by the
    // flush timer on its own queue).
    final class MoveBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var dx = 0.0, dy = 0.0, flags: UInt64 = 0, dirty = false
        func add(dx: Double, dy: Double, flags: UInt64) {
            lock.lock(); self.dx += dx; self.dy += dy; self.flags = flags; dirty = true; lock.unlock()
        }
        func take() -> (dx: Double, dy: Double, flags: UInt64)? {
            lock.lock(); defer { lock.unlock() }
            guard dirty else { return nil }
            let r = (dx, dy, flags); dx = 0; dy = 0; dirty = false; return r
        }
        /// Drain the coalesced delta as a ready `.mouseMove` event, or nil if nothing pending.
        func takeEvent() -> ControlEvent? {
            guard let m = take() else { return nil }
            return ControlEvent(kind: .mouseMove, dx: m.dx, dy: m.dy, flags: m.flags)
        }
    }

    /// Holds the active link so off-main capture/timer threads can send without a
    /// main-actor hop.
    final class LinkBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _link: PeerLink?
        var link: PeerLink? {
            get { lock.lock(); defer { lock.unlock() }; return _link }
            set { lock.lock(); _link = newValue; lock.unlock() }
        }
    }

    private func cgFlags(_ mf: NSEvent.ModifierFlags) -> UInt64 {
        var cg: CGEventFlags = []
        if mf.contains(.shift)    { cg.insert(.maskShift) }
        if mf.contains(.control)  { cg.insert(.maskControl) }
        if mf.contains(.option)   { cg.insert(.maskAlternate) }
        if mf.contains(.command)  { cg.insert(.maskCommand) }
        if mf.contains(.capsLock) { cg.insert(.maskAlphaShift) }
        if mf.contains(.function) { cg.insert(.maskSecondaryFn) }
        return cg.rawValue
    }
}
