import SwiftUI
import AppKit

/// Menu-bar popover for quick control. KMctrl can run from the menu bar, the Dock, or both.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var manager: ControlManager
    @EnvironmentObject private var discovery: DiscoveryService
    @Environment(\.openWindow) private var openWindow
    // Live cross-window mirror of the accept-control switch (see ContentView).
    @AppStorage(AppSettings.Keys.control) private var acceptControl = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack(spacing: Theme.s2) {
                Image(systemName: "keyboard").foregroundStyle(.tint)
                Text(settings.deviceName).fontWeight(.semibold).lineLimit(1)
                Spacer()
            }
            if let by = manager.controlActiveFrom {
                HStack {
                    Label("Controlled by \(by)", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Disconnect") { manager.disconnectControlled() }
                        .controlSize(.small)
                }
            } else {
                Text("\(discovery.peers.count) nearby device\(discovery.peers.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            Toggle("Accept control", isOn: $acceptControl)
                .toggleStyle(.switch).controlSize(.mini)
                .onChange(of: acceptControl) { on in
                    settings.controlEnabled = on
                    if !on { manager.disconnectControlled() }
                }
            Toggle("Show Dock icon", isOn: Binding(
                get: { !settings.hideDockIcon }, set: { model.setHideDockIcon(!$0) }))
                .toggleStyle(.switch).controlSize(.mini)

            Divider()

            Button("Open KMctrl") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            if #available(macOS 14, *) {
                SettingsLink { Text("Settings…") }
            } else {
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }
            }
            Button("Quit KMctrl") { NSApplication.shared.terminate(nil) }
        }
        .padding(Theme.s3)
        .frame(width: 240)
    }
}
