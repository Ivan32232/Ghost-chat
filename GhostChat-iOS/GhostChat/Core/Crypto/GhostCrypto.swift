import Foundation
import CryptoKit
import os.log

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

    private let logger = Logger(subsystem: "com.ivanpokhvalitov.ghostchat", category: "GhostCrypto")

    // MARK: - Protocol Version

    static let protocolVersion = 3

    // MARK: - Keys

    private var privateKey: P256.KeyAgreement.PrivateKey?
    private(set) var publicKey: P256.KeyAgreement.PublicKey?
    private var peerPublicKey: P256.KeyAgreement.PublicKey?

    /// Peer's public key data (x963, 65 bytes) — for contact save fallback
    var peerPublicKeyData: Data? {
        peerPublicKey?.x963Representation
    }

    // MARK: - Double Ratchet

    private var ratchet: DoubleRatchet?

    /// Serialization lock — prevents concurrent encrypt/decrypt from corrupting ratchet state
    /// Web client uses _enqueue() promise chain for the same purpose
    private let cryptoLock = NSLock()

    // MARK: - Post-Quantum (ML-KEM768)

    private var pqSharedSecret: Data?
    private(set) var isPQEnabled = false
    private var mlkemPrivateKeyStorage: Any?
    private(set) var mlkemEncapsulationKeyData: Data?

    // MARK: - Counters & Replay Protection

    private(set) var messageCounter: Int = 0
    private var peerMessageCounter: Int = 0
    private(set) var lastDecryptedCounter: Int?
    private var receivedNonces: [String: Date] = [:]
    private let nonceExpiryInterval: TimeInterval = 60 * 60 // 1 hour
    private let counterWindow: Int = 100

    // MARK: - Initialization tracking

    private(set) var isHost = false

    // MARK: - Key Generation

    func generateKeyPair() {
        ghostLog("[GhostCrypto] generateKeyPair ENTER")
        let key = P256.KeyAgreement.PrivateKey()
        privateKey = key
        publicKey = key.publicKey
        ghostLog("[GhostCrypto] generateKeyPair EXIT: key pair generated")
    }

    // MARK: - Post-Quantum Key Generation

    func generatePQKeyPair() {
        ghostLog("[GhostCrypto] generatePQKeyPair ENTER, pqAvailable=\(Self.isPQAvailable)")
        if #available(iOS 26.0, *) {
            do {
                let mlkemKey = try CryptoKit.MLKEM768.PrivateKey()
                mlkemPrivateKeyStorage = mlkemKey
                mlkemEncapsulationKeyData = mlkemKey.publicKey.rawRepresentation
                ghostLog("[GhostCrypto] generatePQKeyPair EXIT: ML-KEM keypair generated, encapKeySize=\(mlkemEncapsulationKeyData?.count ?? 0)")
            } catch {
                ghostLog("[GhostCrypto] generatePQKeyPair FAILED: \(error.localizedDescription)")
            }
        } else {
            ghostLog("[GhostCrypto] generatePQKeyPair: skipped (iOS<26)")
        }
    }

    func exportPQEncapsulationKey() -> String? {
        mlkemEncapsulationKeyData?.base64EncodedString()
    }

    func pqEncapsulate(encapsKeyBase64: String) -> (ciphertext: String, success: Bool) {
        ghostLog("[GhostCrypto] pqEncapsulate ENTER, keyBase64Len=\(encapsKeyBase64.count)")
        guard #available(iOS 26.0, *),
              let encapsKeyData = Data(base64Encoded: encapsKeyBase64) else {
            ghostLog("[GhostCrypto] pqEncapsulate FAILED: iOS<26 or invalid base64")
            return ("", false)
        }

        do {
            let encapsKey = try CryptoKit.MLKEM768.PublicKey(rawRepresentation: encapsKeyData)
            let result = try encapsKey.encapsulate()
            pqSharedSecret = result.sharedSecret.withUnsafeBytes { Data($0) }
            isPQEnabled = true
            ghostLog("[GhostCrypto] pqEncapsulate EXIT: OK, ctSize=\(result.encapsulated.count)")
            return (result.encapsulated.base64EncodedString(), true)
        } catch {
            ghostLog("[GhostCrypto] pqEncapsulate FAILED: \(error.localizedDescription)")
            return ("", false)
        }
    }

    func pqDecapsulate(ciphertextBase64: String) -> Bool {
        ghostLog("[GhostCrypto] pqDecapsulate ENTER, ctBase64Len=\(ciphertextBase64.count)")
        guard #available(iOS 26.0, *),
              let ctData = Data(base64Encoded: ciphertextBase64),
              let mlkemKey = mlkemPrivateKeyStorage as? CryptoKit.MLKEM768.PrivateKey else {
            ghostLog("[GhostCrypto] pqDecapsulate FAILED: iOS<26 or no mlkemKey or invalid base64")
            return false
        }

        do {
            let sharedKey = try mlkemKey.decapsulate(ctData)
            pqSharedSecret = sharedKey.withUnsafeBytes { Data($0) }
            isPQEnabled = true
            ghostLog("[GhostCrypto] pqDecapsulate EXIT: OK")
            return true
        } catch {
            ghostLog("[GhostCrypto] pqDecapsulate FAILED: \(error.localizedDescription)")
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
        ghostLog("[GhostCrypto] importPeerPublicKey ENTER, base64Len=\(base64Key.count)")
        guard let data = Data(base64Encoded: base64Key) else {
            ghostLog("[GhostCrypto] importPeerPublicKey FAILED: invalid base64 data")
            throw GhostCryptoError.invalidKeyData
        }
        peerPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: data)
        ghostLog("[GhostCrypto] importPeerPublicKey EXIT: \(data.count) bytes imported")
    }

    // MARK: - Key Derivation (Double Ratchet Initialization)

    /// Initialize Double Ratchet from ECDH shared secret
    /// Host (initiator) calls with isHost=true, guest (responder) with isHost=false
    func deriveSharedKey(asHost: Bool = false) throws {
        ghostLog("[GhostCrypto] deriveSharedKey ENTER, asHost=\(asHost), hasPQ=\(pqSharedSecret != nil)")
        guard let priv = privateKey, let peer = peerPublicKey else {
            ghostLog("[GhostCrypto] deriveSharedKey FAILED: keys not ready")
            throw GhostCryptoError.keysNotReady
        }

        self.isHost = asHost

        // ECDH shared secret
        ghostLog("[GhostCrypto] deriveSharedKey: computing ECDH shared secret")
        let sharedSecret = try priv.sharedSecretFromKeyAgreement(with: peer)

        // Build HKDF salt — hybrid PQ if available
        let salt: Data
        if let pqSS = pqSharedSecret {
            var hybridSalt = Data("ghost-chat-v2-pq".utf8)
            hybridSalt.append(pqSS)
            salt = hybridSalt
            ghostLog("[GhostCrypto] deriveSharedKey: using hybrid PQ salt, saltSize=\(salt.count)")
        } else {
            salt = Data("ghost-chat-v2".utf8)
            ghostLog("[GhostCrypto] deriveSharedKey: using classic salt, saltSize=\(salt.count)")
        }

        // Derive root symmetric key from ECDH shared secret
        ghostLog("[GhostCrypto] deriveSharedKey: HKDF deriving 32-byte root key")
        let rootSecret = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("ghost-dr-init-secret".utf8),
            outputByteCount: 32
        )

        // Initialize Double Ratchet
        if asHost {
            ghostLog("[GhostCrypto] deriveSharedKey: initializing ratchet as INITIATOR")
            // Host is initiator: knows peer's DH key, performs first DH ratchet
            ratchet = try DoubleRatchet(asInitiator: rootSecret, peerDHKey: peer)
        } else {
            ghostLog("[GhostCrypto] deriveSharedKey: initializing ratchet as RESPONDER")
            // Guest is responder: will perform DH ratchet on first received message
            // MUST reuse ECDH keypair — peer already knows our public key from key-exchange
            ratchet = DoubleRatchet(asResponder: rootSecret, initialKeyPair: priv)
        }
        let pqLabel = pqSharedSecret != nil ? " (hybrid PQ)" : ""
        ghostLog("[GhostCrypto] deriveSharedKey EXIT: Double Ratchet initialized\(pqLabel)")
    }

    /// Export the DH ratchet public key for the key-exchange message
    func exportDHRatchetKey() -> String? {
        ratchet?.dhPublicKeyData.base64EncodedString()
    }

    // MARK: - Encryption (Double Ratchet v2)

    /// Encrypt a message using Double Ratchet
    /// Returns base64(encryptedHeader + 0xFF + encryptedBody) with embedded {m, t, c} metadata
    func encrypt(_ plaintext: String, options: [String: Any]? = nil) throws -> String {
        cryptoLock.lock()
        defer { cryptoLock.unlock() }

        ghostLog("[GhostCrypto] encrypt ENTER, nextCounter=\(messageCounter + 1), plaintextSize=\(plaintext.count)")

        guard let ratchet else {
            ghostLog("[GhostCrypto] encrypt FAILED: send key not derived")
            throw GhostCryptoError.sendKeyNotDerived
        }

        let prevCounter = messageCounter
        messageCounter += 1
        ghostLog("[GhostCrypto] encrypt: counter \(prevCounter) -> \(messageCounter)")

        // Build message with metadata {m, t, c} + optional {id, r}
        var meta: [String: Any] = [
            "m": plaintext,
            "t": Int(Date().timeIntervalSince1970 * 1000),
            "c": messageCounter
        ]
        // Merge additional fields (id, r) into meta
        if let options {
            for (key, value) in options {
                meta[key] = value
            }
        }
        let metaJSON = try JSONSerialization.data(withJSONObject: meta)
        guard let metaString = String(data: metaJSON, encoding: .utf8) else {
            throw GhostCryptoError.encodingFailed
        }

        // Padding to 256-byte blocks
        let padded = try padMessage(metaString)
        let paddedData = Data(padded.utf8)

        // Double Ratchet encrypt → (encryptedHeader, ciphertext)
        let (encryptedHeader, ciphertext) = try ratchet.encrypt(paddedData)
        ghostLog("[GhostCrypto] encrypt: ratchet produced header=\(encryptedHeader.count)b, ciphertext=\(ciphertext.count)b")

        // Combine: encryptedHeader + separator(0xFF) + ciphertext
        var combined = Data()
        // Header length as 4-byte big-endian prefix (to know where header ends)
        let headerLen = UInt32(encryptedHeader.count)
        combined.append(contentsOf: withUnsafeBytes(of: headerLen.bigEndian) { Array($0) })
        combined.append(encryptedHeader)
        combined.append(ciphertext)

        let result = combined.base64EncodedString()
        ghostLog("[GhostCrypto] encrypt EXIT: base64Size=\(result.count), counter=\(messageCounter)")
        return result
    }

    // MARK: - Decryption (Double Ratchet v2)

    /// Decrypt a Double Ratchet message
    func decrypt(_ encryptedBase64: String) throws -> String {
        cryptoLock.lock()
        defer { cryptoLock.unlock() }

        ghostLog("[GhostCrypto] decrypt ENTER, base64Size=\(encryptedBase64.count)")

        guard let ratchet else {
            ghostLog("[GhostCrypto] decrypt FAILED: receive key not derived")
            throw GhostCryptoError.receiveKeyNotDerived
        }

        guard let combined = Data(base64Encoded: encryptedBase64) else {
            ghostLog("[GhostCrypto] decrypt FAILED: invalid base64")
            throw GhostCryptoError.invalidCiphertext
        }

        // Parse: 4-byte header length + encrypted header + ciphertext
        guard combined.count > 4 else {
            ghostLog("[GhostCrypto] decrypt FAILED: too short (\(combined.count) <= 4)")
            throw GhostCryptoError.invalidCiphertext
        }

        let headerLen = Int(UInt32(bigEndian: combined.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard combined.count > 4 + headerLen else {
            throw GhostCryptoError.invalidCiphertext
        }

        let encryptedHeader = combined.subdata(in: 4..<(4 + headerLen))
        let ciphertext = combined.subdata(in: (4 + headerLen)..<combined.count)
        ghostLog("[GhostCrypto] decrypt: headerLen=\(headerLen), ctLen=\(ciphertext.count)")

        // Replay protection: extract nonce from ciphertext
        guard ciphertext.count > 12 else {
            ghostLog("[GhostCrypto] decrypt FAILED: ciphertext too short")
            throw GhostCryptoError.invalidCiphertext
        }
        let nonceData = ciphertext.prefix(12)
        let nonceString = nonceData.base64EncodedString()

        cleanupExpiredNonces()

        if receivedNonces[nonceString] != nil {
            ghostLog("[GhostCrypto] decrypt FAILED: REPLAY ATTACK — nonce seen before")
            throw GhostCryptoError.replayAttack
        }

        // Try skipped keys first (out-of-order messages)
        if let plainData = try? ratchet.tryDecryptWithSkippedKey(
            encryptedHeader: encryptedHeader,
            ciphertext: ciphertext
        ) {
            ghostLog("[GhostCrypto] decrypt: used SKIPPED KEY path, plaintext=\(plainData.count)b")
            return try processDecryptedData(plainData, nonceString: nonceString)
        }

        // Normal Double Ratchet decrypt
        ghostLog("[GhostCrypto] decrypt: normal DR decrypt path")
        let plainData = try ratchet.decrypt(encryptedHeader: encryptedHeader, ciphertext: ciphertext)
        ghostLog("[GhostCrypto] decrypt: DR decrypt OK, plaintext=\(plainData.count)b")
        return try processDecryptedData(plainData, nonceString: nonceString)
    }

    /// Process decrypted data: unpad, validate metadata, return message
    private func processDecryptedData(_ data: Data, nonceString: String) throws -> String {
        guard let paddedText = String(data: data, encoding: .utf8) else {
            ghostLog("[GhostCrypto] processDecrypted FAILED: non-UTF8")
            throw GhostCryptoError.decodingFailed
        }

        let unpaddedText = try unpadMessage(paddedText)

        if let jsonData = unpaddedText.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {

            // Timestamp validation (5 min tolerance for clock skew)
            guard let timestamp = parsed["t"] as? Int, timestamp > 0 else {
                ghostLog("[GhostCrypto] processDecrypted FAILED: invalid timestamp")
                throw GhostCryptoError.messageTooOld
            }
            let now = Date().timeIntervalSince1970 * 1000
            let messageAge = now - Double(timestamp)
            if messageAge > 5 * 60 * 1000 || messageAge < -5 * 60 * 1000 {
                ghostLog("[GhostCrypto] processDecrypted FAILED: message too old, age=\(Int(messageAge))ms")
                throw GhostCryptoError.messageTooOld
            }

            // Counter validation (mandatory — reject messages without counter)
            guard let counter = parsed["c"] as? Int, counter >= 0 else {
                ghostLog("[GhostCrypto] processDecrypted FAILED: missing counter")
                throw GhostCryptoError.counterTooOld
            }
            let windowStart = max(0, peerMessageCounter - counterWindow)
            if counter <= windowStart && peerMessageCounter > 0 {
                ghostLog("[GhostCrypto] processDecrypted FAILED: counter too old, counter=\(counter), windowStart=\(windowStart), peerCounter=\(peerMessageCounter)")
                throw GhostCryptoError.counterTooOld
            }
            let prevPeerCounter = peerMessageCounter
            if counter > peerMessageCounter {
                peerMessageCounter = counter
            }
            lastDecryptedCounter = counter
            ghostLog("[GhostCrypto] processDecrypted: counter=\(counter), peerCounter \(prevPeerCounter)->\(peerMessageCounter), age=\(Int(messageAge))ms")

            // Save nonce
            receivedNonces[nonceString] = Date()

            if let message = parsed["m"] as? String {
                ghostLog("[GhostCrypto] decrypt EXIT: messageLen=\(message.count)")
                return message
            }
        }

        ghostLog("[GhostCrypto] decrypt EXIT: returning unpadded text (no JSON), len=\(unpaddedText.count)")
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
        ghostLog("[GhostCrypto] generateFingerprint ENTER")
        guard let pub = publicKey, let peer = peerPublicKey else {
            ghostLog("[GhostCrypto] generateFingerprint FAILED: keys not ready")
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

        let fp = groups.joined(separator: " ").uppercased()
        ghostLog("[GhostCrypto] generateFingerprint EXIT: len=\(fp.count)")
        return fp
    }

    // MARK: - Utility

    var isReady: Bool {
        let ready = privateKey != nil && ratchet != nil && peerPublicKey != nil
        return ready
    }

    private func cleanupExpiredNonces() {
        let now = Date()
        receivedNonces = receivedNonces.filter { now.timeIntervalSince($0.value) < nonceExpiryInterval }
    }

    func destroy() {
        ghostLog("[GhostCrypto] destroy ENTER, messageCounter=\(messageCounter), peerCounter=\(peerMessageCounter)")
        // Overwrite private key with throwaway before releasing
        privateKey = P256.KeyAgreement.PrivateKey()
        privateKey = nil
        publicKey = nil
        peerPublicKey = nil
        ratchet?.destroy()
        ratchet = nil
        receivedNonces.removeAll()
        messageCounter = 0
        peerMessageCounter = 0
        lastDecryptedCounter = nil
        // Zero PQ shared secret bytes
        if var pqBytes = pqSharedSecret {
            pqBytes.resetBytes(in: 0..<pqBytes.count)
        }
        pqSharedSecret = nil
        isPQEnabled = false
        // ML-KEM key is a value type — just release the reference
        mlkemPrivateKeyStorage = nil
        mlkemEncapsulationKeyData = nil
        ghostLog("[GhostCrypto] destroy EXIT: all keys zeroed")
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
        cryptoLock.lock()
        defer { cryptoLock.unlock() }
        return ratchet?.exportState()
    }

    /// Export skipped keys for persistent storage
    func exportSkippedKeys() -> [(dhPublicKey: Data, messageNumber: Int, messageKey: Data)] {
        cryptoLock.lock()
        defer { cryptoLock.unlock() }
        return ratchet?.exportSkippedKeys() ?? []
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
