package com.kordar.ghostchat.models

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

/**
 * Application-level control messages over the encrypted DataChannel.
 *
 * Wire format: `{ "_ctrl": true, "type": "<wire>", <payload…> }`.
 * MUST stay byte-for-byte compatible with iOS `ControlMessage.swift`.
 */
sealed class ControlMessage {

    abstract val wireType: String

    data class Renegotiate(val sdp: String) : ControlMessage() {
        override val wireType: String = "renegotiate"
    }

    data object CallRequest : ControlMessage() {
        override val wireType: String = "call-request"
    }

    data class CallResponse(val accepted: Boolean) : ControlMessage() {
        override val wireType: String = "call-response"
    }

    data object CallEnd : ControlMessage() {
        override val wireType: String = "call-end"
    }

    data class SecurityAlert(val alert: String) : ControlMessage() {
        override val wireType: String = "security-alert"
    }

    data class MessageAck(val counter: Long) : ControlMessage() {
        override val wireType: String = "message-ack"
    }

    data class MessageRead(val counter: Long) : ControlMessage() {
        override val wireType: String = "message-read"
    }

    data object Ready : ControlMessage() {
        override val wireType: String = "ready"
    }

    data class PushToken(val token: String) : ControlMessage() {
        override val wireType: String = "push-token"
    }

    data class NotifyToken(val token: String) : ControlMessage() {
        override val wireType: String = "notify-token"
    }

    data class Typing(val isTyping: Boolean) : ControlMessage() {
        override val wireType: String = "typing"
    }

    data class Capabilities(val features: List<String>) : ControlMessage() {
        override val wireType: String = "capabilities"
    }

    data class FileStart(
        val fileId: String,
        val name: String,
        val size: Int,
        val mimeType: String,
        val totalChunks: Int
    ) : ControlMessage() {
        override val wireType: String = "file-start"
    }

    data class FileChunk(
        val fileId: String,
        val index: Int,
        val data: String
    ) : ControlMessage() {
        override val wireType: String = "file-chunk"
    }

    data class FileComplete(val fileId: String) : ControlMessage() {
        override val wireType: String = "file-complete"
    }

    data class FileRetransmit(val fileId: String, val indices: List<Int>) : ControlMessage() {
        override val wireType: String = "file-retransmit"
    }

    data class MessageDelete(val messageId: String) : ControlMessage() {
        override val wireType: String = "message-delete"
    }

    data class MessageEdit(val messageId: String, val newText: String) : ControlMessage() {
        override val wireType: String = "message-edit"
    }

    data class MessagePin(val messageId: String, val pinned: Boolean) : ControlMessage() {
        override val wireType: String = "message-pin"
    }

    sealed class DecodingError : RuntimeException() {
        data object MissingCtrlMarker : DecodingError()
        data class UnknownType(val type: String) : DecodingError()
        data class MissingField(val field: String) : DecodingError()
    }

