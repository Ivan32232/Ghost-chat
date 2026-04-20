import XCTest
@testable import GhostChat

final class ChatMessageTests: XCTestCase {
    func test_codable_roundtrip_basicText() throws {
        let m = ChatMessage(
            id: "fixed",
            contactId: "contact-1",
            sender: .me,
            text: "hello",
            type: .text,
            isDelivered: true,
            isPending: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(m, decoded)
    }

    func test_codable_roundtrip_withReply() throws {
        let m = ChatMessage(
            id: "fixed",
            contactId: "contact-1",
            sender: .peer,
            text: "reply",
            replyToId: "other",
            replyToText: "original",
            senderMessageId: "their-id"
        )
        let data = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(m, decoded)
    }

    func test_wirePayload_matchesSpecKeys() throws {
        let payload = ChatMessage.WirePayload(
            m: "hi",
            t: 1_713_100_800_000,
            c: 42,
            id: "uuid-v4",
            r: .init(id: "reply-id", t: "reply preview text")
        )
        let data = try JSONEncoder().encode(payload)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["m"] as? String, "hi")
        XCTAssertEqual(json?["t"] as? Int64, 1_713_100_800_000)
        XCTAssertEqual(json?["c"] as? UInt64, 42)
        XCTAssertEqual(json?["id"] as? String, "uuid-v4")
        let reply = json?["r"] as? [String: Any]
        XCTAssertEqual(reply?["id"] as? String, "reply-id")
        XCTAssertEqual(reply?["t"] as? String, "reply preview text")
    }

    func test_wirePayload_noReply_encodesWithoutField() throws {
        let payload = ChatMessage.WirePayload(m: "x", t: 0, c: 0, id: "id")
        let data = try JSONEncoder().encode(payload)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(json?["r"])
    }
}
