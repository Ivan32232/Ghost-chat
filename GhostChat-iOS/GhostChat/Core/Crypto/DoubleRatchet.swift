import Foundation
import CryptoKit

// MARK: - Double Ratchet State Machine
// Signal Protocol style: Root chain → Sending/Receiving chain → Per-message keys
// DH Ratchet on every sender change, symmetric ratchet per message
// Header encrypted with header keys derived from root chain

/// Index for looking up skipped message keys
struct SkippedKeyIndex: Hashable {
    let dhPublicKey: Data   // Peer's DH ratchet public key that generated this chain
    let messageNumber: Int  // Message number within that chain
}

/// Double Ratchet message header
struct DRHeader {
    let dhPublicKey: Data   // Sender's current DH ratchet public key (65 bytes, x963)
    let pn: Int             // Previous chain length (messages sent in previous chain)
    let n: Int              // Message number in current chain

    func serialize() -> Data {
        // Format: dhKey(65) + pn(4 bytes big-endian) + n(4 bytes big-endian)
        var data = Data()
        data.append(dhPublicKey)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(pn).bigEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(n).bigEndian) { Array($0) })
        return data
    }

    static func deserialize(_ data: Data) throws -> DRHeader {
        // 65 (DH key) + 4 (pn) + 4 (n) = 73 bytes
        guard data.count == 73 else {
            throw DoubleRatchetError.invalidHeader
        }
        let dhKey = data.prefix(65)
        let pnBytes = data.subdata(in: 65..<69)
        let nBytes = data.subdata(in: 69..<73)

        let pn = Int(UInt32(bigEndian: pnBytes.withUnsafeBytes { $0.load(as: UInt32.self) }))
        let n = Int(UInt32(bigEndian: nBytes.withUnsafeBytes { $0.load(as: UInt32.self) }))

        return DRHeader(dhPublicKey: dhKey, pn: pn, n: n)
    }

    /// Serialize to JSON-compatible dictionary for wire format
    func toJSON() -> [String: Any] {
        [
            "dh": dhPublicKey.base64EncodedString(),
            "pn": pn,
            "n": n
        ]
    }

    static func fromJSON(_ json: [String: Any]) throws -> DRHeader {
        guard let dhBase64 = json["dh"] as? String,
              let dhData = Data(base64Encoded: dhBase64),
              dhData.count == 65,
              let pn = json["pn"] as? Int,
              let n = json["n"] as? Int else {
            throw DoubleRatchetError.invalidHeader
        }
        return DRHeader(dhPublicKey: dhData, pn: pn, n: n)
    }
}

/// Core Double Ratchet state
final class DoubleRatchet {

    // MARK: - Constants

    /// Maximum number of skipped message keys to store
    static let maxSkip = 100

    // KDF labels — must match web client exactly
    private static let rootKDFSalt = Data("ghost-dr-root".utf8)
    private static let rootKDFInfo = Data("ghost-dr-rk".utf8)
    private static let chainKDFSalt = Data("ghost-dr-chain".utf8)
    private static let chainKDFInfoCK = Data("ghost-dr-ck".utf8)
    private static let chainKDFInfoMK = Data("ghost-dr-mk".utf8)
    private static let headerKDFInfo = Data("ghost-dr-header".utf8)

    // MARK: - State

    /// Our current DH ratchet private key
    private(set) var dhSending: P256.KeyAgreement.PrivateKey

    /// Peer's current DH ratchet public key
    private(set) var dhReceiving: P256.KeyAgreement.PublicKey?

    /// Root chain key (32 bytes)
    private var rootKey: SymmetricKey

    /// Sending chain key
    private var sendChainKey: SymmetricKey?

    /// Receiving chain key
    private var receiveChainKey: SymmetricKey?

    /// Header encryption keys
    private var sendHeaderKey: SymmetricKey?
    private var receiveHeaderKey: SymmetricKey?
    private var nextSendHeaderKey: SymmetricKey?
    private var nextReceiveHeaderKey: SymmetricKey?

    /// Message counters
    private(set) var sendMessageNumber: Int = 0
    private(set) var receiveMessageNumber: Int = 0
    private(set) var previousChainLength: Int = 0

    /// Skipped message keys for out-of-order delivery
    private(set) var skippedKeys: [SkippedKeyIndex: SymmetricKey] = [:]

