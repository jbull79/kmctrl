import SwiftUI
import AppKit

/// Diagnostics log with an on/off switch. Off by default; turn it on to capture detailed
/// connection logs when troubleshooting, then Copy or Clear.
struct LogsView: View {
    @ObservedObject private var log = DebugLog.shared

    var body: some View {
        Form {
            Section {
                Toggle("Enable diagnostics logging", isOn: $log.enabled)
            } footer: {
                Text("Off by default. When on, KMctrl records detailed connection/control logs for troubleshooting (and mirrors to Console).")
            }

            Section {
                HStack {
                    Button("Copy") { copyTranscript() }.disabled(log.entries.isEmpty)
                    Button("Clear") { log.clear() }.disabled(log.entries.isEmpty)
                    Spacer()
                    Text("\(log.entries.count) line\(log.entries.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if log.entries.isEmpty {
                    Text(log.enabled ? "No log entries yet." : "Logging is off.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(log.entries) { e in
                                Text("\(stamp(e.time))  \(e.message)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(color(e.level))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(4)
                    }
                    .frame(height: 220)
                    .background(RoundedRectangle(cornerRadius: Theme.radiusSmall).fill(Theme.fieldFill))
                }
            } header: {
                Text("Log")
            }
        }
        .formStyle(.grouped)
    }

    private func color(_ l: DebugLog.Level) -> Color {
        switch l { case .info: return .secondary; case .warn: return .orange; case .error: return .red }
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()
    private func stamp(_ d: Date) -> String { Self.fmt.string(from: d) }

    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(log.transcript(), forType: .string)
    }
}
