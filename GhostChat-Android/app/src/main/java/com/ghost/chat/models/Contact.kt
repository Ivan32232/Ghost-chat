package com.ghost.chat.models

import java.util.Date
import java.util.UUID

data class Contact(
    val id: String = UUID.randomUUID().toString(),
    var label: String,
    var publicKey: ByteArray,       // Ephemeral from last session
    var identityKey: ByteArray,     // Static identity key (65 bytes x963)
    var ratchetState: ByteArray? = null,  // JSON-encoded DoubleRatchetState
    var previousKey: ByteArray? = null,
    var fallbackKey: ByteArray? = null,
    var pushToken: ByteArray? = null,
    var rotationCounter: Int = 0,
    var sessionCount: Int = 0,
    val createdAt: Date = Date(),
    var lastSessionAt: Date? = null
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is Contact) return false
        return id == other.id
    }

    override fun hashCode(): Int = id.hashCode()
}
