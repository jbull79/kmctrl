import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var manager: ControlManager
    @EnvironmentObject private var updates: UpdateChecker

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
    // Live cross-window mirror of the accept-control switch (see ContentView).
    @AppStorage(AppSettings.Keys.control) private var acceptControl = false
    @AppStorage(AppSettings.Keys.keepAwake) private var keepAwake = false

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
            manager.readiness.refresh()
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
                HStack {
                    Text("KMctrl \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                    Spacer()
                    if let a = updates.available {
                        Button("Download \(a.version)") { NSWorkspace.shared.open(a.url) }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    } else if updates.checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(updates.lastError != nil ? "Unavailable"
                             : updates.lastChecked == nil ? "Not checked yet" : "Up to date")
                            .foregroundStyle(.secondary)
                    }
                    Button("Check now") { Task { await updates.checkNow() } }.disabled(updates.checking)
                }
                Toggle("Check for updates on GitHub daily", isOn: $settings.updateCheckEnabled)
                if let e = updates.lastError { Text(e).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("Updates")
            } footer: {
                Text("Checks github.com/jbull79/kmctrl/releases. Downloads open in your browser; the app does not update itself.")
            }
            Section {
                Toggle("Keep this Mac active (prevent Away)", isOn: $keepAwake)
                    .onChange(of: keepAwake) { on in
                        settings.keepAwakeEnabled = on
                        model.keepAwake.setEnabled(on)
                        manager.readiness.refresh()
                        if on && !manager.readiness.accessibility {
                            manager.readiness.requestAccessibility()   // prompt + open the pane
                        }
                    }
                if keepAwake {
                    if manager.readiness.accessibility {
                        Label("Active — keeping this Mac awake.", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    } else {
                        HStack(spacing: Theme.s2) {
                            Label("Needs Accessibility — not working until granted (may be blocked by MDM).",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                            Spacer()
                            Button("Grant…") { manager.readiness.requestAccessibility() }
                                .controlSize(.small)
                        }
                    }
                }
            } header: {
                Text("Presence")
            } footer: {
                Text("Posts a harmless F15 keystroke every few minutes so this Mac stays marked active in Teams/Slack. Local only; nothing is sent to another Mac. Needs Accessibility — a managed (MDM) Mac may block it.")
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
                Toggle("Accept control from trusted Macs", isOn: $acceptControl)
                    .onChange(of: acceptControl) { on in
                        settings.controlEnabled = on
                        if !on { manager.disconnectControlled() }
                    }
                Toggle("Show the floating \"Controlled by\" badge", isOn: $settings.showControlledBadge)
            } header: {
                Text("This Mac")
            } footer: {
                Text("When on, another trusted Mac can control this one (you confirm the first time). The badge sits bottom-right, can be dragged anywhere, and the menu bar always shows who is controlling with a Disconnect button.")
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

            Section {
                Toggle("Sync clipboard with the other Mac during a session", isOn: $settings.clipboardSyncEnabled)
            } header: {
                Text("Clipboard")
            } footer: {
                Text("Text and images copied on either Mac appear on the other while you are controlling or being controlled. Trusted Macs only; both Macs must have this on.")
            }

            Section {
                Toggle("Press \(HotkeyMonitor.label) to start controlling again", isOn: $settings.regrabHotkeyEnabled)
            } header: {
                Text("Re-grab hotkey")
            } footer: {
                Text("Works while a session is connected, from any app. ⌃⌥⌘ alone still releases. No permissions needed.")
            }

            Section {
                HStack {
                    Slider(value: $settings.mouseSensitivity, in: AppSettings.mouseSensitivityRange, step: 0.25)
                    Text(String(format: "%.2g×", settings.mouseSensitivity))
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                    Button("Reset") { settings.mouseSensitivity = 1.0 }
                        .disabled(settings.mouseSensitivity == 1.0)
                }
            } header: {
                Text("Mouse speed")
            } footer: {
                Text("Scales how far the remote pointer moves for each movement of your mouse. Takes effect immediately.")
            }

            Section {
                Toggle("Binary control protocol", isOn: $settings.binaryControl)
                Picker("Mouse flush interval", selection: $settings.flushIntervalMs) {
                    ForEach(AppSettings.flushIntervalChoices, id: \.self) { ms in
                        Text("\(ms) ms").tag(ms)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Experimental — input latency")
            } footer: {
                Text("Binary protocol encodes forwarded input as compact binary instead of JSON (removes per-event encode/decode cost). It's self-describing on the wire, so you only need it on the Mac doing the controlling. Flush interval sets how often coalesced mouse moves are sent — lower is smoother but more packets. Both take effect on the next connection: reconnect after changing them to A/B the feel.")
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
