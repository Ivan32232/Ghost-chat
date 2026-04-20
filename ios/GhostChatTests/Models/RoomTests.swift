import XCTest
@testable import GhostChat

final class RoomTests: XCTestCase {
    func test_validID_64Base64UrlChars_passes() {
        let valid = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        XCTAssertTrue(Room.isValidID(valid))
        XCTAssertTrue(Room.isValidID("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"))
    }

    func test_validID_wrongLength_fails() {
        XCTAssertFalse(Room.isValidID(""))
        XCTAssertFalse(Room.isValidID("short"))
        XCTAssertFalse(Room.isValidID(String(repeating: "A", count: 63)))
        XCTAssertFalse(Room.isValidID(String(repeating: "A", count: 65)))
    }

    func test_validID_invalidCharacters_fails() {
        let base = String(repeating: "A", count: 63)
        XCTAssertFalse(Room.isValidID(base + "+"), "+ not part of base64url")
        XCTAssertFalse(Room.isValidID(base + "/"), "/ not part of base64url")
        XCTAssertFalse(Room.isValidID(base + "="), "padding not allowed")
        XCTAssertFalse(Room.isValidID(base + "!"))
    }

    func test_codable_roundtrip() throws {
        let room = Room(id: String(repeating: "a", count: 64), createdAt: Date(timeIntervalSince1970: 1_700_000_000), myRole: .host)
        let data = try JSONEncoder().encode(room)
        let decoded = try JSONDecoder().decode(Room.self, from: data)
        XCTAssertEqual(room, decoded)
    }
}
