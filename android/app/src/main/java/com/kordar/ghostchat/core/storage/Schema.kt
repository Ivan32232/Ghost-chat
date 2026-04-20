package com.kordar.ghostchat.core.storage

import net.zetetic.database.sqlcipher.SQLiteDatabase

/**
 * Schema migration. Mirrors the iOS GRDB migration "schema.v1" — same column names, types,
 * defaults, and foreign keys so a SQLCipher backup can be opened by either platform.
 */
internal object Schema {

    const val VERSION = 1

    fun migrate(db: SQLiteDatabase) {
        val current = currentVersion(db)
        if (current >= VERSION) return
        db.beginTransaction()
        try {
            if (current < 1) applyV1(db)
            db.setVersion(VERSION)
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    private fun currentVersion(db: SQLiteDatabase): Int {
        db.rawQuery("PRAGMA user_version;", arrayOf()).use { c ->
            return if (c.moveToFirst()) c.getInt(0) else 0
        }
    }

    private fun SQLiteDatabase.setVersion(v: Int) {
        rawExecSQL("PRAGMA user_version = $v;")
    }

    private fun applyV1(db: SQLiteDatabase) {
        db.execSQL(
            """
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
            """.trimIndent()
        )
        db.execSQL(
            """
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
            """.trimIndent()
        )
        db.execSQL(
            """
            CREATE TABLE skippedKeys (
                contactId TEXT NOT NULL,
                dhPublicKey BLOB NOT NULL,
                messageNumber INTEGER NOT NULL,
                messageKey BLOB NOT NULL,
                createdAt REAL NOT NULL,
                PRIMARY KEY (contactId, dhPublicKey, messageNumber),
                FOREIGN KEY (contactId) REFERENCES contacts(id) ON DELETE CASCADE
            )
            """.trimIndent()
        )
        db.execSQL("CREATE INDEX idx_messages_contactId_createdAt ON messages(contactId, createdAt)")
        db.execSQL("CREATE INDEX idx_skippedKeys_createdAt ON skippedKeys(createdAt)")
    }
}
