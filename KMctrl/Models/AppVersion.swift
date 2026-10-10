import Foundation

/// Dotted numeric version ("0.8.0", "v1.2"). Anything else (pre-release suffixes, words) is
/// unparseable → nil, so it can never be reported as "newer" than the running app.
struct AppVersion: Comparable, Equatable {
    let parts: [Int]

    init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        guard !s.isEmpty else { return nil }
        let p = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !p.isEmpty, p.allSatisfy({ $0 != nil }) else { return nil }
        parts = p.map { $0! }
    }

    static var current: AppVersion? {
        AppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
    }

    private func padded(to n: Int) -> [Int] { parts + Array(repeating: 0, count: max(0, n - parts.count)) }

    static func == (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.parts.count, b.parts.count)
        return a.padded(to: n) == b.padded(to: n)
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.parts.count, b.parts.count)
        return a.padded(to: n).lexicographicallyPrecedes(b.padded(to: n))
    }
}

/// Subset of GitHub's `releases/latest` response we care about.
struct ReleaseInfo: Codable {
    struct Asset: Codable {
        let name: String
        let browser_download_url: String
    }
    let tag_name: String
    let html_url: String
    let assets: [Asset]

    /// The app zip (KMctrl-*.zip, not a dSYM) if present, else the release page.
    var downloadURL: URL? {
        let pick = assets.first {
            $0.name.hasPrefix("KMctrl-") && $0.name.hasSuffix(".zip") && !$0.name.contains("dSYM")
        }
        return URL(string: pick?.browser_download_url ?? html_url)
    }
}