    companion object {
        private val json = Json { ignoreUnknownKeys = true; encodeDefaults = false }

        /** Canonical JSON encoder — field order matches iOS where possible. */
        fun encode(message: ControlMessage): String =
            json.encodeToString(JsonElement.serializer(), toJsonObject(message))

        fun decode(raw: String): ControlMessage {
            val obj = json.parseToJsonElement(raw).jsonObject
            return fromJsonObject(obj)
        }

        fun toJsonObject(message: ControlMessage): JsonObject = buildJsonObject {
            put("_ctrl", JsonPrimitive(true))
            put("type", JsonPrimitive(message.wireType))
            when (message) {
                is Renegotiate   -> put("sdp", JsonPrimitive(message.sdp))
                is CallRequest, is CallEnd, is Ready -> Unit
                is CallResponse  -> put("accepted", JsonPrimitive(message.accepted))
                is SecurityAlert -> put("alert", JsonPrimitive(message.alert))
                is MessageAck    -> put("c", JsonPrimitive(message.counter))
                is MessageRead   -> put("c", JsonPrimitive(message.counter))
                is PushToken     -> put("token", JsonPrimitive(message.token))
                is NotifyToken   -> put("token", JsonPrimitive(message.token))
                is Typing        -> put("isTyping", JsonPrimitive(message.isTyping))
                is Capabilities  -> put("features", JsonArray(message.features.map { JsonPrimitive(it) }))
                is FileStart     -> {
                    put("fileId",      JsonPrimitive(message.fileId))
                    put("name",        JsonPrimitive(message.name))
                    put("size",        JsonPrimitive(message.size))
                    put("mimeType",    JsonPrimitive(message.mimeType))
                    put("totalChunks", JsonPrimitive(message.totalChunks))
                }
                is FileChunk -> {
                    put("fileId", JsonPrimitive(message.fileId))
                    put("index",  JsonPrimitive(message.index))
                    put("data",   JsonPrimitive(message.data))
                }
                is FileComplete    -> put("fileId", JsonPrimitive(message.fileId))
                is FileRetransmit  -> {
                    put("fileId",  JsonPrimitive(message.fileId))
                    put("indices", JsonArray(message.indices.map { JsonPrimitive(it) }))
                }
                is MessageDelete   -> put("messageId", JsonPrimitive(message.messageId))
                is MessageEdit     -> {
                    put("messageId", JsonPrimitive(message.messageId))
                    put("newText",   JsonPrimitive(message.newText))
                }
                is MessagePin      -> {
                    put("messageId", JsonPrimitive(message.messageId))
                    put("pinned",    JsonPrimitive(message.pinned))
                }
            }
        }

        fun fromJsonObject(obj: JsonObject): ControlMessage {
            val isCtrl = obj["_ctrl"]?.jsonPrimitive?.booleanOrNull ?: false
            if (!isCtrl) throw DecodingError.MissingCtrlMarker
            val type = obj["type"]?.jsonPrimitive?.content
                ?: throw DecodingError.MissingField("type")
            return when (type) {
                "renegotiate"      -> Renegotiate(obj.string("sdp"))
                "call-request"     -> CallRequest
                "call-response"    -> CallResponse(obj.bool("accepted"))
                "call-end"         -> CallEnd
                "security-alert"   -> SecurityAlert(obj.string("alert"))
                "message-ack"      -> MessageAck(obj.long("c"))
                "message-read"     -> MessageRead(obj.long("c"))
                "ready"            -> Ready
                "push-token"       -> PushToken(obj.string("token"))
                "notify-token"     -> NotifyToken(obj.string("token"))
                "typing"           -> Typing(obj.bool("isTyping"))
                "capabilities"     -> Capabilities(obj.stringList("features"))
                "file-start"       -> FileStart(
                    fileId      = obj.string("fileId"),
                    name        = obj.string("name"),
                    size        = obj.int("size"),
                    mimeType    = obj.string("mimeType"),
                    totalChunks = obj.int("totalChunks")
                )
                "file-chunk"       -> FileChunk(
                    fileId = obj.string("fileId"),
                    index  = obj.int("index"),
                    data   = obj.string("data")
                )
                "file-complete"    -> FileComplete(obj.string("fileId"))
                "file-retransmit"  -> FileRetransmit(
                    fileId  = obj.string("fileId"),
                    indices = obj.intList("indices")
                )
                "message-delete"   -> MessageDelete(obj.string("messageId"))
                "message-edit"     -> MessageEdit(obj.string("messageId"), obj.string("newText"))
                "message-pin"      -> MessagePin(obj.string("messageId"), obj.bool("pinned"))
                else               -> throw DecodingError.UnknownType(type)
            }
        }

        private fun JsonObject.string(key: String): String =
            this[key]?.jsonPrimitive?.content ?: throw DecodingError.MissingField(key)

        private fun JsonObject.bool(key: String): Boolean =
            this[key]?.jsonPrimitive?.boolean ?: throw DecodingError.MissingField(key)

        private fun JsonObject.int(key: String): Int =
            this[key]?.jsonPrimitive?.int ?: throw DecodingError.MissingField(key)

        private fun JsonObject.long(key: String): Long =
            this[key]?.jsonPrimitive?.long ?: throw DecodingError.MissingField(key)

        private fun JsonObject.stringList(key: String): List<String> =
            (this[key]?.jsonArray ?: throw DecodingError.MissingField(key))
                .map { it.jsonPrimitive.content }

        private fun JsonObject.intList(key: String): List<Int> =
            (this[key]?.jsonArray ?: throw DecodingError.MissingField(key))
                .map { it.jsonPrimitive.int }
    }
}
