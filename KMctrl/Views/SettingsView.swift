import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var manager: ControlManager

    @State private var portText = ""
    @State private var localIP: String?

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gear") }
            control.tabItem { Label("Control", systemImage: "keyboard") }
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
                Picker("Hand-off edge", selection: $settings.controlEdge) {
                    ForEach(ScreenEdge.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("This Mac")
            } footer: {
                Text("Hand-off edge is the screen edge that passes control in edge mode.")
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
