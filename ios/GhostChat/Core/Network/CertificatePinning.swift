import CryptoKit
import Foundation

/// SPKI-SHA256 certificate pinning for `ghostchat.one`.
///
/// NO FALLBACK: if neither pin matches, the connection dies. Pins are rotated via app update
/// (both `primary` and `backup` live in this file and are baked into the binary).
///
/// Primary pin: computed from the live Let's Encrypt leaf on 2026-04-20.
/// Backup pin:  controlled ECDSA P-256 keypair stored privately in `deploy/keys/backup-pin-private.pem`.
final class CertificatePinning: NSObject, URLSessionDelegate {

    /// Base64(SHA256(SubjectPublicKeyInfo)) — Let's Encrypt leaf, valid through 2026-06-29.
    static let primaryPin = "u+rYBkrJDJtDcMZuuZxvgrwKAiaN/8Ppuk7pwdxjGbg="

    /// Backup SPKI hash derived from our ECDSA P-256 keypair.
    static let backupPin  = "/AdS6h9evKtyk7J9aoy+0isfcARe0dv7/C+BOUabNeo="

    /// 26-byte ASN.1 SubjectPublicKeyInfo prefix for ECDSA P-256 uncompressed keys.
    /// Concatenated with the 65-byte uncompressed point produces the full 91-byte SPKI DER.
    static let ecP256SPKIHeader = Data([
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
        0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00
    ])

    private let allowedPins: Set<String>

    init(pins: Set<String> = [CertificatePinning.primaryPin, CertificatePinning.backupPin]) {
        self.allowedPins = pins
    }

    // MARK: - URLSessionDelegate

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Step 1: standard TLS chain validation must pass.
        var cferror: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &cferror) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Step 2: extract leaf certificate + its public key.
        guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let leaf = chain.first,
              let secKey = SecCertificateCopyKey(leaf),
              let rawKey = SecKeyCopyExternalRepresentation(secKey, nil) as Data?,
              let pin = Self.spkiPin(forECP256RawKey: rawKey) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Step 3: strict pin comparison. No fallback.
        if allowedPins.contains(pin) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    // MARK: - Pin computation (pure, unit-testable)

    /// Given the 65-byte uncompressed ECDSA P-256 public key (0x04 | X | Y),
    /// returns the base64 SHA-256 of the full SPKI DER.
    static func spkiPin(forECP256RawKey rawKey: Data) -> String? {
        guard rawKey.count == 65, rawKey.first == 0x04 else { return nil }
        let spki = ecP256SPKIHeader + rawKey
        let digest = SHA256.hash(data: spki)
        return Data(digest).base64EncodedString()
    }
}
