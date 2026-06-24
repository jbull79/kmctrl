import Foundation
import Network

/// Owns the *controlled* side: listens for inbound connections, runs the authenticated
/// handshake, and routes `.control` sessions to a `ControlInjector` (and `.status` queries to
/// a readiness report). Also owns Bonjour discovery + listener rebind on network change.
/// The *controlling* side is `ControlHost`.
@MainActor
final class ControlManager: ObservableObject {
    let settings: AppSettings
    let receiver = ReceiverServer()
    let discovery = DiscoveryService()
    let trust = TrustStore()
    let readiness = ControlReadiness()

    /// Peer currently controlling this Mac, if any.
    @Published var controlActiveFrom: String?

    private let pathMonitor = NWPathMonitor()
    private var pathMonitorStarted = false
    private var lastBoundIP: String?
    private var rebindTask: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
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
                    let accepted = self.settings.controlEnabled
                    try await link.sendSecureObject(ControlAck(
                        accepted: accepted,
                        reason: accepted ? "" : "Control is turned off on \(self.settings.deviceName)"))
                    guard accepted else {
                        DebugLog.log("incoming: control refused (control disabled)", .warn)
                        link.cancel(); return
                    }
                    link.setLowLatency()
                    await self.runControlReceive(link: link)
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
                    let event = try await link.receiveSecureObject(ControlEvent.self)
                    if event.kind == .hostStats { continue }
                    injector.apply(event)
                }
            } catch {
                injector.releaseAll()
                DebugLog.log("control: session closed — \(error.localizedDescription)", .warn)
            }
        }.value
        controlActiveFrom = nil
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
                            workbook: false, clipboard: false)
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
