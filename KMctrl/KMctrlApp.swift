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
    private var bag = Set<AnyCancellable>()

    private init() {
        let manager = ControlManager(settings: settings)
        let host = host
        self.manager = manager
        hotkey = HotkeyMonitor { host.regrab() }
        let settings = settings
        updates.isEnabled = { settings.updateCheckEnabled }
        settings.$mouseSensitivity.sink { v in host.mouseSensitivity = v }.store(in: &bag)
        // Hotkey is live only while there is a session to re-enter.
        settings.$regrabHotkeyEnabled.combineLatest(host.$state)
            .map { on, state in on && state != .idle }
            .removeDuplicates()
            .sink { [hotkey] on in hotkey.setEnabled(on) }
            .store(in: &bag)
        // Clipboard sync follows the controlling session's lifetime.
        host.$state.removeDuplicates()
            .sink { state in
                switch state {
                case .connected where host.currentPeer != nil:
                    manager.clipboard.setActive(true) { host.currentPeer }
                case .idle:
                    manager.clipboard.setActive(false) { nil }
                default: break
                }
            }
            .store(in: &bag)
    }

    func start() {
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
    @Environment(\.openWindow) private var openWindow

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
                .onReceive(NotificationCenter.default.publisher(for: .kmctrlOpenMainWindow)) { _ in
                    openWindow(id: "main")
                }
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
