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
    /// That monitor itself (UUID, vendor, model, serial). macOS can give a monitor a new display
    /// number after sleep or a reconnect; this keeps the arrangement on the right one. Only a
    /// drag in the arrangement changes it.
    @Published var handoffDisplayIdentity: DisplayIdentity? {
        didSet { defaults.set(handoffDisplayIdentity.flatMap { try? JSONEncoder().encode($0) }, forKey: Keys.handoffDisplayIdentity) }
    }
    /// Run without a Dock icon. Combined with `menuBarVisible` → Dock / Menu bar / Both.
    @Published var hideDockIcon: Bool { didSet { defaults.set(hideDockIcon, forKey: Keys.hideDock) } }
    @Published var menuBarVisible: Bool { didSet { defaults.set(menuBarVisible, forKey: Keys.menuBar) } }
    /// Keep this Mac "active" (post a harmless F15 on an interval) so presence apps don't
    /// report Away. Local-only; needs Accessibility.
    @Published var keepAwakeEnabled: Bool { didSet { defaults.set(keepAwakeEnabled, forKey: Keys.keepAwake) } }
    /// Controlling Mac: switch to the other Mac when the pointer rests on an edge next to it —
    /// by watching the pointer, so no Accessibility / Input Monitoring.
    @Published var pointerEdgeSwitch: Bool { didSet { defaults.set(pointerEdgeSwitch, forKey: Keys.pointerEdgeSwitch) } }
    /// Controlling Mac: ask the other Mac to hand control back when its pointer is pushed past
    /// the opposite edge (window mode as well as edge mode).
    @Published var returnAtEdge: Bool { didSet { defaults.set(returnAtEdge, forKey: Keys.returnAtEdge) } }
    /// Where the other Mac's screen sits along the hand-off edge: mm from the edge's left/top
    /// end, set by sliding it in the arrangement. nil = centred.
    @Published var handoffOffsetMM: Double? {
        didSet {
            if let v = handoffOffsetMM { defaults.set(v, forKey: Keys.handoffOffset) }
            else { defaults.removeObject(forKey: Keys.handoffOffset) }
        }
    }
    /// The other Mac's screen as it last reported it — drawn to scale in the arrangement.
    @Published var remoteScreen: ScreenGeometry? {
        didSet { defaults.set(remoteScreen.flatMap { try? JSONEncoder().encode($0) }, forKey: Keys.remoteScreen) }
    }
    /// Controlled Mac: the last controller's monitor arrangement and where this Mac sits in it
    /// (protocol v5), shown read-only in Settings, and that controller's name.
    @Published var controllerArrangement: ArrangementSnapshot? {
        didSet { defaults.set(controllerArrangement.flatMap { try? JSONEncoder().encode($0) }, forKey: Keys.controllerArrangement) }
    }
    @Published var controllerArrangementFrom: String? {
        didSet { defaults.set(controllerArrangementFrom, forKey: Keys.controllerArrangementFrom) }
    }
    /// Show the floating "Controlled by …" badge while another Mac drives this one.
    @Published var showControlledBadge: Bool { didSet { defaults.set(showControlledBadge, forKey: Keys.showControlledBadge) } }
    /// Mirror text/image clipboard changes with the session peer (trusted Macs, during a session).
    @Published var clipboardSyncEnabled: Bool { didSet { defaults.set(clipboardSyncEnabled, forKey: Keys.clipboardSync) } }
    /// Daily GitHub releases check (Settings → General).
    @Published var updateCheckEnabled: Bool { didSet { defaults.set(updateCheckEnabled, forKey: Keys.updateCheck) } }
    /// ⌃⌥⌘K re-enters capture on an open session (Carbon hotkey, no permissions).
    @Published var regrabHotkeyEnabled: Bool { didSet { defaults.set(regrabHotkeyEnabled, forKey: Keys.regrabHotkey) } }
    /// Multiplier applied to forwarded mouse deltas on the controlling Mac (1.0 = as-is).
    @Published var mouseSensitivity: Double { didSet { defaults.set(mouseSensitivity, forKey: Keys.mouseSensitivity) } }

    private let defaults = UserDefaults.standard

    /// A value from this app's own saved settings only. `UserDefaults.standard` also reads
    /// launch arguments (`-kmctrl.controlEnabled YES`) and the global domain, which any
    /// program running as this user can set — so security switches must not come from there.
    static func savedValue(_ key: String) -> Any? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        return UserDefaults.standard.persistentDomain(forName: id)?[key]
    }

    enum Keys {
        static let deviceName = "kmctrl.deviceName"
        static let port = "kmctrl.port"
        static let control = "kmctrl.controlEnabled"
        static let controlEdge = "kmctrl.controlEdge"
        static let edgeMode = "kmctrl.useEdgeMode"
        static let handoffDisplay = "kmctrl.handoffDisplayID"
        static let handoffDisplayIdentity = "kmctrl.handoffDisplayIdentity"
        static let hideDock = "kmctrl.hideDockIcon"
        static let menuBar = "kmctrl.menuBarVisible"
        static let keepAwake = "kmctrl.keepAwakeEnabled"
        static let pointerEdgeSwitch = "kmctrl.edgeHandoffSpike"   // key kept from when it was experimental
        static let returnAtEdge = "kmctrl.returnAtEdge"
        static let handoffOffset = "kmctrl.handoffOffsetMM"
        static let remoteScreen = "kmctrl.remoteScreen"
        static let controllerArrangement = "kmctrl.controllerArrangement"
        static let controllerArrangementFrom = "kmctrl.controllerArrangementFrom"
        static let mouseSensitivity = "kmctrl.mouseSensitivity"
        static let regrabHotkey = "kmctrl.regrabHotkeyEnabled"
        static let updateCheck = "kmctrl.updateCheckEnabled"
        static let clipboardSync = "kmctrl.clipboardSyncEnabled"
        static let showControlledBadge = "kmctrl.showControlledBadge"
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
        controlEnabled = AppSettings.savedValue(Keys.control) as? Bool ?? false
        controlEdge = ScreenEdge(rawValue: defaults.string(forKey: Keys.controlEdge) ?? "") ?? .right
        useEdgeMode = defaults.bool(forKey: Keys.edgeMode)
        handoffDisplayID = UInt32(defaults.integer(forKey: Keys.handoffDisplay))
        handoffDisplayIdentity = defaults.data(forKey: Keys.handoffDisplayIdentity)
            .flatMap { try? JSONDecoder().decode(DisplayIdentity.self, from: $0) }
        hideDockIcon = defaults.bool(forKey: Keys.hideDock)
        menuBarVisible = defaults.object(forKey: Keys.menuBar) as? Bool ?? true
        keepAwakeEnabled = defaults.bool(forKey: Keys.keepAwake)
        pointerEdgeSwitch = defaults.bool(forKey: Keys.pointerEdgeSwitch)
        returnAtEdge = defaults.bool(forKey: Keys.returnAtEdge)
        handoffOffsetMM = defaults.object(forKey: Keys.handoffOffset) as? Double
        remoteScreen = defaults.data(forKey: Keys.remoteScreen)
            .flatMap { try? JSONDecoder().decode(ScreenGeometry.self, from: $0) }
            .flatMap { $0.isPlausible ? $0 : nil }   // a bad saved value used to crash Settings
        controllerArrangement = defaults.data(forKey: Keys.controllerArrangement)
            .flatMap { try? JSONDecoder().decode(ArrangementSnapshot.self, from: $0) }?.sanitized
        controllerArrangementFrom = defaults.string(forKey: Keys.controllerArrangementFrom).map(PeerName.sanitize)
        mouseSensitivity = AppSettings.clampedMouseSensitivity(defaults.double(forKey: Keys.mouseSensitivity))
        regrabHotkeyEnabled = defaults.object(forKey: Keys.regrabHotkey) as? Bool ?? true
        updateCheckEnabled = defaults.object(forKey: Keys.updateCheck) as? Bool ?? true
        clipboardSyncEnabled = defaults.object(forKey: Keys.clipboardSync) as? Bool ?? true
        showControlledBadge = AppSettings.savedValue(Keys.showControlledBadge) as? Bool ?? true
    }
}
