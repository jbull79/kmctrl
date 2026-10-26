import Foundation
import Network

enum LocalNetwork {
    /// IPv4 candidates on real (non-virtual) interfaces, in preference order.
    private static func ipv4Candidates() -> [(name: String, ip: String)] {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0 else { return [] }
        defer { freeifaddrs(ifaddrPtr) }

        var candidates: [(name: String, ip: String)] = []
        var cursor = ifaddrPtr
        while let ptr = cursor {
            defer { cursor = ptr.pointee.ifa_next }
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let sa = ptr.pointee.ifa_addr,
                  (flags & IFF_UP) == IFF_UP,
                  (flags & IFF_LOOPBACK) == 0,
                  sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if !isTunnelOrVirtual(name: name, ip: ip) { candidates.append((name, ip)) }
        }
        return ranked(candidates, systemOrder: SystemInterfaceOrder.shared.current)
    }

    /// Interfaces that are never the LAN: Apple's peer-to-peer links and VPN tunnels (utun
    /// covers NordVPN, WireGuard and Tailscale; ipsec/ppp cover IKEv2/L2TP), plus any address
    /// in 100.64.0.0/10 — the range Tailscale hands out — whatever the interface is called.
    static func isTunnelOrVirtual(name: String, ip: String) -> Bool {
        if ["awdl", "llw", "utun", "ipsec", "ppp"].contains(where: { name.hasPrefix($0) }) { return true }
        let octets = ip.split(separator: ".").compactMap { Int($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }

    /// Order candidates the way macOS ranks its interfaces (`scutil --nwi`: service order,
    /// so a plugged-in Ethernet beats Wi-Fi). Interfaces the system hasn't ranked yet fall
    /// back to en0 first, then other en*, then the rest.
    static func ranked(_ candidates: [(name: String, ip: String)],
                       systemOrder: [String]) -> [(name: String, ip: String)] {
        func position(_ n: String) -> Int { systemOrder.firstIndex(of: n) ?? Int.max }
        func fallback(_ n: String) -> Int { n == "en0" ? 0 : (n.hasPrefix("en") ? 1 : 2) }
        return candidates.sorted {
            (position($0.name), fallback($0.name), $0.name) < (position($1.name), fallback($1.name), $1.name)
        }
    }

    /// Start following the system's interface ranking now, so the first address lookup at
    /// launch already prefers the interface macOS prefers.
    static func startTrackingInterfaceOrder() { _ = SystemInterfaceOrder.shared }

    /// Best-guess local IPv4 address, e.g. "192.168.1.42": the highest-ranked physical
    /// interface in macOS's own order, skipping loopback, peer-to-peer links and VPN /
    /// Tailscale tunnels. Returns nil if offline.
    static func ipv4Address() -> String? { ipv4Candidates().first?.ip }

    /// Name of the physical LAN interface we route over (e.g. "en0"), or nil if offline.
    static func lanInterfaceName() -> String? { ipv4Candidates().first?.name }

    /// The live `NWInterface` for our LAN interface, so a connection or listener can be
    /// *pinned* to it (`requiredInterface`). This makes Network.framework route over the
    /// physical LAN like `nc` does, instead of being free to drift onto a VPN tunnel —
    /// the cause of the "stuck on connecting" / NWError 57 failures when a VPN is up.
    static func lanInterface() async -> NWInterface? {
        guard let wanted = lanInterfaceName() else { return nil }
        let monitor = NWPathMonitor()
        let path: NWPath = await withCheckedContinuation { cont in
            let resumed = Atomic(false)
            monitor.pathUpdateHandler = { p in
                if resumed.compareExchange(false, true) { cont.resume(returning: p) }
            }
            monitor.start(queue: .global(qos: .userInitiated))
        }
        monitor.cancel()
        return path.availableInterfaces.first { $0.name == wanted }
            ?? path.availableInterfaces.first { $0.type == .wifi || $0.type == .wiredEthernet }
    }
}

/// Tiny one-shot guard so the path continuation resumes exactly once.
private final class Atomic<T: Equatable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func compareExchange(_ expected: T, _ new: T) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard value == expected else { return false }
        value = new
        return true
    }
}

/// The system's interface ranking (what `scutil --nwi` shows), kept current by a path
/// monitor so the synchronous address lookup can follow it. Empty until the first update.
private final class SystemInterfaceOrder: @unchecked Sendable {
    static let shared = SystemInterfaceOrder()
    private let lock = NSLock()
    private var names: [String] = []
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let ordered = path.availableInterfaces.map(\.name)
            guard let self else { return }
            self.lock.lock(); self.names = ordered; self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "kmctrl.interface-order", qos: .utility))
    }

    var current: [String] { lock.lock(); defer { lock.unlock() }; return names }
}

