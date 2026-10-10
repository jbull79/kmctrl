import Foundation

enum UpdateCheckError: Error, LocalizedError, Equatable {
    case notFound
    case httpStatus(Int)
    var errorDescription: String? {
        switch self {
        case .notFound: return "No release found — the GitHub repo may be private."
        case .httpStatus(let s): return "GitHub answered HTTP \(s)."
        }
    }
}

/// Daily check of the latest GitHub release. No self-update: the app is unsigned, so the
/// user downloads and clears quarantine as the README describes.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Available: Equatable {
        let version: String
        let url: URL
    }

    @Published private(set) var available: Available?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var checking = false
    @Published private(set) var lastError: String?

    static let endpoint = URL(string: "https://api.github.com/repos/jbull79/kmctrl/releases/latest")!
    static let interval: TimeInterval = 24 * 3600

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let last = "kmctrl.update.lastChecked"
        static let tag = "kmctrl.update.latestTag"
        static let url = "kmctrl.update.latestURL"
    }
    private var timer: Timer?
    /// Read at check time so the Settings toggle takes effect without a restart.
    var isEnabled: () -> Bool = { true }

    init() {
        lastChecked = defaults.object(forKey: Keys.last) as? Date
        if let tag = defaults.string(forKey: Keys.tag),
           let u = defaults.string(forKey: Keys.url).flatMap(URL.init(string:)) {
            available = Self.evaluate(tag: tag, url: u)
        }
    }

    /// Call at launch: first check 5 s in if due, then re-evaluated hourly while running.
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
    }

    func checkIfDue() {
        guard isEnabled() else { return }
        if let t = lastChecked, Date().timeIntervalSince(t) < Self.interval { return }
        Task { await checkNow() }
    }

    func checkNow() async {
        guard !checking else { return }
        checking = true; lastError = nil
        defer { checking = false }
        do {
            var req = URLRequest(url: Self.endpoint)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 {
                // Deterministic (private repo / no release yet): back off for this run so we
                // don't hammer GitHub hourly (in-memory only — the next launch retries once),
                // and the UI shows why.
                lastChecked = Date()
                throw UpdateCheckError.notFound
            }
            guard status == 200 else { throw UpdateCheckError.httpStatus(status) }
            let info = try JSONDecoder().decode(ReleaseInfo.self, from: data)
            guard let url = info.downloadURL else { throw URLError(.badURL) }
            available = Self.evaluate(tag: info.tag_name, url: url)
            lastChecked = Date()
            defaults.set(lastChecked, forKey: Keys.last)
            defaults.set(info.tag_name, forKey: Keys.tag)
            defaults.set(url.absoluteString, forKey: Keys.url)
            DebugLog.log("update: latest \(info.tag_name) — \(available == nil ? "up to date" : "update available")")
        } catch {
            lastError = error.localizedDescription
            DebugLog.log("update: check failed — \(error.localizedDescription)", .warn)
        }
    }

    /// nil unless `tag` parses and is strictly newer than the running app.
    static func evaluate(tag: String, url: URL) -> Available? {
        guard let latest = AppVersion(tag), let cur = AppVersion.current, cur < latest else { return nil }
        return Available(version: latest.parts.map(String.init).joined(separator: "."), url: url)
    }
}
