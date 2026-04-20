import XCTest
@testable import GhostChat

final class ContactStoreTests: XCTestCase {

    private var store: ContactStore!
    private var db: DatabaseService!

    override func setUpWithError() throws {
        db = try DatabaseService.inMemory(keychain: InMemoryKeychain())
        store = ContactStore(database: db)
    }

    private func makeContact(label: String = "Alice", createdAt: TimeInterval = 1_700_000_000) -> Contact {
        Contact(
            id: UUID().uuidString,
            label: label,
            identityKey: Data(repeating: 0xAA, count: 65),
            publicKey: Data(repeating: 0xBB, count: 65),
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }

    func test_save_andFetchById() throws {
        let c = makeContact()
        try store.save(c)
        XCTAssertEqual(try store.fetch(id: c.id), c)
    }

    func test_all_emptyInitially() throws {
        XCTAssertEqual(try store.all().count, 0)
    }

    func test_all_returnsSortedByLastSessionThenCreated() throws {
        var a = makeContact(label: "A", createdAt: 100)
        var b = makeContact(label: "B", createdAt: 200)
        var c = makeContact(label: "C", createdAt: 300)
        a.lastSessionAt = Date(timeIntervalSince1970: 100)
        b.lastSessionAt = Date(timeIntervalSince1970: 200)
        c.lastSessionAt = nil
        try store.save(a); try store.save(b); try store.save(c)
        let ordered = try store.all().map(\.label)
        XCTAssertEqual(ordered.first, "B")
        XCTAssertTrue(ordered.contains("C"))
    }

    func test_fetch_byIdentityKey() throws {
        let c = makeContact()
        try store.save(c)
        XCTAssertEqual(try store.fetch(identityKey: c.identityKey), c)
    }

    func test_delete_removesContact() throws {
        let c = makeContact()
        try store.save(c)
        try store.delete(id: c.id)
        XCTAssertNil(try store.fetch(id: c.id))
    }

    func test_deleteAll_clearsEverything() throws {
        try store.save(makeContact())
        try store.save(makeContact())
        try store.deleteAll()
        XCTAssertEqual(try store.all().count, 0)
    }

    func test_updateRatchetState_persists() throws {
        let c = makeContact()
        try store.save(c)
        let state = Data(repeating: 0xCC, count: 128)
        try store.updateRatchetState(id: c.id, state: state)
        XCTAssertEqual(try store.fetch(id: c.id)?.ratchetState, state)
    }

    func test_bumpSessionCount_incrementsAndSetsTimestamp() throws {
        let c = makeContact()
        try store.save(c)
        let now = Date(timeIntervalSince1970: 12345)
        try store.bumpSessionCount(id: c.id, at: now)
        let reloaded = try store.fetch(id: c.id)
        XCTAssertEqual(reloaded?.sessionCount, 1)
        XCTAssertEqual(reloaded?.lastSessionAt, now)
    }

    func test_setMuted_togglesFlag() throws {
        let c = makeContact()
        try store.save(c)
        try store.setMuted(id: c.id, muted: true)
        XCTAssertTrue(try store.fetch(id: c.id)?.isMuted == true)
        try store.setMuted(id: c.id, muted: false)
        XCTAssertFalse(try store.fetch(id: c.id)?.isMuted == true)
    }
}
