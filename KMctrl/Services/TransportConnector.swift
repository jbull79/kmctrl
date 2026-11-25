import Foundation
import Network

/// Establishes an outbound `PeerLink`: finds the other Mac's address, opens a raw POSIX socket
/// to it (kernel routing, so it works with a VPN up, like `nc`) and runs the handshake. Control
/// frames are written synchronously to that socket, so it is the only transport.
@MainActor
final class TransportConnector {
    static let shared = TransportConnector()

    private let connectTimeout: TimeInterval = 6
    /// For an address with others still to try: a LAN answers in milliseconds.
    private let otherAddressTimeout: TimeInterval = 2
    /// Opens the raw socket. Tests replace it to see which thread it runs on.
    var openSocket: @Sendable (String, UInt16, TimeInterval) throws -> POSIXByteStream = POSIXByteStream.connect
    /// Finds where the peer listens, waiting up to the given seconds. Tests replace it.
    var lookup: @MainActor (NWEndpoint, TimeInterval) async -> PeerAddresses? = TransportConnector.addresses

    /// Connect + handshake to `peer`, returning a ready, authenticated link. `lookupLimit` is
    /// how long to wait for the peer's address.
    func connect(to peer: Peer, localName: String, lookupLimit: TimeInterval = 4) async throws -> PeerLink {
        let lookupStart = Date()
        let found = await lookup(peer.endpoint, lookupLimit)
        let lookupMs = Int(Date().timeIntervalSince(lookupStart) * 1000)
        guard let found, !found.hosts.isEmpty else {
            DebugLog.log("connect: no address for \(peer.name) after \(lookupMs) ms", .warn)
            throw LinkError.addressNotFound(peer.name)
        }
        DebugLog.log("connect: found \(peer.name) at \(found.hosts.joined(separator: ", ")) port \(found.port) in \(lookupMs) ms")
        // Off the main thread: a Mac that doesn't answer holds this for the whole timeout,
        // and reconnecting repeats it, with Disconnect the only way out.
        let open = openSocket
        let timeouts = found.hosts.indices.map { $0 == found.hosts.count - 1 ? connectTimeout : otherAddressTimeout }
        let name = peer.name
        let (stream, host) = try await Task.detached(priority: .userInitiated) { () throws -> (POSIXByteStream, String) in
            for (host, timeout) in zip(found.hosts, timeouts) {
                if let stream = try? open(host, found.port, timeout) { return (stream, host) }
            }
            throw LinkError.unreachable(name, found.hosts)
        }.value
        let link = PeerLink(stream: stream)
        do {
            try await link.start()
            try await link.handshake(localName: localName)   // validates the path end-to-end
            return link
        } catch {
            DebugLog.log("connect: \(host):\(found.port) failed — \(error.localizedDescription)", .warn)
            link.cancel()
            throw error
        }
    }

    /// Resolve a peer's endpoint to a display "host:port" string (Bonjour → IP).
    func resolveAddress(of peer: Peer) async -> String? {
        guard let r = await lookup(peer.endpoint, 4), let host = r.hosts.first else { return nil }
        return "\(host):\(r.port)"
    }

    // MARK: - Bonjour / endpoint resolution

    /// Manual endpoints already carry host:port. Bonjour services are looked up from their
    /// mDNS records, without connecting to the other Mac.
    private static func addresses(of endpoint: NWEndpoint, limit: TimeInterval) async -> PeerAddresses? {
        switch endpoint {
        case let .hostPort(host, port):
            return PeerAddresses(hosts: [hostString(host)], port: port.rawValue)
        case let .service(name, type, domain, _):
            return await BonjourResolver.resolve(name: name, type: type, domain: domain, limit: limit)
        default:
            return nil
        }
    }

    private static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let a): return "\(a)".components(separatedBy: "%").first ?? "\(a)"
        case .ipv6(let a): return "\(a)".components(separatedBy: "%").first ?? "\(a)"
        case .name(let n, _): return n
        @unknown default: return "\(host)"
        }
    }
}
