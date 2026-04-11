package com.ghost.chat.models

import org.json.JSONArray
import org.json.JSONObject

/// Control messages through E2E DataChannel
/// All types from app.js handleControlMessage()
sealed class ControlMessage {
    data class Renegotiate(val sdp: JSONObject) : ControlMessage()
    data object CallRequest : ControlMessage()
    data class CallResponse(val accepted: Boolean) : ControlMessage()
    data object CallEnd : ControlMessage()
    data class CallSecurityAlert(val alert: JSONObject) : ControlMessage()
    data class SecurityAlert(val alert: String) : ControlMessage()
    data class MessageAck(val counter: Int) : ControlMessage()
    data class MessageRead(val counter: Int) : ControlMessage()
    data object Ready : ControlMessage()
    data class PushToken(val token: String) : ControlMessage()
    data class NotifyToken(val token: String) : ControlMessage()
    data class Typing(val isTyping: Boolean) : ControlMessage()
    data class Capabilities(val features: List<String>) : ControlMessage()
    data class FileStart(val fileId: String, val name: String, val size: Long, val mimeType: String, val totalChunks: Int) : ControlMessage()
    data class FileChunk(val fileId: String, val index: Int, val data: String) : ControlMessage()
    data class FileComplete(val fileId: String) : ControlMessage()
    data class RoomRotate(val roomId: String) : ControlMessage()
    data class FileRetransmit(val fileId: String, val indices: List<Int>) : ControlMessage()
    data class MessageDelete(val messageId: String) : ControlMessage()
    data class MessageEdit(val messageId: String, val newText: String) : ControlMessage()

    /** Parse from JSON (incoming) */
    companion object {
        fun from(json: JSONObject): ControlMessage? {
            return when (json.optString("type", "")) {
                "renegotiate" -> {
                    val sdp = json.optJSONObject("sdp") ?: return null
                    Renegotiate(sdp)
                }
                "call-request" -> CallRequest
                "call-response" -> {
                    val accepted = json.optBoolean("accepted", false)
                    CallResponse(accepted)
                }
                "call-end" -> CallEnd
                "call-security-alert" -> {
                    val alert = json.optJSONObject("alert") ?: return null
                    CallSecurityAlert(alert)
                }
                "security-alert" -> {
                    val alert = json.optString("alert", "")
                    if (alert.isEmpty()) return null
                    SecurityAlert(alert)
                }
                "message-ack" -> {
                    val counter = json.optInt("c", -1)
                    if (counter < 0) return null
                    MessageAck(counter)
                }
                "message-read" -> {
                    val counter = json.optInt("c", -1)
                    if (counter < 0) return null
                    MessageRead(counter)
                }
                "ready" -> Ready
                "push-token" -> {
                    val token = json.optString("token", "")
                    if (token.isEmpty()) return null
                    PushToken(token)
                }
                "notify-token" -> {
                    val token = json.optString("token", "")
                    if (token.isEmpty()) return null
                    NotifyToken(token)
                }
                "typing" -> {
                    val isTyping = json.optBoolean("isTyping", false)
                    Typing(isTyping)
                }
                "capabilities" -> {
                    val arr = json.optJSONArray("features") ?: return null
                    val features = (0 until arr.length()).map { arr.getString(it) }
                    Capabilities(features)
                }
                "file-start" -> {
                    val fileId = json.optString("fileId", "")
                    val name = json.optString("name", "")
                    val size = json.optLong("size", -1)
                    val mimeType = json.optString("mimeType", "")
                    val totalChunks = json.optInt("totalChunks", -1)
                    if (fileId.isEmpty() || name.isEmpty() || size < 0 || totalChunks < 0) return null
                    FileStart(fileId, name, size, mimeType, totalChunks)
                }
                "file-chunk" -> {
                    val fileId = json.optString("fileId", "")
                    val index = json.optInt("index", -1)
                    val data = json.optString("data", "")
                    if (fileId.isEmpty() || index < 0 || data.isEmpty()) return null
                    FileChunk(fileId, index, data)
                }
                "file-complete" -> {
                    val fileId = json.optString("fileId", "")
                    if (fileId.isEmpty()) return null
                    FileComplete(fileId)
                }
                "room-rotate" -> {
                    val roomId = json.optString("roomId", "")
                    if (roomId.isEmpty()) return null
                    RoomRotate(roomId)
                }
                "file-retransmit" -> {
                    val fileId = json.optString("fileId", "")
                    val indicesArr = json.optJSONArray("indices") ?: return null
                    if (fileId.isEmpty()) return null
                    val indices = (0 until indicesArr.length()).map { indicesArr.getInt(it) }
                    FileRetransmit(fileId, indices)
                }
                "message-delete" -> {
                    val messageId = json.optString("messageId", "")
                    if (messageId.isEmpty()) return null
                    MessageDelete(messageId)
                }
                "message-edit" -> {
                    val messageId = json.optString("messageId", "")
                    val newText = json.optString("newText", "")
                    if (messageId.isEmpty()) return null
                    MessageEdit(messageId, newText)
                }
                else -> null
            }
        }
    }

    /** Serialize for sending */
    fun toJSON(): JSONObject {
        val json = when (this) {
            is Renegotiate -> JSONObject().apply {
                put("type", "renegotiate")
                put("sdp", sdp)
            }
            is CallRequest -> JSONObject().apply { put("type", "call-request") }
            is CallResponse -> JSONObject().apply {
                put("type", "call-response")
                put("accepted", accepted)
            }
            is CallEnd -> JSONObject().apply { put("type", "call-end") }
            is CallSecurityAlert -> JSONObject().apply {
                put("type", "call-security-alert")
                put("alert", alert)
            }
            is SecurityAlert -> JSONObject().apply {
                put("type", "security-alert")
                put("alert", alert)
            }
            is MessageAck -> JSONObject().apply {
                put("type", "message-ack")
                put("c", counter)
            }
            is MessageRead -> JSONObject().apply {
                put("type", "message-read")
                put("c", counter)
            }
            is Ready -> JSONObject().apply { put("type", "ready") }
            is PushToken -> JSONObject().apply {
                put("type", "push-token")
                put("token", token)
            }
            is NotifyToken -> JSONObject().apply {
                put("type", "notify-token")
                put("token", token)
            }
            is Typing -> JSONObject().apply {
                put("type", "typing")
                put("isTyping", isTyping)
            }
            is Capabilities -> JSONObject().apply {
                put("type", "capabilities")
                put("features", JSONArray(features))
            }
            is FileStart -> JSONObject().apply {
                put("type", "file-start")
                put("fileId", fileId)
                put("name", name)
                put("size", size)
                put("mimeType", mimeType)
                put("totalChunks", totalChunks)
            }
            is FileChunk -> JSONObject().apply {
                put("type", "file-chunk")
                put("fileId", fileId)
                put("index", index)
                put("data", data)
            }
            is FileComplete -> JSONObject().apply {
                put("type", "file-complete")
                put("fileId", fileId)
            }
            is FileRetransmit -> JSONObject().apply {
                put("type", "file-retransmit")
                put("fileId", fileId)
                put("indices", JSONArray(indices))
            }
            is RoomRotate -> JSONObject().apply {
                put("type", "room-rotate")
                put("roomId", roomId)
            }
            is MessageDelete -> JSONObject().apply {
                put("type", "message-delete")
                put("messageId", messageId)
            }
            is MessageEdit -> JSONObject().apply {
                put("type", "message-edit")
                put("messageId", messageId)
                put("newText", newText)
            }
        }
        // Web клиент проверяет _ctrl чтобы отличить control от текста
        json.put("_ctrl", true)
        return json
    }
}
