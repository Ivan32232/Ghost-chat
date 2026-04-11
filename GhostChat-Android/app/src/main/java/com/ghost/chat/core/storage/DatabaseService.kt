package com.ghost.chat.core.storage

import android.content.Context
import android.util.Base64
import com.ghost.chat.core.security.KeystoreService
import net.sqlcipher.database.SQLiteDatabase
import net.sqlcipher.database.SQLiteOpenHelper
import java.security.SecureRandom

/// SQLCipher encrypted database — port of iOS DatabaseService
/// Thread-safe via synchronized blocks
class DatabaseService private constructor(private val appContext: Context) :
    SQLiteOpenHelper(appContext, DB_NAME, null, DB_VERSION) {

    companion object {
        private const val DB_NAME = "ghost_chat.db"
        private const val DB_VERSION = 9
        private const val KEYSTORE_DB_KEY = "ghost_db_encryption_key"

        @Volatile
        private var instance: DatabaseService? = null

        fun getInstance(context: Context): DatabaseService {
            return instance ?: synchronized(this) {
                instance ?: DatabaseService(context.applicationContext).also {
                    instance = it
                    // Initialize SQLCipher
                    SQLiteDatabase.loadLibs(context.applicationContext)
                }
            }
        }
    }

    /** Get the encryption key (generate if first run) */
    private fun getEncryptionKey(): String {
        val existing = KeystoreService.load(KEYSTORE_DB_KEY)
        if (existing != null) {
            return "x'" + existing.joinToString("") { "%02x".format(it) } + "'"
        }

        // Generate new 32-byte random key
        val key = ByteArray(32)
        SecureRandom().nextBytes(key)
        KeystoreService.save(key, KEYSTORE_DB_KEY)
        return "x'" + key.joinToString("") { "%02x".format(it) } + "'"
    }

    @Volatile
    private var cachedDb: SQLiteDatabase? = null

    /** Get writable encrypted database (PRAGMAs run only on first open) */
    fun getDb(): SQLiteDatabase {
        cachedDb?.let { if (it.isOpen) return it }
        synchronized(this) {
            cachedDb?.let { if (it.isOpen) return it }
            try {
                val db = getWritableDatabase(getEncryptionKey())
                // Secure delete: overwrite deleted data with zeros (not just mark as free)
                db.rawExecSQL("PRAGMA secure_delete = ON")
                // Wipe key material from memory when no longer needed (anti-forensics)
                db.rawExecSQL("PRAGMA cipher_memory_security = ON")
                // Enable foreign key constraints (required for ON DELETE CASCADE)
                db.rawExecSQL("PRAGMA foreign_keys = ON")
                cachedDb = db
                return db
            } catch (e: Exception) {
                // DB migration failed — delete and recreate
                android.util.Log.e("GhostChat", "[DatabaseService] DB open failed, recreating: ${e.message}")
                appContext.deleteDatabase(DB_NAME)
                val db = getWritableDatabase(getEncryptionKey())
                db.rawExecSQL("PRAGMA secure_delete = ON")
                db.rawExecSQL("PRAGMA cipher_memory_security = ON")
                db.rawExecSQL("PRAGMA foreign_keys = ON")
                cachedDb = db
                return db
            }
        }
    }

    override fun close() {
        synchronized(this) {
            cachedDb = null
            super.close()
        }
    }

    override fun onCreate(db: SQLiteDatabase) {
        // Migration v1: contacts + skippedKeys
        db.execSQL("""
            CREATE TABLE IF NOT EXISTS contacts (
                id TEXT PRIMARY KEY,
                label TEXT NOT NULL,
                publicKey BLOB NOT NULL,
                identityKey BLOB,
                ratchetState BLOB,
                previousKey BLOB,
                fallbackKey BLOB,
                pushToken BLOB,
                notifyToken BLOB,
                notes TEXT,
                identityKeyHex TEXT,
                rotationCounter INTEGER DEFAULT 0,
                sessionCount INTEGER DEFAULT 0,
                createdAt REAL NOT NULL,
                lastSessionAt REAL,
                messageTTL INTEGER
            )
        """)

        db.execSQL("""
            CREATE TABLE IF NOT EXISTS skippedKeys (
                contactId TEXT NOT NULL,
                dhPublicKey BLOB NOT NULL,
                messageNumber INTEGER NOT NULL,
                messageKey BLOB NOT NULL,
                createdAt REAL NOT NULL,
                PRIMARY KEY (contactId, dhPublicKey, messageNumber)
            )
        """)

        db.execSQL("""
            CREATE TABLE IF NOT EXISTS _migrations (
                version INTEGER PRIMARY KEY,
                appliedAt REAL NOT NULL
            )
        """)

        db.execSQL("CREATE INDEX IF NOT EXISTS idx_contacts_identityKeyHex ON contacts(identityKeyHex)")

        // Mark all migrations as applied
        val now = System.currentTimeMillis().toDouble() / 1000.0
        db.execSQL("INSERT OR REPLACE INTO _migrations (version, appliedAt) VALUES (1, $now)")
        db.execSQL("INSERT OR REPLACE INTO _migrations (version, appliedAt) VALUES (2, $now)")
        db.execSQL("INSERT OR REPLACE INTO _migrations (version, appliedAt) VALUES (3, $now)")
        db.execSQL("INSERT OR REPLACE INTO _migrations (version, appliedAt) VALUES (4, $now)")
        db.execSQL("INSERT OR REPLACE INTO _migrations (version, appliedAt) VALUES (5, $now)")

        // Migration v6: messages table (Ghost Threads)
        db.execSQL("""
            CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY,
                contactId TEXT NOT NULL,
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
                isEdited INTEGER NOT NULL DEFAULT 0,
                senderMessageId TEXT,
                FOREIGN KEY (contactId) REFERENCES contacts(id) ON DELETE CASCADE
            )
        """)
        db.execSQL("CREATE INDEX IF NOT EXISTS idx_messages_contactId ON messages(contactId)")
        db.execSQL("CREATE INDEX IF NOT EXISTS idx_messages_createdAt ON messages(createdAt)")
        db.execSQL("INSERT OR REPLACE INTO _migrations (version, appliedAt) VALUES (6, $now)")
        db.execSQL("INSERT OR REPLACE INTO _migrations (version, appliedAt) VALUES (7, $now)")
        db.execSQL("INSERT OR REPLACE INTO _migrations (version, appliedAt) VALUES (8, $now)")
        db.execSQL("INSERT OR REPLACE INTO _migrations (version, appliedAt) VALUES (9, $now)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion < 2) {
            // Migration v2: add identityKey, ratchetState, sessionCount, contactId to skippedKeys
            try { db.execSQL("ALTER TABLE contacts ADD COLUMN identityKey BLOB") } catch (_: Exception) {}
            try { db.execSQL("ALTER TABLE contacts ADD COLUMN ratchetState BLOB") } catch (_: Exception) {}
            try { db.execSQL("ALTER TABLE contacts ADD COLUMN sessionCount INTEGER DEFAULT 0") } catch (_: Exception) {}

            // Recreate skippedKeys with contactId
            db.execSQL("DROP TABLE IF EXISTS skippedKeys")
            db.execSQL("""
                CREATE TABLE skippedKeys (
                    contactId TEXT NOT NULL,
                    dhPublicKey BLOB NOT NULL,
                    messageNumber INTEGER NOT NULL,
                    messageKey BLOB NOT NULL,
                    createdAt REAL NOT NULL,
                    PRIMARY KEY (contactId, dhPublicKey, messageNumber)
                )
            """)

            val now = System.currentTimeMillis().toDouble() / 1000.0
            db.execSQL("INSERT OR REPLACE INTO _migrations (version, appliedAt) VALUES (2, $now)")
        }

        if (oldVersion < 3) {
            try { db.execSQL("ALTER TABLE contacts ADD COLUMN notes TEXT") } catch (_: Exception) {}
            val now = System.currentTimeMillis().toDouble() / 1000.0
            db.execSQL("INSERT OR REPLACE INTO _migrations (version, appliedAt) VALUES (3, $now)")
        }

        if (oldVersion < 4) {
            // Migration v4: indexed identityKeyHex for O(1) lookup
            try { db.execSQL("ALTER TABLE contacts ADD COLUMN identityKeyHex TEXT") } catch (_: Exception) {}
            // Backfill NULL identityKey from publicKey (matching iOS migration v2)
            try { db.execSQL("UPDATE contacts SET identityKey = publicKey WHERE identityKey IS NULL") } catch (_: Exception) {}
            // Populate hex column from BLOB
            try { db.execSQL("UPDATE contacts SET identityKeyHex = lower(hex(identityKey)) WHERE identityKey IS NOT NULL") } catch (_: Exception) {}
            db.execSQL("CREATE INDEX IF NOT EXISTS idx_contacts_identityKeyHex ON contacts(identityKeyHex)")
            val now = System.currentTimeMillis().toDouble() / 1000.0
            db.execSQL("INSERT OR REPLACE INTO _migrations (version, appliedAt) VALUES (4, $now)")
        }

        if (oldVersion < 5) {
            // Migration v5: notifyToken for chat invite push (peer's APNs/FCM token)
            try { db.execSQL("ALTER TABLE contacts ADD COLUMN notifyToken BLOB") } catch (_: Exception) {}
            val now = System.currentTimeMillis().toDouble() / 1000.0
            db.execSQL("INSERT OR REPLACE INTO _migrations (version, appliedAt) VALUES (5, $now)")
        }

        if (oldVersion < 6) {
            // Migration v6: messages table (Ghost Threads)
            db.execSQL("""
                CREATE TABLE IF NOT EXISTS messages (
                    id TEXT PRIMARY KEY,
                    contactId TEXT NOT NULL,
                    text TEXT NOT NULL,
                    type INTEGER NOT NULL DEFAULT 0,
                    isDelivered INTEGER NOT NULL DEFAULT 0,
                    isPending INTEGER NOT NULL DEFAULT 0,
                    createdAt REAL NOT NULL,
                    FOREIGN KEY (contactId) REFERENCES contacts(id) ON DELETE CASCADE
                )
            """)
            db.execSQL("CREATE INDEX IF NOT EXISTS idx_messages_contactId ON messages(contactId)")
            db.execSQL("CREATE INDEX IF NOT EXISTS idx_messages_createdAt ON messages(createdAt)")
            val now = System.currentTimeMillis().toDouble() / 1000.0
            db.execSQL("INSERT OR REPLACE INTO _migrations (version, appliedAt) VALUES (6, $now)")
        }

        if (oldVersion < 7) {
            try { db.execSQL("ALTER TABLE messages ADD COLUMN fileName TEXT") } catch (_: Exception) {}
            try { db.execSQL("ALTER TABLE messages ADD COLUMN fileSize INTEGER") } catch (_: Exception) {}
            try { db.execSQL("ALTER TABLE messages ADD COLUMN fileMimeType TEXT") } catch (_: Exception) {}
            try { db.execSQL("ALTER TABLE messages ADD COLUMN fileLocalPath TEXT") } catch (_: Exception) {}
            try { db.execSQL("ALTER TABLE messages ADD COLUMN fileId TEXT") } catch (_: Exception) {}
            val now = System.currentTimeMillis().toDouble() / 1000.0
            db.execSQL("INSERT OR REPLACE INTO _migrations (version, appliedAt) VALUES (7, $now)")
        }

        if (oldVersion < 8) {
            // Migration v8: per-contact message TTL (seconds, NULL = use global setting)
            try { db.execSQL("ALTER TABLE contacts ADD COLUMN messageTTL INTEGER") } catch (_: Exception) {}
            val now = System.currentTimeMillis().toDouble() / 1000.0
            db.execSQL("INSERT OR REPLACE INTO _migrations (version, appliedAt) VALUES (8, $now)")
        }

        if (oldVersion < 9) {
            // Migration v9: reply, edit, senderMessageId columns for Phase 3 features
            try { db.execSQL("ALTER TABLE messages ADD COLUMN replyToId TEXT") } catch (_: Exception) {}
            try { db.execSQL("ALTER TABLE messages ADD COLUMN replyToText TEXT") } catch (_: Exception) {}
            try { db.execSQL("ALTER TABLE messages ADD COLUMN isEdited INTEGER NOT NULL DEFAULT 0") } catch (_: Exception) {}
            try { db.execSQL("ALTER TABLE messages ADD COLUMN senderMessageId TEXT") } catch (_: Exception) {}
            val now = System.currentTimeMillis().toDouble() / 1000.0
            db.execSQL("INSERT OR REPLACE INTO _migrations (version, appliedAt) VALUES (9, $now)")
        }
    }

    /** Destroy all data */
    fun destroyAll() {
        synchronized(this) {
            try {
                val db = getDb()
                db.execSQL("DELETE FROM messages")
                db.execSQL("DELETE FROM contacts")
                db.execSQL("DELETE FROM skippedKeys")
            } catch (_: Exception) {}
        }
    }
}
