import Foundation

/// Plaintext handshake exchanged before any encrypted frames. `signature` is the
/// identity key's signature over `ephemeralPub || nonce`, proving the sender holds
/// the private key behind the advertised identity and binding the ephemeral key to
/// it (authenticates the fingerprint, defeats key-replay impersonation and MITM).
struct Handshake: Codable {
    var identityPub: Data    // Curve25519 signing public key (raw)
    var ephemeralPub: Data   // Curve25519 key-agreement public key (raw)
    var nonce: Data          // per-handshake random freshness
    var name: String
    var signature: Data      // sign(ephemeralPub || nonce) with the identity key
}
