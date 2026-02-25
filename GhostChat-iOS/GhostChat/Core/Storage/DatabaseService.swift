import Foundation
import SQLCipher

/// Encrypted SQLite database service using SQLCipher
/// DB file: Application Support/ghostchat.db
/// Encryption key: 32 random bytes stored in Keychain (kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
final class DatabaseService {

    static let shared = DatabaseService()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.ghostchat.database", qos: .userInitiated)

    private static let keychainKey = "db_encryption_key"
    private static let dbFileName = "ghostchat.db"

    // MARK: - Setup

    /// Open or create the encrypted database
    func setup() throws {
        let dbPath = try Self.databasePath()
        let key = try Self.getOrCreateEncryptionKey()

        var dbPointer: OpaquePointer?
        let rc = sqlite3_open(dbPath, &dbPointer)
        guard rc == SQLITE_OK, let dbPointer else {
            throw DatabaseError.openFailed(rc)
        }
        db = dbPointer

        // Set encryption key via PRAGMA
        let hexKey = key.map { String(format: "%02x", $0) }.joined()
        let pragmaSQL = "PRAGMA key = \"x'\(hexKey)'\";"
        let keyResult = sqlite3_exec(dbPointer, pragmaSQL, nil, nil, nil)
        guard keyResult == SQLITE_OK else {
            sqlite3_close(dbPointer)
            db = nil
            throw DatabaseError.keyFailed(keyResult)
        }

        // Verify the key works by reading from the DB
        let verifyRC = sqlite3_exec(dbPointer, "SELECT count(*) FROM sqlite_master;", nil, nil, nil)
        guard verifyRC == SQLITE_OK else {
            sqlite3_close(dbPointer)
            db = nil
            throw DatabaseError.keyVerificationFailed(verifyRC)
        }

        // Run migrations
        try runMigrations()
    }

    /// Close the database
    func close() {
        queue.sync {
            if let db {
                sqlite3_close(db)
            }
            db = nil
        }
    }

    // MARK: - Migrations

    private func runMigrations() throws {
        guard db != nil else { throw DatabaseError.notOpen }

        // Create migrations table
        try execute("""
            CREATE TABLE IF NOT EXISTS _migrations (
                version INTEGER PRIMARY KEY,
                appliedAt REAL NOT NULL
            );
        """)

        let currentVersion = try getCurrentMigrationVersion()

        // v1: Contacts + SkippedKeys
        if currentVersion < 1 {
            try execute("""
                CREATE TABLE IF NOT EXISTS contacts (
                    id TEXT PRIMARY KEY,
                    label TEXT NOT NULL,
                    publicKey BLOB NOT NULL,
                    previousKey BLOB,
                    fallbackKey BLOB,
                    pushToken BLOB,
                    rotationCounter INTEGER DEFAULT 0,
                    createdAt REAL NOT NULL,
                    lastSessionAt REAL
                );
            """)

            try execute("""
                CREATE TABLE IF NOT EXISTS skippedKeys (
                    dhPublicKey BLOB NOT NULL,
                    messageNumber INTEGER NOT NULL,
                    messageKey BLOB NOT NULL,
                    createdAt REAL NOT NULL,
                    PRIMARY KEY (dhPublicKey, messageNumber)
                );
            """)

            try execute("""
                INSERT INTO _migrations (version, appliedAt) VALUES (1, \(Date().timeIntervalSince1970));
            """)
        }

        // v2: Identity keys + DR state per contact
        if currentVersion < 2 {
            try execute("ALTER TABLE contacts ADD COLUMN identityKey BLOB;")
            try execute("UPDATE contacts SET identityKey = publicKey;")
            try execute("ALTER TABLE contacts ADD COLUMN ratchetState BLOB;")
            try execute("ALTER TABLE contacts ADD COLUMN sessionCount INTEGER DEFAULT 0;")
            try execute("CREATE INDEX IF NOT EXISTS idx_contacts_identityKey ON contacts(identityKey);")

            // Recreate skippedKeys with contactId column
            try execute("""
                CREATE TABLE IF NOT EXISTS skippedKeys_v2 (
                    contactId TEXT NOT NULL,
                    dhPublicKey BLOB NOT NULL,
                    messageNumber INTEGER NOT NULL,
                    messageKey BLOB NOT NULL,
                    createdAt REAL NOT NULL,
                    PRIMARY KEY (contactId, dhPublicKey, messageNumber)
                );
            """)
            try execute("DROP TABLE IF EXISTS skippedKeys;")
            try execute("ALTER TABLE skippedKeys_v2 RENAME TO skippedKeys;")

            try execute("""
                INSERT INTO _migrations (version, appliedAt) VALUES (2, \(Date().timeIntervalSince1970));
            """)
        }
    }

    private func getCurrentMigrationVersion() throws -> Int {
        guard let db else { throw DatabaseError.notOpen }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        let rc = sqlite3_prepare_v2(db, "SELECT MAX(version) FROM _migrations;", -1, &stmt, nil)
        guard rc == SQLITE_OK else { return 0 }

        if sqlite3_step(stmt) == SQLITE_ROW {
            let version = sqlite3_column_int(stmt, 0)
            return Int(version)
        }
        return 0
    }

    // MARK: - Execute

    @discardableResult
    func execute(_ sql: String) throws -> Int32 {
        guard let db else { throw DatabaseError.notOpen }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let msg = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw DatabaseError.executeFailed(rc, msg)
        }
        return rc
    }

    /// Prepare a statement for parameterized queries
    func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw DatabaseError.notOpen }

        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw DatabaseError.prepareFailed(rc)
        }
        return stmt
    }

    // MARK: - Paths & Keys

    private static func databasePath() throws -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport.appendingPathComponent(dbFileName).path
    }

    /// Get or create the 32-byte encryption key from Keychain
    private static func getOrCreateEncryptionKey() throws -> Data {
        // Try loading existing key
        if let existingKey = KeychainService.load(forKey: keychainKey), existingKey.count == 32 {
            return existingKey
        }

        // Generate new random 32-byte key
        var keyBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, 32, &keyBytes)
        guard status == errSecSuccess else {
            throw DatabaseError.keyGenerationFailed
        }

        let key = Data(keyBytes)
        KeychainService.save(key, forKey: keychainKey)
        return key
    }

    /// Delete ALL data — panic button
    func deleteAll() throws {
        try execute("DELETE FROM contacts;")
        try execute("DELETE FROM skippedKeys;")
    }

    /// Delete DB file entirely and wipe encryption key + identity key from Keychain
    static func destroy() {
        if let path = try? databasePath() {
            try? FileManager.default.removeItem(atPath: path)
        }
        KeychainService.delete(forKey: keychainKey)
        IdentityKeyService.shared.destroy()
    }
}

// MARK: - Errors

enum DatabaseError: LocalizedError {
    case openFailed(Int32)
    case keyFailed(Int32)
    case keyVerificationFailed(Int32)
    case notOpen
    case executeFailed(Int32, String)
    case prepareFailed(Int32)
    case keyGenerationFailed

    var errorDescription: String? {
        switch self {
        case .openFailed(let rc): return "Failed to open database: \(rc)"
        case .keyFailed(let rc): return "Failed to set encryption key: \(rc)"
        case .keyVerificationFailed(let rc): return "Key verification failed: \(rc)"
        case .notOpen: return "Database not open"
        case .executeFailed(let rc, let msg): return "SQL error \(rc): \(msg)"
        case .prepareFailed(let rc): return "Failed to prepare statement: \(rc)"
        case .keyGenerationFailed: return "Failed to generate encryption key"
        }
    }
}
