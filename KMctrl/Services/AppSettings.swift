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
    /// Which display's edge hands off (CGDirectDisplayID). 0 = whole desktop / any outer edge.
    @Published var handoffDisplayID: UInt32 { didSet { defaults.set(Int(handoffDisplayID), forKey: Keys.handoffDisplay) } }
    /// Run without a Dock icon. Combined with `menuBarVisible` → Dock / Menu bar / Both.
    @Published var hideDockIcon: Bool { didSet { defaults.set(hideDockIcon, forKey: Keys.hideDock) } }
    @Published var menuBarVisible: Bool { didSet { defaults.set(menuBarVisible, forKey: Keys.menuBar) } }
    /// Keep this Mac "active" (post a harmless F15 on an interval) so presence apps don't
    /// report Away. Local-only; needs Accessibility.
    @Published var keepAwakeEnabled: Bool { didSet { defaults.set(keepAwakeEnabled, forKey: Keys.keepAwake) } }
    /// EXPERIMENTAL: encode forwarded control events as fixed binary instead of JSON on the
    /// controlling Mac (kills per-event JSONEncoder/Decoder cost). Self-describing on the
    /// wire — the controlled Mac auto-detects, so only the controller's flag matters.
    @Published var binaryControl: Bool { didSet { defaults.set(binaryControl, forKey: Keys.binaryControl) } }
    /// EXPERIMENTAL: mouse-move coalescing flush cadence in ms (controlling Mac). Lower =
    /// smoother but more packets/CPU. One of `flushIntervalChoices`.
    @Published var flushIntervalMs: Int { didSet { defaults.set(flushIntervalMs, forKey: Keys.flushInterval) } }
    /// Mirror text/image clipboard changes with the session peer (trusted Macs, during a session).
    @Published var clipboardSyncEnabled: Bool { didSet { defaults.set(clipboardSyncEnabled, forKey: Keys.clipboardSync) } }
    /// Daily GitHub releases check (Settings → General).
    @Published var updateCheckEnabled: Bool { didSet { defaults.set(updateCheckEnabled, forKey: Keys.updateCheck) } }
    /// ⌃⌥⌘K re-enters capture on an open session (Carbon hotkey, no permissions).
    @Published var regrabHotkeyEnabled: Bool { didSet { defaults.set(regrabHotkeyEnabled, forKey: Keys.regrabHotkey) } }
    /// Multiplier applied to forwarded mouse deltas on the controlling Mac (1.0 = as-is).
    @Published var mouseSensitivity: Double { didSet { defaults.set(mouseSensitivity, forKey: Keys.mouseSensitivity) } }
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
        static let handoffDisplay = "kmctrl.handoffDisplayID"
        static let hideDock = "kmctrl.hideDockIcon"
        static let menuBar = "kmctrl.menuBarVisible"
        static let keepAwake = "kmctrl.keepAwakeEnabled"
        static let binaryControl = "kmctrl.binaryControl"
        static let flushInterval = "kmctrl.flushIntervalMs"
        static let mouseSensitivity = "kmctrl.mouseSensitivity"
        static let regrabHotkey = "kmctrl.regrabHotkeyEnabled"
        static let updateCheck = "kmctrl.updateCheckEnabled"
        static let clipboardSync = "kmctrl.clipboardSyncEnabled"
    }

    /// Allowed flush cadences (ms) for the experimental interval knob, with the default
    /// and the validation in one place so callers don't re-derive them.
    static let flushIntervalChoices = [4, 8, 16]
    static let defaultFlushInterval = 8
    static func clampedFlushInterval(_ value: Int) -> Int {
        flushIntervalChoices.contains(value) ? value : defaultFlushInterval
    }

    static let mouseSensitivityRange = 0.25...3.0
    /// 0 (unset) → 1.0; otherwise clamped into `mouseSensitivityRange`.
    static func clampedMouseSensitivity(_ v: Double) -> Double {
        v == 0 ? 1.0 : min(max(v, mouseSensitivityRange.lowerBound), mouseSensitivityRange.upperBound)
    }

    init() {
        deviceName = defaults.string(forKey: Keys.deviceName) ?? Host.current().localizedName ?? "My Mac"
        let storedPort = defaults.integer(forKey: Keys.port)
        port = storedPort == 0 ? 51236 : UInt16(storedPort)   // distinct from NetCatch (51234) so both can coexist
        controlEnabled = defaults.bool(forKey: Keys.control)
        controlEdge = ScreenEdge(rawValue: defaults.string(forKey: Keys.controlEdge) ?? "") ?? .right
        useEdgeMode = defaults.bool(forKey: Keys.edgeMode)
        handoffDisplayID = UInt32(defaults.integer(forKey: Keys.handoffDisplay))
        hideDockIcon = defaults.bool(forKey: Keys.hideDock)
        menuBarVisible = defaults.object(forKey: Keys.menuBar) as? Bool ?? true
        keepAwakeEnabled = defaults.bool(forKey: Keys.keepAwake)
        binaryControl = defaults.bool(forKey: Keys.binaryControl)
        flushIntervalMs = AppSettings.clampedFlushInterval(defaults.integer(forKey: Keys.flushInterval))
        mouseSensitivity = AppSettings.clampedMouseSensitivity(defaults.double(forKey: Keys.mouseSensitivity))
        regrabHotkeyEnabled = defaults.object(forKey: Keys.regrabHotkey) as? Bool ?? true
        updateCheckEnabled = defaults.object(forKey: Keys.updateCheck) as? Bool ?? true
        clipboardSyncEnabled = defaults.object(forKey: Keys.clipboardSync) as? Bool ?? true
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
