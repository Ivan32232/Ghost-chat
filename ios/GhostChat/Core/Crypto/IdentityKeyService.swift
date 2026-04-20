import CryptoKit
import Foundation

/// Persistent P-256 identity keypair that survives app restarts. Generated once on first
/// call and retained in the Keychain. The public key is what peers see as "who I am"
/// for safety-number comparison and pending-room HOST/GUEST determination.
final class IdentityKeyService: @unchecked Sendable {

    enum Keys {
        static let privateRaw = "identity.private.raw"
    }

    enum Error: Swift.Error, Equatable {
        case decodingFailed
    }

    private let keychain: KeychainServicing
    private let lock = NSLock()
    private var cached: P256.KeyAgreement.PrivateKey?

    init(keychain: KeychainServicing) {
        self.keychain = keychain
    }

    /// Returns the identity private key, generating it on first call.
    func getOrCreateIdentity() throws -> P256.KeyAgreement.PrivateKey {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        if let data = try keychain.get(Keys.privateRaw) {
            guard let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: data) else {
                throw Error.decodingFailed
            }
            cached = key
            return key
        }
        let fresh = P256.KeyAgreement.PrivateKey()
        try keychain.set(fresh.rawRepresentation, for: Keys.privateRaw)
        cached = fresh
        return fresh
    }

    /// 65-byte x963 representation (includes 0x04 prefix).
    var publicKeyX963: Data {
        get throws { try getOrCreateIdentity().publicKey.x963Representation }
    }

    /// 64-byte raw coordinate (x + y), used in safety-number comparisons.
    var publicKeyRaw: Data {
        get throws {
            let x963 = try publicKeyX963
            return Data(x963.dropFirst())
        }
    }

    /// Irrevocably deletes the identity. Used by panic-wipe.
    func resetIdentity() throws {
        lock.lock(); defer { lock.unlock() }
        cached = nil
        try keychain.delete(Keys.privateRaw)
    }
}
