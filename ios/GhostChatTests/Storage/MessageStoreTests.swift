import XCTest
@testable import GhostChat

final class MessageStoreTests: XCTestCase {

    private var db: DatabaseService!
    private var contacts: ContactStore!
    private var messages: MessageStore!
    private var contactId: String!

    override func setUpWithError() throws {
        db = try DatabaseService.inMemory(keychain: InMemoryKeychain())
        contacts = ContactStore(database: db)
        messages = MessageStore(database: db)

        let c = Contact(
            label: "Alice",
            identityKey: Data([0x01]),
            publicKey: Data([0x02])
        )
        try contacts.save(c)
        contactId = c.id
    }

    private func makeMessage(text: String, sender: Sender = .me, at: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString,
            contactId: contactId,
            sender: sender,
            text: text,
            createdAt: at
        )
    }

    // MARK: - Messages

    func test_append_andFetch() throws {
        let m = makeMessage(text: "hi")
        try messages.append(m)
        let fetched = try messages.fetch(contactId: contactId)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.text, "hi")
    }

    func test_fetch_returnsInChronologicalOrder() throws {
        try messages.append(makeMessage(text: "first",  at: Date(timeIntervalSince1970: 100)))
        try messages.append(makeMessage(text: "second", at: Date(timeIntervalSince1970: 200)))
        try messages.append(makeMessage(text: "third",  at: Date(timeIntervalSince1970: 300)))
        let fetched = try messages.fetch(contactId: contactId).map(\.text)
        XCTAssertEqual(fetched, ["first", "second", "third"])
    }

    func test_fetch_limitIsApplied() throws {
        for i in 0..<5 {
            try messages.append(makeMessage(text: "m\(i)", at: Date(timeIntervalSince1970: TimeInterval(i))))
        }
        XCTAssertEqual(try messages.fetch(contactId: contactId, limit: 2).count, 2)
    }

    func test_deleteMessage_removesEntry() throws {
        let m = makeMessage(text: "bye")
        try messages.append(m)
        try messages.deleteMessage(id: m.id)
        XCTAssertEqual(try messages.fetch(contactId: contactId).count, 0)
    }

    func test_deleteAll_forContact() throws {
        try messages.append(makeMessage(text: "a"))
        try messages.append(makeMessage(text: "b"))
        try messages.deleteAll(forContact: contactId)
        XCTAssertEqual(try messages.fetch(contactId: contactId).count, 0)
    }

    func test_pinnedMessages_returnsOnlyPinned() throws {
        var pinned = makeMessage(text: "keep me")
        pinned.isPinned = true
        try messages.append(pinned)
        try messages.append(makeMessage(text: "ephemeral"))
        let result = try messages.pinnedMessages(forContact: contactId)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.text, "keep me")
    }

    func test_deleteContact_cascadesToMessages() throws {
        try messages.append(makeMessage(text: "x"))
        try contacts.delete(id: contactId)
        XCTAssertEqual(try messages.fetch(contactId: contactId).count, 0)
    }

    // MARK: - SkippedKey

    func test_skippedKey_storeAndTake() throws {
        let key = SkippedKey(
            contactId: contactId,
            dhPublicKey: Data(repeating: 0xEE, count: 64),
            messageNumber: 7,
            messageKey: Data(repeating: 0xFF, count: 32),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try messages.storeSkipped(key)
        let taken = try messages.takeSkipped(contactId: contactId, dhPublicKey: key.dhPublicKey, messageNumber: 7)
        XCTAssertEqual(taken, key)
        let again = try messages.takeSkipped(contactId: contactId, dhPublicKey: key.dhPublicKey, messageNumber: 7)
        XCTAssertNil(again, "take should consume the key")
    }

    func test_pruneSkipped_removesOldEntries() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = SkippedKey(
            contactId: contactId,
            dhPublicKey: Data([0x01]),
            messageNumber: 1,
            messageKey: Data([0x02]),
            createdAt: now.addingTimeInterval(-200_000)
        )
        let recent = SkippedKey(
            contactId: contactId,
            dhPublicKey: Data([0x03]),
            messageNumber: 2,
            messageKey: Data([0x04]),
            createdAt: now
        )
        try messages.storeSkipped(old)
        try messages.storeSkipped(recent)

        try messages.pruneSkipped(olderThan: 86_400, now: now)

        XCTAssertNil(try messages.takeSkipped(contactId: contactId, dhPublicKey: old.dhPublicKey, messageNumber: 1))
        XCTAssertNotNil(try messages.takeSkipped(contactId: contactId, dhPublicKey: recent.dhPublicKey, messageNumber: 2))
    }
}
