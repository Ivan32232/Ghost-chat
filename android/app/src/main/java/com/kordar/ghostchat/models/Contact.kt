package com.kordar.ghostchat.models

import java.util.UUID

/**
 * Persisted contact record. Field names match iOS `Contact.swift` and the SQLCipher schema.
 * `identityKey` / `publicKey` store raw bytes (65-byte x963 for identity, same for current DH ratchet pub).
 */
data class Contact(
    val id: String = UUID.randomUUID().toString(),
    var label: String,
    var identityKey: ByteArray,
    var publicKey: ByteArray,
    var previousKey: ByteArray? = null,
    var fallbackKey: ByteArray? = null,
    var pushToken: ByteArray? = null,
    var notifyToken: ByteArray? = null,
    var ratchetState: ByteArray? = null,
    var rotationCounter: Int = 0,
    var sessionCount: Int = 0,
    var messageTTL: Int = MessageTTL.FIVE_MINUTES.seconds,
    var notes: String? = null,
    var isMuted: Boolean = false,
    val createdAt: Long = System.currentTimeMillis(),
    var lastSessionAt: Long? = null
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is Contact) return false
        return id == other.id
    }

    override fun hashCode(): Int = id.hashCode()
}
