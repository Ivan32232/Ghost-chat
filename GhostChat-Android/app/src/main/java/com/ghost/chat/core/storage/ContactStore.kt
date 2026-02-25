package com.ghost.chat.core.storage

import android.content.ContentValues
import com.ghost.chat.models.Contact
import java.util.Date

/// Contact CRUD — port of iOS ContactStore
/// All operations are thread-safe via synchronized
class ContactStore(private val db: DatabaseService) {

    // MARK: - CRUD

    /** Save (insert or replace) a contact */
    fun save(contact: Contact) {
        synchronized(this) {
            val values = ContentValues().apply {
                put("id", contact.id)
                put("label", contact.label)
                put("publicKey", contact.publicKey)
                put("identityKey", contact.identityKey)
                put("ratchetState", contact.ratchetState)
                put("previousKey", contact.previousKey)
                put("fallbackKey", contact.fallbackKey)
                put("pushToken", contact.pushToken)
                put("rotationCounter", contact.rotationCounter)
                put("sessionCount", contact.sessionCount)
                put("createdAt", contact.createdAt.time.toDouble() / 1000.0)
                put("lastSessionAt", contact.lastSessionAt?.let { it.time.toDouble() / 1000.0 })
            }
            db.getDb().insertWithOnConflict("contacts", null, values,
                net.sqlcipher.database.SQLiteDatabase.CONFLICT_REPLACE)
        }
    }

    /** Fetch all contacts ordered by lastSessionAt DESC */
    fun fetchAll(): List<Contact> {
        synchronized(this) {
            val contacts = mutableListOf<Contact>()
            val cursor = db.getDb().rawQuery(
                "SELECT * FROM contacts ORDER BY lastSessionAt DESC", null
            )
            cursor.use {
                while (it.moveToNext()) {
                    contacts.add(cursorToContact(it))
                }
            }
            return contacts
        }
    }

    /** Fetch single contact by ID */
    fun fetch(id: String): Contact? {
        synchronized(this) {
            val cursor = db.getDb().rawQuery(
                "SELECT * FROM contacts WHERE id = ?", arrayOf(id)
            )
            cursor.use {
                if (it.moveToFirst()) return cursorToContact(it)
            }
            return null
        }
    }

    /** Fetch contact by identity key (for peer recognition) */
    fun fetchByIdentityKey(identityKey: ByteArray): Contact? {
        synchronized(this) {
            val cursor = db.getDb().rawQuery(
                "SELECT * FROM contacts WHERE identityKey = ?",
                arrayOf(android.util.Base64.encodeToString(identityKey, android.util.Base64.NO_WRAP))
            )
            // SQLCipher doesn't support direct BLOB comparison well, so fetch all and compare
            cursor.close()

            // Fetch all and compare bytewise
            val all = fetchAll()
            return all.find { it.identityKey.contentEquals(identityKey) }
        }
    }

    /** Update ratchet state */
    fun updateRatchetState(contactId: String, ratchetState: ByteArray?) {
        synchronized(this) {
            val values = ContentValues().apply {
                put("ratchetState", ratchetState)
                put("lastSessionAt", System.currentTimeMillis().toDouble() / 1000.0)
            }
            db.getDb().update("contacts", values, "id = ?", arrayOf(contactId))
        }
    }

    /** Update label */
    fun updateLabel(contactId: String, label: String) {
        synchronized(this) {
            val values = ContentValues().apply { put("label", label) }
            db.getDb().update("contacts", values, "id = ?", arrayOf(contactId))
        }
    }

    /** Increment session count */
    fun incrementSessionCount(contactId: String) {
        synchronized(this) {
            db.getDb().execSQL(
                "UPDATE contacts SET sessionCount = sessionCount + 1, lastSessionAt = ? WHERE id = ?",
                arrayOf(System.currentTimeMillis().toDouble() / 1000.0, contactId)
            )
        }
    }

    /** Delete contact */
    fun delete(id: String) {
        synchronized(this) {
            db.getDb().delete("contacts", "id = ?", arrayOf(id))
            db.getDb().delete("skippedKeys", "contactId = ?", arrayOf(id))
        }
    }

    /** Delete all contacts */
    fun deleteAll() {
        synchronized(this) {
            db.getDb().delete("contacts", null, null)
            db.getDb().delete("skippedKeys", null, null)
        }
    }

    // MARK: - Skipped Keys

    /** Save skipped keys for a contact */
    fun saveSkippedKeys(contactId: String, keys: List<Triple<ByteArray, Int, ByteArray>>) {
        synchronized(this) {
            // Clear existing
            db.getDb().delete("skippedKeys", "contactId = ?", arrayOf(contactId))

            val now = System.currentTimeMillis().toDouble() / 1000.0
            for ((dhKey, msgNum, msgKey) in keys) {
                val values = ContentValues().apply {
                    put("contactId", contactId)
                    put("dhPublicKey", dhKey)
                    put("messageNumber", msgNum)
                    put("messageKey", msgKey)
                    put("createdAt", now)
                }
                db.getDb().insert("skippedKeys", null, values)
            }
        }
    }

    /** Fetch skipped keys for a contact */
    fun fetchSkippedKeys(contactId: String): List<Triple<ByteArray, Int, ByteArray>> {
        synchronized(this) {
            val keys = mutableListOf<Triple<ByteArray, Int, ByteArray>>()
            val cursor = db.getDb().rawQuery(
                "SELECT dhPublicKey, messageNumber, messageKey FROM skippedKeys WHERE contactId = ?",
                arrayOf(contactId)
            )
            cursor.use {
                while (it.moveToNext()) {
                    val dhKey = it.getBlob(0)
                    val msgNum = it.getInt(1)
                    val msgKey = it.getBlob(2)
                    keys.add(Triple(dhKey, msgNum, msgKey))
                }
            }
            return keys
        }
    }

    // MARK: - Private

    private fun cursorToContact(cursor: net.sqlcipher.Cursor): Contact {
        return Contact(
            id = cursor.getString(cursor.getColumnIndexOrThrow("id")),
            label = cursor.getString(cursor.getColumnIndexOrThrow("label")),
            publicKey = cursor.getBlob(cursor.getColumnIndexOrThrow("publicKey")),
            identityKey = cursor.getBlob(cursor.getColumnIndexOrThrow("identityKey")) ?: ByteArray(0),
            ratchetState = cursor.getBlob(cursor.getColumnIndexOrThrow("ratchetState")),
            previousKey = cursor.getBlob(cursor.getColumnIndexOrThrow("previousKey")),
            fallbackKey = cursor.getBlob(cursor.getColumnIndexOrThrow("fallbackKey")),
            pushToken = cursor.getBlob(cursor.getColumnIndexOrThrow("pushToken")),
            rotationCounter = cursor.getInt(cursor.getColumnIndexOrThrow("rotationCounter")),
            sessionCount = cursor.getInt(cursor.getColumnIndexOrThrow("sessionCount")),
            createdAt = Date((cursor.getDouble(cursor.getColumnIndexOrThrow("createdAt")) * 1000).toLong()),
            lastSessionAt = cursor.getColumnIndex("lastSessionAt").let { idx ->
                if (idx >= 0 && !cursor.isNull(idx)) {
                    Date((cursor.getDouble(idx) * 1000).toLong())
                } else null
            }
        )
    }
}
