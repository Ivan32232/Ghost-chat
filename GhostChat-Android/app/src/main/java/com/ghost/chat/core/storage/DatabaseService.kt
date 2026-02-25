package com.ghost.chat.core.storage

import android.content.Context
import android.util.Base64
import com.ghost.chat.core.security.KeystoreService
import net.sqlcipher.database.SQLiteDatabase
import net.sqlcipher.database.SQLiteOpenHelper
import java.security.SecureRandom

/// SQLCipher encrypted database — port of iOS DatabaseService
/// Thread-safe via synchronized blocks
class DatabaseService private constructor(context: Context) :
    SQLiteOpenHelper(context, DB_NAME, null, DB_VERSION) {

    companion object {
        private const val DB_NAME = "ghost_chat.db"
        private const val DB_VERSION = 2
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

    /** Get writable encrypted database */
    fun getDb(): SQLiteDatabase {
        return getWritableDatabase(getEncryptionKey())
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
                rotationCounter INTEGER DEFAULT 0,
                sessionCount INTEGER DEFAULT 0,
                createdAt REAL NOT NULL,
                lastSessionAt REAL
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

        // Mark both migrations as applied
        val now = System.currentTimeMillis().toDouble() / 1000.0
        db.execSQL("INSERT OR REPLACE INTO _migrations (version, appliedAt) VALUES (1, $now)")
        db.execSQL("INSERT OR REPLACE INTO _migrations (version, appliedAt) VALUES (2, $now)")
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
    }

    /** Destroy all data */
    fun destroyAll() {
        synchronized(this) {
            try {
                val db = getDb()
                db.execSQL("DELETE FROM contacts")
                db.execSQL("DELETE FROM skippedKeys")
            } catch (_: Exception) {}
        }
    }
}
