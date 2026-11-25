import SwiftUI
import AppKit

/// Diagnostics log with an on/off switch. Off by default; turn it on to capture detailed
/// connection logs when troubleshooting, then Copy or Clear.
struct LogsView: View {
    @ObservedObject private var log = DebugLog.shared
    @ObservedObject private var exchange = LogExchange.shared
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Enable diagnostics logging", isOn: $log.enabled)
                Toggle("Keep the log on disk", isOn: $log.diskEnabled)
                    .disabled(!log.enabled)
            } footer: {
                Text("Diagnostics logging is off by default. When on, KMctrl records detailed connection/control logs for troubleshooting (and mirrors to Console). Keep the log on disk also writes them to ~/Library/Logs/KMctrl/KMctrl.log as they happen, so they survive a crash or a restart. The file keeps the last 24 hours, at most 20 MB. Turning it off deletes the file.")
            }

            Section {
                HStack {
                    Button("Save Logs") { model.pullLogs() }
                    Button("Show in Finder") {
                        let fm = FileManager.default
                        let disk = DiskLog.shared.url
                        if let f = exchange.lastFolder ?? (fm.fileExists(atPath: disk.path) ? disk : nil) {
                            NSWorkspace.shared.activateFileViewerSelecting([f])
                        }
                    }
                    .disabled(exchange.lastFolder == nil && !(log.enabled && log.diskEnabled))
                }
                if let s = exchange.status {
                    Text(s).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } header: {
                Text("Save to file")
            } footer: {
                Text("Saves this Mac’s log to ~/Library/Logs/KMctrl and fetches the other Mac’s over the open session: the newest megabyte of each log on disk, or the last 1,000 lines. Keystrokes and clipboard contents are never logged.")
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
