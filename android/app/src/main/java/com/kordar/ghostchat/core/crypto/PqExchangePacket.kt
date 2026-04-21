package com.kordar.ghostchat.core.crypto

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Second-round handshake packet — GUEST-originated. Sent over the plaintext DataChannel
 * *after* the initial simultaneous exchange of [KeyExchangePacket]s, iff HOST advertised
 * a Kyber public key in its `pqKey` field and the GUEST can do ML-KEM encapsulation.
 *
 * HOST decapsulates the `pqCiphertext` into the 32-byte PQ shared secret, combines it
 * with the ECDH shared secret via [PostQuantum.hybridDeriveSharedKey], and only then
 * initialises its DoubleRatchet — before that it sits in an `awaitingPq` state.
 *
 * Wire shape: `{"type":"pq-exchange","pqCiphertext":"<base64>"}`.
 * Byte-identical to iOS `PqExchangePacket`.
 */
@Serializable
data class PqExchangePacket(
    val type: String = "pq-exchange",
    /** base64 of the 1088-byte ML-KEM768 ciphertext */
    val pqCiphertext: String
) {
    companion object {
        private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

        fun encode(p: PqExchangePacket): String = json.encodeToString(serializer(), p)
        fun decode(raw: String): PqExchangePacket = json.decodeFromString(serializer(), raw)
    }
}
