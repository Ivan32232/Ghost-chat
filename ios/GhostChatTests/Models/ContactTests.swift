import XCTest
@testable import GhostChat

final class ContactTests: XCTestCase {
    func test_codable_roundtrip_minimalContact() throws {
        let contact = Contact(
            label: "Alice",
            identityKey: Data([0x04] + Array(repeating: UInt8(0xAA), count: 64)),
            publicKey: Data([0x04] + Array(repeating: UInt8(0xBB), count: 64))
        )
        let data = try JSONEncoder().encode(contact)
        let decoded = try JSONDecoder().decode(Contact.self, from: data)
        XCTAssertEqual(contact, decoded)
    }

    func test_codable_roundtrip_fullContact() throws {
        let contact = Contact(
            id: "fixed-id",
            label: "Bob",
            identityKey: Data(repeating: 0x01, count: 65),
            publicKey: Data(repeating: 0x02, count: 65),
            previousKey: Data(repeating: 0x03, count: 65),
            fallbackKey: Data(repeating: 0x04, count: 65),
            pushToken: Data(repeating: 0x05, count: 32),
            notifyToken: Data(repeating: 0x06, count: 32),
            ratchetState: Data(repeating: 0x07, count: 128),
            rotationCounter: 5,
            sessionCount: 42,
            messageTTL: 900,
            notes: "meeting notes",
            isMuted: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSessionAt: Date(timeIntervalSince1970: 1_700_500_000)
        )
        let data = try JSONEncoder().encode(contact)
        let decoded = try JSONDecoder().decode(Contact.self, from: data)
        XCTAssertEqual(contact, decoded)
    }

    func test_defaults() {
        let c = Contact(label: "x", identityKey: Data(), publicKey: Data())
        XCTAssertEqual(c.rotationCounter, 0)
        XCTAssertEqual(c.sessionCount, 0)
        XCTAssertEqual(c.messageTTL, 300)
        XCTAssertFalse(c.isMuted)
        XCTAssertNil(c.ratchetState)
    }
}
