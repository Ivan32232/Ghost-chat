package com.ghost.chat.models

import java.util.Date
import java.util.UUID

data class ChatMessage(
    val id: String = UUID.randomUUID().toString(),
    val text: String,
    val type: MessageType,
    val timestamp: Date = Date(),
    var isDelivered: Boolean = false,
    val expiresAt: Date
) {
    enum class MessageType { SENT, RECEIVED, SYSTEM }

    val isExpired: Boolean get() = expiresAt.time <= System.currentTimeMillis()
    val remainingTime: Long get() = maxOf(0, expiresAt.time - System.currentTimeMillis())
}
