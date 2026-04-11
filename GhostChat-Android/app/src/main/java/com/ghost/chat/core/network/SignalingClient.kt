package com.ghost.chat.core.network

import android.os.Handler
import android.os.Looper
import android.util.Log
import okhttp3.*
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import kotlin.math.min
import kotlin.math.pow

/// WebSocket client for signaling server — port of SignalingClient.swift
/// Protocol fully compatible with server/index.js
class SignalingClient(private val serverURL: String) {

    // OkHttp WebSocket
    private var webSocket: WebSocket? = null
    private val client = OkHttpClient.Builder()
        .pingInterval(30, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()

    private val mainHandler = Handler(Looper.getMainLooper())

    // Message queue — messages sent before WS opens get queued and flushed on open
    private val pendingMessages = mutableListOf<JSONObject>()
    private var isOpen = false

    // Reconnection state
    private var isReconnecting = false
    private var reconnectAttempts = 0
    private val maxReconnectAttempts = 10

    // Callbacks
    var onRoomCreated: ((String) -> Unit)? = null
    var onRoomJoined: ((String) -> Unit)? = null
    var onRejoinOk: (() -> Unit)? = null
    var onPeerJoined: (() -> Unit)? = null
    var onPeerLeft: (() -> Unit)? = null
    var onSignal: ((JSONObject) -> Unit)? = null
    var onError: ((String) -> Unit)? = null
    var onConnected: (() -> Unit)? = null
    var onDisconnected: (() -> Unit)? = null

    // MARK: - Connection

    fun connect() {
        Log.d("GhostChat", "[SignalingClient] connect called, serverURL=$serverURL")
        // Build WS URL: https -> wss
        val wsURL = serverURL
            .replace("https://", "wss://")
            .replace("http://", "ws://")
            .trimEnd('/') + "/ws"
        Log.d("GhostChat", "[SignalingClient] connect — wsURL=$wsURL")

        val request = Request.Builder().url(wsURL).build()

        webSocket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                Log.d("GhostChat", "[SignalingClient] onOpen — WebSocket connected")
                mainHandler.post {
                    isOpen = true
                    // Flush queued messages
                    Log.d("GhostChat", "[SignalingClient] flushing ${pendingMessages.size} queued messages")
                    for (msg in pendingMessages) {
                        webSocket.send(msg.toString())
                    }
                    pendingMessages.clear()
                    onConnected?.invoke()
                }
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                Log.d("GhostChat", "[SignalingClient] onMessage received")
                handleMessage(text)
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                Log.d("GhostChat", "[SignalingClient] onClosing code=$code reason=$reason")
                mainHandler.post { isOpen = false; onDisconnected?.invoke() }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.e("GhostChat", "[SignalingClient] onError: ${t.message}")
                mainHandler.post { isOpen = false; onDisconnected?.invoke() }
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                Log.d("GhostChat", "[SignalingClient] onClosed code=$code reason=$reason")
                mainHandler.post { isOpen = false; onDisconnected?.invoke() }
            }
        })
    }

    fun disconnect() {
        Log.d("GhostChat", "[SignalingClient] disconnect called, isOpen=$isOpen, isReconnecting=$isReconnecting, pendingCount=${pendingMessages.size}")
        isReconnecting = false
        isOpen = false
        pendingMessages.clear()
        webSocket?.close(1000, "Going away")
        webSocket = null
        Log.d("GhostChat", "[SignalingClient] disconnect complete")
    }

    // MARK: - Send Messages

    fun send(message: JSONObject) {
        val type = message.optString("type", "unknown")
        if (isOpen) {
            Log.d("GhostChat", "[SignalingClient] send type=$type")
            webSocket?.send(message.toString())
        } else {
            Log.d("GhostChat", "[SignalingClient] send queued (WS not open) type=$type")
            // Queue messages until WebSocket is open
            pendingMessages.add(message)
        }
    }

    fun createRoom() {
        Log.d("GhostChat", "[SignalingClient] createRoom called")
        send(JSONObject().apply { put("type", "create-room") })
    }

    fun joinRoom(roomId: String) {
        Log.d("GhostChat", "[SignalingClient] joinRoom called, roomId=${roomId.take(8)}...")
        send(JSONObject().apply {
            put("type", "join-room")
            put("roomId", roomId)
        })
    }

    fun rejoinRoom(roomId: String, role: String) {
        Log.d("GhostChat", "[SignalingClient] rejoinRoom called, roomId=${roomId.take(8)}..., role=$role")
        send(JSONObject().apply {
            put("type", "rejoin-room")
            put("roomId", roomId)
            put("role", role)
        })
    }

    fun sendSignal(data: JSONObject) {
        val signalType = data.optString("type", "unknown")
        Log.d("GhostChat", "[SignalingClient] sendSignal signalType=$signalType")
        send(JSONObject().apply {
            put("type", "signal")
            put("data", data)
        })
    }

    fun leaveRoom() {
        Log.d("GhostChat", "[SignalingClient] leaveRoom called")
        send(JSONObject().apply { put("type", "leave-room") })
    }

    // MARK: - Receive Messages

    private fun handleMessage(text: String) {
        try {
            val json = JSONObject(text)
            val type = json.optString("type", "")
            Log.d("GhostChat", "[SignalingClient] handleMessage type=$type")

            mainHandler.post {
                when (type) {
                    "room-created" -> {
                        val roomId = json.optString("roomId", "")
                        Log.d("GhostChat", "[SignalingClient] room-created roomId=${roomId.take(8)}...")
                        if (roomId.isNotEmpty()) onRoomCreated?.invoke(roomId)
                    }
                    "room-joined" -> {
                        val roomId = json.optString("roomId", "")
                        Log.d("GhostChat", "[SignalingClient] room-joined roomId=${roomId.take(8)}...")
                        if (roomId.isNotEmpty()) onRoomJoined?.invoke(roomId)
                    }
                    "rejoin-ok" -> {
                        Log.d("GhostChat", "[SignalingClient] rejoin-ok")
                        onRejoinOk?.invoke()
                    }
                    "peer-joined" -> {
                        Log.d("GhostChat", "[SignalingClient] peer-joined")
                        onPeerJoined?.invoke()
                    }
                    "peer-left" -> {
                        Log.d("GhostChat", "[SignalingClient] peer-left")
                        onPeerLeft?.invoke()
                    }
                    "signal" -> {
                        val signalData = json.optJSONObject("data")
                        val signalType = signalData?.optString("type", "unknown") ?: "null"
                        Log.d("GhostChat", "[SignalingClient] signal received signalType=$signalType")
                        if (signalData != null) onSignal?.invoke(signalData)
                    }
                    "error" -> {
                        val message = json.optString("message", "Unknown error")
                        Log.e("GhostChat", "[SignalingClient] server error: $message")
                        onError?.invoke(message)
                    }
                }
            }
        } catch (e: Exception) {
            Log.e("GhostChat", "[SignalingClient] handleMessage parse error: ${e.message}")
        }
    }

    // MARK: - Reconnection

    fun scheduleReconnect(roomId: String, isHost: Boolean) {
        Log.d("GhostChat", "[SignalingClient] scheduleReconnect called, roomId=${roomId.take(8)}..., isHost=$isHost, isReconnecting=$isReconnecting")
        if (isReconnecting) {
            Log.d("GhostChat", "[SignalingClient] scheduleReconnect — already reconnecting, skipping")
            return
        }
        isReconnecting = true
        reconnectAttempts = 0
        attemptReconnect(roomId, isHost)
    }

    private fun attemptReconnect(roomId: String, isHost: Boolean) {
        Log.d("GhostChat", "[SignalingClient] attemptReconnect called, attempt=${reconnectAttempts + 1}/$maxReconnectAttempts, isReconnecting=$isReconnecting")
        if (!isReconnecting) {
            Log.d("GhostChat", "[SignalingClient] attemptReconnect — reconnection cancelled, skipping")
            return
        }

        reconnectAttempts++
        if (reconnectAttempts > maxReconnectAttempts) {
            Log.e("GhostChat", "[SignalingClient] attemptReconnect — max attempts exceeded ($maxReconnectAttempts)")
            isReconnecting = false
            mainHandler.post { onError?.invoke("Reconnection failed") }
            return
        }

        // Exponential backoff: 1s, 2s, 4s, 8s... max 30s
        val delay = min(2.0.pow(reconnectAttempts - 1), 30.0).toLong() * 1000
        Log.d("GhostChat", "[SignalingClient] attemptReconnect — scheduling attempt #$reconnectAttempts in ${delay}ms")

        mainHandler.postDelayed({
            if (!isReconnecting) return@postDelayed

            val wasReconnecting = isReconnecting
            disconnect()
            isReconnecting = wasReconnecting

            val wsURL = serverURL
                .replace("https://", "wss://")
                .replace("http://", "ws://")
                .trimEnd('/') + "/ws"

            val request = Request.Builder().url(wsURL).build()

            webSocket = client.newWebSocket(request, object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    Log.d("GhostChat", "[SignalingClient] reconnect onOpen — WebSocket reconnected")
                    mainHandler.post {
                        isOpen = true
                        reconnectAttempts = 0
                        isReconnecting = false
                        Log.d("GhostChat", "[SignalingClient] reconnect — rejoining room as ${if (isHost) "host" else "guest"}")
                        rejoinRoom(roomId, if (isHost) "host" else "guest")
                    }
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    Log.d("GhostChat", "[SignalingClient] reconnect onMessage received")
                    handleMessage(text)
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    Log.e("GhostChat", "[SignalingClient] reconnect onFailure: ${t.message}")
                    mainHandler.post { isOpen = false; attemptReconnect(roomId, isHost) }
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    Log.d("GhostChat", "[SignalingClient] reconnect onClosed code=$code reason=$reason")
                    mainHandler.post { onDisconnected?.invoke() }
                }
            })
        }, delay)
    }

    val isConnected: Boolean
        get() = isOpen

    fun destroy() {
        Log.d("GhostChat", "[SignalingClient] destroy called, isOpen=$isOpen, isReconnecting=$isReconnecting")
        disconnect()
        // Remove any pending reconnect handlers to prevent post-destroy callbacks
        mainHandler.removeCallbacksAndMessages(null)
        onRoomCreated = null
        onRoomJoined = null
        onRejoinOk = null
        onPeerJoined = null
        onPeerLeft = null
        onSignal = null
        onError = null
        onConnected = null
        onDisconnected = null
        Log.d("GhostChat", "[SignalingClient] destroy complete — all callbacks cleared")
    }
}
