import SwiftUI
import AppKit
import Combine

/// Top-level app state.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let settings = AppSettings()
    let manager: ControlManager      // controlled side (listen + inject)
    let host = ControlHost()         // controlling side (capture + send)
    let keepAwake = KeepAwake()      // local presence keep-alive
    let hotkey: HotkeyMonitor        // ⌃⌥⌘K re-grab
    let updates = UpdateChecker()    // daily GitHub release check
    /// The main window, captured when ContentView first appears. SwiftUI keeps it alive
    /// when closed, so the re-grab hotkey can bring it back from menu-bar-only use.
    weak var mainWindow: NSWindow?
    private var bag = Set<AnyCancellable>()

    private init() {
        let manager = ControlManager(settings: settings)
        let host = host
        self.manager = manager
        hotkey = HotkeyMonitor { host.regrab() }
        host.mainWindowProvider = { [weak self] in self?.mainWindow }
        let settings = settings
        updates.isEnabled = { settings.updateCheckEnabled }
        settings.$mouseSensitivity.sink { v in host.mouseSensitivity = v }.store(in: &bag)
        // Arrangement edits in Settings apply to an open session straight away. A drag commits
        // edge, monitor and position together, so let the burst settle first.
        settings.$controlEdge.combineLatest(settings.$handoffDisplayID, settings.$handoffOffsetMM)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { edge, display, offset in host.arrangementChanged(edge: edge, displayID: display, offsetMM: offset) }
            .store(in: &bag)
        // Hotkey is live only while there is a session to re-enter.
        settings.$regrabHotkeyEnabled.combineLatest(host.$state)
            .map { on, state in on && state != .idle }
            .removeDuplicates()
            .sink { [hotkey] on in hotkey.setEnabled(on) }
            .store(in: &bag)
        // Clipboard sync follows the controlling session's lifetime.
        // Clipboard travels over whichever control link this Mac is on: as the controlled
        // Mac, a ControlReturn back to the controller; as the controller, a .clipboard event.
        manager.clipboard.transport = { payload, _ in
            if let link = manager.controlledLink {
                // Off the main thread: a large image on a stalled link must not freeze the app.
                let sent = await Task.detached { link.sendSecureObjectSync(ControlReturn(clipboard: payload)) }.value
                guard sent else { throw LinkError.closed }
            } else {
                try host.sendClipboard(payload)
            }
        }
        host.onClipboardReceived = { payload, fp in manager.clipboard.receive(payload, from: fp) }
        host.hostCheck = { name, fp in manager.trust.checkHost(name: name, fingerprint: fp) }
        var previous: ControlHost.State = .idle
        host.$state.removeDuplicates()
            .sink { state in
                defer { previous = state }
                switch ClipboardSessionPolicy.action(from: previous, to: state) {
                case .activate:
                    if let fp = host.peerFingerprint {
                        manager.clipboard.setActive(true, sessionFingerprint: fp)
                    }
                case .push:
                    manager.clipboard.pushNow(reason: "control started")   // clipboard follows the keyboard
                case .deactivate:
                    manager.clipboard.setActive(false, sessionFingerprint: "")
                case .none: break
                }
            }
            .store(in: &bag)
    }

    private var started = false

    /// Once per launch. It runs from the main window's onAppear, which fires again for every
    /// window opened later — each extra run leaked an update timer and rebound the listener.
    func start() {
        guard !started else { return }
        started = true
        _ = HealthMonitor.appStarted
        signal(SIGPIPE, SIG_IGN)   // belt and braces for SO_NOSIGPIPE: never die on a closed peer
        // Load the identity key now, off the main thread. A Keychain read blocks its caller
        // until any password prompt is answered; doing it lazily on the main thread during a
        // session froze the app with the pointer hidden (0.8.0–0.8.6). After this it is cached.
        Task.detached(priority: .userInitiated) { _ = CryptoService.identitySigningKey() }
        LocalNetwork.startTrackingInterfaceOrder()   // follow macOS's interface ranking from launch
        manager.startServices()
        applyActivationPolicy()
        if settings.keepAwakeEnabled { keepAwake.start() }
        updates.start()
    }

    /// Dock icon visibility. The menu-bar item is controlled separately (settings.menuBarVisible).
    func applyActivationPolicy() {
        NSApp.setActivationPolicy(settings.hideDockIcon ? .accessory : .regular)
    }

    func setHideDockIcon(_ hide: Bool) {
        settings.hideDockIcon = hide
        applyActivationPolicy()
        if !hide { NSApp.activate(ignoringOtherApps: true) }
    }
}

@main
struct KMctrlApp: App {
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .environmentObject(model.manager)
                .environmentObject(model.manager.discovery)
                .environmentObject(model.host)
                .environmentObject(model.updates)
                .frame(width: 440)
                .onAppear { model.start() }
                .background(WindowAccessor { model.mainWindow = $0 })
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified)

        MenuBarExtra("KMctrl", systemImage: "keyboard", isInserted: Binding(
            get: { model.settings.menuBarVisible },
            set: { model.settings.menuBarVisible = $0 })
        ) {
            MenuBarView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .environmentObject(model.manager)
                .environmentObject(model.manager.discovery)
                .environmentObject(model.host)
                .environmentObject(model.updates)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .environmentObject(model.manager)
                .environmentObject(model.updates)
        }
    }
}
