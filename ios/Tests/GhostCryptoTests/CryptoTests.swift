import XCTest
import CryptoKit
import Foundation
@testable import GhostCrypto

// MARK: - Test Vector Loading

struct TestVectors: Decodable {
    let ecdh: ECDHVectors
    let initialRootKey: InitialRootKeyVectors
    let rootKDF: RootKDFVectors
    let chainKDF: ChainKDFVectors
    let aesGcm: AESGCMVectors
    let messagePadding: MessagePaddingVectors
    let wireFormat: WireFormatVectors
    let safetyNumber: SafetyNumberVectors
    let session: SessionVectors
}

struct ECDHVectors: Decodable {
    let alice: KeyPairVector
    let bob: KeyPairVector
    let sharedSecret: String
}

struct KeyPairVector: Decodable {
    let privateKey: String
    let publicKey: String
    let publicKeyRaw: String
}

struct InitialRootKeyVectors: Decodable {
    let ikm: String
    let salt: String
    let info: String
    let length: Int
    let rootKey: String
}

struct RootKDFVectors: Decodable {
    let rootKey: String
    let dhOutput: String
    let newRootKey: String
    let chainKey: String
    let hostRatchetPublicKey: String
    let hostRatchetPublicKeyRaw: String
    let hostRatchetPrivateKey: String
}

struct ChainKDFVectors: Decodable {
    let chainKey: String
    let messageKey0: String
    let nextChainKey0: String
    let messageKey1: String
    let nextChainKey1: String
}

struct AESGCMVectors: Decodable {
    let key: String
    let nonce: String
    let plaintext: String
    let plaintextUtf8: String
    let aad: String
    let ciphertext: String
    let tag: String
}

struct MessagePaddingVectors: Decodable {
    let input: String
    let inputBase64: String
    let paddedHex: String
    let paddedLength: Int
    let isMultipleOf256: Bool
}

struct WireFormatVectors: Decodable {
    let headerVersion: Int
    let dhPublicKeyRaw: String
    let pn: Int
    let n: Int
    let headerHex: String
    let headerLength: Int
    let nonce: String
    let ciphertext: String
    let tag: String
    let wireMessageHex: String
    let wireMessageBase64: String
    let wireMessageLength: Int
}

struct SafetyNumberVectors: Decodable {
    let identityKeyA: String
    let identityKeyB: String
    let fingerprint: String
}

struct SessionVectors: Decodable {
    let hostEphemeralPrivateKey: String
    let hostEphemeralPublicKey: String
    let guestEphemeralPrivateKey: String
    let guestEphemeralPublicKey: String
    let sharedSecret: String
    let initialRootKey: String
    let ratchetKeypairs: [KeyPairVector]
    let messages: [SessionMessage]
}

struct SessionMessage: Decodable {
    let sender: String
    let index: Int
    let messageJson: String
    let paddedHex: String
    let messageKey: String
    let nonce: String
    let headerHex: String
    let ciphertextHex: String
    let tagHex: String
    let wireBase64: String
}

// Hex helpers come from GhostCrypto.Extensions

// MARK: - Tests

final class CryptoTests: XCTestCase {

    static var vectors: TestVectors!

    override class func setUp() {
        super.setUp()
        let url = Bundle.module.url(forResource: "test-vectors", withExtension: "json")!
        let data = try! Data(contentsOf: url)
        vectors = try! JSONDecoder().decode(TestVectors.self, from: data)
    }

    var v: TestVectors { Self.vectors }

    // MARK: - 1. ECDH Key Exchange

    func testECDHSharedSecret() throws {
        let alicePrivData = Data(hex: v.ecdh.alice.privateKey)!
        let bobPubData = Data(hex: v.ecdh.bob.publicKey)!

        let alicePrivKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: alicePrivData)
        let bobPubKey = try P256.KeyAgreement.PublicKey(x963Representation: bobPubData)

        let shared = try alicePrivKey.sharedSecretFromKeyAgreement(with: bobPubKey)
        let sharedData = shared.rawData