    // MARK: - Initialization

    /// Initialize Double Ratchet as the initiator (host/Alice)
    /// Called after initial ECDH key exchange
    /// - Parameters:
    ///   - sharedSecret: The ECDH shared secret from initial key exchange
    ///   - peerDHKey: The peer's initial DH ratchet public key (from key-exchange message)
    init(asInitiator sharedSecret: SymmetricKey, peerDHKey: P256.KeyAgreement.PublicKey) throws {
        // Generate our first DH ratchet key pair
        let dhKey = P256.KeyAgreement.PrivateKey()
        self.dhSending = dhKey
        self.dhReceiving = peerDHKey

        // Derive initial root key from shared secret
        // This establishes the root chain from ECDH
        let initialRootKey = Self.kdfRootInitial(sharedSecret: sharedSecret)

        // Perform first DH ratchet step
        let dhOutput = try dhKey.sharedSecretFromKeyAgreement(with: peerDHKey)
        let dhOutputData = dhOutput.withUnsafeBytes { Data($0) }

        // Root KDF: rootKey + DH output → new rootKey + sendChainKey + headerKeys
        let (newRootKey, chainKey, sendHK, nextRecvHK) = Self.kdfRootChain(
            rootKey: initialRootKey,
            dhOutput: dhOutputData
        )

        self.rootKey = newRootKey
        self.sendChainKey = chainKey
        self.receiveChainKey = nil
        self.sendHeaderKey = sendHK
        self.nextReceiveHeaderKey = nextRecvHK
        self.receiveHeaderKey = nil
        self.nextSendHeaderKey = nil
    }

    /// Initialize Double Ratchet as the responder (guest/Bob)
    /// Called after initial ECDH key exchange
    /// - Parameters:
    ///   - sharedSecret: The ECDH shared secret from initial key exchange
    init(asResponder sharedSecret: SymmetricKey) {
        // Generate our first DH ratchet key pair
        let dhKey = P256.KeyAgreement.PrivateKey()
        self.dhSending = dhKey
        self.dhReceiving = nil

        // Derive initial root key from shared secret
        self.rootKey = Self.kdfRootInitial(sharedSecret: sharedSecret)
        self.sendChainKey = nil
        self.receiveChainKey = nil
        self.sendHeaderKey = nil
        self.receiveHeaderKey = nil
        self.nextSendHeaderKey = nil
        self.nextReceiveHeaderKey = nil
    }

    /// Export the current DH ratchet public key (for key-exchange message)
    var dhPublicKeyData: Data {
        dhSending.publicKey.x963Representation
    }

    // MARK: - Encrypt

    /// Encrypt a plaintext message. Returns (header, ciphertext)
    /// Header is encrypted with header key, body with message key
    func encrypt(_ plaintext: Data) throws -> (encryptedHeader: Data, ciphertext: Data) {
        guard let chainKey = sendChainKey else {
            throw DoubleRatchetError.sendChainNotInitialized
        }

        // Advance sending chain: chainKey → newChainKey + messageKey
        let (newChainKey, messageKey) = Self.kdfChain(chainKey: chainKey)
        sendChainKey = newChainKey

        // Create header
        let header = DRHeader(
            dhPublicKey: dhSending.publicKey.x963Representation,
            pn: previousChainLength,
            n: sendMessageNumber
        )
        sendMessageNumber += 1

        // Encrypt body with message key
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(plaintext, using: messageKey, nonce: nonce)
        guard let ciphertext = sealedBox.combined else {
            throw DoubleRatchetError.encryptionFailed
        }

        // Always plaintext headers (0x00 prefix)
        // Header encryption disabled: avoids chicken-and-egg where responder
        // has no header key to decrypt initiator's first messages
        var encryptedHeader = Data([0x00])
        encryptedHeader.append(header.serialize())

        return (encryptedHeader, ciphertext)
    }

    // MARK: - Decrypt

