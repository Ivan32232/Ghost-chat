import XCTest
@testable import GhostChat
import GhostCrypto

final class PqHandshakeTests: XCTestCase {

    private func pair() -> (GhostChatCrypto, GhostChatCrypto) {
        let host = GhostChatCrypto(identity: IdentityKeyService(keychain: InMemoryKeychain()))
        let guest = GhostChatCrypto(identity: IdentityKeyService(keychain: InMemoryKeychain()))
        return (host, guest)
    }

    /// iOS ↔ iOS: neither side can do ML-KEM (PostQuantum.isSupported = false on iOS).
    /// The hybrid path degrades cleanly to ECDH-only and both sides become ready
    /// after the first round-trip.
    func test_iOSiOS_degradesToEcdhOnly_noPqExchange() async throws {
        let (host, guest) = pair()
        let hostPkt = try await host.beginHandshake(role: .host)
        let guestPkt = try await guest.beginHandshake(role: .guest)

        XCTAssertNil(hostPkt.pqKey, "iOS host must not advertise pqKey")
        XCTAssertEqual(hostPkt.pqSupported, false)
        XCTAssertEqual(guestPkt.pqSupported, false)

        let pqOut = try await guest.completeAsGuest(peer: hostPkt)
        XCTAssertNil(pqOut, "iOS guest cannot encapsulate")

        let hostReady = try await host.completeAsHost(peer: guestPkt)
        XCTAssertTrue(hostReady)

        let ready = await (host.isReady, guest.isReady)
        XCTAssertTrue(ready.0); XCTAssertTrue(ready.1)

        // Can exchange a message end-to-end.
        let w = try await host.encrypt("hello")
        let got = try await guest.decrypt(w)
        XCTAssertEqual(got, "hello")
    }

    func test_hybridHkdfMatchesCrossPlatformVector() throws {
        // Pins the combine step against docs/test-vectors.json > pqHandshake.
        let ecdh = Data(repeating: 0xAB, count: 32)
        let pq = Data(repeating: 0xCD, count: 32)
        let out = PostQuantum.hybridDeriveSharedKey(ecdhSharedSecret: ecdh, pqSharedSecret: pq)
        XCTAssertEqual(
            out.map { String(format: "%02x", $0) }.joined(),
            "207fad0312271a11364d7c3184693501082f1f614ff632987ba8e763df762eae"
        )
    }

    func test_hybridEcdhOnly_matchesCrossPlatformVector() throws {
        let ecdh = Data(repeating: 0xAB, count: 32)
        let out = PostQuantum.hybridDeriveSharedKey(ecdhSharedSecret: ecdh, pqSharedSecret: nil)
        XCTAssertEqual(
            out.map { String(format: "%02x", $0) }.joined(),
            "11edf4ea0a6fb4e02b042841e5e72f2c8415cfca1ab9a815b0ffe6fb4fc69e4a"
        )
    }

    func test_completePQ_onEcdhOnlySession_throwsUnexpectedState() async throws {
        let (host, guest) = pair()
        let hostPkt = try await host.beginHandshake(role: .host)
        let guestPkt = try await guest.beginHandshake(role: .guest)
        _ = try await guest.completeAsGuest(peer: hostPkt)
        _ = try await host.completeAsHost(peer: guestPkt)    // iOS → ready immediately
        do {
            try await host.completePQ(pqCiphertext: Data(count: 1088))
            XCTFail("should have thrown unexpectedState")
        } catch {
            XCTAssertEqual(error as? GhostChatCrypto.Error, .unexpectedState)
        }
    }
}
