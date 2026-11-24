import Foundation

/// One Mac's KMctrl diagnostics log, sent when the other Mac asks for it over the control link
/// (protocol v6). It is KMctrl's own Diagnostics log only: connections, hand-offs, sleep, wake
/// and network changes. Keystrokes and clipboard contents are never logged.
struct LogBundle: Codable, Equatable {
    /// The sending Mac's name for itself.
    var device: String
    /// KMctrl version and build, e.g. "1.0 (39)".
    var app: String
    var os: String
    /// When it was written, seconds since 1970 by the sender's clock.
    var created: Double
    /// Whether that Mac had diagnostics logging on. Off means `lines` is empty or stale.
    var diagnosticsOn: Bool
    var lines: String

    /// The most a log carries: well over the 1,000 lines Diagnostics keeps.
    static let maxBytes = 1_000_000
    static let maxField = 120

    /// Fit to save and show: names cleaned, terminal control codes removed, and a log that's too
    /// big cut to its newest lines.
    var sanitized: LogBundle {
        var b = self
        b.device = String(PeerName.sanitize(device).prefix(Self.maxField))
        b.app = String(PeerName.sanitize(app).prefix(Self.maxField))
        b.os = String(PeerName.sanitize(os).prefix(Self.maxField))
        if !created.isFinite { b.created = 0 }
        b.lines = Self.clean(Self.newest(lines))
        return b
    }

    private static func newest(_ text: String) -> String {
        let bytes = Data(text.utf8)
        guard bytes.count > maxBytes else { return text }
        let tail = String(decoding: bytes.suffix(maxBytes), as: UTF8.self)
        let whole = tail.firstIndex(of: "\n").map { tail[tail.index(after: $0)...] } ?? Substring(tail)
        return "… (earlier lines cut)\n" + whole
    }

    /// Keeps newlines and tabs, drops every other control character (escape sequences included).
    private static func clean(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            if s == "\n" || s == "\t" { out.append(s); continue }
            if s.value < 0x20 || (0x7F...0x9F).contains(s.value) { continue }
            out.append(s)
        }
        return String(out)
    }
}

/// Where logs are saved: ~/Library/Logs/KMctrl, one file per Mac, replaced each time.
enum LogFiles {
    /// In the real home folder. The sandbox's own home is its container, which nothing else can
    /// read; the app's entitlements allow this one folder.
    static var directory: URL {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Library/Logs/KMctrl", isDirectory: true)
    }

    static func fileName(device: String, received: Bool = false) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        var name = String(String.UnicodeScalarView(device.unicodeScalars.map { allowed.contains($0) ? $0 : "-" }))
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " -."))
        name = String(name.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: " -."))
        if name.isEmpty { name = "Mac" }
        return name + (received ? " (received)" : "") + ".log"
    }

    static func render(_ b: LogBundle, receivedFrom peer: String?) -> String {
        let iso = ISO8601DateFormatter()
        var head = ["KMctrl diagnostics log — \(b.device)",
                    "KMctrl \(b.app), macOS \(b.os)",
                    "Written \(iso.string(from: Date(timeIntervalSince1970: b.created))) by that Mac's clock"]
        if let peer { head.append("Saved here \(iso.string(from: Date())), received from \(peer) over the control link") }
        head.append(b.diagnosticsOn ? "Diagnostics logging was on"
                                    : "Diagnostics logging was off — turn it on in KMctrl Settings → Diagnostics on that Mac, then ask again")
        return head.joined(separator: "\n") + "\n" + String(repeating: "─", count: 40) + "\n" + b.lines
    }

    /// Writes (or replaces) the file for that Mac and returns where it went.
    @discardableResult
    static func save(_ b: LogBundle, receivedFrom peer: String?, in dir: URL = directory) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName(device: peer ?? b.device, received: peer != nil))
        try Data(render(b, receivedFrom: peer).utf8).write(to: url, options: .atomic)
        return url
    }
}

/// When a log may be taken or sent. A log that turns up unasked is ignored, and answering is
/// rate-limited so a peer can't make this Mac send megabytes in a loop.
struct LogRequestPolicy {
    static let answerWindow: TimeInterval = 30
    static let answerInterval: TimeInterval = 2

    private var askedAt = -Double.infinity
    private var answeredAt = -Double.infinity

    mutating func asked(at t: Double) { askedAt = t }

    func accepts(at t: Double) -> Bool { t >= askedAt && t - askedAt <= Self.answerWindow }

    mutating func mayAnswer(at t: Double) -> Bool {
        guard t - answeredAt >= Self.answerInterval else { return false }
        answeredAt = t
        return true
    }
}
