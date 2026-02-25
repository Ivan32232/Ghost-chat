import Foundation
import CommonCrypto
import Security

/// M1: Real SPKI (Subject Public Key Info) certificate pinning for gbskgs.xyz
/// Extracts the server certificate's public key, hashes it with SHA-256,
/// and compares against pinned hashes. Rejects connections if no match.
enum CertificatePinning {

    private static let pinnedHost = "gbskgs.xyz"

    /// SHA-256 hashes of pinned SPKI (base64-encoded)
    /// Update with:
    ///   openssl s_client -connect gbskgs.xyz:443 </dev/null 2>/dev/null \
    ///     | openssl x509 -pubkey -noout \
    ///     | openssl pkey -pubin -outform der \
    ///     | openssl dgst -sha256 -binary | base64
    ///
    /// Multiple hashes allow leaf rotation without downtime — pin both current and backup.
    private static let pinnedSPKIHashes: Set<String> = [
        // Let's Encrypt E7 (current leaf, expires ~May 2026)
        "uv4xkRztclgAjr/9IS7cNxGemBFTB6ekFqIQ+EKcqc0=",
        // Let's Encrypt ISRG Root X1 (backup — root CA, long-lived)
        "C5+lpZ7tcVwmwQIMcRtPbsQtWLABXhQzejna0wHFr8M=",
    ]

    // MARK: - ASN.1 DER header for EC P-256 public key (SPKI wrapper)
    // When SecKeyCopyExternalRepresentation returns raw EC key bytes (65 bytes for P-256),
    // we prepend this header to reconstruct the full SubjectPublicKeyInfo DER structure.
    private static let ecDSASecp256r1Header: [UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86,
        0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A,
        0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03,
        0x42, 0x00
    ]

    // RSA 2048 SPKI header
    private static let rsa2048Header: [UInt8] = [
        0x30, 0x82, 0x01, 0x22, 0x30, 0x0D, 0x06, 0x09,
        0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01,
        0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0F, 0x00
    ]

    // RSA 4096 SPKI header
    private static let rsa4096Header: [UInt8] = [
        0x30, 0x82, 0x02, 0x22, 0x30, 0x0D, 0x06, 0x09,
        0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01,
        0x01, 0x05, 0x00, 0x03, 0x82, 0x02, 0x0F, 0x00
    ]

    // EC P-384 SPKI header
    private static let ecDSASecp384r1Header: [UInt8] = [
        0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2A, 0x86,
        0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x05, 0x2B,
        0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00
    ]

    /// Handle URLSession authentication challenge with real SPKI pinning
    static func handleChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host

        // Only pin our server; allow default handling for others (STUN/TURN on other domains)
        guard host == pinnedHost else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Standard TLS validation first
        var error: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &error) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Check every certificate in the chain against pinned hashes
        guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        for certificate in chain {
            if let hash = spkiHash(for: certificate), pinnedSPKIHashes.contains(hash) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }

        // No pinned hash matched — reject the connection
        #if DEBUG
        print("[CertificatePinning] SPKI hash mismatch for \(host) — rejecting connection")
        #endif
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    // MARK: - SPKI Hash Extraction

    /// Extracts the public key from a certificate, wraps it in SPKI DER, and returns SHA-256 base64 hash
    private static func spkiHash(for certificate: SecCertificate) -> String? {
        guard let publicKey = SecCertificateCopyKey(certificate) else { return nil }
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as? Data else { return nil }

        // Determine the ASN.1 header based on key type and size
        guard let header = headerForKey(publicKey) else { return nil }

        // Build full SPKI: header + raw public key bytes
        var spkiData = Data(header)
        spkiData.append(publicKeyData)

        // SHA-256 hash
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        spkiData.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(spkiData.count), &hash)
        }

        return Data(hash).base64EncodedString()
    }

    /// Returns the appropriate ASN.1 DER header for the given key type
    private static func headerForKey(_ key: SecKey) -> [UInt8]? {
        guard let attributes = SecKeyCopyAttributes(key) as? [String: Any],
              let keyType = attributes[kSecAttrKeyType as String] as? String,
              let keySize = attributes[kSecAttrKeySizeInBits as String] as? Int else {
            return nil
        }

        if keyType == (kSecAttrKeyTypeEC as String) || keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            switch keySize {
            case 256: return ecDSASecp256r1Header
            case 384: return ecDSASecp384r1Header
            default: return nil
            }
        } else if keyType == (kSecAttrKeyTypeRSA as String) {
            switch keySize {
            case 2048: return rsa2048Header
            case 4096: return rsa4096Header
            default: return nil
            }
        }

        return nil
    }
}
