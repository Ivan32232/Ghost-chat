package com.ghost.chat.core.storage

import android.content.ContentValues
import com.ghost.chat.models.ChatMessage
import java.util.Date

/// CRUD для сообщений (Ghost Threads) — SQLCipher
class MessageStore(private val db: DatabaseService) {

    // MARK: - Save

    fun save(message: ChatMessage) {
        synchronized(this) {
            val values = ContentValues().apply {
                put("id", message.id)
                put("contactId", message.contactId)
                put("text", message.text)
                put("type", message.type.value)
                put("isDelivered", if (message.isDelivered) 1 else 0)
                put("isPending", if (message.isPending) 1 else 0)
                put("createdAt", message.timestamp.time.toDouble() / 1000.0)
                put("fileName", message.fileName)
                put("fileSize", message.fileSize)
                put("fileMimeType", message.fileMimeType)
                put("fileLocalPath", message.fileLocalPath)
                put("fileId", message.fileId)
                put("replyToId", message.replyToId)
                put("replyToText", message.replyToText)
                put("isEdited", if (message.isEdited) 1 else 0)
                put("senderMessageId", message.senderMessageId)
            }
            db.getDb().insertWithOnConflict(
                "messages", null, values,
                net.sqlcipher.database.SQLiteDatabase.CONFLICT_REPLACE
            )
        }
    }

    // MARK: - Fetch

    fun fetchForContact(contactId: String, limit: Int = 100, offset: Int = 0): List<ChatMessage> {
        synchronized(this) {
            val cursor = db.getDb().rawQuery(
                "SELECT id, contactId, text, type, isDelivered, isPending, createdAt, fileName, fileSize, fileMimeType, fileLocalPath, fileId, replyToId, replyToText, isEdited, senderMessageId FROM messages WHERE contactId = ? ORDER BY createdAt ASC LIMIT ? OFFSET ?",
                arrayOf(contactId, limit.toString(), offset.toString())
            )
            val messages = mutableListOf<ChatMessage>()
            cursor.use {
                while (it.moveToNext()) {
                    cursorToMessage(it)?.let { msg -> messages.add(msg) }
                }
            }
            return messages
        }
    }

    fun fetchLastMessage(contactId: String): ChatMessage? {
        synchronized(this) {
            val cursor = db.getDb().rawQuery(
                "SELECT id, contactId, text, type, isDelivered, isPending, createdAt, fileName, fileSize, fileMimeType, fileLocalPath, fileId, replyToId, replyToText, isEdited, senderMessageId FROM messages WHERE contactId = ? ORDER BY createdAt DESC LIMIT 1",
                arrayOf(contactId)
            )
            cursor.use {
                if (it.moveToFirst()) {
                    return cursorToMessage(it)
                }
            }
            return null
        }
    }

    fun countUnread(contactId: String): Int {
        synchronized(this) {
            val cursor = db.getDb().rawQuery(
                "SELECT COUNT(*) FROM messages WHERE contactId = ? AND type = 1 AND isDelivered = 0",
                arrayOf(contactId)
            )
            cursor.use {
                if (it.moveToFirst()) return it.getInt(0)
            }
            return 0
        }
    }

    fun fetchPending(contactId: String): List<ChatMessage> {
        synchronized(this) {
            val cursor = db.getDb().rawQuery(
                "SELECT id, contactId, text, type, isDelivered, isPending, createdAt, fileName, fileSize, fileMimeType, fileLocalPath, fileId, replyToId, replyToText, isEdited, senderMessageId FROM messages WHERE contactId = ? AND isPending = 1 ORDER BY createdAt ASC",
                arrayOf(contactId)
            )
            val messages = mutableListOf<ChatMessage>()
            cursor.use {
                while (it.moveToNext()) {
                    cursorToMessage(it)?.let { msg -> messages.add(msg) }
                }
            }
            return messages
        }
    }

    // MARK: - Update

    fun markDelivered(messageId: String) {
        synchronized(this) {
            val values = ContentValues().apply { put("isDelivered", 1) }
            db.getDb().update("messages", values, "id = ?", arrayOf(messageId))
        }
    }

    fun markSent(messageId: String) {
        synchronized(this) {
            val values = ContentValues().apply { put("isPending", 0) }
            db.getDb().update("messages", values, "id = ?", arrayOf(messageId))
        }
    }

    /** Mark all received messages for a contact as delivered (clears unread count) */
    fun markAllDelivered(contactId: String) {
        synchronized(this) {
            val values = ContentValues().apply { put("isDelivered", 1) }
            db.getDb().update("messages", values, "contactId = ? AND type = 1 AND isDelivered = 0", arrayOf(contactId))
        }
    }

