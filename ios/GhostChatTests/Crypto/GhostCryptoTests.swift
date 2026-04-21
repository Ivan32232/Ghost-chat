import XCTest
@testable import GhostChat

final class GhostChatCryptoTests: XCTestCase {

    private func pair() -> (GhostChatCrypto, IdentityKeyService, GhostChatCrypto, IdentityKeyService) {
        let idHost = IdentityKeyService(keychain: InMemoryKeychain())
        let idGuest = IdentityKeyService(keychain: InMemoryKeychain())
        return (GhostChatCrypto(identity: idHost), idHost, GhostChatCrypto(identity: idGuest), idGuest)
    }

    private func handshake(_ host: GhostChatCrypto, _ guest: GhostChatCrypto) async throws {
        let hostPkt = try await host.beginHandshake(role: .host)
        let guestPkt = try await guest.beginHandshake(role: .guest)
        let pqOut = try await guest.completeAsGuest(peer: hostPkt)
        try await host.completeAsHost(peer: guestPkt)
        if let pq = pqOut {
            try await host.completePQ(pqCiphertext: pq.pqCiphertext)
        }
    }

    // MARK: - Handshake

    func test_handshake_completes_bothReady() async throws {
        let (host, _, guest, _) = pair()
        try await handshake(host, guest)
        let ready = await (host.isReady, guest.isReady)
        XCTAssertTrue(ready.0)
        XCTAssertTrue(ready.1)
    }

    func test_beginHandshake_returnsValidPacket() async throws {
        let (host, idHost, _, _) = pair()
        let pkt = try await host.beginHandshake(role: .host)
        XCTAssertEqual(pkt.type, "key-exchange")
        XCTAssertEqual(pkt.publicKey.count, 65)
        XCTAssertEqual(pkt.publicKey[0], 0x04)
        XCTAssertEqual(pkt.identityKey, try idHost.publicKeyX963)
        XCTAssertEqual(pkt.v, 3)
        // iOS: PostQuantum.isSupported = false → no pqKey advertised.
        XCTAssertNil(pkt.pqKey)
        XCTAssertEqual(pkt.pqSupported, false)
    }

    func test_completeBeforeBegin_throws() async throws {
        let (host, _, guest, _) = pair()
        let guestPkt = try await guest.beginHandshake(role: .guest)
        do {
            try await host.completeAsHost(peer: guestPkt)
            XCTFail("should have thrown")
        } catch {
            XCTAssertEqual(error as? GhostChatCrypto.Error, .notInitialized)
        }
    }

    func test_invalidPeerPacketType_throws() async throws {
        let (host, _, _, _) = pair()
        _ = try await host.beginHandshake(role: .host)
        // Build one with a wrong type directly via raw JSON:
        let raw = #"{"type":"bogus","publicKey":"","identityKey":"","v":3}"#
        let bad = try JSONDecoder().decode(KeyExchangePacket.self, from: Data(raw.utf8))
        do {
            try await host.completeAsHost(peer: bad)
            XCTFail("should have thrown")
        } catch {
            XCTAssertEqual(error as? GhostChatCrypto.Error, .invalidPeerPacket)
        }
    }

    // MARK: - Encrypt / decrypt

    func test_roundtrip_hostToGuest() async throws {
        let (host, _, guest, _) = pair()
        try await handshake(host, guest)
        let wire = try await host.encrypt("hello")
        let decoded = try await guest.decrypt(wire)
        XCTAssertEqual(decoded, "hello")
    }

    func test_roundtrip_guestToHost_requiresPriorHostMessage() async throws {
        let (host, _, guest, _) = pair()
        try await handshake(host, guest)
        // GUEST can't send until it receives at least one HOST message (initializes receiving chain)
        let first = try await host.encrypt("hi from host")
        _ = try await guest.decrypt(first)
        let reply = try await guest.encrypt("hi from guest")
        let decoded = try await host.decrypt(reply)
        XCTAssertEqual(decoded, "hi from guest")
    }

    func test_manyMessages_roundtrip() async throws {
        let (host, _, guest, _) = pair()
        try await handshake(host, guest)
        for i in 0..<20 {
            let text = "msg-\(i)"
            let wire = try await host.encrypt(text)
            let got = try await guest.decrypt(wire)
            XCTAssertEqual(got, text)
        }
    }

    func test_encrypt_beforeHandshake_throws() async throws {
        let host = GhostChatCrypto(identity: IdentityKeyService(keychain: InMemoryKeychain()))
        do {
            _ = try await host.encrypt("nope")
            XCTFail("should have thrown")
        } catch {
            XCTAssertEqual(error as? GhostChatCrypto.Error, .notInitialized)
        }
    }

    // MARK: - Safety number

    func test_safetyNumber_bothSidesIdentical() async throws {
        let (host, _, guest, _) = pair()
        try await handshake(host, guest)
        let a = try await host.safetyNumber()
        let b = try await guest.safetyNumber()
        XCTAssertEqual(a, b)
    }

    func test_safetyNumber_format() async throws {
        let (host, _, guest, _) = pair()
        try await handshake(host, guest)
        let sn = try await host.safetyNumber()
        // "XXXX XXXX XXXX XXXX XXXX XXXX XXXX XXXX" — 39 chars total (32 hex + 7 spaces)
        XCTAssertEqual(sn.count, 39)
        XCTAssertEqual(sn.filter { $0 == " " }.count, 7)
    }

    // MARK: - State persistence

    func test_exportAndRestore_resumesMessaging() async throws {
        let (host, _, guest, _) = pair()
        try await handshake(host, guest)
        let first = try await host.encrypt("a")
        _ = try await guest.decrypt(first)

        let exported = try await host.exportState()
        let freshHost = GhostChatCrypto(identity: IdentityKeyService(keychain: InMemoryKeychain()))
        try await freshHost.restore(from: exported)

        let second = try await freshHost.encrypt("b")
        let decoded = try await guest.decrypt(second)
        XCTAssertEqual(decoded, "b")
    }

    func test_exportBeforeHandshake_throws() async throws {
        let host = GhostChatCrypto(identity: IdentityKeyService(keychain: InMemoryKeychain()))
        do {
            _ = try await host.exportState()
            XCTFail("should have thrown")
        } catch {
            XCTAssertEqual(error as? GhostChatCrypto.Error, .notInitialized)
        }
    }

    // MARK: - Codable of KeyExchangePacket

    func test_keyExchangePacket_codableRoundtrip() throws {
        let pkt = KeyExchangePacket(
            publicKey: Data(count: 65),
            identityKey: Data(count: 65),
            v: 3
        )
        let data = try JSONEncoder().encode(pkt)
        let decoded = try JSONDecoder().decode(KeyExchangePacket.self, from: data)
        XCTAssertEqual(pkt, decoded)
    }

    func test_keyExchangePacket_wireKeys() throws {
        let pkt = KeyExchangePacket(publicKey: Data([1, 2]), identityKey: Data([3, 4]), v: 3, pqKey: Data([5]), pqSupported: true)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pkt)) as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "key-exchange")
        XCTAssertEqual(json?["v"] as? Int, 3)
        XCTAssertNotNil(json?["publicKey"])
        XCTAssertNotNil(json?["identityKey"])
        XCTAssertNotNil(json?["pqKey"])
        XCTAssertEqual(json?["pqSupported"] as? Bool, true)
    }
}
