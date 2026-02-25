package com.ghost.chat.models

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
    data object Ready : ControlMessage()

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
                "ready" -> Ready
                else -> null
            }
        }
    }

    /** Serialize for sending */
    fun toJSON(): JSONObject {
        return when (this) {
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
            is Ready -> JSONObject().apply { put("type", "ready") }
        }
    }
}