        XCTAssertEqual(sharedData.hexString, v.ecdh.sharedSecret,
                       "ECDH shared secret mismatch")
    }

    func testECDHSymmetry() throws {
        let alicePrivData = Data(hex: v.ecdh.alice.privateKey)!
        let bobPrivData = Data(hex: v.ecdh.bob.privateKey)!
        let alicePubData = Data(hex: v.ecdh.alice.publicKey)!
        let bobPubData = Data(hex: v.ecdh.bob.publicKey)!

        let alicePriv = try P256.KeyAgreement.PrivateKey(rawRepresentation: alicePrivData)
        let bobPriv = try P256.KeyAgreement.PrivateKey(rawRepresentation: bobPrivData)
        let alicePub = try P256.KeyAgreement.PublicKey(x963Representation: alicePubData)
        let bobPub = try P256.KeyAgreement.PublicKey(x963Representation: bobPubData)

        let shared1 = try alicePriv.sharedSecretFromKeyAgreement(with: bobPub)
        let shared2 = try bobPriv.sharedSecretFromKeyAgreement(with: alicePub)

        let d1 = shared1.rawData
        let d2 = shared2.rawData
        XCTAssertEqual(d1, d2, "ECDH must be symmetric")
    }

    func testPublicKeyDerivation() throws {
        let alicePrivData = Data(hex: v.ecdh.alice.privateKey)!
        let alicePriv = try P256.KeyAgreement.PrivateKey(rawRepresentation: alicePrivData)
        let pubHex = alicePriv.publicKey.x963Representation.hexString
        XCTAssertEqual(pubHex, v.ecdh.alice.publicKey,
                       "Public key derivation mismatch")
    }

    // MARK: - 2. Initial Root Key (HKDF)

    func testInitialRootKeyDerivation() throws {
        let ikm = Data(hex: v.initialRootKey.ikm)!
        let derived = CryptoUtils.deriveInitialRootKey(sharedSecretData: ikm)
        let derivedData = derived.rawData
        XCTAssertEqual(derivedData.hexString, v.initialRootKey.rootKey,
                       "Initial root key mismatch")
    }

    // MARK: - 3. Root KDF

    func testRootKDF() throws {
        let rootKey = SymmetricKey(data: Data(hex: v.rootKDF.rootKey)!)
        let dhOutput = Data(hex: v.rootKDF.dhOutput)!

        let result = CryptoUtils.rootKDF(rootKey: rootKey, dhOutput: dhOutput)
        let newRKHex = result.newRootKey.rawData.hexString
        let ckHex = result.chainKey.rawData.hexString

        XCTAssertEqual(newRKHex, v.rootKDF.newRootKey, "Root KDF new root key mismatch")
        XCTAssertEqual(ckHex, v.rootKDF.chainKey, "Root KDF chain key mismatch")
    }

    // MARK: - 4. Chain KDF

    func testChainKDF() throws {
        let ck = SymmetricKey(data: Data(hex: v.chainKDF.chainKey)!)

        let step0 = CryptoUtils.chainKDF(chainKey: ck)
        let mk0Hex = step0.messageKey.rawData.hexString
        let nextCK0Hex = step0.nextChainKey.rawData.hexString
        XCTAssertEqual(mk0Hex, v.chainKDF.messageKey0, "Chain KDF message key 0 mismatch")
        XCTAssertEqual(nextCK0Hex, v.chainKDF.nextChainKey0, "Chain KDF next chain key 0 mismatch")

        let step1 = CryptoUtils.chainKDF(chainKey: step0.nextChainKey)
        let mk1Hex = step1.messageKey.rawData.hexString
        let nextCK1Hex = step1.nextChainKey.rawData.hexString
        XCTAssertEqual(mk1Hex, v.chainKDF.messageKey1, "Chain KDF message key 1 mismatch")
        XCTAssertEqual(nextCK1Hex, v.chainKDF.nextChainKey1, "Chain KDF next chain key 1 mismatch")
    }

    // MARK: - 5. AES-256-GCM

    func testAESGCMEncrypt() throws {
        let key = SymmetricKey(data: Data(hex: v.aesGcm.key)!)
        let nonce = try AES.GCM.Nonce(data: Data(hex: v.aesGcm.nonce)!)
        let plaintext = Data(hex: v.aesGcm.plaintext)!
        let aad = Data(hex: v.aesGcm.aad)!

        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)

        XCTAssertEqual(sealed.ciphertext.hexString, v.aesGcm.ciphertext,
                       "AES-GCM ciphertext mismatch")
        XCTAssertEqual(sealed.tag.hexString, v.aesGcm.tag,
                       "AES-GCM tag mismatch")
    }

    func testAESGCMDecrypt() throws {
        let key = SymmetricKey(data: Data(hex: v.aesGcm.key)!)
        let nonce = try AES.GCM.Nonce(data: Data(hex: v.aesGcm.nonce)!)
        let ct = Data(hex: v.aesGcm.ciphertext)!
        let tag = Data(hex: v.aesGcm.tag)!
        let aad = Data(hex: v.aesGcm.aad)!

        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        let decrypted = try AES.GCM.open(box, using: key, authenticating: aad)

        XCTAssertEqual(String(data: decrypted, encoding: .utf8), v.aesGcm.plaintextUtf8,
                       "AES-GCM decryption mismatch")
    }

    // MARK: - 6. Message Padding

    func testMessagePadding() throws {
        let padded = MessagePadding.pad(v.messagePadding.input, deterministicPadByte: 0x00)
        XCTAssertEqual(padded.hexString, v.messagePadding.paddedHex,
                       "Message padding mismatch")
        XCTAssertEqual(padded.count, v.messagePadding.paddedLength,
                       "Padded length mismatch")
        XCTAssertTrue(padded.count % 256 == 0,
                      "Padded length not multiple of 256")
    }

    func testMessageUnpadding() throws {
        let padded = Data(hex: v.messagePadding.paddedHex)!
        let unpadded = MessagePadding.unpad(padded)
        XCTAssertEqual(unpadded, v.messagePadding.input,
                       "Message unpadding mismatch")
    }

    // MARK: - 7. Wire Format

    func testHeaderConstruction() throws {
        let dhPubRaw = Data(hex: v.wireFormat.dhPublicKeyRaw)!
        let header = WireFormat.buildHeader(
            dhPublicKeyRaw: dhPubRaw,
            pn: UInt32(v.wireFormat.pn),
            n: UInt32(v.wireFormat.n)
        )
        XCTAssertEqual(header.hexString, v.wireFormat.headerHex,
                       "Header construction mismatch")
        XCTAssertEqual(header.count, v.wireFormat.headerLength,
                       "Header length mismatch (\(header.count) != \(v.wireFormat.headerLength))")
    }

    func testHeaderParsing() throws {
        let headerData = Data(hex: v.wireFormat.headerHex)!
        let parsed = try WireFormat.parseHeader(headerData)
        XCTAssertEqual(parsed.version, UInt8(v.wireFormat.headerVersion))
        XCTAssertEqual(parsed.dhPublicKeyRaw.hexString, v.wireFormat.dhPublicKeyRaw)
        XCTAssertEqual(parsed.pn, UInt32(v.wireFormat.pn))
        XCTAssertEqual(parsed.n, UInt32(v.wireFormat.n))
    }

    func testWireMessageAssembly() throws {
        let header = Data(hex: v.wireFormat.headerHex)!
        let nonce = Data(hex: v.wireFormat.nonce)!
        let ct = Data(hex: v.wireFormat.ciphertext)!
        let tag = Data(hex: v.wireFormat.tag)!

        let wire = WireFormat.buildMessage(header: header, nonce: nonce, ciphertext: ct, tag: tag)
        XCTAssertEqual(wire.hexString, v.wireFormat.wireMessageHex,
                       "Wire message assembly mismatch")
    }

    func testWireMessageParsing() throws {
        let wireData = Data(hex: v.wireFormat.wireMessageHex)!
        let parsed = try WireFormat.parseMessage(wireData)
        XCTAssertEqual(parsed.header.hexString, v.wireFormat.headerHex)
        XCTAssertEqual(parsed.nonce.hexString, v.wireFormat.nonce)
        XCTAssertEqual(parsed.ciphertext.hexString, v.wireFormat.ciphertext)
        XCTAssertEqual(parsed.tag.hexString, v.wireFormat.tag)
    }

    // MARK: - 8. Safety Number

    func testSafetyNumber() throws {
        let keyA = Data(hex: v.safetyNumber.identityKeyA)!
        let keyB = Data(hex: v.safetyNumber.identityKeyB)!
        let fingerprint = CryptoUtils.safetyNumber(identityKeyA: keyA, identityKeyB: keyB)
        XCTAssertEqual(fingerprint, v.safetyNumber.fingerprint,
                       "Safety number mismatch")
    }

    func testSafetyNumberOrderIndependent() throws {
        let keyA = Data(hex: v.safetyNumber.identityKeyA)!
        let keyB = Data(hex: v.safetyNumber.identityKeyB)!
        let fp1 = CryptoUtils.safetyNumber(identityKeyA: keyA, identityKeyB: keyB)
        let fp2 = CryptoUtils.safetyNumber(identityKeyA: keyB, identityKeyB: keyA)
        XCTAssertEqual(fp1, fp2, "Safety number must be order-independent")
    }

    // MARK: - 9. Full Double Ratchet Session

    func testDoubleRatchetSession() throws {
        let sv = v.session

        // Build host and guest ephemeral keys
        let hostEphPriv = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: sv.hostEphemeralPrivateKey)!)
        let guestEphPriv = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: sv.guestEphemeralPrivateKey)!)

        // Shared secret
        let shared = try hostEphPriv.sharedSecretFromKeyAgreement(with: guestEphPriv.publicKey)
        let sharedData = shared.rawData
        XCTAssertEqual(sharedData.hexString, sv.sharedSecret, "Session shared secret mismatch")

        // Initial root key
        let sk = CryptoUtils.deriveInitialRootKey(sharedSecret: shared)
        let skHex = sk.rawData.hexString
        XCTAssertEqual(skHex, sv.initialRootKey, "Session initial root key mismatch")

        // Pre-built ratchet keypairs
        var ratchetKeyPairs: [P256.KeyAgreement.PrivateKey] = []
        for kp in sv.ratchetKeypairs {
            let priv = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: kp.privateKey)!)
            ratchetKeyPairs.append(priv)
        }

        // Initialize HOST Double Ratchet
        var host = DoubleRatchet(
            role: .host,
            sharedKey: sk,
            ourKeyPair: ratchetKeyPairs[0],
            theirPublicKey: guestEphPriv.publicKey,
            keyPairGenerator: TestKeyPairGenerator(keys: Array(ratchetKeyPairs.dropFirst(2)))
        )

        // Initialize GUEST Double Ratchet
        var guest = DoubleRatchet(
            role: .guest,
            sharedKey: sk,
            ourKeyPair: guestEphPriv,
            theirPublicKey: nil,
            keyPairGenerator: TestKeyPairGenerator(keys: [ratchetKeyPairs[1], ratchetKeyPairs[3]])
        )

        // Process each message
        for msg in sv.messages {
            if msg.sender == "HOST" {
                // HOST encrypts
                let encrypted = try host.encrypt(
                    plaintext: msg.messageJson,
                    deterministicNonce: Data(hex: msg.nonce),
                    deterministicPadByte: 0x00
                )

                // Verify message key
                XCTAssertEqual(encrypted.debugMessageKey?.hexString, msg.messageKey,
                               "Message key mismatch at index \(msg.index)")

                // Verify wire format
                XCTAssertEqual(encrypted.wireBase64, msg.wireBase64,
                               "Wire base64 mismatch at index \(msg.index)")

                // GUEST decrypts
                let decrypted = try guest.decrypt(wireBase64: encrypted.wireBase64)
                XCTAssertEqual(decrypted, msg.messageJson,
                               "Decryption mismatch at index \(msg.index)")
            } else {
                // GUEST encrypts
                let encrypted = try guest.encrypt(
                    plaintext: msg.messageJson,
                    deterministicNonce: Data(hex: msg.nonce),
                    deterministicPadByte: 0x00
                )

                XCTAssertEqual(encrypted.debugMessageKey?.hexString, msg.messageKey,
                               "Message key mismatch at index \(msg.index)")
                XCTAssertEqual(encrypted.wireBase64, msg.wireBase64,
                               "Wire base64 mismatch at index \(msg.index)")

                // HOST decrypts
                let decrypted = try host.decrypt(wireBase64: encrypted.wireBase64)
                XCTAssertEqual(decrypted, msg.messageJson,
                               "Decryption mismatch at index \(msg.index)")
            }
        }
    }

    // MARK: - 10. Out-of-order Messages (Skipped Keys)

    func testOutOfOrderMessages() throws {
        let sv = v.session
        let hostEphPriv = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: sv.hostEphemeralPrivateKey)!)
        let guestEphPriv = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: sv.guestEphemeralPrivateKey)!)
        let shared = try hostEphPriv.sharedSecretFromKeyAgreement(with: guestEphPriv.publicKey)
        let sk = CryptoUtils.deriveInitialRootKey(sharedSecret: shared)

        var host = DoubleRatchet(role: .host, sharedKey: sk,
                                 ourKeyPair: try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: sv.ratchetKeypairs[0].privateKey)!),
                                 theirPublicKey: guestEphPriv.publicKey)
        var guest = DoubleRatchet(role: .guest, sharedKey: sk,
                                  ourKeyPair: guestEphPriv, theirPublicKey: nil)

        // HOST sends 3 messages
        let msg0 = try host.encrypt(plaintext: "msg-0")
        let msg1 = try host.encrypt(plaintext: "msg-1")
        let msg2 = try host.encrypt(plaintext: "msg-2")

        // GUEST receives them out of order: 2, 0, 1
        let dec2 = try guest.decrypt(wireBase64: msg2.wireBase64)
        XCTAssertEqual(dec2, "msg-2", "Out-of-order msg2 failed")

        let dec0 = try guest.decrypt(wireBase64: msg0.wireBase64)
        XCTAssertEqual(dec0, "msg-0", "Out-of-order msg0 failed")

        let dec1 = try guest.decrypt(wireBase64: msg1.wireBase64)
        XCTAssertEqual(dec1, "msg-1", "Out-of-order msg1 failed")
    }

    // MARK: - 11. Replay Attack Rejection

    func testReplayAttackRejected() throws {
        let sv = v.session
        let hostEphPriv = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: sv.hostEphemeralPrivateKey)!)
        let guestEphPriv = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: sv.guestEphemeralPrivateKey)!)
        let shared = try hostEphPriv.sharedSecretFromKeyAgreement(with: guestEphPriv.publicKey)
        let sk = CryptoUtils.deriveInitialRootKey(sharedSecret: shared)

        var host = DoubleRatchet(role: .host, sharedKey: sk,
                                 ourKeyPair: try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: sv.ratchetKeypairs[0].privateKey)!),
                                 theirPublicKey: guestEphPriv.publicKey)
        var guest = DoubleRatchet(role: .guest, sharedKey: sk,
                                  ourKeyPair: guestEphPriv, theirPublicKey: nil)

        let encrypted = try host.encrypt(plaintext: "test replay")
        _ = try guest.decrypt(wireBase64: encrypted.wireBase64)

        // Same ciphertext again → must throw
        XCTAssertThrowsError(try guest.decrypt(wireBase64: encrypted.wireBase64),
                             "Replay attack should be rejected")
    }

    // MARK: - 12. Padding Properties

    func testPaddingAlwaysMultipleOf256() {
        for len in [1, 10, 50, 100, 200, 252, 253, 500, 1000] {
            let msg = String(repeating: "A", count: len)
            let padded = MessagePadding.pad(msg)
            XCTAssertTrue(padded.count % 256 == 0,
                          "Padded length \(padded.count) not multiple of 256 for input length \(len)")
            XCTAssertTrue(padded.count > 0)
        }
    }

    func testPaddingRoundtrip() {
        let messages = [
            "Hello",
            "{\"m\":\"test\",\"t\":0,\"c\":0,\"id\":\"x\"}",
            String(repeating: "X", count: 1000),
            ""
        ]
        for msg in messages {
            let padded = MessagePadding.pad(msg)
            let unpadded = MessagePadding.unpad(padded)
            XCTAssertEqual(unpadded, msg, "Padding roundtrip failed for: \(msg.prefix(20))")
        }
    }
}

// MARK: - Test Key Pair Generator

final class TestKeyPairGenerator: KeyPairGenerating {
    private var keys: [P256.KeyAgreement.PrivateKey]
    private var index = 0

    init(keys: [P256.KeyAgreement.PrivateKey]) {
        self.keys = keys
    }

    func generateKeyPair() -> P256.KeyAgreement.PrivateKey {
        if index < keys.count {
            let key = keys[index]
            index += 1
            return key
        }
        // Fallback to random for tests that don't need deterministic keys
        return P256.KeyAgreement.PrivateKey()
    }
}

