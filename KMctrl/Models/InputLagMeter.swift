import Foundation

/// How late input reaches the capture monitor on the controlling Mac: the gap between when the
/// hardware event happened (`NSEvent.timestamp`) and when the main thread delivered it. A main
/// thread that stalls shows up here as tens or hundreds of ms — the signature of moves reaching
/// the other Mac in bursts. Written on the main thread, read once per second by the flush timer.
final class InputLagMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var maxMs = 0.0

    func note(eventTime: TimeInterval, now: TimeInterval) {
        let lag = max(0, (now - eventTime) * 1000)
        lock.lock(); if lag > maxMs { maxMs = lag }; lock.unlock()
    }

    /// The worst lag since the last call, then reset.
    func takeMax() -> Double {
        lock.lock(); defer { maxMs = 0; lock.unlock() }
        return maxMs
    }
}
