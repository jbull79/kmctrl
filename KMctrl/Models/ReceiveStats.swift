import Foundation

/// Controlled-side diagnostics: how many mouse moves arrive per second and the longest
/// silence between consecutive events. Bursty arrival (large gaps with many moves) points
/// at the controller or the network; smooth arrival with a rough pointer points at injection.
struct ReceiveStats {
    private var windowStart: Double?
    private var lastEvent: Double?
    private var moves = 0
    private var events = 0
    private var maxGap = 0.0

    /// Feed one received event with a monotonic timestamp in seconds. Returns a summary
    /// line once at least a second has elapsed since the window started, else nil.
    mutating func record(isMove: Bool, at now: Double) -> String? {
        if let last = lastEvent { maxGap = max(maxGap, now - last) }
        lastEvent = now
        guard let start = windowStart else { windowStart = now; moves = isMove ? 1 : 0; events = 1; return nil }
        if isMove { moves += 1 }
        events += 1
        guard now - start >= 1.0 else { return nil }
        let line = String(format: "control: %d moves/s received, %d events, max gap %.0f ms",
                          moves, events, maxGap * 1000)
        windowStart = now; moves = 0; events = 0; maxGap = 0
        return line
    }
}