    /// Decrypt a received message
    /// - Parameters:
    ///   - encryptedHeader: The encrypted header data
    ///   - ciphertext: The encrypted body data
    func decrypt(encryptedHeader: Data, ciphertext: Data) throws -> Data {
        // Try to decrypt header with current and next receive header keys
        let (header, usedNextKey) = try decryptHeader(encryptedHeader)

        // Check if this is from a new DH ratchet key
        let peerDHKeyData = header.dhPublicKey

        if dhReceiving == nil || peerDHKeyData != dhReceiving!.x963Representation {
            // New DH ratchet key from peer — skip messages in current chain, then DH ratchet
            if let recvCK = receiveChainKey {
                try skipMessageKeys(chainKey: recvCK, until: header.pn, peerDHKey: dhReceiving?.x963Representation)
            }
            try dhRatchetReceive(peerDHKeyData: peerDHKeyData, usedNextHeaderKey: usedNextKey)
        }

        // Skip missed messages in current receiving chain
        guard let recvCK = receiveChainKey else {
            throw DoubleRatchetError.receiveChainNotInitialized
        }
        try skipMessageKeys(chainKey: recvCK, until: header.n, peerDHKey: peerDHKeyData)

        // Advance receiving chain
        let (newChainKey, messageKey) = Self.kdfChain(chainKey: receiveChainKey!)
        receiveChainKey = newChainKey
        receiveMessageNumber = header.n + 1

        // Decrypt body
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(sealedBox, using: messageKey)
    }

    /// Try to decrypt with a stored skipped key first
    func tryDecryptWithSkippedKey(encryptedHeader: Data, ciphertext: Data) throws -> Data? {
        let header: DRHeader
        do {
            let (h, _) = try decryptHeader(encryptedHeader)
            header = h
        } catch {
            return nil
        }

        let index = SkippedKeyIndex(dhPublicKey: header.dhPublicKey, messageNumber: header.n)
        guard let messageKey = skippedKeys[index] else { return nil }

        skippedKeys.removeValue(forKey: index)

        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(sealedBox, using: messageKey)
    }

    // MARK: - DH Ratchet

    private func dhRatchetReceive(peerDHKeyData: Data, usedNextHeaderKey: Bool) throws {
        let peerDHKey = try P256.KeyAgreement.PublicKey(x963Representation: peerDHKeyData)

        previousChainLength = sendMessageNumber
        sendMessageNumber = 0
        receiveMessageNumber = 0
        dhReceiving = peerDHKey

        // Update header keys
        if usedNextHeaderKey {
            receiveHeaderKey = nextReceiveHeaderKey
        }

        // DH with our current key and new peer key → update receive chain
        let dhOutputRecv = try dhSending.sharedSecretFromKeyAgreement(with: peerDHKey)
        let dhOutputRecvData = dhOutputRecv.withUnsafeBytes { Data($0) }
        let (rk1, recvCK, _, nextRecvHK) = Self.kdfRootChain(rootKey: rootKey, dhOutput: dhOutputRecvData)
        rootKey = rk1
        receiveChainKey = recvCK
        nextReceiveHeaderKey = nextRecvHK

        // Generate new DH key pair
        dhSending = P256.KeyAgreement.PrivateKey()

        // DH with new key and peer key → update send chain
        let dhOutputSend = try dhSending.sharedSecretFromKeyAgreement(with: peerDHKey)
        let dhOutputSendData = dhOutputSend.withUnsafeBytes { Data($0) }
        let (rk2, sendCK, sendHK, nextSendHK) = Self.kdfRootChain(rootKey: rootKey, dhOutput: dhOutputSendData)
        rootKey = rk2
        sendChainKey = sendCK
        sendHeaderKey = sendHK
        nextSendHeaderKey = nextSendHK
    }

    // MARK: - Header Encryption / Decryption

    private func decryptHeader(_ encryptedHeader: Data) throws -> (DRHeader, Bool) {
        // Check if plaintext header (prefix 0x00)
        if encryptedHeader.first == 0x00 && encryptedHeader.count == 74 { // 1 + 73
            let headerData = encryptedHeader.dropFirst()
            return (try DRHeader.deserialize(Data(headerData)), false)
        }

        // Try current receive header key
        if let rhk = receiveHeaderKey {
            if let header = try? decryptHeaderWithKey(encryptedHeader, key: rhk) {
                return (header, false)
            }
        }

        // Try next receive header key
        if let nrhk = nextReceiveHeaderKey {
            if let header = try? decryptHeaderWithKey(encryptedHeader, key: nrhk) {
                return (header, true)
            }
        }

        throw DoubleRatchetError.headerDecryptionFailed
    }

