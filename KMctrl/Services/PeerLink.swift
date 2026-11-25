import Foundation
import CryptoKit

enum LinkError: Error, LocalizedError {
    case closed
    case lost
    case notReady
    case rejected
    case integrityMismatch(String)
    case malformed
    case authenticationFailed
    case addressNotFound(String)
    /// Found over Bonjour, but no address answered.
    case unreachable(String, [String])

    var errorDescription: String? {
        switch self {
        case .addressNotFound(let name): return "Couldn’t find “\(name)” on the network. Check that KMctrl is running on it, then try again."
        case .unreachable(let name, let hosts):
            return "Found “\(name)” at \(hosts.joined(separator: ", ")), but it didn’t answer. Something between the Macs may be blocking the connection, such as a VPN or firewall."
        case .closed: return "Connection closed."
        case .lost: return "Connection lost."
        case .notReady: return "Connection not ready."
        case .rejected: return "The other device declined the transfer."
        case .integrityMismatch(let name): return "Integrity check failed for \(name)."
        case .malformed: return "Received malformed data."
        case .authenticationFailed: return "Could not verify the other device's identity."
        }
    }
}

/// An encrypted, framed peer connection over any `ByteStream`. After `handshake()` all
/// frames are AES-GCM sealed with the negotiated session key. Sendable so the control
/// receive loop can run off the main actor (sessionKey/names are set once at handshake).
final class PeerLink: @unchecked Sendable {
    let stream: ByteStream
    private(set) var sessionKey: SymmetricKey?
    private(set) var remoteName: String = "Unknown"
    private(set) var remoteFingerprint: String = ""

    init(stream: ByteStream) {
        self.stream = stream
        Self.countLock.lock(); Self.live += 1; Self.countLock.unlock()
    }

    deinit { Self.countLock.lock(); Self.live -= 1; Self.countLock.unlock() }

    /// Links still in memory (Diagnostics health line): a number that keeps growing is a leak.
    private static let countLock = NSLock()
    nonisolated(unsafe) private static var live = 0
    static var liveCount: Int { countLock.lock(); defer { countLock.unlock() }; return live }


    func start() async throws { try await stream.open() }

    func cancel() { stream.close() }

    /// Request low-latency treatment for this link (control sessions only).
    func setLowLatency() { (stream as? POSIXByteStream)?.setLowLatency() }

    /// Exchange signed ephemeral + identity keys, verify the peer's signature, and
    /// derive the session key. Each side signs its ephemeral key with its long-term
    /// identity key, so the fingerprint authenticates the peer (no key-replay
    /// impersonation) and the ephemeral DH is bound to that identity (no MITM).
    /// `identity` defaults to the persisted Keychain key in the app; tests inject their own
    /// so the handshake can run without the Keychain.
    func handshake(localName: String,
                   identity: Curve25519.Signing.PrivateKey = CryptoService.identitySigningKey()) async throws {
        // Reap connections that open but stall before authenticating (slow-loris), then
        // relax the timeout so legit transfers and accept-prompt waits aren't cut off.
        stream.setReadTimeout(15)
        defer { stream.setReadTimeout(0) }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPub = ephemeral.publicKey.rawRepresentation
        let nonce = CryptoService.randomNonce()
        let signature = try identity.signature(for: ephemeralPub + nonce)
        let outgoing = Handshake(identityPub: identity.publicKey.rawRepresentation,
                                 ephemeralPub: ephemeralPub,
                                 nonce: nonce,
                                 name: localName,
                                 signature: signature)
        try await stream.sendFrame(try JSONEncoder().encode(outgoing))

        // The handshake is tiny; cap the (still-unauthenticated) frame well below the
        // general limit so a hostile peer can't force a large pre-auth allocation.
        let incomingData = try await stream.receiveFrame(maxBytes: 64 * 1024)
        let incoming = try JSONDecoder().decode(Handshake.self, from: incomingData)

        // Verify the peer holds the identity private key behind its fingerprint and
        // that the ephemeral key it offered is bound to that identity.
        guard let signingPub = try? Curve25519.Signing.PublicKey(rawRepresentation: incoming.identityPub),
              signingPub.isValidSignature(incoming.signature, for: incoming.ephemeralPub + incoming.nonce) else {
            throw LinkError.authenticationFailed
        }

        sessionKey = try CryptoService.deriveSessionKey(ephemeralPrivate: ephemeral,
                                                        remoteEphemeralPublicRaw: incoming.ephemeralPub,
                                                        localEphemeralPublicRaw: ephemeralPub)
        remoteName = PeerName.sanitize(incoming.name)   // chosen by the peer: display text only
        remoteFingerprint = CryptoService.fingerprint(of: incoming.identityPub)
    }

    func sendSecure(_ data: Data) async throws {
        guard let key = sessionKey else { throw LinkError.notReady }
        try await stream.sendFrame(try CryptoService.seal(data, key: key))
    }

    func receiveSecure() async throws -> Data {
        guard let key = sessionKey else { throw LinkError.notReady }
        return try CryptoService.open(try await stream.receiveFrame(), key: key)
    }

    // MARK: Codable helpers

    func sendSecureObject<T: Encodable>(_ value: T) async throws {
        try await sendSecure(try JSONEncoder().encode(value))
    }

    /// Synchronous encrypted send (POSIX transport only) for the low-latency control
    /// path. Returns false if not possible (e.g. NW transport) so the caller can fall back.
    func sendSecureObjectSync<T: Encodable>(_ value: T) -> Bool {
        do {
            return sendSealedSync(try JSONEncoder().encode(value))
        } catch {
            DebugLog.log("link: JSON encode failed for \(T.self) — \(error)", .error)
            return false
        }
    }

    /// Seal `payload` and write it as one frame on the sync path (POSIX transport only).
    /// The single place the sync-send tail (cipher + framed write) lives.
    private func sendSealedSync(_ payload: Data) -> Bool {
        guard let key = sessionKey else { DebugLog.log("link: sync send before handshake", .error); return false }
        guard let posix = stream as? POSIXByteStream else {
            DebugLog.log("link: sync send needs the POSIX transport (link is \(type(of: stream)))", .error); return false
        }
        guard let sealed = try? CryptoService.seal(payload, key: key) else {
            DebugLog.log("link: seal failed", .error); return false
        }
        let ok = posix.sendFrameSync(sealed)
        if !ok { DebugLog.log("link: socket write failed (errno \(errno): \(String(cString: strerror(errno))))", .error) }
        return ok
    }

    func receiveSecureObject<T: Decodable>(_ type: T.Type) async throws -> T {
        try JSONDecoder().decode(type, from: try await receiveSecure())
    }

    // MARK: Control events

    /// Send a control event on the low-latency sync path. POSIX transport only (returns false
    /// otherwise).
    func sendControlEventSync(_ event: ControlEvent) -> Bool { sendSecureObjectSync(event) }

    func receiveControlEvent() async throws -> ControlEvent {
        try JSONDecoder().decode(ControlEvent.self, from: try await receiveSecure())
    }
}
