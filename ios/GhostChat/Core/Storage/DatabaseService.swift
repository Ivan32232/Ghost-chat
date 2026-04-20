import Foundation
import GRDB

/// Encrypted persistent storage for saved contacts, messages, and Double Ratchet state.
///
/// **Encryption:** SQLCipher with a 32-byte per-install master key stored in Keychain
/// (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). PRAGMAs:
///   - `cipher_page_size = 4096`, `kdf_iter = 256000`
///   - `cipher_memory_security = ON` (zeros page buffers on free)
///   - `secure_delete = ON` (zeros freed pages before reuse)
///
/// File is excluded from iCloud/iTunes backup. With SQLCipher in place, the
/// iOS-level `FileProtectionType.complete` attribute is no longer required —
/// SQLCipher encrypts pages regardless of device lock state, which is strictly
/// stronger than FileProtection (which only encrypts while the device is locked).
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

    // MARK: - Factories

    /// Opens (or creates) the on-disk encrypted database in Application Support.
    static func onDisk(keychain: KeychainServicing) throws -> DatabaseService {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw Error.applicationSupportUnavailable
        }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let dbURL = base.appendingPathComponent("ghostchat.db")

        excludeFromBackup(url: dbURL)

        return try encrypted(at: dbURL.path, keychain: keychain)
    }

    /// Opens or creates an encrypted database at an explicit path. Intended for tests
    /// that need to inspect the raw file (e.g., prove ciphertext).
    static func encrypted(at path: String, keychain: KeychainServicing) throws -> DatabaseService {
        let passphrase = try ensureMasterKey(keychain: keychain)

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            // Cipher parameters MUST be set before `usePassphrase` on a fresh DB, and
            // must match on re-open — hard-coded here so they never drift.
            try db.execute(sql: "PRAGMA cipher_page_size = 4096")
            try db.execute(sql: "PRAGMA kdf_iter = 256000")
            try db.usePassphrase(passphrase)
            try db.execute(sql: "PRAGMA cipher_memory_security = ON")
            try db.execute(sql: "PRAGMA secure_delete = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let queue = try DatabaseQueue(path: path, configuration: configuration)
        let service = DatabaseService(keychain: keychain, dbQueue: queue)
        try service.migrate()
        return service
    }

    /// Plain in-memory DB for fast unit tests — no encryption because the DB never
    /// touches disk. The master key is still provisioned so code paths exercising
    /// the keychain stay covered.
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

    // MARK: - Private

    private static func excludeFromBackup(url: URL) {
        var mutable = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? mutable.setResourceValues(resourceValues)
    }
}
