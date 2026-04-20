import XCTest
@testable import GhostChat

final class TURNCredentialsTests: XCTestCase {

    func test_isExpired_withinTTL_false() {
        let c = TURNCredentials(
            username: "u", credential: "c", urls: ["turn:"], ttl: 3600,
            fetchedAt: Date(timeIntervalSince1970: 1000)
        )
        XCTAssertFalse(c.isExpired(now: Date(timeIntervalSince1970: 2000), skew: 300))
    }

    func test_isExpired_withinSkewWindow_true() {
        let c = TURNCredentials(
            username: "u", credential: "c", urls: ["turn:"], ttl: 600,
            fetchedAt: Date(timeIntervalSince1970: 1000)
        )
        // ttl=600, skew=300 → creds considered expired at t=1300 (1000 + 600 - 300)
        XCTAssertTrue(c.isExpired(now: Date(timeIntervalSince1970: 1400), skew: 300))
    }

    func test_codable_roundtrip() throws {
        let c = TURNCredentials(
            username: "u", credential: "c", urls: ["turn:foo", "stun:bar"], ttl: 3600,
            fetchedAt: Date(timeIntervalSince1970: 12345)
        )
        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(TURNCredentials.self, from: data)
        XCTAssertEqual(c, decoded)
    }
}
