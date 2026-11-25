import Foundation
import Network
import Darwin

/// Always-on listener that advertises this device over Bonjour and hands off each
/// incoming connection. It accepts over a raw POSIX socket (kernel routing, so replies
/// go out the physical LAN interface even when a VPN is up — like `nc`), and advertises
/// the service with `NetService`. Control replies are written synchronously to that socket, so
/// there is no other listener.
@MainActor
final class ReceiverServer: ObservableObject {
    @Published var isRunning = false
    @Published var lastError: String?

    private let serviceType = "_kmctrl._tcp"

    // POSIX path
    private var listenFD: Int32 = -1
    private var acceptQueue = DispatchQueue(label: "netcatch.accept")
    private var advertiser: NetService?
    /// Bound on concurrent inbound connections (anti-DoS); shared with the accept thread.
    private let inbound = InboundLimiter(maximum: 24)

    /// Called (on the main actor) for every new inbound connection.
    var onIncoming: ((PeerLink) -> Void)?

    func start(serviceName: String, port: UInt16) {
        stop()
        guard startPOSIX(serviceName: serviceName, port: port) else {
            DebugLog.log("listener: couldn't listen on port \(port)", .error)
            lastError = "Couldn’t listen on port \(port). Another app may be using it; pick another port in Settings."
            return
        }
    }

    func stop() {
        if listenFD >= 0 { shutdown(listenFD, SHUT_RDWR); Darwin.close(listenFD); listenFD = -1 }
        advertiser?.stop(); advertiser = nil
        isRunning = false
    }

    // MARK: - POSIX listener (primary)

    private func startPOSIX(serviceName: String, port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        // Bind to the LAN interface address when known (limits exposure to the local
        // network instead of every interface); fall back to INADDR_ANY otherwise.
        var boundIP: String?
        if let ip = LocalNetwork.ipv4Address(), inet_pton(AF_INET, ip, &addr.sin_addr) == 1 {
            DebugLog.log("listener: binding to LAN address \(ip)")
            boundIP = ip
        } else {
            addr.sin_addr.s_addr = INADDR_ANY
        }
        let bindOK = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOK == 0, Darwin.listen(fd, 16) == 0 else {
            DebugLog.log("listener: POSIX bind/listen errno=\(errno)", .warn)
            Darwin.close(fd); return false
        }
        // Read back the actual port (covers port 0 = any).
        var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let actualPort: UInt16 = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        } == 0 ? bound.sin_port.bigEndian : port

        listenFD = fd
        isRunning = true
        lastError = nil
        DebugLog.log("listener: POSIX ready on port \(actualPort) as '\(serviceName)'")

        // Accept loop on a background queue. Capture the fd by value — never touch
        // main-actor state (e.g. listenFD) from this thread, or Swift's exclusivity
        // enforcement traps and the app crashes. The loop ends when stop() closes the
        // socket and accept() returns an error.
        let limiter = inbound
        acceptQueue.async { [weak self] in
            while true {
                let clientFD = accept(fd, nil, nil)
                if clientFD < 0 { break }
                // Drop new connections past the concurrency cap (anti-DoS).
                guard limiter.tryAcquire() else {
                    Darwin.close(clientFD)
                    DebugLog.log("listener: inbound connection dropped (at capacity)", .warn)
                    continue
                }
                let stream = POSIXByteStream(fd: clientFD)
                stream.setOnClose { limiter.release() }   // free the slot when the link ends
                Task { @MainActor in
                    guard let self else { stream.close(); return }
                    DebugLog.log("listener: incoming POSIX connection")
                    self.onIncoming?(PeerLink(stream: stream))
                }
            }
        }

        // Advertise over Bonjour (NetService just publishes the record; it doesn't own the socket).
        let service = NetService(domain: "", type: "\(serviceType).", name: serviceName, port: Int32(actualPort))
        // A Mac on Ethernet and Wi-Fi at once is advertised at both addresses, but listens on
        // one. Say which, so the other Mac dials it first.
        if let boundIP { service.setTXTRecord(NetService.data(fromTXTRecord: [BonjourResolver.listenAddressKey: Data(boundIP.utf8)])) }
        service.publish()
        advertiser = service
        return true
    }
}
