import XCTest
@testable import GhostChat

final class PostQuantumTests: XCTestCase {

    func test_isSupported_reportsDeploymentReality() {
        // Until Xcode ships CryptoKit.MLKEM768 on the iOS 26+ SDK, the flag is
        // always false (see implementation note). When the SDK lights up we'll
        // flip this check to `if #available(iOS 26, *)`.
        XCTAssertFalse(PostQuantum.isSupported)
    }

    func test_generateKeyPair_onUnsupportedSDK_throws() {
        XCTAssertThrowsError(try PostQuantum.generateKeyPair()) { err in
            XCTAssertEqual(err as? PostQuantum.Error, .unsupportedOS)
        }
    }

    func test_encapsulate_onUnsupportedSDK_throws() {
        XCTAssertThrowsError(try PostQuantum.encapsulate(peerPublic: Data(count: 1184))) { err in
            XCTAssertEqual(err as? PostQuantum.Error, .unsupportedOS)
        }
    }

    func test_decapsulate_onUnsupportedSDK_throws() {
        XCTAssertThrowsError(try PostQuantum.decapsulate(
            ciphertext: Data(count: 1088),
            privateKey: Data(count: 2400)
        )) { err in
            XCTAssertEqual(err as? PostQuantum.Error, .unsupportedOS)
        }
    }

    // MARK: - hybridDeriveSharedKey (always safe — pure HKDF)

    func test_hybridDerive_ecdhOnly_matches32Bytes() {
        let ecdh = Data(repeating: 0xAB, count: 32)
        let out = PostQuantum.hybridDeriveSharedKey(
            ecdhSharedSecret: ecdh, pqSharedSecret: nil
        )
        XCTAssertEqual(out.count, 32)
    }

    func test_hybridDerive_withPQ_differsFromEcdhOnly() {
        let ecdh = Data(repeating: 0xAB, count: 32)
        let pq   = Data(repeating: 0xCD, count: 32)
        let hyb = PostQuantum.hybridDeriveSharedKey(
            ecdhSharedSecret: ecdh, pqSharedSecret: pq
        )
        let plain = PostQuantum.hybridDeriveSharedKey(
            ecdhSharedSecret: ecdh, pqSharedSecret: nil
        )
        XCTAssertNotEqual(hyb, plain)
    }

    func test_hybridDerive_deterministic_acrossCalls() {
        let ecdh = Data(repeating: 0x11, count: 32)
        let pq   = Data(repeating: 0x22, count: 32)
        let a = PostQuantum.hybridDeriveSharedKey(ecdhSharedSecret: ecdh, pqSharedSecret: pq)
        let b = PostQuantum.hybridDeriveSharedKey(ecdhSharedSecret: ecdh, pqSharedSecret: pq)
        XCTAssertEqual(a, b)
    }

    /// Cross-platform vector. The hybrid derivation MUST match Android's
    /// `PostQuantum.hybridDeriveSharedKey` byte-for-byte — pinned in
    /// docs/test-vectors.json `pqHybrid.combinedWithPQ`.
    func test_hybridDerive_crossPlatformVector_withPQ() {
        let ecdh = Data(repeating: 0xAB, count: 32)
        let pq   = Data(repeating: 0xCD, count: 32)
        let out = PostQuantum.hybridDeriveSharedKey(
            ecdhSharedSecret: ecdh, pqSharedSecret: pq
        )
        let hex = out.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "207fad0312271a11364d7c3184693501082f1f614ff632987ba8e763df762eae")
    }

    func test_hybridDerive_crossPlatformVector_withoutPQ() {
        let ecdh = Data(repeating: 0xAB, count: 32)
        let out = PostQuantum.hybridDeriveSharedKey(
            ecdhSharedSecret: ecdh, pqSharedSecret: nil
        )
        // Recomputed from Node (see generate-test-vectors.cjs pqHybrid.combinedWithoutPQ).
        let expected = Self.pqHybridVector_withoutPQ
        XCTAssertEqual(out.map { String(format: "%02x", $0) }.joined(), expected)
    }

    // The expected hex is computed in generate-test-vectors.cjs; we pin it here.
    private static let pqHybridVector_withoutPQ: String = {
        // For deterministic CI, store the expected value inline — regenerate via
        // `node scripts/generate-test-vectors.cjs` and re-sync.
        "11edf4ea0a6fb4e02b042841e5e72f2c8415cfca1ab9a815b0ffe6fb4fc69e4a"
    }()
}
