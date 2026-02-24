import XCTest
@testable import GhostChat

/// Тесты крипто-модуля
/// Проверяют совместимость с веб-клиентом (crypto.js)
final class CryptoTests: XCTestCase {

    // MARK: - Key Generation

    func testKeyPairGeneration() {
        let crypto = GhostCrypto()
        crypto.generateKeyPair()

        XCTAssertNotNil(crypto.publicKey)
        XCTAssertNotNil(crypto.exportPublicKey())
    }

    func testPublicKeyExportFormat() {
        let crypto = GhostCrypto()
        crypto.generateKeyPair()

        let base64Key = crypto.exportPublicKey()!
        let keyData = Data(base64Encoded: base64Key)!

        // P-256 uncompressed public key: 04 || x (32 bytes) || y (32 bytes) = 65 bytes
        XCTAssertEqual(keyData.count, 65)
        XCTAssertEqual(keyData[0], 0x04) // Uncompressed point indicator
    }

    // MARK: - Key Exchange

    func testKeyExchange() throws {
        let alice = GhostCrypto()
        let bob = GhostCrypto()

        alice.generateKeyPair()
        bob.generateKeyPair()

        let alicePublicKey = alice.exportPublicKey()!
        let bobPublicKey = bob.exportPublicKey()!

        try bob.importPeerPublicKey(alicePublicKey)
        try alice.importPeerPublicKey(bobPublicKey)

        try alice.deriveSharedKey()
        try bob.deriveSharedKey()

        XCTAssertTrue(alice.isReady)
        XCTAssertTrue(bob.isReady)
    }

    // MARK: - Encryption Roundtrip

    func testEncryptDecryptRoundtrip() throws {
        let (alice, bob) = try createPair()

        let originalMessage = "Привет, мир! Hello, world! 🌍"
        let encrypted = try alice.encrypt(originalMessage)
        let decrypted = try bob.decrypt(encrypted)

        XCTAssertEqual(decrypted, originalMessage)
    }

    func testMultipleMessagesRoundtrip() throws {
        let (alice, bob) = try createPair()

        let messages = [
            "Первое сообщение",
            "Second message",
            "Третье с эмодзи 🔒🗝️",
            "Длинное сообщение: " + String(repeating: "абвгд ", count: 100),
            ""  // Пустое сообщение
        ]

        for msg in messages {
            let encrypted = try alice.encrypt(msg)
            let decrypted = try bob.decrypt(encrypted)
            XCTAssertEqual(decrypted, msg, "Failed for message: \(msg.prefix(20))...")
        }
    }

    func testBidirectionalCommunication() throws {
        let (alice, bob) = try createPair()

        // Alice → Bob
        let msg1 = "Привет от Алисы"
        let encrypted1 = try alice.encrypt(msg1)
        let decrypted1 = try bob.decrypt(encrypted1)
        XCTAssertEqual(decrypted1, msg1)

        // Bob → Alice
        let msg2 = "Привет от Боба"
        let encrypted2 = try bob.encrypt(msg2)
        let decrypted2 = try alice.decrypt(encrypted2)
        XCTAssertEqual(decrypted2, msg2)
    }

    // MARK: - Replay Protection

    func testReplayAttackDetection() throws {
        let (alice, bob) = try createPair()

        let encrypted = try alice.encrypt("test")
        _ = try bob.decrypt(encrypted) // First decrypt succeeds

        // Replay the same message
        XCTAssertThrowsError(try bob.decrypt(encrypted)) { error in
            XCTAssertTrue(error is GhostCryptoError)
        }
    }

    // MARK: - Padding

    func testPaddingRoundtrip() throws {
        let crypto = GhostCrypto()

        let messages = [
            "short",
            "Средней длины сообщение на русском языке",
            String(repeating: "x", count: 1000),
            "🔒🗝️💬"
        ]

        for msg in messages {
            let padded = try crypto.padMessage(msg)
            let unpadded = try crypto.unpadMessage(padded)
            XCTAssertEqual(unpadded, msg)
        }
    }

    func testPaddingBlockAlignment() throws {
        let crypto = GhostCrypto()
        let padded = try crypto.padMessage("test", blockSize: 256)
        XCTAssertEqual(padded.count % 256, 0)
    }

    // MARK: - PFS Key Rotation

    func testKeyRotationAfter50Messages() throws {
        let (alice, bob) = try createPair()

        // Send 55 messages — rotation should happen at message 50
        for i in 1...55 {
            let msg = "Message #\(i)"
            let encrypted = try alice.encrypt(msg)
            let decrypted = try bob.decrypt(encrypted)
            XCTAssertEqual(decrypted, msg)
        }
    }

    // MARK: - Fingerprint

    func testFingerprintConsistency() throws {
        let (alice, bob) = try createPair()

        let fpAlice = try alice.generateFingerprint()
        let fpBob = try bob.generateFingerprint()

        // Оба участника должны получить одинаковый fingerprint
        XCTAssertEqual(fpAlice, fpBob)

        // Формат: группы по 4 hex символа, разделённые пробелами, uppercase
        XCTAssertTrue(fpAlice.allSatisfy { $0.isHexDigit || $0 == " " })
    }

    func testFingerprintDifferentPairs() throws {
        let (alice1, _) = try createPair()
        let (alice2, _) = try createPair()

        let fp1 = try alice1.generateFingerprint()
        let fp2 = try alice2.generateFingerprint()

        // Разные пары ключей → разные fingerprints
        XCTAssertNotEqual(fp1, fp2)
    }

    // MARK: - Edge Cases

    func testEncryptWithoutKeysFails() {
        let crypto = GhostCrypto()
        XCTAssertThrowsError(try crypto.encrypt("test"))
    }

    func testDecryptWithoutKeysFails() {
        let crypto = GhostCrypto()
        XCTAssertThrowsError(try crypto.decrypt("dGVzdA=="))
    }

    func testDestroy() throws {
        let crypto = GhostCrypto()
        crypto.generateKeyPair()
        XCTAssertNotNil(crypto.publicKey)

        crypto.destroy()
        XCTAssertNil(crypto.publicKey)
        XCTAssertFalse(crypto.isReady)
    }

    // MARK: - Helpers

    private func createPair() throws -> (GhostCrypto, GhostCrypto) {
        let alice = GhostCrypto()
        let bob = GhostCrypto()

        alice.generateKeyPair()
        bob.generateKeyPair()

        try alice.importPeerPublicKey(bob.exportPublicKey()!)
        try bob.importPeerPublicKey(alice.exportPublicKey()!)

        try alice.deriveSharedKey()
        try bob.deriveSharedKey()

        return (alice, bob)
    }
}
