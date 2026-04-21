package com.kordar.ghostchat.core.crypto

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

/**
 * Plaintext envelope wrapping every message (chat text or control JSON) before padding +
 * encryption. Carries the application-level timestamp and counter used by [ReplayGuard]
 * to reject stale replays.
 *
 * Wire shape — sorted JSON keys, byte-identical iOS ↔ Android:
 * `{"c":7,"id":"env-1","m":"hello","t":1713100800000}`.
 *
 * Mirror of iOS `MessageEnvelope` — [encode] produces the exact same JSON as iOS
 * `JSONEncoder.envelope.encode(env)`.
 */
data class MessageEnvelope(
    /** Application payload — raw chat text or a JSON-encoded [com.kordar.ghostchat.models.ControlMessage]. */
    val m: String,
    /** Sender's wall-clock timestamp in milliseconds since the Unix epoch. */
    val t: Long,
    /** Monotonic per-session counter minted by the sender (independent of ratchet n). */
    val c: Long,
    /** Unique message identifier (UUID-v4 in production, arbitrary string in tests). */
    val id: String
) {
    companion object {
        private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

        /**
         * Produce the canonical sorted-key JSON. kotlinx.serialization does not guarantee key
         * ordering on its own, so we build the [JsonObject] in alphabetical order ourselves:
         * c, id, m, t.
         */
        fun encode(env: MessageEnvelope): String {
            val obj = buildJsonObject {
                put("c",  JsonPrimitive(env.c))
                put("id", JsonPrimitive(env.id))
                put("m",  JsonPrimitive(env.m))
                put("t",  JsonPrimitive(env.t))
            }
            return json.encodeToString(JsonObject.serializer(), obj)
        }

        fun decode(raw: String): MessageEnvelope {
            val obj = json.parseToJsonElement(raw).jsonObject
            val c  = obj["c"]?.jsonPrimitive?.long
                ?: throw IllegalArgumentException("MessageEnvelope missing c")
            val id = obj["id"]?.jsonPrimitive?.content
                ?: throw IllegalArgumentException("MessageEnvelope missing id")
            val m  = obj["m"]?.jsonPrimitive?.content
                ?: throw IllegalArgumentException("MessageEnvelope missing m")
            val t  = obj["t"]?.jsonPrimitive?.long
                ?: throw IllegalArgumentException("MessageEnvelope missing t")
            return MessageEnvelope(m = m, t = t, c = c, id = id)
        }
    }
}
