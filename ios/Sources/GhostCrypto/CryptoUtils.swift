import CryptoKit
import Foundation

public enum CryptoUtils {

    // MARK: - Initial Root Key (from ECDH shared secret)

    /// Derive initial root key from SharedSecret (production ECDH path)
    public static func deriveInitialRootKey(sharedSecret: SharedSecret) -> SymmetricKey {
        sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("ghost-dr-root".utf8),
            sharedInfo: Data("ghost-dr-rk".utf8),
            outputByteCount: 32
        )
    }

    /// Derive initial root key from raw bytes (test path / cross-platform)
    public static func deriveInitialRootKey(sharedSecretData: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecretData),
            salt: Data("ghost-dr-root".utf8),
            info: Data("ghost-dr-rk".utf8),
            outputByteCount: 32
        )
    }

    // MARK: - Root KDF (ratchet step)

    public struct RootKDFResult {
        public let newRootKey: SymmetricKey
        public let chainKey: SymmetricKey
    }

    /// HKDF(ikm=dhOutput, salt=rootKey, info="ghost-dr-rk", len=64)
    /// Split into newRootKey(32) + chainKey(32)
    public static func rootKDF(rootKey: SymmetricKey, dhOutput: Data) -> RootKDFResult {
        let rootKeyData = rootKey.rawData
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: dhOutput),
            salt: rootKeyData,
            info: Data("ghost-dr-rk".utf8),
            outputByteCount: 64
        )
        let derivedData = derived.rawData
        return RootKDFResult(
            newRootKey: SymmetricKey(data: derivedData.prefix(32)),
            chainKey: SymmetricKey(data: derivedData.suffix(32))
        )
    }

    // MARK: - Chain KDF

    public struct ChainKDFResult {
        public let messageKey: SymmetricKey
        public let nextChainKey: SymmetricKey
    }

    /// messageKey = HMAC-SHA256(CK, 0x01)
    /// nextChainKey = HMAC-SHA256(CK, 0x02)
    public static func chainKDF(chainKey: SymmetricKey) -> ChainKDFResult {
        let mk = HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: chainKey)
        let nck = HMAC<SHA256>.authenticationCode(for: Data([0x02]), using: chainKey)
        return ChainKDFResult(
            messageKey: SymmetricKey(data: Data(mk)),
            nextChainKey: SymmetricKey(data: Data(nck))
        )
    }

    // MARK: - Safety Number

    /// SHA-256(sorted(keyA + keyB)) → first 16 bytes → hex groups of 4 → uppercase
    public static func safetyNumber(identityKeyA: Data, identityKeyB: Data) -> String {
        let sorted: Data
        if identityKeyA.lexicographicallyPrecedes(identityKeyB) {
            sorted = identityKeyA + identityKeyB
        } else {
            sorted = identityKeyB + identityKeyA
        }
        let hash = SHA256.hash(data: sorted)
        let first16 = Data(hash).prefix(16)
        let hexStr = first16.map { String(format: "%02X", $0) }.joined()
        // Groups of 4
        var groups: [String] = []
        var idx = hexStr.startIndex
        while idx < hexStr.endIndex {
            let end = hexStr.index(idx, offsetBy: 4, limitedBy: hexStr.endIndex) ?? hexStr.endIndex
            groups.append(String(hexStr[idx..<end]))
            idx = end
        }
        return groups.joined(separator: " ")
    }

    // MARK: - ECDH Shared Secret

    public static func ecdhSharedSecret(
        privateKey: P256.KeyAgreement.PrivateKey,
        publicKey: P256.KeyAgreement.PublicKey
    ) throws -> Data {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return shared.rawData
    }
}
