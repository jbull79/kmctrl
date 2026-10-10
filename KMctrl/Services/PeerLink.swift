import Foundation
import Network
import CryptoKit

enum LinkError: Error, LocalizedError {
    case closed
    case notReady
    case rejected
    case integrityMismatch(String)
    case malformed
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .closed: return "Connection closed."
        case .notReady: return "Connection not ready."
        case .rejected: return "The other device declined the transfer."
        case .integrityMismatch(let name): return "Integrity check failed for \(name)."
        case .malformed: return "Received malformed data."
        case .authenticationFailed: return "Could not verify the other device's identity."
        }
    }
}

/// Brings an `NWConnection` to `.ready`. Still used by the Network.framework transport
/// strategy and by Bonjour endpoint resolution.
extension NWConnection {
    func startAndWaitReady() async throws {
        let endpointDesc = "\(self.endpoint)"
        DebugLog.log("connect: starting → \(endpointDesc)")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.stateUpdateHandler = { [weak self] state in
                switch state {
                case .preparing:
                    DebugLog.log("connect: preparing → \(endpointDesc)")
                case .ready:
                    let ifaces = self?.currentPath?.availableInterfaces.map(\.name).joined(separator: ",") ?? "?"
                    DebugLog.log("connect: ready (interfaces: \(ifaces))")
                    self?.stateUpdateHandler = nil
                    cont.resume()
                case .waiting(let error):
                    DebugLog.log("connect: waiting — \(error)", .warn)
                    self?.stateUpdateHandler = nil
                    self?.cancel()
                    cont.resume(throwing: error)
                case .failed(let error):
                    DebugLog.log("connect: failed — \(error)", .error)
                    self?.stateUpdateHandler = nil
                    self?.cancel()
                    cont.resume(throwing: error)
                case .cancelled:
                    DebugLog.log("connect: cancelled", .warn)
                    self?.stateUpdateHandler = nil
                    cont.resume(throwing: LinkError.closed)
                default:
                    break
                }
            }
            self.start(queue: .global(qos: .userInitiated))
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
    /// Codec for the control-event send path, set once at connect. The receiver
    /// auto-detects the format, so only the sender's choice matters.
    var useBinaryControl = false

    init(stream: ByteStream) { self.stream = stream }

    /// Convenience for the NWListener fallback path.
    convenience init(connection: NWConnection) { self.init(stream: NWByteStream(connection)) }

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
        remoteName = incoming.name
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
        guard let data = try? JSONEncoder().encode(value) else { return false }
        return sendSealedSync(data)
    }

    /// Seal `payload` and write it as one frame on the sync path (POSIX transport only).
    /// The single place the sync-send tail (cipher + framed write) lives.
    private func sendSealedSync(_ payload: Data) -> Bool {
        guard let key = sessionKey, let posix = stream as? POSIXByteStream,
              let sealed = try? CryptoService.seal(payload, key: key) else { return false }
        return posix.sendFrameSync(sealed)
    }

    func receiveSecureObject<T: Decodable>(_ type: T.Type) async throws -> T {
        try JSONDecoder().decode(type, from: try await receiveSecure())
    }

    // MARK: Control-event fast path (feature-flagged codec)

    /// Leading sentinel byte marking a binary-codec control frame. JSON payloads always
    /// begin with `{` (0x7B), never 0x01, so the peer disambiguates by content — no
    /// handshake negotiation. Flag OFF sends bare JSON, byte-identical to the legacy
    /// protocol, so an un-updated peer still interoperates when binary is disabled.
    private static let binaryControlTag: UInt8 = 0x01

    /// Send a control event on the low-latency sync path using this link's codec
    /// (`useBinaryControl`, set once at connect). JSON path reuses `sendSecureObjectSync`;
    /// binary path prepends the sentinel tag so the peer disambiguates by content.
    /// POSIX transport only (returns false otherwise).
    func sendControlEventSync(_ event: ControlEvent) -> Bool {
        guard useBinaryControl else { return sendSecureObjectSync(event) }
        var payload = Data([PeerLink.binaryControlTag])
        payload.append(event.encodedBinary())
        return sendSealedSync(payload)
    }

    /// Receive one control event, auto-detecting the codec from the payload's first byte.
    /// Always handles both JSON and binary, so the sender's flag needs no coordination.
    func receiveControlEvent() async throws -> ControlEvent {
        let plain = try await receiveSecure()
        if plain.first == PeerLink.binaryControlTag, plain.count >= ControlEvent.binarySize + 1 {
            return try ControlEvent(binary: plain.dropFirst())
        }
        return try JSONDecoder().decode(ControlEvent.self, from: plain)   // legacy / flag-off JSON
    }
}
