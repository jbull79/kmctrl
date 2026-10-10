import SwiftUI

/// Single-screen KMctrl: control another Mac, and allow this Mac to be controlled.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var manager: ControlManager
    @EnvironmentObject private var discovery: DiscoveryService
    @EnvironmentObject private var host: ControlHost
    // Mirror the accept-control switch through UserDefaults so every window (main, Settings,
    // menu bar) refreshes live — @Published alone doesn't redraw a non-key background window.
    @AppStorage(AppSettings.Keys.control) private var acceptControl = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: Theme.s4) {
                controlSection
                beControlledSection
            }
            .padding(Theme.s4)
        }
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle("KMctrl")
        .alert("Allow keyboard & mouse control?", isPresented: Binding(
            get: { manager.pendingControlRequest != nil },
            set: { if !$0 { manager.resolveControlPending(false) } })
        ) {
            Button("Decline", role: .cancel) { manager.resolveControlPending(false) }
            Button("Allow") { manager.resolveControlPending(true) }
        } message: {
            if let r = manager.pendingControlRequest {
                Text("“\(r.peerName)” wants to control this Mac's keyboard and mouse.\nFingerprint: \(r.fingerprint)\n\nAllowing trusts this device for future control.")
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.s2) {
            Image(systemName: "keyboard").foregroundStyle(.tint)
            Text(settings.deviceName).fontWeight(.semibold)
            Spacer()
            if let by = manager.controlActiveFrom {
                Label("Controlled by \(by)", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, Theme.s4).padding(.vertical, Theme.s3)
    }

    // MARK: Control another Mac

    private var controlSection: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            SectionLabel("Control a device")

            if host.state != .idle {
                activeHostCard
            }

            if discovery.peers.isEmpty {
                HStack(spacing: Theme.s2) {
                    ProgressView().controlSize(.small)
                    Text("Looking for nearby Macs running KMctrl…").foregroundStyle(.secondary)
                }
                .padding(.vertical, Theme.s2)
            } else {
                ForEach(discovery.peers) { peer in peerRow(peer) }
            }
        }
    }

    private func peerRow(_ peer: Peer) -> some View {
        HStack(spacing: Theme.s3) {
            Image(systemName: "desktopcomputer").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(peer.name).fontWeight(.medium)
                if let a = peer.address {
                    Text(a).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Control") { startControl(peer) }
                .disabled(host.state != .idle)
        }
        .padding(Theme.s3)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private var activeHostCard: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack(spacing: Theme.s2) {
                StatusDot(color: host.state == .capturing ? .green : .orange)
                Text(hostStatusText).fontWeight(.medium)
                Spacer()
                Button("Disconnect") { host.disconnect() }
            }
            if let err = host.lastError { Text(err).font(.caption).foregroundStyle(.red) }
            if host.state == .connected {
                Button { host.beginCapture() } label: {
                    Label("Start controlling", systemImage: "cursorarrow.rays").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Text("Your keyboard & mouse drive \(host.peerName ?? "the other Mac"). Press ⌃⌥⌘ to release\(settings.regrabHotkeyEnabled ? " · \(HotkeyMonitor.label) re-grabs" : "").")
                    .font(.caption).foregroundStyle(.secondary)
            } else if host.state == .capturing {
                Text("Controlling \(host.peerName ?? "") — press ⌃⌥⌘ to release.")
                    .font(.caption).foregroundStyle(.green)
            }
        }
        .padding(Theme.s3)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
    }

    private var hostStatusText: String {
        switch host.state {
        case .idle: return ""
        case .connecting: return "Connecting to \(host.peerName ?? "")…"
        case .connected: return "Connected to \(host.peerName ?? "")"
        case .capturing: return "Controlling \(host.peerName ?? "")"
        }
    }

    private func startControl(_ peer: Peer) {
        host.edgeModeEnabled = settings.useEdgeMode   // window mode unless edge mode is on
        host.controlEdge = settings.controlEdge
        host.controlDisplayID = settings.handoffDisplayID
        host.useBinaryControl = settings.binaryControl        // experimental codec flag
        host.flushIntervalMs = settings.flushIntervalMs       // experimental cadence knob
        host.connect(to: peer, localName: settings.deviceName)
    }

    // MARK: Be controlled

    private var beControlledSection: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            SectionLabel("Allow this Mac to be controlled")
            if let by = manager.controlActiveFrom {
                HStack(spacing: Theme.s2) {
                    StatusDot(color: .orange)
                    Text("Being controlled by \(by)").fontWeight(.medium)
                    Spacer()
                    Button("Disconnect") { manager.disconnectControlled() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
                .padding(.bottom, Theme.s1)
            }
            Toggle("Accept keyboard & mouse control from trusted Macs", isOn: $acceptControl)
                .toggleStyle(.switch)
                .onChange(of: acceptControl) { on in
                    settings.controlEnabled = on                // keep the model + services in sync
                    if !on { manager.disconnectControlled() }   // ending acceptance ends any session
                }
            Text("Window mode needs no permissions. Edge mode (bump a screen edge) needs Accessibility + Input Monitoring — grant them in Settings → Control.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(Theme.s3)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}
