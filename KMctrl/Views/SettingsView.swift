import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var manager: ControlManager

    private enum Presence: String, CaseIterable, Identifiable {
        case both = "Dock + Menu bar", dock = "Dock only", menuBar = "Menu bar only"
        var id: String { rawValue }
    }
    private var presence: Presence {
        if settings.hideDockIcon { return .menuBar }
        return settings.menuBarVisible ? .both : .dock
    }
    private func setPresence(_ p: Presence) {
        switch p {
        case .both:    settings.menuBarVisible = true;  model.setHideDockIcon(false)
        case .dock:    settings.menuBarVisible = false; model.setHideDockIcon(false)
        case .menuBar: settings.menuBarVisible = true;  model.setHideDockIcon(true)
        }
    }

    @State private var portText = ""
    @State private var localIP: String?

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gear") }
            control.tabItem { Label("Control", systemImage: "keyboard") }
            LogsView().tabItem { Label("Diagnostics", systemImage: "doc.text.magnifyingglass") }
        }
        .frame(width: 460, height: 440)
        .onAppear {
            portText = String(settings.port)
            localIP = LocalNetwork.ipv4Address()
        }
    }

    private var general: some View {
        Form {
            Section("This device") {
                TextField("Name", text: $settings.deviceName)
                HStack {
                    TextField("Port", text: $portText).frame(width: 90)
                    Button("Apply") {
                        if let p = UInt16(portText) { settings.port = p }
                        manager.restartServices()
                    }
                }
                if let ip = localIP {
                    LabeledContent("Address") {
                        Text(verbatim: "\(ip):\(settings.port)")
                            .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            Section {
                Picker("Show KMctrl in", selection: Binding(
                    get: { presence }, set: { setPresence($0) })) {
                    ForEach(Presence.allCases) { Text($0.rawValue).tag($0) }
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("Run from the Dock, the menu bar, or both.")
            }
            Section {
                ForEach(TransportStrategy.allCases, id: \.self) { s in
                    Toggle(isOn: Binding(
                        get: { settings.isTransportEnabled(s) },
                        set: { settings.setTransport(s, enabled: $0) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.label)
                            Text(s.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Connection methods")
            }
        }
        .formStyle(.grouped)
    }

    private var control: some View {
        Form {
            Section {
                Toggle("Accept control from trusted Macs", isOn: $settings.controlEnabled)
            } header: {
                Text("This Mac")
            } footer: {
                Text("When on, another trusted Mac can control this one (you confirm the first time).")
            }

            Section {
                Toggle("Use edge mode to drive another Mac", isOn: $settings.useEdgeMode)
                ScreenArrangementView(edge: $settings.controlEdge, displayID: $settings.handoffDisplayID)
                Text("Bump the **\(settings.controlEdge.label.lowercased())** edge of the highlighted screen to take control; ⌃⌥⌘ releases.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Edge hand-off arrangement")
            } footer: {
                Text("Drag the remote Mac next to the monitor it physically sits beside. On a multi-monitor setup only that screen's edge hands off. Edge mode needs Accessibility + Input Monitoring (below); window mode (click-to-capture) needs neither.")
            }

            Section {
                HStack(spacing: 8) {
                    pip(manager.readiness.allReady)
                    Text(manager.readiness.allReady ? "Ready for edge mode" : "Window mode only (no permissions)")
                        .fontWeight(.medium)
                    Spacer()
                    Button("Re-check") { manager.readiness.refresh() }
                }
                readinessRow("Accessibility", ok: manager.readiness.accessibility,
                             hint: "Inject + consume input") { manager.readiness.requestAccessibility() }
                readinessRow("Input Monitoring", ok: manager.readiness.inputMonitoring,
                             hint: "Capture keyboard & mouse") { manager.readiness.requestInputMonitoring() }
                HStack(spacing: 10) {
                    pip(manager.readiness.eventTapCreatable)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Live event tap")
                        Text("Run manually — can crash a locked-down (MDM) Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Test") { manager.readiness.probeEventTap() }
                }
            } header: {
                Text("Edge-mode permissions")
            } footer: {
                Text("Window mode (click-to-capture) needs none of these and works on a locked-down MDM Mac. Edge mode needs Accessibility + Input Monitoring.")
            }
        }
        .formStyle(.grouped)
        .onAppear { manager.readiness.refresh() }
    }

    @ViewBuilder
    private func readinessRow(_ title: String, ok: Bool, hint: String, grant: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            pip(ok)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok { Button("Grant…", action: grant) }
        }
    }

    private func pip(_ ok: Bool) -> some View {
        StatusDot(color: ok ? .green : .red, size: 11)
    }
}
