package com.ghost.chat.core.network

import android.os.Handler
import android.os.Looper
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
        // Build WS URL: https -> wss
        val wsURL = serverURL
            .replace("https://", "wss://")
            .replace("http://", "ws://")
            .trimEnd('/') + "/ws"

        val request = Request.Builder().url(wsURL).build()

        webSocket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                mainHandler.post { onConnected?.invoke() }
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                handleMessage(text)
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                mainHandler.post { onDisconnected?.invoke() }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                mainHandler.post { onDisconnected?.invoke() }
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                mainHandler.post { onDisconnected?.invoke() }
            }
        })
    }

    fun disconnect() {
        isReconnecting = false
        webSocket?.close(1000, "Going away")
        webSocket = null
    }

    // MARK: - Send Messages

    fun send(message: JSONObject) {
        webSocket?.send(message.toString())
    }

    fun createRoom() {
        send(JSONObject().apply { put("type", "create-room") })
    }

    fun joinRoom(roomId: String) {
        send(JSONObject().apply {
            put("type", "join-room")
            put("roomId", roomId)
        })
    }

    fun rejoinRoom(roomId: String, role: String) {
        send(JSONObject().apply {
            put("type", "rejoin-room")
            put("roomId", roomId)
            put("role", role)
        })
    }

    fun sendSignal(data: JSONObject) {
        send(JSONObject().apply {
            put("type", "signal")
            put("data", data)
        })
    }

    fun leaveRoom() {
        send(JSONObject().apply { put("type", "leave-room") })
    }

    // MARK: - Receive Messages

    private fun handleMessage(text: String) {
        try {
            val json = JSONObject(text)
            val type = json.optString("type", "")

            mainHandler.post {
                when (type) {
                    "room-created" -> {
                        val roomId = json.optString("roomId", "")
                        if (roomId.isNotEmpty()) onRoomCreated?.invoke(roomId)
                    }
                    "room-joined" -> {
                        val roomId = json.optString("roomId", "")
                        if (roomId.isNotEmpty()) onRoomJoined?.invoke(roomId)
                    }
                    "rejoin-ok" -> onRejoinOk?.invoke()
                    "peer-joined" -> onPeerJoined?.invoke()
                    "peer-left" -> onPeerLeft?.invoke()
                    "signal" -> {
                        val signalData = json.optJSONObject("data")
                        if (signalData != null) onSignal?.invoke(signalData)
                    }
                    "error" -> {
                        val message = json.optString("message", "Unknown error")
                        onError?.invoke(message)
                    }
                }
            }
        } catch (e: Exception) {
            // Invalid JSON — ignore
        }
    }

    // MARK: - Reconnection

    fun scheduleReconnect(roomId: String, isHost: Boolean) {
        if (isReconnecting) return
        isReconnecting = true
        reconnectAttempts = 0
        attemptReconnect(roomId, isHost)
    }

    private fun attemptReconnect(roomId: String, isHost: Boolean) {
        if (!isReconnecting) return

        reconnectAttempts++
        if (reconnectAttempts > maxReconnectAttempts) {
            isReconnecting = false
            mainHandler.post { onError?.invoke("Reconnection failed") }
            return
        }

        // Exponential backoff: 1s, 2s, 4s, 8s... max 30s
        val delay = min(2.0.pow(reconnectAttempts - 1), 30.0).toLong() * 1000

        mainHandler.postDelayed({
            if (!isReconnecting) return@postDelayed

            disconnect()

            val wsURL = serverURL
                .replace("https://", "wss://")
                .replace("http://", "ws://")
                .trimEnd('/') + "/ws"

            val request = Request.Builder().url(wsURL).build()

            webSocket = client.newWebSocket(request, object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    mainHandler.post {
                        reconnectAttempts = 0
                        isReconnecting = false
                        rejoinRoom(roomId, if (isHost) "host" else "guest")
                    }
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    handleMessage(text)
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    mainHandler.post { attemptReconnect(roomId, isHost) }
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    mainHandler.post { onDisconnected?.invoke() }
                }
            })
        }, delay)
    }

    val isConnected: Boolean
        get() = webSocket != null

    fun destroy() {
        disconnect()
        onRoomCreated = null
        onRoomJoined = null
        onRejoinOk = null
        onPeerJoined = null
        onPeerLeft = null
        onSignal = null
        onError = null
        onConnected = null
        onDisconnected = null
    }
}
