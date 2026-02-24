import Foundation
import CryptoKit

/// Полный порт crypto.js — E2E шифрование Ghost Chat
/// ECDH P-256 → HKDF → AES-256-GCM с двунаправленными ключами
///
/// Совместимость с веб-клиентом:
/// - Тот же ECDH P-256 key agreement
/// - Тот же HKDF salt ("ghost-chat-v1") и info ("ghost-first-to-second"/"ghost-second-to-first")
/// - Тот же AES-256-GCM с 12-byte IV
/// - Тот же padding (256-byte blocks)
/// - Тот же PFS rotation (SHA-256 → HKDF с salt "ghost-pfs-rotation")
final class GhostCrypto {

    // MARK: - Keys

    private var privateKey: P256.KeyAgreement.PrivateKey?
    private(set) var publicKey: P256.KeyAgreement.PublicKey?
    private var peerPublicKey: P256.KeyAgreement.PublicKey?

    /// Двунаправленные ключи для корректного PFS
    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?

    // MARK: - Counters & Replay Protection

    private(set) var messageCounter: Int = 0
    private var peerMessageCounter: Int = 0
    private var receivedNonces: [String: Date] = [:]
    private let nonceExpiryInterval: TimeInterval = 5 * 60 // 5 минут
    private let counterWindow: Int = 100

    // MARK: - PFS Key Rotation

    private var sendKeyRotations: Int = 0
    private var receiveKeyRotations: Int = 0
    private let keyRotationInterval: Int = 50
    private var previousReceiveKeys: [SymmetricKey] = []
    private let maxPreviousKeys: Int = 2

    // MARK: - Key Generation

    func generateKeyPair() {
        let key = P256.KeyAgreement.PrivateKey()
        privateKey = key
        publicKey = key.publicKey
    }

    /// Экспорт публичного ключа в base64 (raw P-256 uncompressed, 65 bytes)
    /// Совместим с Web Crypto API exportKey('raw')
    func exportPublicKey() -> String? {
        guard let pub = publicKey else { return nil }
        // x963Representation = 04 || x || y (65 bytes) — тот же формат что Web Crypto 'raw'
        return pub.x963Representation.base64EncodedString()
    }