    // MARK: - Delete

    fun deleteForContact(contactId: String) {
        synchronized(this) {
            db.getDb().delete("messages", "contactId = ?", arrayOf(contactId))
        }
    }

    fun deleteOlderThan(date: Date) {
        synchronized(this) {
            val timestamp = date.time.toDouble() / 1000.0
            db.getDb().execSQL("DELETE FROM messages WHERE createdAt < ?", arrayOf(timestamp))
        }
    }

    /** Delete expired messages for a specific contact based on TTL (seconds) */
    fun deleteExpired(contactId: String, ttlSeconds: Int) {
        synchronized(this) {
            val cutoff = (System.currentTimeMillis() / 1000.0) - ttlSeconds
            db.getDb().execSQL(
                "DELETE FROM messages WHERE contactId = ? AND createdAt < ?",
                arrayOf(contactId, cutoff)
            )
        }
    }

    fun deleteAll() {
        synchronized(this) {
            db.getDb().execSQL("DELETE FROM messages")
        }
    }

    // MARK: - Delete by sender message ID (for "delete for everyone")

    fun deleteBySenderMessageId(senderMessageId: String) {
        synchronized(this) {
            db.getDb().delete("messages", "senderMessageId = ?", arrayOf(senderMessageId))
        }
    }

    // MARK: - Update text (for "edit message")

    fun updateText(senderMessageId: String, newText: String) {
        synchronized(this) {
            val values = ContentValues().apply {
                put("text", newText)
                put("isEdited", 1)
            }
            db.getDb().update("messages", values, "senderMessageId = ?", arrayOf(senderMessageId))
        }
    }

    // MARK: - Private

    private fun cursorToMessage(cursor: android.database.Cursor): ChatMessage? {
        return try {
            val id = cursor.getString(cursor.getColumnIndexOrThrow("id"))
            val contactId = cursor.getString(cursor.getColumnIndexOrThrow("contactId"))
            val text = cursor.getString(cursor.getColumnIndexOrThrow("text"))
            val typeVal = cursor.getInt(cursor.getColumnIndexOrThrow("type"))
            val isDelivered = cursor.getInt(cursor.getColumnIndexOrThrow("isDelivered")) != 0
            val isPending = cursor.getInt(cursor.getColumnIndexOrThrow("isPending")) != 0
            val createdAt = cursor.getDouble(cursor.getColumnIndexOrThrow("createdAt"))

            val fileName = if (!cursor.isNull(cursor.getColumnIndexOrThrow("fileName")))
                cursor.getString(cursor.getColumnIndexOrThrow("fileName")) else null
            val fileSize = if (!cursor.isNull(cursor.getColumnIndexOrThrow("fileSize")))
                cursor.getLong(cursor.getColumnIndexOrThrow("fileSize")) else null
            val fileMimeType = if (!cursor.isNull(cursor.getColumnIndexOrThrow("fileMimeType")))
                cursor.getString(cursor.getColumnIndexOrThrow("fileMimeType")) else null
            val fileLocalPath = if (!cursor.isNull(cursor.getColumnIndexOrThrow("fileLocalPath")))
                cursor.getString(cursor.getColumnIndexOrThrow("fileLocalPath")) else null
            val fileId = if (!cursor.isNull(cursor.getColumnIndexOrThrow("fileId")))
                cursor.getString(cursor.getColumnIndexOrThrow("fileId")) else null

            val replyToId = if (!cursor.isNull(cursor.getColumnIndexOrThrow("replyToId")))
                cursor.getString(cursor.getColumnIndexOrThrow("replyToId")) else null
            val replyToText = if (!cursor.isNull(cursor.getColumnIndexOrThrow("replyToText")))
                cursor.getString(cursor.getColumnIndexOrThrow("replyToText")) else null
            val isEdited = cursor.getInt(cursor.getColumnIndexOrThrow("isEdited")) != 0
            val senderMessageId = if (!cursor.isNull(cursor.getColumnIndexOrThrow("senderMessageId")))
                cursor.getString(cursor.getColumnIndexOrThrow("senderMessageId")) else null

            ChatMessage(
                id = id,
                contactId = contactId,
                text = text,
                type = ChatMessage.MessageType.fromValue(typeVal),
                timestamp = Date((createdAt * 1000).toLong()),
                isDelivered = isDelivered,
                isPending = isPending,
                fileName = fileName,
                fileSize = fileSize,
                fileMimeType = fileMimeType,
                fileLocalPath = fileLocalPath,
                fileId = fileId,
                replyToId = replyToId,
                replyToText = replyToText,
                isEdited = isEdited,
                senderMessageId = senderMessageId
            )
        } catch (_: Exception) {
            null
        }
    }
}
