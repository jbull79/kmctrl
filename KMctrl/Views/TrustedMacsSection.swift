import SwiftUI

/// Settings → Control: the Macs this one trusts, both ways, each removable. Removing a Mac
/// that controls this one means it must be allowed again; removing one this Mac controls
/// forgets its fingerprint, so the next connection pins whatever answers.
struct TrustedMacsSection: View {
    @ObservedObject var trust: TrustStore
    @State private var ownFingerprint = "…"

    var body: some View {
        Section {
            LabeledContent("This Mac's fingerprint") {
                Text(ownFingerprint).font(.body.monospaced()).textSelection(.enabled)
            }
            if trust.known.isEmpty && trust.hosts.pins.isEmpty {
                Text("No trusted Macs yet.").foregroundStyle(.secondary)
            }
            ForEach(trust.known.sorted { $0.value < $1.value }, id: \.key) { fingerprint, name in
                row(name, detail: "Can control this Mac", fingerprint: fingerprint) { trust.forget(fingerprint) }
            }
            ForEach(trust.hosts.pins.sorted { $0.key < $1.key }, id: \.key) { name, fingerprint in
                row(name, detail: "This Mac controls it", fingerprint: fingerprint) { trust.forgetHost(name) }
            }
        } header: {
            Text("Trusted Macs")
        } footer: {
            Text("A Mac you allowed to control this one, or one this Mac has connected to. If a Mac you control is reinstalled its fingerprint changes and KMctrl refuses it — remove it here, then connect again.")
        }
        .task {
            // The key is cached after launch; read it off the main thread anyway.
            let fp = await Task.detached {
                CryptoService.fingerprint(of: CryptoService.identitySigningKey().publicKey.rawRepresentation)
            }.value
            ownFingerprint = fp
        }
    }

    private func row(_ name: String, detail: String, fingerprint: String, remove: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text("\(detail) · \(fingerprint)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            Button("Remove", role: .destructive, action: remove)
        }
    }
}
