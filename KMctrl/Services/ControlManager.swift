import Foundation
import Network
import IOKit.pwr_mgt

/// Owns the *controlled* side: listens for inbound connections, runs the authenticated
/// handshake, and routes `.control` sessions to a `ControlInjector` (and `.status` queries to
/// a readiness report). Also owns Bonjour discovery + listener rebind on network change.
/// The *controlling* side is `ControlHost`.
/// A first-time request from an untrusted peer to control this Mac. Accepting trusts it so
/// future control sessions are silent.
@MainActor
final class ControlApprovalRequest: ObservableObject, Identifiable {
    let id = UUID()
    let peerName: String
    let fingerprint: String
    private var respond: ((Bool) -> Void)?
    init(peerName: String, fingerprint: String, respond: @escaping (Bool) -> Void) {
        self.peerName = peerName; self.fingerprint = fingerprint; self.respond = respond
    }
    /// Answers once; a later answer (the timeout after a click, or the reverse) is ignored.
    func resolve(_ accepted: Bool) {
        let r = respond
        respond = nil
        r?(accepted)
    }
}

/// Controllers whose session was ended from this Mac. The kill switch has to stay a kill switch:
/// their automatic reconnects are refused until someone connects from that Mac on purpose.
struct ControllerKickList {
    private var kicked: Set<String> = []

    mutating func kick(_ fingerprint: String) { kicked.insert(fingerprint) }

    mutating func allows(_ fingerprint: String, isReconnect: Bool) -> Bool {
        if isReconnect { return !kicked.contains(fingerprint) }
        kicked.remove(fingerprint)
        return true
    }
}

@MainActor
final class ControlManager: ObservableObject {
    /// A controller that has come back has given up on its old session, even if this Mac hasn't
    /// noticed yet. Another Mac's session is not its to end.
    nonisolated static func replacesSession(of current: String?, with new: String) -> Bool { current == new }

    let settings: AppSettings
    let receiver = ReceiverServer()
    let discovery = DiscoveryService()
    let trust = TrustStore()
    let readiness = ControlReadiness()
    let clipboard: ClipboardSync

    /// Peer currently controlling this Mac, if any.
    @Published var controlActiveFrom: String?
    /// A first-time request from an untrusted peer to control this Mac.
    @Published var pendingControlRequest: ControlApprovalRequest?
    /// An unanswered Allow prompt is declined after this long, freeing the connection.
    static let approvalTimeout: TimeInterval = 60
    /// A connection that has finished the handshake must say what it wants within this long.
    static let helloTimeout: TimeInterval = 15

    /// The link of the active inbound control session, so this Mac can end it (and hand
    /// its clipboard back over it).
    private(set) var controlledLink: PeerLink?
    /// On-screen "being controlled" badge (+ kill switch) shown while a remote drives us.
    private let badge = ControlBadgeController()
    /// Re-reports this Mac's screen to the controller when monitors change mid-session.
    private let screens = ScreenChangeWatcher()
    private var reportedScreen: ScreenGeometry?

    /// End the control session from the controlled side (kick the controller off).
    func disconnectControlled() {
        if let link = controlledLink { kickedControllers.kick(link.remoteFingerprint) }
        controlledLink?.cancel()
    }
    private var kickedControllers = ControllerKickList()

