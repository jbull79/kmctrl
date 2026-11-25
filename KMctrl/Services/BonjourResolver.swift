import Foundation

/// Where a Mac found over Bonjour is listening: its IPv4 addresses, best first, and the port.
struct PeerAddresses: Equatable {
    var hosts: [String]
    var port: UInt16
}

/// Looks up a Bonjour service's addresses from its mDNS records alone. The old lookup opened a
/// real TCP connection to the other Mac to read the address off it, and the other Mac logged
/// every one as a connection that failed.
///
/// NetService runs on the main run loop; `resolve` starts it there and every callback comes
/// back there, which is what makes the unchecked Sendable safe.
final class BonjourResolver: NSObject, NetServiceDelegate, @unchecked Sendable {
    /// TXT key: the one address the advertising Mac listens on.
    static let listenAddressKey = "ip"
    /// After the first IPv4 address, how long to wait for the rest: a Mac on Ethernet and
    /// Wi-Fi has one address on each, and only one of them is listening.
    static let settle: TimeInterval = 0.3

    private let service: NetService
    private var continuation: CheckedContinuation<PeerAddresses?, Never>?
    private var timer: DispatchWorkItem?
    private var settling = false

    private init(name: String, type: String, domain: String) {
        service = NetService(domain: domain.isEmpty ? "local." : domain,
                             type: type.hasSuffix(".") ? type : type + ".", name: name)
    }

    /// The service's IPv4 addresses, or nil if none turned up within `limit` seconds.
    @MainActor
    static func resolve(name: String, type: String, domain: String, limit: TimeInterval) async -> PeerAddresses? {
        let r = BonjourResolver(name: name, type: type, domain: domain)
        return await withCheckedContinuation { r.start(limit: limit, continuation: $0) }
    }

    @MainActor
    private func start(limit: TimeInterval, continuation c: CheckedContinuation<PeerAddresses?, Never>) {
        continuation = c
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: max(limit, 0.1))
        // NetService's own timeout can run late; this keeps the limit.
        let t = DispatchWorkItem { [self] in finish() }
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + max(limit, 0.1), execute: t)
    }

    /// Called as addresses turn up. IPv6 can come first; once an IPv4 one is in, give the rest
    /// a moment to arrive.
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard !settling, !Self.ipv4Hosts(sender.addresses ?? []).isEmpty else { return }
        settling = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle) { [self] in finish() }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        DebugLog.log("connect: address lookup for \(sender.name) failed — \(errorDict)", .warn)
        finish()
    }

    func netServiceDidStop(_ sender: NetService) { finish() }

    private func finish() {
        guard let c = continuation else { return }
        continuation = nil
        timer?.cancel(); timer = nil
        let listening = service.txtRecordData()
            .flatMap { NetService.dictionary(fromTXTRecord: $0)[Self.listenAddressKey] }
            .map { String(decoding: $0, as: UTF8.self) }
        let hosts = Self.listeningFirst(Self.ipv4Hosts(service.addresses ?? []), listening: listening)
        let port = service.port
        service.delegate = nil
        service.stop()
        service.remove(from: .main, forMode: .common)
        c.resume(returning: hosts.isEmpty || !(1...65535).contains(port) ? nil : PeerAddresses(hosts: hosts, port: UInt16(port)))
    }

    /// The address the other Mac says it listens on goes first, if it is one of its addresses.
    static func listeningFirst(_ hosts: [String], listening: String?) -> [String] {
        guard let listening, let i = hosts.firstIndex(of: listening) else { return hosts }
        var out = hosts
        out.insert(out.remove(at: i), at: 0)
        return out
    }

    /// IPv4 addresses from NetService's sockaddr list, in order and without repeats, with
    /// self-assigned (169.254/16) ones last. The listener takes IPv4 only, on one LAN address.
    static func ipv4Hosts(_ addresses: [Data]) -> [String] {
        var lan: [String] = [], selfAssigned: [String] = []
        for data in addresses where data.count >= MemoryLayout<sockaddr_in>.size {
            var sa = sockaddr_in()
            _ = withUnsafeMutableBytes(of: &sa) { data.prefix(MemoryLayout<sockaddr_in>.size).copyBytes(to: $0) }
            guard sa.sin_family == sa_family_t(AF_INET) else { continue }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &sa.sin_addr, &buf, socklen_t(buf.count)) != nil else { continue }
            let ip = String(cString: buf)
            if lan.contains(ip) || selfAssigned.contains(ip) { continue }
            if ip.hasPrefix("169.254.") { selfAssigned.append(ip) } else { lan.append(ip) }
        }
        return lan + selfAssigned
    }
}
