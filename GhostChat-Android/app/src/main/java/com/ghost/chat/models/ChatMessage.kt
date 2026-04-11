package com.ghost.chat.models

import java.util.Date
import java.util.UUID

data class ChatMessage(
    val id: String = UUID.randomUUID().toString(),
    val contactId: String? = null,      // null = legacy/anonymous session
    val text: String,
    val type: MessageType,
    val timestamp: Date = Date(),
    var isDelivered: Boolean = false,
    var isRead: Boolean = false,
    var isPending: Boolean = false,
    val expiresAt: Date? = null,        // null = persistent, no auto-delete
    // File attachment (null = text-only message)
    val fileName: String? = null,
    val fileSize: Long? = null,
    val fileMimeType: String? = null,
    var fileLocalPath: String? = null,   // relative path inside app's files dir
    var fileTransferProgress: Double? = null, // 0.0-1.0 during transfer, null when done
    val fileId: String? = null,           // unique ID for chunked transfer correlation
    // Reply (Telegram-style inline quote)
    val replyToId: String? = null,         // sender's message UUID that this replies to
    val replyToText: String? = null,       // quoted text preview (truncated)
    // Edit
    val isEdited: Boolean = false,
    // Sender's message ID (for cross-device delete/edit correlation)
    val senderMessageId: String? = null
) {
    val isFileMessage: Boolean get() = fileName != null

    enum class MessageType(val value: Int) {
        SENT(0), RECEIVED(1), SYSTEM(2);

        companion object {
            fun fromValue(value: Int) = entries.firstOrNull { it.value == value } ?: SYSTEM
        }
    }

    val isExpired: Boolean get() = expiresAt != null && expiresAt.time <= System.currentTimeMillis()
    val remainingTime: Long get() = if (expiresAt != null) maxOf(0, expiresAt.time - System.currentTimeMillis()) else Long.MAX_VALUE

    // NOTE: data class default equals/hashCode uses ALL fields
    // Required for SnapshotStateList to detect changes to fileLocalPath,
    // isDelivered, isRead, fileTransferProgress, etc.
}
