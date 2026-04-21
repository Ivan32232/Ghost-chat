import XCTest
import CryptoKit
@testable import GhostChat

final class ContactKeyRotationTests: XCTestCase {

    // MARK: - deriveNextSeed

    func test_deriveNextSeed_deterministic() {
        let shared = Data(repeating: 0x42, count: 32)
        let a = ContactKeyRotation.deriveNextSeed(sessionSecret: shared)
        let b = ContactKeyRotation.deriveNextSeed(sessionSecret: shared)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 32)
    }

    func test_deriveNextSeed_differentInputs_differentOutputs() {
        let a = ContactKeyRotation.deriveNextSeed(sessionSecret: Data(repeating: 0x42, count: 32))
        let b = ContactKeyRotation.deriveNextSeed(sessionSecret: Data(repeating: 0x43, count: 32))
        XCTAssertNotEqual(a, b)
    }

    /// Cross-platform vector — MUST match Android `ContactKeyRotationTest
    /// "deriveNextSeed cross-platform vector"`.
    func test_deriveNextSeed_crossPlatformVector() {
        let shared = Data(repeating: 0xAA, count: 32)
        let derived = ContactKeyRotation.deriveNextSeed(sessionSecret: shared)
        let hex = derived.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "1f4f27ab8ba143449e1d4de39c3752b9e11538152f8876f1482c550c2b7dd65e")
    }

    func test_deriveNextSeed_chainOfGenerations_allDistinct() {
        let shared = Data(repeating: 0x01, count: 32)
        let a = ContactKeyRotation.deriveNextSeed(sessionSecret: shared)
        let b = ContactKeyRotation.deriveNextSeed(sessionSecret: a)
        let c = ContactKeyRotation.deriveNextSeed(sessionSecret: b)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(b, c)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - rotate

    func test_rotate_bumpsCounter_andEmitsValidKeypair() throws {
        let current = P256.KeyAgreement.PrivateKey()
        let prev    = P256.KeyAgreement.PrivateKey()
        let rotated = ContactKeyRotation.rotate(
            sessionSecret: Data(repeating: 0x42, count: 32),
            currentPrivate: current.rawRepresentation,
            previousPublic: prev.publicKey.x963Representation,
            fallbackPublic: nil,
            counter: 0
        )
        XCTAssertEqual(rotated.counter, 1)
        XCTAssertEqual(rotated.newPrivate.count, 32)
        XCTAssertEqual(rotated.newPublicX963.count, 65)
        XCTAssertEqual(rotated.newPublicX963[0], 0x04)
        XCTAssertEqual(rotated.previousPublicX963, prev.publicKey.x963Representation)
        XCTAssertNil(rotated.fallbackPublicX963)
        XCTAssertNotEqual(rotated.newPrivate, current.rawRepresentation)
        // Deriving with the same material returns an equal keypair (determinism).
        let twice = ContactKeyRotation.rotate(
            sessionSecret: Data(repeating: 0x42, count: 32),
            currentPrivate: current.rawRepresentation,
            previousPublic: prev.publicKey.x963Representation,
            fallbackPublic: nil,
            counter: 0
        )
        XCTAssertEqual(rotated, twice)
    }

    func test_rotate_slidesPreviousIntoFallback() throws {
        let current = P256.KeyAgreement.PrivateKey()
        let prev = P256.KeyAgreement.PrivateKey()
        let fallback = P256.KeyAgreement.PrivateKey()
        let rotated = ContactKeyRotation.rotate(
            sessionSecret: Data(repeating: 0x42, count: 32),
            currentPrivate: current.rawRepresentation,
            previousPublic: prev.publicKey.x963Representation,
            fallbackPublic: fallback.publicKey.x963Representation,
            counter: 7
        )
        XCTAssertEqual(rotated.counter, 8)
        XCTAssertEqual(rotated.fallbackPublicX963, fallback.publicKey.x963Representation)
    }

    /// The new keypair must actually work as a P-256 keypair (ECDH roundtrip).
    func test_rotate_newKeypairParticipatesInECDH() throws {
        let peer = P256.KeyAgreement.PrivateKey()
        let current = P256.KeyAgreement.PrivateKey()
        let rotated = ContactKeyRotation.rotate(
            sessionSecret: Data(repeating: 0xEE, count: 32),
            currentPrivate: current.rawRepresentation,
            previousPublic: peer.publicKey.x963Representation,
            fallbackPublic: nil,
            counter: 0
        )
        let rotatedPriv = try P256.KeyAgreement.PrivateKey(rawRepresentation: rotated.newPrivate)
        let rotatedPub = try P256.KeyAgreement.PublicKey(x963Representation: rotated.newPublicX963)
        XCTAssertEqual(rotatedPriv.publicKey.x963Representation, rotatedPub.x963Representation)
        let ss1 = try rotatedPriv.sharedSecretFromKeyAgreement(with: peer.publicKey)
        let ss2 = try peer.sharedSecretFromKeyAgreement(with: rotatedPub)
        XCTAssertEqual(ss1, ss2)
    }
}
