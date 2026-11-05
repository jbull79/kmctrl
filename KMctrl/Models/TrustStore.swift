import Foundation

/// Which Mac this one expects behind each name it controls: the fingerprint seen the first
/// time (trust on first use). A different fingerprint under the same name is refused — that
/// is another machine answering as your Mac, and it would receive everything you type.
struct HostPins: Equatable {
    enum Check: Equatable { case firstUse, match, mismatch(expected: String) }

    private(set) var pins: [String: String] = [:]   // peer name -> fingerprint

    init(_ pins: [String: String] = [:]) { self.pins = pins }

    func check(name: String, fingerprint: String) -> Check {
        guard let expected = pins[name] else { return .firstUse }
        return expected == fingerprint ? .match : .mismatch(expected: expected)
    }

    mutating func pin(name: String, fingerprint: String) { pins[name] = fingerprint }
    mutating func forget(name: String) { pins.removeValue(forKey: name) }
}

/// Trust-on-first-use records, both directions:
/// - `known`: Macs allowed to control this one (fingerprint -> last name), added by Allow.
/// - `hosts`: Macs this one controls (name -> fingerprint), pinned on first connection.
/// Saved in this app's own preferences and read only from there, so a launch argument or a
/// global default can't add a trusted Mac.
@MainActor
final class TrustStore: ObservableObject {
    @Published private(set) var known: [String: String] = [:]   // fingerprint -> last name
    @Published private(set) var hosts = HostPins()
    private let key = "netcatch.trustedDevices"
    private let hostsKey = "kmctrl.pinnedHosts"

    init() {
        if let data = AppSettings.savedValue(key) as? Data,
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            known = decoded
        }
        if let data = AppSettings.savedValue(hostsKey) as? Data,
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            hosts = HostPins(decoded)
        }
    }

    func isTrusted(_ fingerprint: String) -> Bool { known[fingerprint] != nil }

    func trust(_ fingerprint: String, name: String) {
        known[fingerprint] = name
        persist()
    }

    func forget(_ fingerprint: String) {
        known.removeValue(forKey: fingerprint)
        persist()
    }

    /// Check the Mac we just connected to, pinning it if it is the first time.
    func checkHost(name: String, fingerprint: String) -> HostPins.Check {
        let result = hosts.check(name: name, fingerprint: fingerprint)
        if result == .firstUse {
            hosts.pin(name: name, fingerprint: fingerprint)
            persist()
        }
        return result
    }

    func forgetHost(_ name: String) {
        hosts.forget(name: name)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(known) { UserDefaults.standard.set(data, forKey: key) }
        if let data = try? JSONEncoder().encode(hosts.pins) { UserDefaults.standard.set(data, forKey: hostsKey) }
    }
}
