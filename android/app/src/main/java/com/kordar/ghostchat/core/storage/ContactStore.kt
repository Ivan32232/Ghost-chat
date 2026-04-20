package com.kordar.ghostchat.core.storage

import android.content.ContentValues
import com.kordar.ghostchat.models.Contact
import net.zetetic.database.sqlcipher.SQLiteDatabase

/**
 * Mirror of iOS `ContactStore`. Uses raw SQLCipher cursors — same schema, same semantics.
 */
class ContactStore(database: DatabaseService) {

    private val db: SQLiteDatabase = database.db

    fun all(): List<Contact> =
        db.rawQuery(
            "SELECT * FROM contacts ORDER BY lastSessionAt DESC, createdAt DESC",
            arrayOf()
        ).use { cursor ->
            val rows = mutableListOf<Contact>()
            while (cursor.moveToNext()) rows += cursor.toContact()
            rows
        }

    fun fetch(id: String): Contact? =
        db.rawQuery("SELECT * FROM contacts WHERE id = ?", arrayOf(id)).use { cursor ->
            if (cursor.moveToNext()) cursor.toContact() else null
        }

    fun fetchByIdentityKey(identityKey: ByteArray): Contact? =
        db.rawQuery(
            "SELECT * FROM contacts WHERE identityKey = ?",
            arrayOf(identityKey)
        ).use { cursor ->
            if (cursor.moveToNext()) cursor.toContact() else null
        }

    fun save(contact: Contact) {
        val values = ContentValues().apply {
            put("id", contact.id)
            put("label", contact.label)
            put("identityKey", contact.identityKey)
            put("publicKey", contact.publicKey)
            put("previousKey", contact.previousKey)
            put("fallbackKey", contact.fallbackKey)
            put("pushToken", contact.pushToken)
            put("notifyToken", contact.notifyToken)
            put("ratchetState", contact.ratchetState)
            put("rotationCounter", contact.rotationCounter)
            put("sessionCount", contact.sessionCount)
            put("messageTTL", contact.messageTTL)
            put("notes", contact.notes)
            put("isMuted", if (contact.isMuted) 1 else 0)
            put("createdAt", contact.createdAt.toSqlDouble())
            put("lastSessionAt", contact.lastSessionAt?.toSqlDouble())
        }
        db.insertWithOnConflict("contacts", null, values, SQLiteDatabase.CONFLICT_REPLACE)
    }

    fun delete(id: String) {
        db.delete("contacts", "id = ?", arrayOf(id))
    }

    fun deleteAll() {
        db.delete("contacts", null, null)
    }

    fun updateRatchetState(id: String, state: ByteArray) {
        val values = ContentValues().apply { put("ratchetState", state) }
        db.update("contacts", values, "id = ?", arrayOf(id))
    }

    fun bumpSessionCount(id: String, nowEpochMs: Long = System.currentTimeMillis()) {
        db.execSQL(
            "UPDATE contacts SET sessionCount = sessionCount + 1, lastSessionAt = ? WHERE id = ?",
            arrayOf(nowEpochMs.toSqlDouble(), id)
        )
    }

    fun setMuted(id: String, muted: Boolean) {
        db.execSQL("UPDATE contacts SET isMuted = ? WHERE id = ?", arrayOf(if (muted) 1 else 0, id))
    }

    private fun android.database.Cursor.toContact(): Contact {
        return Contact(
            id             = getString(getColumnIndexOrThrow("id")),
            label          = getString(getColumnIndexOrThrow("label")),
            identityKey    = getBlob(getColumnIndexOrThrow("identityKey")),
            publicKey      = getBlob(getColumnIndexOrThrow("publicKey")),
            previousKey    = getBlobOrNull("previousKey"),
            fallbackKey    = getBlobOrNull("fallbackKey"),
            pushToken      = getBlobOrNull("pushToken"),
            notifyToken    = getBlobOrNull("notifyToken"),
            ratchetState   = getBlobOrNull("ratchetState"),
            rotationCounter = getInt(getColumnIndexOrThrow("rotationCounter")),
            sessionCount   = getInt(getColumnIndexOrThrow("sessionCount")),
            messageTTL     = getInt(getColumnIndexOrThrow("messageTTL")),
            notes          = getStringOrNull("notes"),
            isMuted        = getInt(getColumnIndexOrThrow("isMuted")) != 0,
            createdAt      = getDouble(getColumnIndexOrThrow("createdAt")).fromSqlDouble(),
            lastSessionAt  = if (isNull(getColumnIndexOrThrow("lastSessionAt"))) null
                             else getDouble(getColumnIndexOrThrow("lastSessionAt")).fromSqlDouble()
        )
    }

    private fun android.database.Cursor.getBlobOrNull(column: String): ByteArray? {
        val idx = getColumnIndexOrThrow(column)
        return if (isNull(idx)) null else getBlob(idx)
    }

    private fun android.database.Cursor.getStringOrNull(column: String): String? {
        val idx = getColumnIndexOrThrow(column)
        return if (isNull(idx)) null else getString(idx)
    }
}

// MARK: - Date conversions (match iOS GRDB REAL-as-seconds-since-1970 convention)

private fun Long.toSqlDouble(): Double = this.toDouble() / 1000.0
private fun Double.fromSqlDouble(): Long = (this * 1000.0).toLong()
