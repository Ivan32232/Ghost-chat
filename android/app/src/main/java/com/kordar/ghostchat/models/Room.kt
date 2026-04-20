package com.kordar.ghostchat.models

import java.util.UUID

/**
 * Ephemeral session room. IDs are 48 random bytes → base64url (64 chars / 384-bit entropy).
 */
data class Room(
    val id: String,
    val createdAt: Long = System.currentTimeMillis(),
    val myRole: Role
) {
    companion object {
        /** Mirrors iOS `Room.isValidID`. */
        fun isValidId(candidate: String): Boolean {
            if (candidate.length != 64) return false
            return candidate.all { ch ->
                ch.isLetterOrDigit() || ch == '-' || ch == '_'
            }
        }

        /** Generate a fresh UUID-backed ID for tests only — production IDs come from the server. */
        internal fun randomTestingId(): String = UUID.randomUUID().toString().replace("-", "").padEnd(64, '_').substring(0, 64)
    }
}
