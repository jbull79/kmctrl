import Foundation

/// Tracks `NSPasteboard.changeCount` so we send real user copies and ignore our own writes
/// (otherwise a mirrored payload would bounce back and forth between the two Macs).
struct ClipboardSyncState {
    private var lastSeen: Int?
    private var ownWrite: Int?

    /// Returns true when `count` is a new, user-originated change worth sending. The first
    /// observation only sets the baseline.
    mutating func noteLocalChange(count: Int) -> Bool {
        defer { lastSeen = count }
        guard let last = lastSeen, count != last else { return false }
        if count == ownWrite { ownWrite = nil; return false }
        return true
    }

    /// Record the change count produced by writing a remote payload locally.
    mutating func noteOwnWrite(count: Int) {
        ownWrite = count
        lastSeen = count
    }
}
