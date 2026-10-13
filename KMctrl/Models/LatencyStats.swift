import Foundation

/// Aggregates control-link round-trip samples into one Diagnostics line per second. The
/// probe fires ~5×/s; logging each sample re-rendered the Diagnostics view on the main
/// thread — the same thread window-mode capture runs on — and made the pointer stutter.
struct LatencyStats {
    private var windowStart: Double?
    private var minRTT = Double.greatestFiniteMagnitude
    private var maxRTT = 0.0
    private var sum = 0.0
    private var count = 0
    private(set) var sessionMin = Double.greatestFiniteMagnitude

    /// Feed one sample (ms) with a monotonic timestamp (seconds). Returns a summary line
    /// once at least a second of samples has accumulated, else nil.
    mutating func record(rtt: Double, at now: Double) -> String? {
        sessionMin = min(sessionMin, rtt)
        minRTT = min(minRTT, rtt); maxRTT = max(maxRTT, rtt); sum += rtt; count += 1
        guard let start = windowStart else { windowStart = now; return nil }
        guard now - start >= 1.0 else { return nil }
        let line = String(format: "control latency: RTT min %.1f / avg %.1f / max %.1f ms over %d probes · session min %.1f ms",
                          minRTT, sum / Double(count), maxRTT, count, sessionMin)
        windowStart = nil; minRTT = .greatestFiniteMagnitude; maxRTT = 0; sum = 0; count = 0
        return line
    }
}
