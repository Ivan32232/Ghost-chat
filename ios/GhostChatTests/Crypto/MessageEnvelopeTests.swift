import XCTest
@testable import GhostChat

final class MessageEnvelopeTests: XCTestCase {

    func test_encode_sortedKeys_exactJSON() throws {
        let env = MessageEnvelope(m: "hello", t: 1_713_100_800_000, c: 7, id: "env-1")
        let data = try JSONEncoder.envelope.encode(env)
        let str = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(str, #"{"c":7,"id":"env-1","m":"hello","t":1713100800000}"#)
    }

    func test_decode_roundtrip() throws {
        let raw = #"{"m":"hi","t":1000,"c":0,"id":"x"}"#.data(using: .utf8)!
        let env = try JSONDecoder().decode(MessageEnvelope.self, from: raw)
        XCTAssertEqual(env.m, "hi")
        XCTAssertEqual(env.t, 1000)
        XCTAssertEqual(env.c, 0)
        XCTAssertEqual(env.id, "x")
    }

    func test_matchesCrossPlatformVector() throws {
        // Mirror of docs/test-vectors.json > messageEnvelope.
        let env = MessageEnvelope(m: "hello", t: 1_713_100_800_000, c: 7, id: "env-1")
        let data = try JSONEncoder.envelope.encode(env)
        let str = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(str, #"{"c":7,"id":"env-1","m":"hello","t":1713100800000}"#)
    }

    func test_largeCounter_preservedAsUInt64() throws {
        let env = MessageEnvelope(m: "x", t: 0, c: .max, id: "big")
        let data = try JSONEncoder.envelope.encode(env)
        let decoded = try JSONDecoder().decode(MessageEnvelope.self, from: data)
        XCTAssertEqual(decoded.c, UInt64.max)
    }
}
