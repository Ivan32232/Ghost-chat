import Foundation
import CryptoKit

/// Управляет постоянным P-256 Identity Key пользователя.
/// Генерируется один раз при первом запуске, хранится в Keychain.
/// Этот ключ идентифицирует пользователя между сессиями.
final class IdentityKeyService {

    static let shared = IdentityKeyService()

    private static let keychainKey = "ghost_identity_key"

    private var _privateKey: P256.KeyAgreement.PrivateKey?

    // MARK: - Public API

    /// Private identity key (lazy-loaded from Keychain or generated)
    var privateKey: P256.KeyAgreement.PrivateKey {
        if let key = _privateKey { return key }
        let key = loadOrGenerate()
        _privateKey = key
        return key
    }

    /// Public identity key
    var publicKey: P256.KeyAgreement.PublicKey {
        privateKey.publicKey
    }

    /// x963 representation (65 bytes) for storage in Contact.identityKey
    var publicKeyData: Data {
        publicKey.x963Representation
    }

    /// Base64-encoded x963 public key for key-exchange wire protocol
    func exportPublicKey() -> String {
        publicKeyData.base64EncodedString()
    }

    /// Destroy identity key — panic button (wipes from Keychain + memory)
    func destroy() {
        _privateKey = nil
        KeychainService.delete(forKey: Self.keychainKey)
    }

    // MARK: - Internal

    private func loadOrGenerate() -> P256.KeyAgreement.PrivateKey {
        // Try loading from Keychain
        if let data = KeychainService.load(forKey: Self.keychainKey),
           let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return key
        }

        // Generate new key
        let key = P256.KeyAgreement.PrivateKey()
        KeychainService.save(key.rawRepresentation, forKey: Self.keychainKey)
        return key
    }

    private init() {}
}
