package com.kordar.ghostchat.core.storage

import android.content.ContentValues
import com.kordar.ghostchat.models.ChatMessage
import com.kordar.ghostchat.models.MessageType
import com.kordar.ghostchat.models.Sender
import net.zetetic.database.sqlcipher.SQLiteDatabase

/** Persisted skipped Double-Ratchet message key (for saved contacts). */
data class SkippedKey(
    val contactId: String,
    val dhPublicKey: ByteArray,
    val messageNumber: Int,
    val messageKey: ByteArray,
    val createdAt: Long
)

class MessageStore(database: DatabaseService) {

    private val db: SQLiteDatabase = database.db

    // MARK: - Messages

    fun append(message: ChatMessage) {
        val values = ContentValues().apply {
            put("id", message.id)
            put("contactId", message.contactId)
            put("sender", message.sender.raw)
            put("text", message.text)
            put("type", message.type.raw)
            put("isDelivered", if (message.isDelivered) 1 else 0)
            put("isPending",   if (message.isPending) 1 else 0)
            put("createdAt", message.createdAt.toSqlDouble())
            put("fileName", message.fileName)
            put("fileSize", message.fileSize)
            put("fileMimeType", message.fileMimeType)
            put("fileLocalPath", message.fileLocalPath)
            put("fileId", message.fileId)
            put("replyToId", message.replyToId)
            put("replyToText", message.replyToText)
            put("isEdited", if (message.isEdited) 1 else 0)
            put("senderMessageId", message.senderMessageId)
            put("isPinned", if (message.isPinned) 1 else 0)
        }
        db.insertWithOnConflict("messages", null, values, SQLiteDatabase.CONFLICT_REPLACE)
    }

    fun fetch(contactId: String, limit: Int = 500): List<ChatMessage> =
        db.rawQuery(
            "SELECT * FROM messages WHERE contactId = ? ORDER BY createdAt ASC LIMIT ?",
            arrayOf(contactId, limit.toString())
        ).use { cursor ->
            val rows = mutableListOf<ChatMessage>()
            while (cursor.moveToNext()) rows += cursor.toMessage()
            rows
        }

    fun deleteMessage(id: String) {
        db.delete("messages", "id = ?", arrayOf(id))
    }

    fun deleteAll(contactId: String) {
        db.delete("messages", "contactId = ?", arrayOf(contactId))
    }

    fun pinnedMessages(contactId: String): List<ChatMessage> =
        db.rawQuery(
            "SELECT * FROM messages WHERE contactId = ? AND isPinned = 1 ORDER BY createdAt ASC",
            arrayOf(contactId)
        ).use { cursor ->
            val rows = mutableListOf<ChatMessage>()
            while (cursor.moveToNext()) rows += cursor.toMessage()
            rows
        }

    // MARK: - Skipped keys

    fun storeSkipped(key: SkippedKey) {
        val values = ContentValues().apply {
            put("contactId", key.contactId)
            put("dhPublicKey", key.dhPublicKey)
            put("messageNumber", key.messageNumber)
            put("messageKey", key.messageKey)
            put("createdAt", key.createdAt.toSqlDouble())
        }
        db.insertWithOnConflict("skippedKeys", null, values, SQLiteDatabase.CONFLICT_REPLACE)
    }

    fun takeSkipped(contactId: String, dhPublicKey: ByteArray, messageNumber: Int): SkippedKey? {
        val row = db.rawQuery(
            """
            SELECT contactId, dhPublicKey, messageNumber, messageKey, createdAt
            FROM skippedKeys
            WHERE contactId = ? AND dhPublicKey = ? AND messageNumber = ?
            """.trimIndent(),
            arrayOf(contactId, dhPublicKey, messageNumber.toString())
        ).use { cursor ->
            if (!cursor.moveToNext()) return null
            SkippedKey(
                contactId = cursor.getString(0),
                dhPublicKey = cursor.getBlob(1),
                messageNumber = cursor.getInt(2),
                messageKey = cursor.getBlob(3),
                createdAt = cursor.getDouble(4).fromSqlDouble()
            )
        }
        db.delete(
            "skippedKeys",
            "contactId = ? AND dhPublicKey = ? AND messageNumber = ?",
            arrayOf(contactId, dhPublicKey, messageNumber.toString())
        )
        return row
    }

    fun pruneSkipped(maxAgeMs: Long = 86_400_000L, nowEpochMs: Long = System.currentTimeMillis()) {
        val cutoff = (nowEpochMs - maxAgeMs).toSqlDouble()
        db.delete("skippedKeys", "createdAt < ?", arrayOf(cutoff.toString()))
    }

    // MARK: - Private

    private fun android.database.Cursor.toMessage(): ChatMessage {
        return ChatMessage(
            id               = getString(getColumnIndexOrThrow("id")),
            contactId        = getString(getColumnIndexOrThrow("contactId")),
            sender           = Sender.fromRaw(getInt(getColumnIndexOrThrow("sender"))),
            text             = getString(getColumnIndexOrThrow("text")),
            type             = MessageType.fromRaw(getInt(getColumnIndexOrThrow("type"))),
            isDelivered      = getInt(getColumnIndexOrThrow("isDelivered")) != 0,
            isPending        = getInt(getColumnIndexOrThrow("isPending")) != 0,
            createdAt        = getDouble(getColumnIndexOrThrow("createdAt")).fromSqlDouble(),
            fileName         = getStringOrNull("fileName"),
            fileSize         = getIntOrNull("fileSize"),
            fileMimeType     = getStringOrNull("fileMimeType"),
            fileLocalPath    = getStringOrNull("fileLocalPath"),
            fileId           = getStringOrNull("fileId"),
            replyToId        = getStringOrNull("replyToId"),
            replyToText      = getStringOrNull("replyToText"),
            isEdited         = getInt(getColumnIndexOrThrow("isEdited")) != 0,
            senderMessageId  = getStringOrNull("senderMessageId"),
            isPinned         = getInt(getColumnIndexOrThrow("isPinned")) != 0
        )
    }

    private fun android.database.Cursor.getStringOrNull(column: String): String? {
        val idx = getColumnIndexOrThrow(column)
        return if (isNull(idx)) null else getString(idx)
    }

    private fun android.database.Cursor.getIntOrNull(column: String): Int? {
        val idx = getColumnIndexOrThrow(column)
        return if (isNull(idx)) null else getInt(idx)
    }
}

private fun Long.toSqlDouble(): Double = this.toDouble() / 1000.0
private fun Double.fromSqlDouble(): Long = (this * 1000.0).toLong()
