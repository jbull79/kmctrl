import Foundation

/// Learns how mouse motion arrives — a steady stream, or bursts separated by silences
/// (Wi-Fi power-save batches every ~100 ms) — and tells the injector what fraction of the
/// buffered motion to apply per tick so a burst is spread evenly across the gap that
/// follows it. Steady arrival → apply everything at once (no added latency). Bursty
/// arrival → latency ≈ one burst period, but continuous motion instead of glide-and-freeze.
struct PaceEstimator {
    static let burstGap = 0.015        // a silence longer than this separates bursts
    static let idleGap = 0.5           // longer than this is idle, not pacing information
    static let minPeriod = 0.016, maxPeriod = 0.16
    static let defaultFraction = 0.25  // until enough has been seen

    private var lastArrival: Double?
    private var lastBurstStart: Double?
    private var periodEMA: Double?
    private var arrivals = 0

    mutating func noteArrival(at t: Double) {
        arrivals += 1
        defer { lastArrival = t }
        guard let last = lastArrival else { lastBurstStart = t; return }
        let gap = t - last
        guard gap > Self.burstGap else { return }                    // same burst
        if gap < Self.idleGap, let start = lastBurstStart {           // new burst: measure period
            let p = min(max(t - start, Self.minPeriod), Self.maxPeriod)
            periodEMA = periodEMA.map { $0 * 0.7 + p * 0.3 } ?? p
        }
        lastBurstStart = t
    }

    /// Fraction of pending motion to apply on a tick of `tick` seconds.
    func drainFraction(tick: Double) -> Double {
        if let p = periodEMA { return min(max(tick / p, 0.05), 1.0) }
        return arrivals >= 10 ? 1.0 : Self.defaultFraction          // steady stream vs. fresh
    }
}
