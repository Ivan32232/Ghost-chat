package com.kordar.ghostchat.models

import java.util.UUID

/**
 * Persisted / in-memory chat message. Field names mirror iOS `ChatMessage.swift` so the
 * same SQLCipher schema works for both platforms.
 */
data class ChatMessage(
    val id: String = UUID.randomUUID().toString(),
    val contactId: String = "",
    val sender: Sender,
    val text: String,
    val type: MessageType = MessageType.TEXT,
    var isDelivered: Boolean = false,
    var isPending: Boolean = true,
    val createdAt: Long = System.currentTimeMillis(),
    val fileName: String? = null,
    val fileSize: Int? = null,
    val fileMimeType: String? = null,
    val fileLocalPath: String? = null,
    val fileId: String? = null,
    val replyToId: String? = null,
    val replyToText: String? = null,
    var isEdited: Boolean = false,
    val senderMessageId: String? = null,
    var isPinned: Boolean = false
) {
    /**
     * Over-the-wire payload format (matches iOS ChatMessage.WirePayload exactly):
     *   { "m": text, "t": unix_ms, "c": counter, "id": uuid, "r"?: { "id", "t" } }
     */
    data class WirePayload(
        val m: String,
        val t: Long,
        val c: Long,
        val id: String,
        val r: Reply? = null
    ) {
        data class Reply(val id: String, val t: String)
    }
}
