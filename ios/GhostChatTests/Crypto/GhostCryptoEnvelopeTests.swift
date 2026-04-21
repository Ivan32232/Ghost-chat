import XCTest
@testable import GhostChat

final class GhostCryptoEnvelopeTests: XCTestCase {

    /// Controllable clock — lets tests shift `now` forward / backward deterministically.
    final class ManualClock: GhostClock, @unchecked Sendable {
        var currentMs: Int64
        init(_ initial: Int64) { self.currentMs = initial }
        func nowMs() -> Int64 { currentMs }
    }

    private func pair(hostClock: GhostClock, guestClock: GhostClock)
    -> (GhostChatCrypto, GhostChatCrypto) {
        let host = GhostChatCrypto(
            identity: IdentityKeyService(keychain: InMemoryKeychain()),
            clock: hostClock
        )
        let guest = GhostChatCrypto(
            identity: IdentityKeyService(keychain: InMemoryKeychain()),
            clock: guestClock
        )
        return (host, guest)
    }

    private func handshake(_ host: GhostChatCrypto, _ guest: GhostChatCrypto) async throws {
        let hostPkt = try await host.beginHandshake()
        let guestPkt = try await guest.beginHandshake()
        try await host.completeAsHost(peer: guestPkt)
        try await guest.completeAsGuest(peer: hostPkt)
    }

    func test_encryptWrapsInEnvelopeAndDecryptUnwraps() async throws {
        let clock = ManualClock(1_713_100_800_000)
        let (host, guest) = pair(hostClock: clock, guestClock: clock)
        try await handshake(host, guest)

        let wire = try await host.encrypt("hello")
        let got = try await guest.decrypt(wire)
        XCTAssertEqual(got, "hello")
    }

    func test_staleTimestampRejected() async throws {
        let hostClock = ManualClock(1_713_100_800_000)
        let guestClock = ManualClock(1_713_100_800_000 + 6 * 60 * 1000) // +6 min on receiver
        let (host, guest) = pair(hostClock: hostClock, guestClock: guestClock)
        try await handshake(host, guest)

        let wire = try await host.encrypt("stale")
        do {
            _ = try await guest.decrypt(wire)
            XCTFail("should have thrown timestampOutOfWindow")
        } catch let err as ReplayError {
            XCTAssertEqual(err, .timestampOutOfWindow)
        }
    }

    func test_clockWithinWindow_admits() async throws {
        let hostClock = ManualClock(1_713_100_800_000)
        let guestClock = ManualClock(1_713_100_800_000 + 3 * 60 * 1000) // +3 min: within ±5
        let (host, guest) = pair(hostClock: hostClock, guestClock: guestClock)
        try await handshake(host, guest)

        let wire = try await host.encrypt("in-window")
        let got = try await guest.decrypt(wire)
        XCTAssertEqual(got, "in-window")
    }

    func test_counterIncrementsMonotonically() async throws {
        let clock = ManualClock(1_713_100_800_000)
        let (host, guest) = pair(hostClock: clock, guestClock: clock)
        try await handshake(host, guest)

        // Send 3 messages; each one should have a strictly-increasing envelope counter when
        // decoded on the guest side.
        let w1 = try await host.encrypt("a")
        let w2 = try await host.encrypt("b")
        let w3 = try await host.encrypt("c")
        let p1 = try await guest.decryptEnvelope(w1)
        let p2 = try await guest.decryptEnvelope(w2)
        let p3 = try await guest.decryptEnvelope(w3)
        XCTAssertEqual(p1.m, "a")
        XCTAssertEqual(p2.m, "b")
        XCTAssertEqual(p3.m, "c")
        XCTAssertLessThan(p1.c, p2.c)
        XCTAssertLessThan(p2.c, p3.c)
        XCTAssertEqual(p1.t, clock.currentMs)
    }
}
