import SwiftUI
import AppKit

/// Top-level app state.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let settings = AppSettings()
    let manager: ControlManager      // controlled side (listen + inject)
    let host = ControlHost()         // controlling side (capture + send)

    private init() {
        manager = ControlManager(settings: settings)
    }

    func start() {
        manager.startServices()
        applyActivationPolicy()
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
                .frame(minWidth: 620, minHeight: 480)
                .onAppear { model.start() }
        }
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
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .environmentObject(model.manager)
        }
    }
}
