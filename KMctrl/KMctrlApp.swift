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
    }
}

@main
struct KMctrlApp: App {
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
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

        Settings {
            SettingsView()
                .environmentObject(model.settings)
                .environmentObject(model.manager)
        }
    }
}
