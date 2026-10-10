import Foundation
import Network

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
    private let respond: (Bool) -> Void
    init(peerName: String, fingerprint: String, respond: @escaping (Bool) -> Void) {
        self.peerName = peerName; self.fingerprint = fingerprint; self.respond = respond
    }
    func resolve(_ accepted: Bool) { respond(accepted) }
}

@MainActor
final class ControlManager: ObservableObject {
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

    /// The link of the active inbound control session, so this Mac can end it.
    private var controlledLink: PeerLink?
    /// On-screen "being controlled" badge (+ kill switch) shown while a remote drives us.
    private let badge = ControlBadgeController()

    /// End the control session from the controlled side (kick the controller off).
    func disconnectControlled() {
        controlledLink?.cancel()
    }

    private let pathMonitor = NWPathMonitor()
    private var pathMonitorStarted = false
    private var lastBoundIP: String?
    private var rebindTask: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
        clipboard = ClipboardSync(isEnabled: { settings.clipboardSyncEnabled }) { payload, peer, fp in
            try await ClipboardSync.push(payload, to: peer, expectingFingerprint: fp,
                                         localName: settings.deviceName, allowed: settings.enabledTransportStrategies)
        }
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
                let hello = try await link.receiveSecureObject(SessionHello.self)
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
                    // Trust-gate: a trusted peer is accepted silently; an unknown peer needs a
                    // one-time prompt, and accepting trusts it. Never inject input from a
                    // stranger just because the master switch is on.
                    let fp = link.remoteFingerprint
                    let accepted = self.trust.isTrusted(fp)
                        ? true
                        : await self.requestControlApproval(name: link.remoteName, fingerprint: fp)
                    try await link.sendSecureObject(ControlAck(
                        accepted: accepted, reason: accepted ? "" : "\(self.settings.deviceName) declined control",
                        version: SessionHello.currentControlVersion))
                    guard accepted else {
                        DebugLog.log("incoming: control declined", .warn)
                        link.cancel(); return
                    }
                    if !self.trust.isTrusted(fp) { self.trust.trust(fp, name: link.remoteName) }
                    link.setLowLatency()
                    await self.runControlReceive(link: link)
                case .clipboard:
                    // Trusted peers only, and only when this Mac opted in. Otherwise drop silently.
                    guard self.settings.clipboardSyncEnabled, self.trust.isTrusted(link.remoteFingerprint) else {
                        link.cancel(); return
                    }
                    let payload = try await link.receiveSecureObject(ClipboardPayload.self)
                    link.cancel()
                    self.clipboard.receive(payload, from: link.remoteFingerprint)
                default:
                    link.cancel()
                }
            } catch {
                DebugLog.log("incoming: failed — \(error.localizedDescription)", .warn)
                link.cancel()
            }
        }
    }

    private func runControlReceive(link: PeerLink) async {
        let name = link.remoteName
        controlActiveFrom = name
        controlledLink = link
        badge.show(controller: name) { [weak self] in self?.disconnectControlled() }
        // Push our clipboard back to the controller: resolved by name from discovery, but the
        // push verifies the connected Mac's fingerprint against this session's before sending.
        clipboard.setActive(true, sessionFingerprint: link.remoteFingerprint) { [weak self] in
            self?.discovery.peers.first { $0.name == name }
        }
        DebugLog.log("control: session started from \(name)")
        await Task.detached(priority: .userInitiated) {
            let injector = ControlInjector()
            injector.start()
            defer { injector.stop() }
            do {
                let setup = try await link.receiveSecureObject(ControlSetup.self)
                if setup.autoReturn {
                    injector.returnEdge = setup.hostEdge.opposite
                    injector.onReturn = { _ = link.sendSecureObjectSync(ControlReturn()) }
                }
                while true {
                    let event = try await link.receiveControlEvent()   // auto-detects JSON/binary codec
                    if event.kind == .ping {
                        _ = link.sendSecureObjectSync(ControlReturn(pong: event.dx))   // bounce timestamp back
                        continue
                    }
                    if event.kind == .hostStats { continue }
                    if event.kind == .wakeDisplay { DisplayWake.wake(); continue }
                    injector.apply(event)
                }
            } catch {
                injector.releaseAll()
                DebugLog.log("control: session closed — \(error.localizedDescription)", .warn)
            }
        }.value
        clipboard.setActive(false, sessionFingerprint: "") { nil }
        controlActiveFrom = nil
        controlledLink = nil
        badge.hide()
        link.cancel()
        DebugLog.log("control: session ended (\(name))")
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
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            pendingControlRequest = ControlApprovalRequest(peerName: name, fingerprint: fingerprint) { ok in
                cont.resume(returning: ok)
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
