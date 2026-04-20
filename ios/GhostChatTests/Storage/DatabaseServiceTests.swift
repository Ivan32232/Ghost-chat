import XCTest
import GRDB
@testable import GhostChat

final class DatabaseServiceTests: XCTestCase {

    func test_inMemory_createsTables() throws {
        let keychain = InMemoryKeychain()
        let db = try DatabaseService.inMemory(keychain: keychain)
        let tables = try db.dbQueue.read { d -> [String] in
            try String.fetchAll(d, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        }
        XCTAssertTrue(tables.contains("contacts"))
        XCTAssertTrue(tables.contains("messages"))
        XCTAssertTrue(tables.contains("skippedKeys"))
    }

    func test_ensureMasterKey_generatesOnceAndPersists() throws {
        let keychain = InMemoryKeychain()
        let key1 = try DatabaseService.ensureMasterKey(keychain: keychain)
        let key2 = try DatabaseService.ensureMasterKey(keychain: keychain)
        XCTAssertEqual(key1, key2)
        XCTAssertEqual(key1.count, 32)
    }

    func test_ensureMasterKey_regeneratesAfterDelete() throws {
        let keychain = InMemoryKeychain()
        let first = try DatabaseService.ensureMasterKey(keychain: keychain)
        try keychain.delete(DatabaseService.Keys.dbMasterKey)
        let second = try DatabaseService.ensureMasterKey(keychain: keychain)
        XCTAssertNotEqual(first, second)
    }

    func test_migrate_isIdempotent() throws {
        let keychain = InMemoryKeychain()
        let db = try DatabaseService.inMemory(keychain: keychain)
        XCTAssertNoThrow(try db.dbQueue.read { _ in })
    }
}
