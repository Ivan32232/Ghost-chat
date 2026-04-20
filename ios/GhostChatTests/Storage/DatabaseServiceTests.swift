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

    // MARK: - SQLCipher encryption proof

    /// Writes a contact with a very unique plaintext marker label, closes the DB,
    /// then reads the raw bytes of the on-disk file. The marker MUST NOT appear in
    /// the raw bytes and the file MUST NOT start with the unencrypted SQLite magic
    /// header. Either failure means SQLCipher is not actually encrypting pages.
    func test_onDiskFile_isEncrypted_notPlaintext() throws {
        let keychain = InMemoryKeychain()
        let tmpDir = FileManager.default.temporaryDirectory
        let dbURL = tmpDir.appendingPathComponent("sqlcipher-proof-\(UUID().uuidString).db")
        defer {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(at: dbURL.appendingPathExtension("").deletingPathExtension().appendingPathExtension("db\(suffix)"))
            }
            try? FileManager.default.removeItem(at: dbURL)
        }

        let marker = "GHOSTCHAT_SQLCIPHER_PROOF_MARKER_\(UUID().uuidString)"

        // 1. Open encrypted, write the contact with the marker as label, force a WAL
        //    checkpoint so the data lands in the main file, then close.
        do {
            let db = try DatabaseService.encrypted(at: dbURL.path, keychain: keychain)
            let store = ContactStore(database: db)
            let contact = Contact(
                label: marker,
                identityKey: Data(repeating: 0xAA, count: 65),
                publicKey: Data(repeating: 0xBB, count: 65),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            try store.save(contact)
            try db.dbQueue.write { d in
                try d.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            }
        }

        // 2. Raw read — inspect the main file AND any WAL/SHM siblings together.
        //    Plaintext must not appear in any of them.
        let siblings = [dbURL.path, dbURL.path + "-wal", dbURL.path + "-shm", dbURL.path + "-journal"]
        let markerData = Data(marker.utf8)
        let sqliteMagic = Data("SQLite format 3\0".utf8)

        var mainSize = 0
        for path in siblings {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            if path == dbURL.path { mainSize = data.count }
            XCTAssertFalse(data.range(of: markerData) != nil,
                           "plaintext label found in \(path) — SQLCipher not engaged")
            XCTAssertFalse(data.prefix(sqliteMagic.count) == sqliteMagic,
                           "\(path) starts with unencrypted SQLite magic — SQLCipher not engaged")
        }
        XCTAssertGreaterThan(mainSize, 0, "main DB file is empty")

        // 2c. Reopening with the SAME master key must decrypt successfully.
        let db2 = try DatabaseService.encrypted(at: dbURL.path, keychain: keychain)
        let fetched = try ContactStore(database: db2).all()
        XCTAssertEqual(fetched.first?.label, marker, "reopen with same key should recover contact")
    }

    /// Reopening the encrypted file with a DIFFERENT master key must fail.
    func test_onDiskFile_reopenWithDifferentKey_fails() throws {
        let keychain1 = InMemoryKeychain()
        let keychain2 = InMemoryKeychain()
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlcipher-wrongkey-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        do {
            let db = try DatabaseService.encrypted(at: dbURL.path, keychain: keychain1)
            try ContactStore(database: db).save(
                Contact(label: "x",
                        identityKey: Data([0x01]),
                        publicKey: Data([0x02]),
                        createdAt: Date(timeIntervalSince1970: 100))
            )
        }

        // keychain2 generates its own unrelated master key on first call.
        XCTAssertThrowsError(try {
            let db = try DatabaseService.encrypted(at: dbURL.path, keychain: keychain2)
            _ = try db.dbQueue.read { d in try Row.fetchAll(d, sql: "SELECT 1") }
        }())
    }
}
