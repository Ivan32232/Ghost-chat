import CryptoKit
import Foundation

/// ML-KEM768 post-quantum key encapsulation (optional hybrid leg of the handshake).
///
/// The ECDH (P-256) leg of the handshake is always present. When both sides
/// advertise `pqSupported = true` during `KeyExchangePacket` exchange, they ALSO
/// perform an ML-KEM768 encapsulation and combine the PQ shared secret with the
/// ECDH shared secret via `hybridDeriveSharedKey` — a Kyber break would still
/// need to break P-256 to recover the root key.
///
/// **iOS reality check:** `CryptoKit.MLKEM768` ships in the iOS 26 SDK. On older
/// OS versions the operations fail with `Error.unsupportedOS`, and
/// `KeyExchangePacket.pqSupported` reports `false`. The hybrid then degrades
/// cleanly to ECDH-only. The Android peer (BouncyCastle 1.82 with native
/// ML-KEM) sees `pqSupported=false` from the iOS side and skips the PQ leg.
///
/// Mirror of Android `PostQuantum` — `hybridDeriveSharedKey` is byte-identical.
enum PostQuantum {

    enum Error: Swift.Error, Equatable {
        case unsupportedOS
        case invalidKey
        case invalidCiphertext
    }

    /// Whether this device can perform real ML-KEM768 operations. `false` on
    /// iOS < 26; `true` once CryptoKit.MLKEM768 is wired in on iOS 26+ SDKs.
    static var isSupported: Bool {
        if #available(iOS 26, *) {
            // TODO(phase-6): enable once Xcode toolchain ships CryptoKit.MLKEM768
            // symbols. Until then we keep the hybrid architecture in place but
            // don't actually call ML-KEM on iOS — peer Android devices advertise
            // PQ but iOS degrades cleanly to ECDH-only.
            return false
        }
        return false
    }

    /// Public key + private key pair for ML-KEM768. Sizes per FIPS 203 (768):
    /// - public:  1184 bytes
    /// - private: 2400 bytes
    struct KeyPair: Equatable {
        let publicKey: Data
        let privateKey: Data
    }

    /// Encapsulate against a peer's public key. Returns the ciphertext to send
    /// back to the peer plus the locally-derived shared secret.
    struct Encapsulation: Equatable {
        /// ML-KEM768 ciphertext — 1088 bytes.
        let ciphertext: Data
        /// ML-KEM768 shared secret — 32 bytes.
        let sharedSecret: Data
    }

    /// Generate a fresh ML-KEM768 keypair.
    static func generateKeyPair() throws -> KeyPair {
        throw Error.unsupportedOS
    }

    /// Encapsulate against `peerPublic`, returning the ciphertext + shared secret.
    static func encapsulate(peerPublic: Data) throws -> Encapsulation {
        _ = peerPublic
        throw Error.unsupportedOS
    }

    /// Decapsulate a peer's ciphertext using our private key → shared secret.
    static func decapsulate(ciphertext: Data, privateKey: Data) throws -> Data {
        _ = ciphertext; _ = privateKey
        throw Error.unsupportedOS
    }

    /// Hybrid root-key derivation — always safe to call regardless of
    /// `isSupported`. If `pqSharedSecret` is `nil`, we derive only from the
    /// ECDH secret (identical to Phase 2 path but through a new HKDF salt so
    /// the resulting key is distinct from the plain ECDH root — that way, a
    /// hybrid session can never be downgraded silently into a non-hybrid one).
    ///
    /// Byte-identical to Android `PostQuantum.hybridDeriveSharedKey`.
    static func hybridDeriveSharedKey(ecdhSharedSecret: Data,
                                      pqSharedSecret: Data?) -> Data {
        var ikm = ecdhSharedSecret
        if let pq = pqSharedSecret { ikm.append(pq) }
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: Data("ghost-chat-v1-pq".utf8),
            info: Data("ghost-dr-root".utf8),
            outputByteCount: 32
        )
        return derived.withUnsafeBytes { buf in
            Data(bytes: buf.baseAddress!, count: buf.count)
        }
    }
}
