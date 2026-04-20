import Foundation
import GRDB

/// Encrypted persistent storage for saved contacts, messages, and Double Ratchet state.
///
/// **Encryption strategy (Phase 3):** system-level `FileProtectionType.complete` — data is
/// encrypted on disk with a device-derived key, decrypted only while the device is unlocked.
/// The 32-byte master key is generated once and kept in the Keychain for when SQLCipher
/// integration lands in Phase 6 (page-level encryption regardless of lock state).
///
/// File layout: `Application Support/ghostchat.db` (+ wal, shm), excluded from iCloud backup.
final class DatabaseService {

    enum Error: Swift.Error, Equatable {
        case applicationSupportUnavailable
        case masterKeyGenerationFailed
    }

    struct Keys {
        static let dbMasterKey = "db.master.key"
    }

    private let keychain: KeychainServicing
    let dbQueue: DatabaseQueue

    init(keychain: KeychainServicing, dbQueue: DatabaseQueue) {
        self.keychain = keychain
        self.dbQueue = dbQueue
    }

    // MARK: - Factory

    /// Opens (or creates) the on-disk database at the app's Application Support directory.
    static func onDisk(keychain: KeychainServicing) throws -> DatabaseService {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw Error.applicationSupportUnavailable
        }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)

        let dbURL = base.appendingPathComponent("ghostchat.db")

        // Protect at file-system level: `.complete` = decryption requires unlocked device.
        var attrs: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
        if fm.fileExists(atPath: dbURL.path) {
            try? fm.setAttributes(attrs, ofItemAtPath: dbURL.path)
        } else {
            fm.createFile(atPath: dbURL.path, contents: nil, attributes: attrs)
        }

        // Exclude from iCloud / iTunes backup.
        var urlVar = dbURL
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? urlVar.setResourceValues(resourceValues)

        _ = try ensureMasterKey(keychain: keychain)

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let queue = try DatabaseQueue(path: dbURL.path, configuration: configuration)
        let service = DatabaseService(keychain: keychain, dbQueue: queue)
        try service.migrate()
        return service
    }

    /// Spins up an in-memory DB for tests.
    static func inMemory(keychain: KeychainServicing) throws -> DatabaseService {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: configuration)
        let service = DatabaseService(keychain: keychain, dbQueue: queue)
        _ = try ensureMasterKey(keychain: keychain)
        try service.migrate()
        return service
    }

    // MARK: - Master key

    /// Returns the 32-byte DB master key, generating it on first access.
    /// Not applied to the SQLite connection in Phase 3 — reserved for Phase 6 SQLCipher.
    @discardableResult
    static func ensureMasterKey(keychain: KeychainServicing) throws -> Data {
        if let existing = try keychain.get(Keys.dbMasterKey) {
            return existing
        }
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { buf in
            SecRandomCopyBytes(kSecRandomDefault, 32, buf.baseAddress!)
        }
        guard status == errSecSuccess else { throw Error.masterKeyGenerationFailed }
        try keychain.set(bytes, for: Keys.dbMasterKey)
        return bytes
    }

    // MARK: - Migration

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("schema.v1") { db in
            try db.execute(sql: """
                CREATE TABLE contacts (
                    id TEXT PRIMARY KEY,
                    label TEXT NOT NULL,
                    identityKey BLOB NOT NULL,
                    publicKey BLOB NOT NULL,
                    previousKey BLOB,
                    fallbackKey BLOB,
                    pushToken BLOB,
                    notifyToken BLOB,
                    ratchetState BLOB,
                    rotationCounter INTEGER DEFAULT 0,
                    sessionCount INTEGER DEFAULT 0,
                    messageTTL INTEGER DEFAULT 300,
                    notes TEXT,
                    isMuted INTEGER DEFAULT 0,
                    createdAt REAL NOT NULL,
                    lastSessionAt REAL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE messages (
                    id TEXT PRIMARY KEY,
                    contactId TEXT NOT NULL,
                    sender INTEGER NOT NULL DEFAULT 0,
                    text TEXT NOT NULL,
                    type INTEGER NOT NULL DEFAULT 0,
                    isDelivered INTEGER NOT NULL DEFAULT 0,
                    isPending INTEGER NOT NULL DEFAULT 0,
                    createdAt REAL NOT NULL,
                    fileName TEXT,
                    fileSize INTEGER,
                    fileMimeType TEXT,
                    fileLocalPath TEXT,
                    fileId TEXT,
                    replyToId TEXT,
                    replyToText TEXT,
                    isEdited INTEGER DEFAULT 0,
                    senderMessageId TEXT,
                    isPinned INTEGER DEFAULT 0,
                    FOREIGN KEY (contactId) REFERENCES contacts(id) ON DELETE CASCADE
                )
                """)
            try db.execute(sql: """
                CREATE TABLE skippedKeys (
                    contactId TEXT NOT NULL,
                    dhPublicKey BLOB NOT NULL,
                    messageNumber INTEGER NOT NULL,
                    messageKey BLOB NOT NULL,
                    createdAt REAL NOT NULL,
                    PRIMARY KEY (contactId, dhPublicKey, messageNumber),
                    FOREIGN KEY (contactId) REFERENCES contacts(id) ON DELETE CASCADE
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_messages_contactId_createdAt ON messages(contactId, createdAt)")
            try db.execute(sql: "CREATE INDEX idx_skippedKeys_createdAt ON skippedKeys(createdAt)")
        }

        try migrator.migrate(dbQueue)
    }

    // MARK: - Nuke

    /// Irrecoverably deletes the DB file and its WAL/SHM siblings. Used by panic wipe.
    static func deleteFile() {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        ["ghostchat.db", "ghostchat.db-wal", "ghostchat.db-shm", "ghostchat.db-journal"].forEach { name in
            let url = base.appendingPathComponent(name)
            try? fm.removeItem(at: url)
        }
    }
}
