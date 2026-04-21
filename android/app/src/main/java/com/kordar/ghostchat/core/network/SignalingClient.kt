package com.kordar.ghostchat.core.network

import com.kordar.ghostchat.models.Role
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import java.util.concurrent.TimeUnit

/**
 * High-level event emitted by the signaling server over WebSocket.
 * Mirror of iOS `SignalingEvent`.
 */
sealed class SignalingEvent {
    data object Connected                 : SignalingEvent()
    data class RoomCreated(val roomId: String) : SignalingEvent()
    data class RoomJoined(val roomId: String)  : SignalingEvent()
    data object RejoinOk                  : SignalingEvent()
    data object PeerJoined                : SignalingEvent()
    data object PeerLeft                  : SignalingEvent()
    data class Signal(val rawJSON: ByteArray) : SignalingEvent()
    data class Error(val message: String) : SignalingEvent()
    data object Disconnected              : SignalingEvent()
}

/**
 * Thin OkHttp WebSocket wrapper targeting the Ghost Chat signaling endpoint.
 *
 * Owns one connection, parses inbound frames, emits [SignalingEvent]s via a
 * [SharedFlow]. No reconnect policy — that belongs in `ConnectionManager`.
 */
class SignalingClient(
    private val url: String,
    private val client: OkHttpClient = defaultClient()
) {

    private val _events = MutableSharedFlow<SignalingEvent>(
        replay = 0,
        extraBufferCapacity = 64,
        onBufferOverflow = BufferOverflow.DROP_OLDEST
    )
    val events: SharedFlow<SignalingEvent> = _events.asSharedFlow()

    private var socket: WebSocket? = null

    // MARK: - Lifecycle

    fun connect() {
        if (socket != null) return
        val request = Request.Builder().url(url).build()
        socket = client.newWebSocket(request, listener)
        _events.tryEmit(SignalingEvent.Connected)
    }

    fun disconnect() {
        socket?.close(CODE_GOING_AWAY, null)
        socket = null
        _events.tryEmit(SignalingEvent.Disconnected)
    }

    // MARK: - Outgoing

    fun createRoom() = send(mapOf("type" to "create-room"))
    fun joinRoom(roomId: String) = send(mapOf("type" to "join-room", "roomId" to roomId))
    fun rejoinRoom(roomId: String, role: Role) =
        send(mapOf("type" to "rejoin-room", "roomId" to roomId, "role" to role.wire))
    fun leaveRoom() = send(mapOf("type" to "leave-room"))

    /** Sends a raw signal payload. Caller supplies already-encoded JSON. */
    fun sendSignal(rawJson: String) {
        val payload = buildJsonObject {
            put("type", JsonPrimitive("signal"))
            put("data", jsonCodec.parseToJsonElement(rawJson))
        }
        writeString(jsonCodec.encodeToString(JsonElement.serializer(), payload))
    }

    private fun send(fields: Map<String, String>) {
        val payload = buildJsonObject {
            fields.forEach { (k, v) -> put(k, JsonPrimitive(v)) }
        }
        writeString(jsonCodec.encodeToString(JsonElement.serializer(), payload))
    }

    private fun writeString(text: String) {
        val ws = socket ?: return
        if (!ws.send(text)) _events.tryEmit(SignalingEvent.Disconnected)
    }

    // MARK: - Incoming

    private val listener = object : WebSocketListener() {
        override fun onMessage(webSocket: WebSocket, text: String) = handle(text)
        override fun onMessage(webSocket: WebSocket, bytes: ByteString) = handle(bytes.utf8())
        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            socket = null
            _events.tryEmit(SignalingEvent.Disconnected)
        }
        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            socket = null
            _events.tryEmit(SignalingEvent.Error(t.message ?: "websocket failure"))
            _events.tryEmit(SignalingEvent.Disconnected)
        }
    }

    private fun handle(text: String) {
        val obj: JsonObject = runCatching { jsonCodec.parseToJsonElement(text).jsonObject }.getOrNull() ?: return
        val type = obj["type"]?.jsonPrimitive?.content ?: return
        when (type) {
            "room-created" -> obj["roomId"]?.jsonPrimitive?.content
                ?.let { _events.tryEmit(SignalingEvent.RoomCreated(it)) }
            "room-joined"  -> obj["roomId"]?.jsonPrimitive?.content
                ?.let { _events.tryEmit(SignalingEvent.RoomJoined(it)) }
            "rejoin-ok"    -> _events.tryEmit(SignalingEvent.RejoinOk)
            "peer-joined"  -> _events.tryEmit(SignalingEvent.PeerJoined)
            "peer-left"    -> _events.tryEmit(SignalingEvent.PeerLeft)
            "signal"       -> obj["data"]?.let { data ->
                val raw = jsonCodec.encodeToString(JsonElement.serializer(), data).toByteArray(Charsets.UTF_8)
                _events.tryEmit(SignalingEvent.Signal(raw))
            }
            "error"        -> _events.tryEmit(
                SignalingEvent.Error(obj["message"]?.jsonPrimitive?.content ?: "unknown")
            )
        }
    }

    companion object {
        const val CODE_GOING_AWAY = 1001
        internal val jsonCodec = Json { ignoreUnknownKeys = true; encodeDefaults = true }

        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .certificatePinner(CertificatePinning.pinner())
            .pingInterval(25, TimeUnit.SECONDS)
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.SECONDS) // 0 = no timeout (long-lived WS)
            .build()
    }
}
