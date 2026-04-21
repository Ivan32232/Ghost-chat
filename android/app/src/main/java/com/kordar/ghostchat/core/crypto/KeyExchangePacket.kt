package com.kordar.ghostchat.core.crypto

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Plain-text wire packet exchanged during the ECDH handshake, before Double Ratchet
 * is initialised. JSON field names are identical to iOS `KeyExchangePacket`.
 *
 * `publicKey` and `identityKey` are base64-encoded 65-byte x963 points.
 * `pqKey` / `pqSupported` are reserved for Phase 6 ML-KEM hybrid.
 */
@Serializable
data class KeyExchangePacket(
    val type: String = "key-exchange",
    val publicKey: String,   // base64(65-byte x963 pub)
    val identityKey: String, // base64(65-byte x963 identity pub)
    val v: Int = 3,
    val pqKey: String? = null,
    val pqSupported: Boolean? = null
) {
    companion object {
        private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

        fun encode(packet: KeyExchangePacket): String = json.encodeToString(serializer(), packet)
        fun decode(raw: String): KeyExchangePacket = json.decodeFromString(serializer(), raw)
    }
}

/** Persistence blob capturing a full crypto session. Mirrors iOS `GhostCryptoExport`. */
@Serializable
internal data class GhostCryptoExport(
    val ratchetState: String,  // base64 of DoubleRatchet.exportedState
    val peerIdentity: String   // base64 of 65-byte x963 peer identity
)
