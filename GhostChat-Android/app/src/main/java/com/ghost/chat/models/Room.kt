package com.ghost.chat.models

import java.util.Date

data class Room(
    val id: String,
    val isHost: Boolean,
    val createdAt: Date = Date()
) {
    /** Room TTL: 10 minutes */
    val isExpired: Boolean
        get() = (System.currentTimeMillis() - createdAt.time) > 10 * 60 * 1000
}
