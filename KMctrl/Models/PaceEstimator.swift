import Foundation

/// Learns how mouse motion arrives — a steady stream, or clumps separated by silences
/// (Wi-Fi power-save delivers a batch every ~100 ms) — and tells the injector what fraction
/// of the buffered motion to apply per tick, so a clump is spread evenly across the gap that
/// follows it. Steady arrival → apply everything at once (no added latency). Clumped
/// arrival → latency ≈ one batch period, but continuous motion instead of glide-and-freeze.
///
/// Thresholds are chosen so a clean wired link reads as steady: a mouse reports every
/// 8–17 ms, so only arrivals much closer than that (`clumpGap`) are a network batch, and a
/// silence longer than `maxPeriod` is the user pausing, not pacing information.
struct PaceEstimator {
    static let clumpGap = 0.004        // arrivals closer than this came in one network batch
    static let minPeriod = 0.016, maxPeriod = 0.16
    static let steadyPeriod = 0.03     // batches this frequent already look smooth: no pacing
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
        guard gap > Self.clumpGap else { return }                    // same network batch
        if gap <= Self.maxPeriod, let start = lastBurstStart {        // next batch: measure period
            let p = min(max(t - start, Self.minPeriod), Self.maxPeriod)
            periodEMA = periodEMA.map { $0 * 0.7 + p * 0.3 } ?? p
        }                                                             // longer gap = a pause
        lastBurstStart = t
    }

    /// Fraction of pending motion to apply on a tick of `tick` seconds.
    func drainFraction(tick: Double) -> Double {
        if let p = periodEMA {
            if p <= Self.steadyPeriod { return 1.0 }                  // already arrives smoothly
            return min(max(tick / p, 0.05), 1.0)
        }
        return arrivals >= 10 ? 1.0 : Self.defaultFraction           // steady stream vs. fresh
    }
}