    private func decryptHeaderWithKey(_ data: Data, key: SymmetricKey) throws -> DRHeader {
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        let headerData = try AES.GCM.open(sealedBox, using: key)
        return try DRHeader.deserialize(headerData)
    }

    // MARK: - Skipped Keys

    private func skipMessageKeys(chainKey: SymmetricKey, until targetN: Int, peerDHKey: Data?) throws {
        guard let dhKey = peerDHKey else { return }

        var currentCK = chainKey
        var currentN = receiveMessageNumber

        guard targetN - currentN <= Self.maxSkip else {
            throw DoubleRatchetError.tooManySkippedMessages
        }

        while currentN < targetN {
            let (newCK, messageKey) = Self.kdfChain(chainKey: currentCK)
            let index = SkippedKeyIndex(dhPublicKey: dhKey, messageNumber: currentN)
            skippedKeys[index] = messageKey
            currentCK = newCK
            currentN += 1
        }

        receiveChainKey = currentCK
        receiveMessageNumber = currentN

        // Enforce max skip limit by removing oldest
        while skippedKeys.count > Self.maxSkip {
            // Remove arbitrary oldest entry
            if let firstKey = skippedKeys.keys.first {
                skippedKeys.removeValue(forKey: firstKey)
            }
        }
    }

    // MARK: - KDF Functions

    /// Initial root key derivation from ECDH shared secret
    private static func kdfRootInitial(sharedSecret: SymmetricKey) -> SymmetricKey {
        let ikm = sharedSecret
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: rootKDFSalt,
            info: Data("ghost-dr-init".utf8),
            outputByteCount: 32
        )
    }

    /// Root chain KDF: (rootKey, dhOutput) → (newRootKey, chainKey, headerKey, nextHeaderKey)
    private static func kdfRootChain(
        rootKey: SymmetricKey,
        dhOutput: Data
    ) -> (rootKey: SymmetricKey, chainKey: SymmetricKey, headerKey: SymmetricKey, nextHeaderKey: SymmetricKey) {
        // Combine root key and DH output
        let rootKeyData = rootKey.withUnsafeBytes { Data($0) }
        var ikm = Data()
        ikm.append(rootKeyData)
        ikm.append(dhOutput)

        // Derive 128 bytes: 32 (rootKey) + 32 (chainKey) + 32 (headerKey) + 32 (nextHeaderKey)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: rootKDFSalt,
            info: rootKDFInfo,
            outputByteCount: 128
        )

        let derivedData = derived.withUnsafeBytes { Data($0) }
        let newRootKey = SymmetricKey(data: derivedData[0..<32])
        let chainKey = SymmetricKey(data: derivedData[32..<64])
        let headerKey = SymmetricKey(data: derivedData[64..<96])
        let nextHeaderKey = SymmetricKey(data: derivedData[96..<128])

        return (newRootKey, chainKey, headerKey, nextHeaderKey)
    }

    /// Symmetric chain KDF: chainKey → (newChainKey, messageKey)
    private static func kdfChain(chainKey: SymmetricKey) -> (chainKey: SymmetricKey, messageKey: SymmetricKey) {
        let ckData = chainKey.withUnsafeBytes { Data($0) }

        let newChainKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ckData),
            salt: chainKDFSalt,
            info: chainKDFInfoCK,
            outputByteCount: 32
        )

        let messageKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ckData),
            salt: chainKDFSalt,
            info: chainKDFInfoMK,
            outputByteCount: 32
        )

        return (newChainKey, messageKey)
    }

    // MARK: - State Serialization

    /// Restore Double Ratchet from persisted state
    init(fromState s: DoubleRatchetState) throws {
        self.dhSending = try P256.KeyAgreement.PrivateKey(rawRepresentation: s.dhSendingPrivateKey)
        self.dhReceiving = try s.dhReceivingPublicKey.map {
            try P256.KeyAgreement.PublicKey(x963Representation: $0)
        }
        self.rootKey = SymmetricKey(data: s.rootKey)
        self.sendChainKey = s.sendChainKey.map { SymmetricKey(data: $0) }
        self.receiveChainKey = s.receiveChainKey.map { SymmetricKey(data: $0) }
        self.sendHeaderKey = s.sendHeaderKey.map { SymmetricKey(data: $0) }
        self.receiveHeaderKey = s.receiveHeaderKey.map { SymmetricKey(data: $0) }
        self.nextSendHeaderKey = s.nextSendHeaderKey.map { SymmetricKey(data: $0) }
        self.nextReceiveHeaderKey = s.nextReceiveHeaderKey.map { SymmetricKey(data: $0) }
        self.sendMessageNumber = s.sendMessageNumber
        self.receiveMessageNumber = s.receiveMessageNumber
        self.previousChainLength = s.previousChainLength
    }

    /// Export current state as serializable snapshot
    func exportState() -> DoubleRatchetState {
        DoubleRatchetState(
            dhSendingPrivateKey: dhSending.rawRepresentation,
            dhReceivingPublicKey: dhReceiving?.x963Representation,
            rootKey: rootKey.withUnsafeBytes { Data($0) },
            sendChainKey: sendChainKey.map { $0.withUnsafeBytes { Data($0) } },
            receiveChainKey: receiveChainKey.map { $0.withUnsafeBytes { Data($0) } },
            sendHeaderKey: sendHeaderKey.map { $0.withUnsafeBytes { Data($0) } },
            receiveHeaderKey: receiveHeaderKey.map { $0.withUnsafeBytes { Data($0) } },
            nextSendHeaderKey: nextSendHeaderKey.map { $0.withUnsafeBytes { Data($0) } },
            nextReceiveHeaderKey: nextReceiveHeaderKey.map { $0.withUnsafeBytes { Data($0) } },
            sendMessageNumber: sendMessageNumber,
            receiveMessageNumber: receiveMessageNumber,
            previousChainLength: previousChainLength
        )
    }

    /// Export skipped keys for per-contact persistent storage
    func exportSkippedKeys() -> [(dhPublicKey: Data, messageNumber: Int, messageKey: Data)] {
        skippedKeys.map { (index, key) in
            (index.dhPublicKey, index.messageNumber, key.withUnsafeBytes { Data($0) })
        }
    }

    /// Import skipped keys from persistent storage
    func importSkippedKeys(_ keys: [(dhPublicKey: Data, messageNumber: Int, messageKey: Data)]) {
        for entry in keys {
            let index = SkippedKeyIndex(dhPublicKey: entry.dhPublicKey, messageNumber: entry.messageNumber)
            skippedKeys[index] = SymmetricKey(data: entry.messageKey)
        }
    }

    // MARK: - Cleanup

    /// Securely destroy all key material
    func destroy() {
        skippedKeys.removeAll()
        sendChainKey = nil
        receiveChainKey = nil
        sendHeaderKey = nil
        receiveHeaderKey = nil
        nextSendHeaderKey = nil
        nextReceiveHeaderKey = nil
        dhReceiving = nil
    }
}

