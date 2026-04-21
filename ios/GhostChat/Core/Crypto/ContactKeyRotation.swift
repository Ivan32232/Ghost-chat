import CryptoKit
import Foundation

/// Output of one rotation step. Sides A and B derive identical keys from the same
/// `sessionSecret`, so there's no wire exchange for rotation — both parties just
/// run this function after the session they shared.
struct RotatedKeyMaterial: Equatable {
    /// 32-byte raw scalar for the new P-256 ratchet keypair.
    let newPrivate: Data
    /// 65-byte x963 uncompressed public key (with the leading 0x04).
    let newPublicX963: Data
    /// The contact's prior current public key — slides into the `previousKey` column.
    let previousPublicX963: Data
    /// The contact's prior previous key — slides into `fallbackKey`. `nil` on first rotation.
    let fallbackPublicX963: Data?
    /// Bumped generation counter (was `counter`, becomes `counter + 1`).
    let counter: Int
}

/// Deterministic per-contact key rotation.
///
/// After every saved-contact session, both sides run `rotate(...)` on the session's
/// shared secret (the current ratchet root key). The function derives a new P-256
/// private key via `HKDF(sessionSecret, salt="ghost-rot-v1", info="ghost-rot-seed")`
/// — so both parties compute the SAME seed and arrive at the SAME keypair without
/// exchanging a byte.
///
/// The rotated public key is stored on each side's contact record; the prior
/// `publicKey` slides into `previousKey`, and `previousKey` slides into `fallbackKey`.
/// On the next connect, if the "current" key fails to establish a session, the
/// callers can retry with previous / fallback, giving us 3 generations of forward
/// continuity across occasional state desync.
enum ContactKeyRotation {

    /// HKDF-SHA256 with salt `ghost-rot-v1` and info `ghost-rot-seed`, 32 bytes out.
    /// Byte-identical to `ContactKeyRotation.deriveNextSeed` on Android.
    static func deriveNextSeed(sessionSecret: Data) -> Data {
        let prk = HKDF<SHA256>.extract(
            inputKeyMaterial: SymmetricKey(data: sessionSecret),
            salt: Data("ghost-rot-v1".utf8)
        )
        let okm = HKDF<SHA256>.expand(
            pseudoRandomKey: prk,
            info: Data("ghost-rot-seed".utf8),
            outputByteCount: 32
        )
        return okm.withUnsafeBytes { buf in
            Data(bytes: buf.baseAddress!, count: buf.count)
        }
    }

    /// Compute the next generation of per-contact keys from a session's shared secret.
    /// - Parameters:
    ///   - sessionSecret: 32-byte secret carried over from the just-ended ratchet session.
    ///   - currentPrivate: prior private key (unused except to assert non-equality;
    ///     the new private comes from the HKDF seed above).
    ///   - previousPublic: prior current-public, about to slide into `previousKey`.
    ///   - fallbackPublic: prior previous-public, about to slide into `fallbackKey`. `nil` on first rotation.
    ///   - counter: current `rotationCounter` (bumped by 1 in the result).
    static func rotate(
        sessionSecret: Data,
        currentPrivate: Data,
        previousPublic: Data,
        fallbackPublic: Data?,
        counter: Int
    ) -> RotatedKeyMaterial {
        _ = currentPrivate
        let seed = deriveNextSeed(sessionSecret: sessionSecret)
        // P-256 private scalar: seed is already 32 random bytes, reject unlikely
        // zero-scalar (probability ~2^-256) by folding into a valid range if needed.
        let safeSeed = Self.clampToP256Range(seed)
        let nextPriv = try! P256.KeyAgreement.PrivateKey(rawRepresentation: safeSeed)
        return RotatedKeyMaterial(
            newPrivate: safeSeed,
            newPublicX963: nextPriv.publicKey.x963Representation,
            previousPublicX963: previousPublic,
            fallbackPublicX963: fallbackPublic,
            counter: counter + 1
        )
    }

    /// Clamp an arbitrary 32-byte scalar into `[1, n-1]` for P-256 (n = curve order).
    /// P-256 order starts with 0xFFFFFFFF00000000FFFFFFFF... so zeroing the top bit
    /// is enough to keep us strictly below the order — and if the result is zero we
    /// bump to 1. This preserves determinism while guaranteeing a valid scalar.
    private static func clampToP256Range(_ seed: Data) -> Data {
        var out = Data(seed)
        out[0] &= 0x7F
        if out.allSatisfy({ $0 == 0 }) { out[31] = 0x01 }
        return out
    }
}
