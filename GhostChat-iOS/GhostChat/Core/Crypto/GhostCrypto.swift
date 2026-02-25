import Foundation
import CryptoKit

/// Ghost Chat E2E Encryption — Double Ratchet Protocol (v2)
///
/// Signal Protocol style:
/// - Initial ECDH P-256 key exchange
/// - Double Ratchet: DH ratchet per sender change, symmetric ratchet per message
/// - Every message encrypted with a unique key (per-message forward secrecy)
/// - Encrypted headers hide DH ratchet keys from observers
/// - Hybrid Post-Quantum: ML-KEM768 (iOS 26+)
///
/// Wire format v2:
/// { type: "encrypted-message", data: "base64(encryptedHeader + separator + encryptedBody)", v: 2 }
final class GhostCrypto {

    // MARK: - Protocol Version

    static let protocolVersion = 3

    // MARK: - Keys

    private var privateKey: P256.KeyAgreement.PrivateKey?
    private(set) var publicKey: P256.KeyAgreement.PublicKey?
    private var peerPublicKey: P256.KeyAgreement.PublicKey?

    // MARK: - Double Ratchet

    private var ratchet: DoubleRatchet?

    // MARK: - Post-Quantum (ML-KEM768)

    private var pqSharedSecret: Data?
    private(set) var isPQEnabled = false
    private var mlkemPrivateKeyStorage: Any?
    private(set) var mlkemEncapsulationKeyData: Data?

    // MARK: - Counters & Replay Protection

    private(set) var messageCounter: Int = 0
    private var peerMessageCounter: Int = 0
    private var receivedNonces: [String: Date] = [:]
    private let nonceExpiryInterval: TimeInterval = 5 * 60
    private let counterWindow: Int = 100

    // MARK: - Initialization tracking

    private(set) var isHost = false

    // MARK: - Key Generation

    func generateKeyPair() {
        let key = P256.KeyAgreement.PrivateKey()
        privateKey = key
        publicKey = key.publicKey
    }

    // MARK: - Post-Quantum Key Generation