    private let pathMonitor = NWPathMonitor()
    private var pathMonitorStarted = false
    private var lastBoundIP: String?
    private var rebindTask: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
        // Transport is wired by AppModel (control link, either direction).
        clipboard = ClipboardSync(isEnabled: { settings.clipboardSyncEnabled }) { _, _ in throw LinkError.notReady }
        receiver.onIncoming = { [weak self] link in self?.handleIncoming(link) }
    }

    func startServices() {
        DebugLog.log("services: starting as '\(settings.deviceName)', listen port \(settings.port)")
        discovery.ownServiceName = settings.deviceName
        receiver.start(serviceName: settings.deviceName, port: settings.port)
        lastBoundIP = LocalNetwork.ipv4Address()
        discovery.start()
        startPathMonitorIfNeeded()
    }

    func restartServices() {
        receiver.stop()
        discovery.stop()
        TransportConnector.shared.resetCache()
        startServices()
    }

    func setDiscoverable(_ on: Bool) {
        if on { startServices() } else { receiver.stop(); discovery.stop() }
    }

    // MARK: Network rebind

    private func startPathMonitorIfNeeded() {
        guard !pathMonitorStarted else { return }
        pathMonitorStarted = true
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.handlePathChange() }
        }
        pathMonitor.start(queue: .global(qos: .utility))
    }

    private func handlePathChange() {
        guard LocalNetwork.ipv4Address() != lastBoundIP else { return }
        rebindTask?.cancel()
        rebindTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self, !Task.isCancelled else { return }
            let settled = LocalNetwork.ipv4Address()
            guard settled != self.lastBoundIP else { return }
            DebugLog.log("network: LAN address changed — rebinding listener", .warn)
            self.restartServices()
        }
    }

    // MARK: Incoming sessions

    private func handleIncoming(_ link: PeerLink) {
        Task { @MainActor [weak self] in
            guard let self else { link.cancel(); return }
            do {
                try await link.start()
                try await link.handshake(localName: self.settings.deviceName)
                // Don't let a peer sit on a connection slot after the handshake without asking
                // for anything (24 slots; a stranger could otherwise hold them all).
                link.stream.setReadTimeout(Self.helloTimeout)
                let hello = try await link.receiveSecureObject(SessionHello.self)
                link.stream.setReadTimeout(0)
                DebugLog.log("incoming: \(hello.kind.rawValue) from \(link.remoteName) fp=\(link.remoteFingerprint)")
                switch hello.kind {
                case .status:
                    let trusted = self.trust.isTrusted(link.remoteFingerprint)
                    try await link.sendSecureObject(self.localStatusReport(trusted: trusted))
                    link.cancel()
                case .control:
                    // Master switch off → refuse outright.
                    guard self.settings.controlEnabled else {
                        try await link.sendSecureObject(ControlAck(
                            accepted: false, reason: "Control is turned off on \(self.settings.deviceName)",
                            version: SessionHello.currentControlVersion))
                        link.cancel(); return
                    }
                    let fp = link.remoteFingerprint
                    guard self.kickedControllers.allows(fp, isReconnect: hello.reconnect == true) else {
                        DebugLog.log("incoming: refused an automatic reconnect from \(link.remoteName) — its session was ended here", .warn)
                        try await link.sendSecureObject(ControlAck(
                            accepted: false, reason: "\(self.settings.deviceName) ended the session. Click Control to connect again.",
                            version: SessionHello.currentControlVersion))
                        link.cancel(); return
                    }
                    // Trust-gate: a trusted peer is accepted silently; an unknown peer needs a
                    // one-time prompt, and accepting trusts it. Never inject input from a
                    // stranger just because the master switch is on.
                    let accepted = self.trust.isTrusted(fp)
                        ? true
                        : await self.requestControlApproval(name: link.remoteName, fingerprint: fp)
                    let screen = accepted ? ScreenGeometry.mainDisplay() : nil
                    try await link.sendSecureObject(ControlAck(
                        accepted: accepted, reason: accepted ? "" : "\(self.settings.deviceName) declined control",
                        version: SessionHello.currentControlVersion, screen: screen))
                    self.reportedScreen = screen
                    guard accepted else {
                        DebugLog.log("incoming: control declined", .warn)
                        link.cancel(); return
                    }
                    if !self.trust.isTrusted(fp) { self.trust.trust(fp, name: link.remoteName) }
                    link.setLowLatency()
                    await self.runControlReceive(link: link, hostVersion: hello.version)
                default:
                    link.cancel()
                }
            } catch {
                DebugLog.log("incoming: failed — \(error.localizedDescription)", .warn)
                link.cancel()
            }
        }
    }

    private func runControlReceive(link: PeerLink, hostVersion: Int) async {
        let name = link.remoteName
        let replaced = Self.replacesSession(of: controlledLink?.remoteFingerprint, with: link.remoteFingerprint) ? controlledLink : nil
        controlActiveFrom = name
        controlledLink = link
        replaced?.cancel()      // lets go of anything its dead session left held down
        badge.show(controller: name) { [weak self] in self?.disconnectControlled() }
        clipboard.setActive(true, sessionFingerprint: link.remoteFingerprint)
        DebugLog.log("control: session started from \(name)")
        let injector = ControlInjector()
        screens.start { [weak self] in self?.screensChanged(link: link, injector: injector, hostVersion: hostVersion) }
        await Task.detached(priority: .userInitiated) {
            injector.start()
            defer { injector.stop() }
            do {
                injector.configureReturn(try await link.receiveSecureObject(ControlSetup.self))
                injector.onReturn = { at in _ = link.sendSecureObjectSync(ControlReturn(at: [at.x, at.y])) }
                var stats = ReceiveStats()
                var pulse = ActivityPulse()                 // remote input keeps us awake like local use
                var activity: IOPMAssertionID = 0
                while true {
                    // Auto-detects JSON/binary codec. Out-of-range values are dropped, not injected.
                    guard let event = try await link.receiveControlEvent().sanitizedForInjection() else { continue }
                    if let line = stats.record(isMove: event.kind == .mouseMove, at: ControlHost.nowMs() / 1000) {
                        DebugLog.log(line)
                    }
                    if event.kind == .ping {
                        _ = link.sendSecureObjectSync(ControlReturn(pong: event.dx))   // bounce timestamp back
                        continue
                    }
                    if event.kind == .hostStats { continue }
                    if event.kind == .wakeDisplay { DisplayWake.wake(); continue }
                    if event.kind == .edgeSetup {           // the controller re-laid the screens out
                        if let setup = event.setup { injector.configureReturn(setup) }
                        continue
                    }
                    if event.kind == .clipboard {
                        if let p = event.clipboard {
                            Task { @MainActor [weak self] in self?.clipboard.receive(p, from: link.remoteFingerprint) }
                        }
                        continue
                    }
                    if event.kind == .releaseAll, hostVersion >= 3 {
                        // Control is going back: hand our clipboard to the controller over this link
                        // (v3 hosts only — older ones would read it as a return-of-control signal).
                        Task { @MainActor [weak self] in self?.clipboard.pushNow(reason: "control released") }
                    }
                    injector.apply(event)
                    if event.kind != .releaseAll, pulse.due(at: ControlHost.nowMs() / 1000) {
                        DisplayWake.noteActivity(&activity)
                    }
                }
            } catch {
                injector.releaseAll()
                DebugLog.log("control: session closed — \(error.localizedDescription)", .warn)
            }
        }.value
        // An old session can end late (keepalive reaping a link whose network went away)
        // after a newer one took over — only clear the shared state if it is still ours.
        if controlledLink === link {
            screens.stop()
            clipboard.setActive(false, sessionFingerprint: "")
            controlActiveFrom = nil
            controlledLink = nil
            badge.hide()
        }
        link.cancel()
        DebugLog.log("control: session ended (\(name))")
    }

    /// Monitors changed while being controlled: keep the cursor inside the new desktop, and tell
    /// a v4 controller our new screen so it can re-line the hand-off edge up (older ones would
    /// read the report as a return of control).
    private func screensChanged(link: PeerLink, injector: ControlInjector, hostVersion: Int) {
        guard controlledLink === link else { return }
        injector.refreshDesktop()
        let screen = ScreenGeometry.mainDisplay()
        guard hostVersion >= 4, screen != reportedScreen else { return }
        reportedScreen = screen
        DebugLog.log(String(format: "control: screen changed — now %.0f×%.0f pt, %.0f×%.0f mm; telling the controller",
                            screen.width, screen.height, screen.widthMM, screen.heightMM))
        Task.detached { _ = link.sendSecureObjectSync(ControlReturn(screen: screen)) }   // never block the main thread on the socket
    }

    // MARK: Status

    func localStatusReport(trusted: Bool = true) -> StatusReport {
        readiness.refresh()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        guard trusted else {
            return StatusReport(deviceName: settings.deviceName, appVersion: version,
                                control: false, controlAccessibility: false,
                                controlInputMonitoring: false, controlEventTap: false,
                                workbook: false, clipboard: false)
        }
        return StatusReport(deviceName: settings.deviceName, appVersion: version,
                            control: readiness.allReady,
                            controlAccessibility: readiness.accessibility,
                            controlInputMonitoring: readiness.inputMonitoring,
                            controlEventTap: readiness.eventTapCreatable,
                            workbook: false, clipboard: settings.clipboardSyncEnabled)
    }

    private func requestControlApproval(name: String, fingerprint: String) async -> Bool {
        // One prompt at a time. A second request used to replace the one on screen, so Allow
        // trusted whoever asked last (and the first connection hung forever).
        guard pendingControlRequest == nil else {
            DebugLog.log("incoming: control request from \(name) declined — another request is waiting for an answer", .warn)
            return false
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let request = ControlApprovalRequest(peerName: name, fingerprint: fingerprint) { ok in
                cont.resume(returning: ok)
            }
            pendingControlRequest = request
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.approvalTimeout * 1_000_000_000))
                guard let self, self.pendingControlRequest === request else { return }
                DebugLog.log("incoming: control request from \(name) not answered — declined", .warn)
                self.resolveControlPending(false)
            }
        }
    }

    func resolveControlPending(_ accepted: Bool) {
        let req = pendingControlRequest
        pendingControlRequest = nil
        req?.resolve(accepted)
    }

    func queryStatus(of peer: Peer) async -> StatusReport? {
        do {
            let link = try await TransportConnector.shared.connect(to: peer, localName: settings.deviceName,
                                                                   allowed: settings.enabledTransportStrategies)
            defer { link.cancel() }
            try await link.sendSecureObject(SessionHello(kind: .status))
            return try await link.receiveSecureObject(StatusReport.self)
        } catch {
            DebugLog.log("status: query to '\(peer.name)' failed — \(error.localizedDescription)", .warn)
            return nil
        }
    }
}
