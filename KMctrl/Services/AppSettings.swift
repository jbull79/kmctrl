import Foundation

/// User-configurable settings, persisted in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    @Published var deviceName: String { didSet { defaults.set(deviceName, forKey: Keys.deviceName) } }
    @Published var port: UInt16 { didSet { defaults.set(Int(port), forKey: Keys.port) } }
    /// Accept inbound keyboard/mouse control (master switch). Off by default.
    @Published var controlEnabled: Bool { didSet { defaults.set(controlEnabled, forKey: Keys.control) } }
    /// Which screen edge hands off control to the other Mac (edge mode).
    @Published var controlEdge: ScreenEdge { didSet { defaults.set(controlEdge.rawValue, forKey: Keys.controlEdge) } }
    /// Drive the other Mac by bumping a screen edge (needs Accessibility + Input Monitoring).
    /// Off = window mode (click to capture, no permissions).
    @Published var useEdgeMode: Bool { didSet { defaults.set(useEdgeMode, forKey: Keys.edgeMode) } }
    /// Run without a Dock icon. Combined with `menuBarVisible` → Dock / Menu bar / Both.
    @Published var hideDockIcon: Bool { didSet { defaults.set(hideDockIcon, forKey: Keys.hideDock) } }
    @Published var menuBarVisible: Bool { didSet { defaults.set(menuBarVisible, forKey: Keys.menuBar) } }
    /// Which transport methods the connector may use, by raw value.
    @Published var enabledTransports: Set<String> {
        didSet { defaults.set(Array(enabledTransports), forKey: Keys.transports) }
    }

    private let defaults = UserDefaults.standard

    enum Keys {
        static let deviceName = "kmctrl.deviceName"
        static let port = "kmctrl.port"
        static let transports = "kmctrl.enabledTransports"
        static let control = "kmctrl.controlEnabled"
        static let controlEdge = "kmctrl.controlEdge"
        static let edgeMode = "kmctrl.useEdgeMode"
        static let hideDock = "kmctrl.hideDockIcon"
        static let menuBar = "kmctrl.menuBarVisible"
    }

    init() {
        deviceName = defaults.string(forKey: Keys.deviceName) ?? Host.current().localizedName ?? "My Mac"
        let storedPort = defaults.integer(forKey: Keys.port)
        port = storedPort == 0 ? 51234 : UInt16(storedPort)
        controlEnabled = defaults.bool(forKey: Keys.control)
        controlEdge = ScreenEdge(rawValue: defaults.string(forKey: Keys.controlEdge) ?? "") ?? .right
        useEdgeMode = defaults.bool(forKey: Keys.edgeMode)
        hideDockIcon = defaults.bool(forKey: Keys.hideDock)
        menuBarVisible = defaults.object(forKey: Keys.menuBar) as? Bool ?? true
        if let stored = defaults.array(forKey: Keys.transports) as? [String], !stored.isEmpty {
            enabledTransports = Set(stored)
        } else {
            enabledTransports = Set(TransportStrategy.allCases.map(\.rawValue))
        }
    }

    /// Enabled strategies as a typed set; never empty (falls back to all).
    var enabledTransportStrategies: Set<TransportStrategy> {
        let set = Set(enabledTransports.compactMap(TransportStrategy.init(rawValue:)))
        return set.isEmpty ? Set(TransportStrategy.allCases) : set
    }

    func isTransportEnabled(_ s: TransportStrategy) -> Bool { enabledTransports.contains(s.rawValue) }

    func setTransport(_ s: TransportStrategy, enabled: Bool) {
        if enabled { enabledTransports.insert(s.rawValue) }
        else if enabledTransports.count > 1 { enabledTransports.remove(s.rawValue) }
    }
}