    func generatePQKeyPair() {
        if #available(iOS 26.0, *) {
            do {
                let mlkemKey = try CryptoKit.MLKEM768.PrivateKey()
                mlkemPrivateKeyStorage = mlkemKey
                mlkemEncapsulationKeyData = mlkemKey.publicKey.rawRepresentation
            } catch {
                #if DEBUG
                print("[GhostCrypto] ML-KEM key generation failed: \(error)")
                #endif
            }
        }
    }

    func exportPQEncapsulationKey() -> String? {
        mlkemEncapsulationKeyData?.base64EncodedString()
    }

    func pqEncapsulate(encapsKeyBase64: String) -> (ciphertext: String, success: Bool) {
        guard #available(iOS 26.0, *),
              let encapsKeyData = Data(base64Encoded: encapsKeyBase64) else {
            return ("", false)
        }

        do {
            let encapsKey = try CryptoKit.MLKEM768.PublicKey(rawRepresentation: encapsKeyData)
            let result = try encapsKey.encapsulate()
            pqSharedSecret = result.sharedSecret.withUnsafeBytes { Data($0) }
            isPQEnabled = true
            return (result.encapsulated.base64EncodedString(), true)
        } catch {
            #if DEBUG
            print("[GhostCrypto] ML-KEM encapsulation failed: \(error)")
            #endif
            return ("", false)
        }
    }

    func pqDecapsulate(ciphertextBase64: String) -> Bool {
        guard #available(iOS 26.0, *),
              let ctData = Data(base64Encoded: ciphertextBase64),
              let mlkemKey = mlkemPrivateKeyStorage as? CryptoKit.MLKEM768.PrivateKey else {
            return false
        }

        do {
            let sharedKey = try mlkemKey.decapsulate(ctData)
            pqSharedSecret = sharedKey.withUnsafeBytes { Data($0) }
            isPQEnabled = true
            return true
        } catch {
            #if DEBUG
            print("[GhostCrypto] ML-KEM decapsulation failed: \(error)")
            #endif
            return false
        }
    }

    static var isPQAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    // MARK: - Key Export/Import

    func exportPublicKey() -> String? {
        guard let pub = publicKey else { return nil }
        return pub.x963Representation.base64EncodedString()
    }

    func importPeerPublicKey(_ base64Key: String) throws {
        guard let data = Data(base64Encoded: base64Key) else {
            throw GhostCryptoError.invalidKeyData
        }
        peerPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: data)
    }

    // MARK: - Key Derivation (Double Ratchet Initialization)

    /// Initialize Double Ratchet from ECDH shared secret
    /// Host (initiator) calls with isHost=true, guest (responder) with isHost=false
    func deriveSharedKey(asHost: Bool = false) throws {
        guard let priv = privateKey, let peer = peerPublicKey else {
            throw GhostCryptoError.keysNotReady
        }

        self.isHost = asHost

        // ECDH shared secret
        let sharedSecret = try priv.sharedSecretFromKeyAgreement(with: peer)

        // Build HKDF salt — hybrid PQ if available
        let salt: Data
        if let pqSS = pqSharedSecret {
            var hybridSalt = Data("ghost-chat-v2-pq".utf8)
            hybridSalt.append(pqSS)
            salt = hybridSalt
        } else {
            salt = Data("ghost-chat-v2".utf8)
        }

        // Derive root symmetric key from ECDH shared secret
        let rootSecret = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("ghost-dr-init-secret".utf8),
            outputByteCount: 32
        )

        // Initialize Double Ratchet
        if asHost {
            // Host is initiator: knows peer's DH key, performs first DH ratchet
            ratchet = try DoubleRatchet(asInitiator: rootSecret, peerDHKey: peer)
        } else {
            // Guest is responder: will perform DH ratchet on first received message
            ratchet = DoubleRatchet(asResponder: rootSecret)
        }
    }

    /// Export the DH ratchet public key for the key-exchange message
    func exportDHRatchetKey() -> String? {
        ratchet?.dhPublicKeyData.base64EncodedString()
    }

    // MARK: - Encryption (Double Ratchet v2)

    /// Encrypt a message using Double Ratchet
    /// Returns base64(encryptedHeader + 0xFF + encryptedBody) with embedded {m, t, c} metadata
    func encrypt(_ plaintext: String) throws -> String {
        guard let ratchet else {
            throw GhostCryptoError.sendKeyNotDerived
        }

        messageCounter += 1

        // Build message with metadata {m, t, c}
        let meta: [String: Any] = [
            "m": plaintext,
            "t": Int(Date().timeIntervalSince1970 * 1000),
            "c": messageCounter
        ]
        let metaJSON = try JSONSerialization.data(withJSONObject: meta)
        guard let metaString = String(data: metaJSON, encoding: .utf8) else {
            throw GhostCryptoError.encodingFailed
        }

        // Padding to 256-byte blocks
        let padded = try padMessage(metaString)
        let paddedData = Data(padded.utf8)

        // Double Ratchet encrypt → (encryptedHeader, ciphertext)
        let (encryptedHeader, ciphertext) = try ratchet.encrypt(paddedData)

        // Combine: encryptedHeader + separator(0xFF) + ciphertext
        var combined = Data()
        // Header length as 4-byte big-endian prefix (to know where header ends)
        let headerLen = UInt32(encryptedHeader.count)
        combined.append(contentsOf: withUnsafeBytes(of: headerLen.bigEndian) { Array($0) })
        combined.append(encryptedHeader)
        combined.append(ciphertext)

        return combined.base64EncodedString()
    }

    // MARK: - Decryption (Double Ratchet v2)

    /// Decrypt a Double Ratchet message
    func decrypt(_ encryptedBase64: String) throws -> String {
        guard let ratchet else {
            throw GhostCryptoError.receiveKeyNotDerived
        }

        guard let combined = Data(base64Encoded: encryptedBase64) else {
            throw GhostCryptoError.invalidCiphertext
        }

        // Parse: 4-byte header length + encrypted header + ciphertext
        guard combined.count > 4 else {
            throw GhostCryptoError.invalidCiphertext
        }

        let headerLen = Int(UInt32(bigEndian: combined.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard combined.count > 4 + headerLen else {
            throw GhostCryptoError.invalidCiphertext
        }

        let encryptedHeader = combined.subdata(in: 4..<(4 + headerLen))
        let ciphertext = combined.subdata(in: (4 + headerLen)..<combined.count)

        // Replay protection: extract nonce from ciphertext
        guard ciphertext.count > 12 else {
            throw GhostCryptoError.invalidCiphertext
        }
        let nonceData = ciphertext.prefix(12)
        let nonceString = nonceData.base64EncodedString()

        cleanupExpiredNonces()

        if receivedNonces[nonceString] != nil {
            throw GhostCryptoError.replayAttack
        }

        // Try skipped keys first (out-of-order messages)
        if let plainData = try? ratchet.tryDecryptWithSkippedKey(
            encryptedHeader: encryptedHeader,
            ciphertext: ciphertext
        ) {
            return try processDecryptedData(plainData, nonceString: nonceString)
        }

        // Normal Double Ratchet decrypt
        let plainData = try ratchet.decrypt(encryptedHeader: encryptedHeader, ciphertext: ciphertext)
        return try processDecryptedData(plainData, nonceString: nonceString)
    }

    /// Process decrypted data: unpad, validate metadata, return message
    private func processDecryptedData(_ data: Data, nonceString: String) throws -> String {
        guard let paddedText = String(data: data, encoding: .utf8) else {
            throw GhostCryptoError.decodingFailed
        }

        let unpaddedText = try unpadMessage(paddedText)

        if let jsonData = unpaddedText.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {

            // Timestamp validation (5 min max age)
            if let timestamp = parsed["t"] as? Int {
                let messageAge = Date().timeIntervalSince1970 * 1000 - Double(timestamp)
                if messageAge > 5 * 60 * 1000 {
                    throw GhostCryptoError.messageTooOld
                }
            }

            // Counter validation
            if let counter = parsed["c"] as? Int {
                if counter <= peerMessageCounter - counterWindow {
                    throw GhostCryptoError.counterTooOld
                }
                if counter > peerMessageCounter {
                    peerMessageCounter = counter
                }
            }

            // Save nonce
            receivedNonces[nonceString] = Date()

            if let message = parsed["m"] as? String {
                return message
            }
        }

        return unpaddedText
    }

    // MARK: - Message Padding

    func padMessage(_ message: String, blockSize: Int = 256) throws -> String {
        let base64Message = Data(message.utf8).base64EncodedString()
        let messageLength = base64Message.count

        guard messageLength <= 9999 else {
            throw GhostCryptoError.messageTooLong
        }

        let paddedLength = ((messageLength + 4 + blockSize - 1) / blockSize) * blockSize
        let paddingLength = paddedLength - messageLength - 4

        let paddingChars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var randomBytes = [UInt8](repeating: 0, count: paddingLength)
        _ = SecRandomCopyBytes(kSecRandomDefault, paddingLength, &randomBytes)

        let padding = String(randomBytes.map { paddingChars[Int($0) % paddingChars.count] })
        let lengthPrefix = String(format: "%04d", messageLength)

        return lengthPrefix + base64Message + padding
    }

    func unpadMessage(_ paddedMessage: String) throws -> String {
        guard paddedMessage.count >= 4 else {
            throw GhostCryptoError.invalidPaddedMessage
        }

        let prefixStr = String(paddedMessage.prefix(4))
        guard let originalLength = Int(prefixStr),
              originalLength >= 0,
              originalLength <= paddedMessage.count - 4 else {
            throw GhostCryptoError.invalidPaddedMessage
        }

        let startIndex = paddedMessage.index(paddedMessage.startIndex, offsetBy: 4)
        let endIndex = paddedMessage.index(startIndex, offsetBy: originalLength)
        let base64Message = String(paddedMessage[startIndex..<endIndex])

        guard let data = Data(base64Encoded: base64Message) else {
            throw GhostCryptoError.invalidPaddedMessage
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw GhostCryptoError.decodingFailed
        }

        return text
    }

    // MARK: - Fingerprint

    func generateFingerprint() throws -> String {
        guard let pub = publicKey, let peer = peerPublicKey else {
            throw GhostCryptoError.keysNotReady
        }

        let ourKeyRaw = [UInt8](pub.x963Representation)
        let peerKeyRaw = [UInt8](peer.x963Representation)

        let sorted: [[UInt8]] = [ourKeyRaw, peerKeyRaw].sorted { a, b in
            for i in 0..<min(a.count, b.count) {
                if a[i] != b[i] { return a[i] < b[i] }
            }
            return a.count < b.count
        }

        var combined = Data(sorted[0])
        combined.append(contentsOf: sorted[1])

        let hash = SHA256.hash(data: combined)
        let hashBytes = Array(hash)

        let hexString = hashBytes.prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()

        let groups = stride(from: 0, to: hexString.count, by: 4).map { i -> String in
            let start = hexString.index(hexString.startIndex, offsetBy: i)
            let end = hexString.index(start, offsetBy: min(4, hexString.count - i))
            return String(hexString[start..<end])
        }

        return groups.joined(separator: " ").uppercased()
    }

    // MARK: - Utility

    var isReady: Bool {
        privateKey != nil && ratchet != nil && peerPublicKey != nil
    }

    private func cleanupExpiredNonces() {
        let now = Date()
        receivedNonces = receivedNonces.filter { now.timeIntervalSince($0.value) < nonceExpiryInterval }
    }

    func destroy() {
        privateKey = nil
        publicKey = nil
        peerPublicKey = nil
        ratchet?.destroy()
        ratchet = nil
        receivedNonces.removeAll()
        messageCounter = 0
        peerMessageCounter = 0
        pqSharedSecret = nil
        isPQEnabled = false
        mlkemPrivateKeyStorage = nil
        mlkemEncapsulationKeyData = nil
    }

    // MARK: - DR State Persistence (for per-contact key storage)

    /// Restore Double Ratchet from persisted state (known contacts)
    func restoreRatchet(from state: DoubleRatchetState, skippedKeys: [(dhPublicKey: Data, messageNumber: Int, messageKey: Data)]) throws {
        let dr = try DoubleRatchet(fromState: state)
        dr.importSkippedKeys(skippedKeys)
        self.ratchet = dr
    }

    /// Export current DR state for persistent storage
    func exportRatchetState() -> DoubleRatchetState? {
        ratchet?.exportState()
    }

    /// Export skipped keys for persistent storage
    func exportSkippedKeys() -> [(dhPublicKey: Data, messageNumber: Int, messageKey: Data)] {
        ratchet?.exportSkippedKeys() ?? []
    }

    /// Export message counters for replay protection persistence
    var counters: (our: Int, peer: Int) {
        (messageCounter, peerMessageCounter)
    }
}

// MARK: - Errors

enum GhostCryptoError: LocalizedError {
    case invalidKeyData
    case keysNotReady
    case sendKeyNotDerived
    case receiveKeyNotDerived
    case invalidCiphertext
    case encryptionFailed
    case decryptionFailed
    case decodingFailed
    case encodingFailed
    case replayAttack
    case messageTooOld
    case counterTooOld
    case messageTooLong
    case invalidPaddedMessage
    case incompatibleProtocolVersion

    var errorDescription: String? {
        switch self {
        case .invalidKeyData: return "Invalid key data"
        case .keysNotReady: return "Keys not ready for derivation"
        case .sendKeyNotDerived: return "Send key not derived"
        case .receiveKeyNotDerived: return "Receive key not derived"
        case .invalidCiphertext: return "Invalid ciphertext"
        case .encryptionFailed: return "Encryption failed"
        case .decryptionFailed: return "Decryption failed"
        case .decodingFailed: return "Decoding failed"
        case .encodingFailed: return "Encoding failed"
        case .replayAttack: return "Replay attack detected"
        case .messageTooOld: return "Message too old"
        case .counterTooOld: return "Counter too old"
        case .messageTooLong: return "Message too long"
        case .invalidPaddedMessage: return "Invalid padded message"
        case .incompatibleProtocolVersion: return "Incompatible protocol version"
        }
    }
}
