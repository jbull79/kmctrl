import AppKit

/// Which physical monitor a display is, independent of its CGDirectDisplayID. macOS hands out
/// display numbers as monitors appear, so the same monitor can come back with a new number after
/// sleep, a dock or hub reconnect, or a restart. The hand-off arrangement is saved against this.
struct DisplayIdentity: Codable, Equatable {
    /// ColorSync's display UUID, built from the monitor's EDID: the steadiest key there is.
    var uuid: String?
    var vendor: UInt32
    var model: UInt32
    /// 0 when the monitor doesn't report one.
    var serial: UInt32
    /// As System Settings names it, for messages only.
    var name: String

    static func of(_ id: CGDirectDisplayID, name: String) -> DisplayIdentity {
        let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { ref -> String in
            let u = ref.takeRetainedValue()
            return CFUUIDCreateString(nil, u) as String
        }
        return DisplayIdentity(uuid: uuid, vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                               serial: CGDisplaySerialNumber(id), name: name)
    }

    fileprivate var hasModel: Bool { vendor != 0 || model != 0 }
}

/// Finds the saved hand-off monitor among the ones connected now.
enum HandoffAnchor {
    /// The monitor's current display number, or nil when it isn't connected — in which case the
    /// saved arrangement is kept as it is, and used again once the monitor is back.
    static func resolve(saved: DisplayIdentity?, savedID: UInt32, among monitors: [HandoffMonitor]) -> UInt32? {
        guard let saved else {
            // Saved before identities were kept: the number is all there is.
            return savedID != 0 && monitors.contains { $0.id == savedID } ? savedID : nil
        }
        let tests: [(DisplayIdentity) -> Bool] = [
            { s in saved.uuid.map { !$0.isEmpty && $0 == s.uuid } ?? false },
            { s in saved.hasModel && saved.serial != 0 && (s.vendor, s.model, s.serial) == (saved.vendor, saved.model, saved.serial) },
            { s in saved.hasModel && (s.vendor, s.model) == (saved.vendor, saved.model) },
        ]
        for matches in tests {
            let found = monitors.filter { $0.identity.map(matches) ?? false }
            if found.isEmpty { continue }
            // Twins that nothing else tells apart: keep the one with the saved number if it's there.
            return (found.first { $0.id == savedID } ?? found[0]).id
        }
        return nil
    }

    /// For an arrangement saved before identities: the identity of the monitor it was set on,
    /// once that monitor is connected. nil when there's nothing to adopt.
    static func adopt(saved: DisplayIdentity?, savedID: UInt32, among monitors: [HandoffMonitor]) -> DisplayIdentity? {
        guard saved == nil, savedID != 0 else { return nil }
        return monitors.first { $0.id == savedID }?.identity
    }
}