// MARK: - Serializable DR State

/// Snapshot of the full Double Ratchet state for persistence in SQLCipher
struct DoubleRatchetState: Codable {
    let dhSendingPrivateKey: Data       // 32 bytes (P-256 raw representation)
    let dhReceivingPublicKey: Data?     // 65 bytes (x963) or nil
    let rootKey: Data                   // 32 bytes
    let sendChainKey: Data?
    let receiveChainKey: Data?
    let sendHeaderKey: Data?
    let receiveHeaderKey: Data?
    let nextSendHeaderKey: Data?
    let nextReceiveHeaderKey: Data?
    let sendMessageNumber: Int
    let receiveMessageNumber: Int
    let previousChainLength: Int
}

// MARK: - Errors

enum DoubleRatchetError: LocalizedError {
    case sendChainNotInitialized
    case receiveChainNotInitialized
    case invalidHeader
    case headerDecryptionFailed
    case encryptionFailed
    case decryptionFailed
    case tooManySkippedMessages
    case invalidPeerKey

    var errorDescription: String? {
        switch self {
        case .sendChainNotInitialized: return "Send chain not initialized"
        case .receiveChainNotInitialized: return "Receive chain not initialized"
        case .invalidHeader: return "Invalid DR header"
        case .headerDecryptionFailed: return "Header decryption failed"
        case .encryptionFailed: return "DR encryption failed"
        case .decryptionFailed: return "DR decryption failed"
        case .tooManySkippedMessages: return "Too many skipped messages"
        case .invalidPeerKey: return "Invalid peer DH key"
        }
    }
}