    /// Импорт публичного ключа собеседника из base64 (raw format)
    func importPeerPublicKey(_ base64Key: String) throws {
        guard let data = Data(base64Encoded: base64Key) else {
            throw GhostCryptoError.invalidKeyData
        }
        peerPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: data)
    }

    // MARK: - Key Derivation

    /// Деривация двунаправленных ключей — порт deriveSharedKey()
    /// Детерминистически определяет порядок по raw-байтам публичных ключей
    func deriveSharedKey() throws {
        guard let priv = privateKey, let peer = peerPublicKey, let pub = publicKey else {
            throw GhostCryptoError.keysNotReady
        }

        // ECDH shared secret
        let sharedSecret = try priv.sharedSecretFromKeyAgreement(with: peer)

        // Определяем порядок ключей детерминистически (как в JS)
        let ourKeyRaw = [UInt8](pub.x963Representation)
        let peerKeyRaw = [UInt8](peer.x963Representation)

        var weAreFirst = false
        for i in 0..<min(ourKeyRaw.count, peerKeyRaw.count) {
            if ourKeyRaw[i] < peerKeyRaw[i] { weAreFirst = true; break }
            if ourKeyRaw[i] > peerKeyRaw[i] { weAreFirst = false; break }
        }

        // Деривация двух направленных ключей через HKDF
        let salt = Data("ghost-chat-v1".utf8)

        let keyFirstToSecond = deriveDirectionalKey(
            sharedSecret: sharedSecret,
            salt: salt,
            info: Data("ghost-first-to-second".utf8)
        )
        let keySecondToFirst = deriveDirectionalKey(
            sharedSecret: sharedSecret,
            salt: salt,
            info: Data("ghost-second-to-first".utf8)
        )

        sendKey = weAreFirst ? keyFirstToSecond : keySecondToFirst
        receiveKey = weAreFirst ? keySecondToFirst : keyFirstToSecond
    }

    private func deriveDirectionalKey(
        sharedSecret: SharedSecret,
        salt: Data,
        info: Data
    ) -> SymmetricKey {
        // HKDF-SHA256, 256-bit output — совместимо с Web Crypto deriveKey AES-GCM 256
        sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: 32
        )
    }

    // MARK: - Encryption

    /// Шифрование сообщения — порт encrypt()
    /// Возвращает base64(IV + ciphertext + tag)
    func encrypt(_ plaintext: String) throws -> String {
        guard let key = sendKey else {
            throw GhostCryptoError.sendKeyNotDerived
        }

        messageCounter += 1

        // Формируем JSON с метаданными {m, t, c} — как в JS
        let meta: [String: Any] = [
            "m": plaintext,
            "t": Int(Date().timeIntervalSince1970 * 1000), // JS Date.now() = milliseconds
            "c": messageCounter
        ]
        let metaJSON = try JSONSerialization.data(withJSONObject: meta)
        guard let metaString = String(data: metaJSON, encoding: .utf8) else {
            throw GhostCryptoError.encodingFailed
        }

        // Padding до 256-byte блоков
        let padded = try padMessage(metaString)
        let paddedData = Data(padded.utf8)

        // AES-256-GCM с 12-byte nonce
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(paddedData, using: key, nonce: nonce)

        // Формат: IV (12) + ciphertext + tag (16) — совместимо с Web Crypto
        // sealedBox.combined = nonce + ciphertext + tag
        guard let combined = sealedBox.combined else {
            throw GhostCryptoError.encryptionFailed
        }

        // PFS: ротация ПОСЛЕ шифрования
        if messageCounter % keyRotationInterval == 0 {
            try rotateSendKey()
        }

        return combined.base64EncodedString()
    }

    // MARK: - Decryption

    /// Дешифрование — порт decrypt()
    /// Принимает base64(IV + ciphertext + tag)
    func decrypt(_ encryptedBase64: String) throws -> String {
        guard let key = receiveKey else {
            throw GhostCryptoError.receiveKeyNotDerived
        }

        guard let combined = Data(base64Encoded: encryptedBase64) else {
            throw GhostCryptoError.invalidCiphertext
        }

        // Извлекаем nonce (первые 12 байт) для replay protection
        guard combined.count > 12 else {
            throw GhostCryptoError.invalidCiphertext
        }
        let nonceData = combined.prefix(12)
        let nonceString = nonceData.base64EncodedString()

        // Очистка expired nonces
        cleanupExpiredNonces()

        if receivedNonces[nonceString] != nil {
            throw GhostCryptoError.replayAttack
        }

        // Пробуем текущий ключ, затем предыдущие
        var decryptedData: Data?

        if let result = try? decryptWithKey(combined, key: key) {
            decryptedData = result
        } else {
            for prevKey in previousReceiveKeys.reversed() {
                if let result = try? decryptWithKey(combined, key: prevKey) {
                    decryptedData = result
                    break
                }
            }
        }

        guard let data = decryptedData else {
            throw GhostCryptoError.decryptionFailed
        }

        guard let paddedText = String(data: data, encoding: .utf8) else {
            throw GhostCryptoError.decodingFailed
        }

        // Удаляем padding
        let unpaddedText = try unpadMessage(paddedText)

        // Парсим метаданные
        if let jsonData = unpaddedText.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {

            // Проверяем timestamp (не старше 5 минут)
            if let timestamp = parsed["t"] as? Int {
                let messageAge = Date().timeIntervalSince1970 * 1000 - Double(timestamp)
                if messageAge > 5 * 60 * 1000 {
                    throw GhostCryptoError.messageTooOld
                }
            }

            // Проверяем counter
            if let counter = parsed["c"] as? Int {
                if counter <= peerMessageCounter - counterWindow {
                    throw GhostCryptoError.counterTooOld
                }
                if counter > peerMessageCounter {
                    peerMessageCounter = counter
                }
            }

            // Сохраняем nonce
            receivedNonces[nonceString] = Date()

            // PFS: ротация receiveKey по счётчику отправителя
            if let counter = parsed["c"] as? Int,
               counter > 0,
               counter % keyRotationInterval == 0 {
                try rotateReceiveKey()
            }

            if let message = parsed["m"] as? String {
                return message
            }
        }

        return unpaddedText
    }

    private func decryptWithKey(_ combined: Data, key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(sealedBox, using: key)
    }

    // MARK: - Message Padding

    /// Padding сообщения до блоков по 256 символов — порт padMessage()
    /// Формат: длина(4 символа) + base64(сообщение) + рандомный padding
    func padMessage(_ message: String, blockSize: Int = 256) throws -> String {
        let base64Message = Data(message.utf8).base64EncodedString()
        let messageLength = base64Message.count

        guard messageLength <= 9999 else {
            throw GhostCryptoError.messageTooLong
        }

        let paddedLength = ((messageLength + 4 + blockSize - 1) / blockSize) * blockSize
        let paddingLength = paddedLength - messageLength - 4

        // Криптостойкий random padding
        let paddingChars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var randomBytes = [UInt8](repeating: 0, count: paddingLength)
        _ = SecRandomCopyBytes(kSecRandomDefault, paddingLength, &randomBytes)

        let padding = String(randomBytes.map { paddingChars[Int($0) % paddingChars.count] })
        let lengthPrefix = String(format: "%04d", messageLength)

        return lengthPrefix + base64Message + padding
    }

    /// Удаление padding — порт unpadMessage()
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

    // MARK: - PFS Key Rotation

    /// Ротация sendKey — порт _rotateSendKey()
    /// SHA-256(старый ключ) → HKDF → новый AES-256-GCM ключ
    private func rotateSendKey() throws {
        guard let key = sendKey else { return }
        sendKey = try rotateKeyInternal(key)
        sendKeyRotations += 1
    }

    /// Ротация receiveKey — порт _rotateReceiveKey()
    private func rotateReceiveKey() throws {
        guard let key = receiveKey else { return }

        previousReceiveKeys.append(key)
        if previousReceiveKeys.count > maxPreviousKeys {
            previousReceiveKeys.removeFirst()
        }

        receiveKey = try rotateKeyInternal(key)
        receiveKeyRotations += 1
    }

    /// Общая логика ротации — порт _rotateKeyInternal()
    private func rotateKeyInternal(_ key: SymmetricKey) throws -> SymmetricKey {
        // SHA-256(старый ключ material)
        let keyData = key.withUnsafeBytes { Data($0) }
        let hash = SHA256.hash(data: keyData)
        let hashData = Data(hash)

        // HKDF с salt "ghost-pfs-rotation" и info "key-rotation"
        let salt = Data("ghost-pfs-rotation".utf8)
        let info = Data("key-rotation".utf8)

        let newKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: hashData),
            salt: salt,
            info: info,
            outputByteCount: 32
        )

        return newKey
    }

    // MARK: - Fingerprint

    /// Safety Number — порт generateFingerprint()
    /// SHA-256(sorted(pubkey1 || pubkey2)) → hex → groups of 4
    func generateFingerprint() throws -> String {
        guard let pub = publicKey, let peer = peerPublicKey else {
            throw GhostCryptoError.keysNotReady
        }

        let ourKeyRaw = [UInt8](pub.x963Representation)
        let peerKeyRaw = [UInt8](peer.x963Representation)

        // Сортируем для консистентности (как в JS)
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

        // Первые 16 байт → hex → группы по 4 → uppercase
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
        privateKey != nil && sendKey != nil && receiveKey != nil && peerPublicKey != nil
    }

    private func cleanupExpiredNonces() {
        let now = Date()
        receivedNonces = receivedNonces.filter { now.timeIntervalSince($0.value) < nonceExpiryInterval }
    }

    /// Полная очистка всех ключей из памяти
    func destroy() {
        privateKey = nil
        publicKey = nil
        peerPublicKey = nil
        sendKey = nil
        receiveKey = nil
        previousReceiveKeys.removeAll()
        receivedNonces.removeAll()
        messageCounter = 0
        peerMessageCounter = 0
        sendKeyRotations = 0
        receiveKeyRotations = 0
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
        }
    }
}
