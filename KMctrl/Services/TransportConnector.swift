import Foundation
import Network

/// Establishes an outbound `PeerLink`: finds the other Mac's address, opens a raw POSIX socket
/// to it (kernel routing, so it works with a VPN up, like `nc`) and runs the handshake. Control
/// frames are written synchronously to that socket, so it is the only transport.
@MainActor
final class TransportConnector {
    static let shared = TransportConnector()

    private let connectTimeout: TimeInterval = 6
    /// Opens the raw socket. Tests replace it to see which thread it runs on.
    var openSocket: @Sendable (String, UInt16, TimeInterval) throws -> POSIXByteStream = POSIXByteStream.connect

    /// Connect + handshake to `peer`, returning a ready, authenticated link. `lookupLimit` is
    /// how long to wait for the peer's address.
    func connect(to peer: Peer, localName: String, lookupLimit: TimeInterval = 4) async throws -> PeerLink {
        let lookupStart = Date()
        let resolved = await resolveHostPort(peer.endpoint, limit: lookupLimit)
        let lookupMs = Int(Date().timeIntervalSince(lookupStart) * 1000)
        guard let resolved else {
            DebugLog.log("connect: no address for \(peer.name) after \(lookupMs) ms", .warn)
            throw LinkError.addressNotFound(peer.name)
        }
        DebugLog.log("connect: found \(peer.name) at \(resolved.host):\(resolved.port) in \(lookupMs) ms")
        // Off the main thread: a Mac that doesn't answer holds this for the whole timeout,
        // and reconnecting repeats it, with Disconnect the only way out.
        let timeout = connectTimeout
        let open = openSocket
        let stream = try await Task.detached(priority: .userInitiated) { try open(resolved.host, resolved.port, timeout) }.value
        let link = PeerLink(stream: stream)
        do {
            try await link.start()
            try await link.handshake(localName: localName)   // validates the path end-to-end
            return link
        } catch {
            DebugLog.log("connect: \(resolved.host):\(resolved.port) failed — \(error.localizedDescription)", .warn)
            link.cancel()
            throw error
        }
    }

    /// Resolve a peer's endpoint to a display "host:port" string (Bonjour → IP).
    func resolveAddress(of peer: Peer) async -> String? {
        guard let r = await resolveHostPort(peer.endpoint) else { return nil }
        return "\(r.host):\(r.port)"
    }

    // MARK: - Bonjour / endpoint resolution

    /// Resolve an endpoint to a concrete host:port so the POSIX transport can dial it.
    /// Manual endpoints already carry host:port; Bonjour `.service` endpoints are resolved
    /// with a short-lived NWConnection (Network.framework's discovery works fine even when
    /// its data path doesn't), reading the peer's address from the established path.
    private func resolveHostPort(_ endpoint: NWEndpoint, limit: TimeInterval = 4) async -> (host: String, port: UInt16)? {
        if case let .hostPort(host, port) = endpoint {
            return (hostString(host), port.rawValue)
        }
        // Bonjour service — resolve via a throwaway connection.
        return await withCheckedContinuation { (cont: CheckedContinuation<(host: String, port: UInt16)?, Never>) in
            let conn = NWConnection(to: endpoint, using: .tcp)
            let done = ResolveOnce()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var result: (host: String, port: UInt16)?
                    if case let .hostPort(host, port)? = conn.currentPath?.remoteEndpoint {
                        result = (self.hostString(host), port.rawValue)
                    }
                    if done.fire() { conn.cancel(); cont.resume(returning: result) }
                case .failed, .cancelled:
                    if done.fire() { conn.cancel(); cont.resume(returning: nil) }
                case .waiting(let error):
                    DebugLog.log("connect: address lookup waiting — \(error)", .warn)
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            // Safety timeout so resolution can't hang the connect.
            DispatchQueue.global().asyncAfter(deadline: .now() + limit) {
                if done.fire() { conn.cancel(); cont.resume(returning: nil) }
            }
        }
    }

    private nonisolated func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let a): return "\(a)".components(separatedBy: "%").first ?? "\(a)"
        case .ipv6(let a): return "\(a)".components(separatedBy: "%").first ?? "\(a)"
        case .name(let n, _): return n
        @unknown default: return "\(host)"
        }
    }
}

/// One-shot latch so a resolve continuation resumes exactly once.
private final class ResolveOnce: @unchecked Sendable {
    private let lock = NSLock(); private var fired = false
    func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if fired { return false }; fired = true; return true }
}
