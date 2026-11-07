import AppKit
import Network

/// Records what this Mac did — sleep, wake, display, network changes — in Diagnostics, so a
/// dropped link can be lined up against them. A managed Mac may refuse `log show`, which
/// leaves KMctrl's own log as the only record available there.
final class SystemEventLog: @unchecked Sendable {
    static let shared = SystemEventLog()

    private let monitor = NWPathMonitor()
    private var network = ChangeFilter()   // only touched on the monitor's serial queue
    private var started = false            // only touched on the main thread

    /// Keeps the last line, so only a line that differs from it gets through.
    struct ChangeFilter {
        private var last: String?
        mutating func changed(_ line: String) -> String? {
            guard line != last else { return nil }
            last = line
            return line
        }
    }

    static func networkLine(connected: Bool, interfaces: [String], address: String?) -> String {
        let names = interfaces.isEmpty ? "no interfaces" : interfaces.joined(separator: ",")
        return "network: \(connected ? "up" : "down") — \(names), address \(address ?? "none")"
    }

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let line = Self.networkLine(connected: path.status == .satisfied,
                                        interfaces: path.availableInterfaces.map(\.name),
                                        address: LocalNetwork.ipv4Address())
            if let changed = self?.network.changed(line) { DebugLog.log(changed) }
        }
        monitor.start(queue: DispatchQueue(label: "kmctrl.system-events", qos: .utility))

        let events: [(Notification.Name, String)] = [
            (NSWorkspace.willSleepNotification, "mac: going to sleep"),
            (NSWorkspace.didWakeNotification, "mac: woke from sleep"),
            (NSWorkspace.screensDidSleepNotification, "mac: display off"),
            (NSWorkspace.screensDidWakeNotification, "mac: display on"),
        ]
        for (name, line) in events {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                DebugLog.log(line)
            }
        }
    }
}
