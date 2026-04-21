package com.kordar.ghostchat.core.managers

import android.content.Context
import com.kordar.ghostchat.core.crypto.GhostChatCrypto
import com.kordar.ghostchat.core.crypto.IdentityKeyService
import com.kordar.ghostchat.core.crypto.KeyExchangePacket
import com.kordar.ghostchat.core.network.SignalingClient
import com.kordar.ghostchat.core.network.SignalingEvent
import com.kordar.ghostchat.core.network.TURNCredentials
import com.kordar.ghostchat.core.network.TURNService
import com.kordar.ghostchat.core.push.PushManager
import com.kordar.ghostchat.core.webrtc.GhostRTC
import com.kordar.ghostchat.core.webrtc.GhostRTCEvent
import com.kordar.ghostchat.models.ConnectionState
import com.kordar.ghostchat.models.Role
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Orchestrates SignalingClient + GhostRTC + GhostChatCrypto through a single state machine.
 * Mirror of iOS `ConnectionManager`. Owns the per-session RTC and crypto instances;
 * recreated on every fresh [createRoom] / [joinRoom].
 */
class ConnectionManager(
    private val context: Context,
    private val signalingUrl: String,
    private val apiBaseUrl: String,
    private val identity: IdentityKeyService,
    private val push: PushManager,
    private val turnService: TURNService = TURNService(apiBaseUrl)
) {

    private val _state = MutableStateFlow(ConnectionState.DISCONNECTED)
    val state: StateFlow<ConnectionState> = _state.asStateFlow()

    private val _roomId = MutableStateFlow<String?>(null)
    val roomId: StateFlow<String?> = _roomId.asStateFlow()

    private val _safetyNumber = MutableStateFlow<String?>(null)
    val safetyNumber: StateFlow<String?> = _safetyNumber.asStateFlow()

    private val _peerIdentity = MutableStateFlow<ByteArray?>(null)
    val peerIdentity: StateFlow<ByteArray?> = _peerIdentity.asStateFlow()

    private val _incomingText = MutableSharedFlow<String>(
        replay = 0, extraBufferCapacity = 64, onBufferOverflow = BufferOverflow.DROP_OLDEST
    )
    val incomingText: SharedFlow<String> = _incomingText.asSharedFlow()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var signaling: SignalingClient? = null
    private var rtc: GhostRTC? = null
    private var crypto: GhostChatCrypto? = null
    private var role: Role? = null
    private val watchers = mutableListOf<Job>()

    private val json = Json { ignoreUnknownKeys = true }

    // MARK: - Connect flows

    suspend fun createRoom() {
        reset()
        _state.value = ConnectionState.CONNECTING
        role = Role.HOST

        val creds = turnService.fetchCredentials()
        push.pushAuth = creds.pushAuth

        val rtc = GhostRTC(context, Role.HOST, creds).also { it.start() }
        this.rtc = rtc
        crypto = GhostChatCrypto(identity)
        watchRtc(rtc)

        val sig = SignalingClient(signalingUrl)
        signaling = sig
        watchSignaling(sig)
        sig.connect()
        sig.createRoom()
        _state.value = ConnectionState.SIGNALING
    }

    suspend fun joinRoom(id: String) {
        reset()
        _state.value = ConnectionState.CONNECTING
        role = Role.GUEST

        val creds = turnService.fetchCredentials()
        push.pushAuth = creds.pushAuth

        val rtc = GhostRTC(context, Role.GUEST, creds).also { it.start() }
        this.rtc = rtc
        crypto = GhostChatCrypto(identity)
        watchRtc(rtc)

        val sig = SignalingClient(signalingUrl)
        signaling = sig
        watchSignaling(sig)
        sig.connect()
        sig.joinRoom(id)
        _state.value = ConnectionState.SIGNALING
    }

    suspend fun sendText(text: String) {
        val crypto = crypto ?: error("crypto not initialized")
        val rtc = rtc ?: error("rtc not initialized")
        check(_state.value == ConnectionState.ENCRYPTED) { "not encrypted yet" }
        val wire = crypto.encrypt(text)
        rtc.send(wire.toByteArray(Charsets.UTF_8))
    }

    fun leave() {
        signaling?.leaveRoom()
        reset()
    }

    private fun reset() {
        watchers.forEach { it.cancel() }
        watchers.clear()
        signaling?.disconnect(); signaling = null
        rtc?.close();           rtc = null
        crypto = null
        _roomId.value = null
        _safetyNumber.value = null
        _peerIdentity.value = null
        role = null
        _state.value = ConnectionState.DISCONNECTED
    }

    // MARK: - Event loops

    private fun watchSignaling(sig: SignalingClient) {
        watchers += scope.launch {
            sig.events.collect { handleSignaling(it) }
        }
    }

    private fun watchRtc(rtc: GhostRTC) {
        watchers += scope.launch {
            rtc.events.collect { handleRtc(it) }
        }
    }

    private suspend fun handleSignaling(event: SignalingEvent) {
        when (event) {
            is SignalingEvent.RoomCreated -> _roomId.value = event.roomId
            is SignalingEvent.RoomJoined  -> _roomId.value = event.roomId
            is SignalingEvent.PeerJoined  -> if (role == Role.HOST) rtc?.createOffer()
            is SignalingEvent.Signal      -> handleSignalPayload(event.rawJSON)
            is SignalingEvent.PeerLeft, is SignalingEvent.Disconnected, is SignalingEvent.Error ->
                _state.value = ConnectionState.DISCONNECTED
            else -> Unit
        }
    }

    private suspend fun handleSignalPayload(raw: ByteArray) {
        val text = String(raw, Charsets.UTF_8)
        val obj = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull() ?: return
        obj["type"]?.jsonPrimitive?.contentOrNull()?.let { type ->
            when (type) {
                "offer"  -> obj["sdp"]?.jsonPrimitive?.content?.let { rtc?.receiveOffer(it) }
                "answer" -> obj["sdp"]?.jsonPrimitive?.content?.let { rtc?.receiveAnswer(it) }
                "key-exchange" -> completeHandshake(runCatching { KeyExchangePacket.decode(text) }.getOrNull())
                else -> Unit
            }
            return
        }
        obj["candidate"]?.jsonPrimitive?.content?.let { candidate ->
            val mid = obj["sdpMid"]?.jsonPrimitive?.contentOrNull()
            val idx = obj["sdpMLineIndex"]?.jsonPrimitive?.intOrNull ?: 0
            rtc?.addIceCandidate(candidate, mid, idx)
        }
    }

    private suspend fun handleRtc(event: GhostRTCEvent) {
        when (event) {
            is GhostRTCEvent.IceCandidate -> emitSignal(buildJsonObject {
                put("candidate", JsonPrimitive(event.sdp))
                put("sdpMid", JsonPrimitive(event.sdpMid ?: ""))
                put("sdpMLineIndex", JsonPrimitive(event.sdpMLineIndex))
            })
            is GhostRTCEvent.OfferReady -> emitSignal(buildJsonObject {
                put("type", JsonPrimitive("offer"))
                put("sdp",  JsonPrimitive(event.sdp))
            })
            is GhostRTCEvent.AnswerReady -> {
                emitSignal(buildJsonObject {
                    put("type", JsonPrimitive("answer"))
                    put("sdp",  JsonPrimitive(event.sdp))
                })
                _state.value = ConnectionState.WEB_RTC
            }
            GhostRTCEvent.DataChannelOpen -> {
                _state.value = ConnectionState.WEB_RTC
                startKeyExchangeOverDataChannel()
            }
            is GhostRTCEvent.DataChannelMessage -> handleDataChannelMessage(event.data)
            GhostRTCEvent.DataChannelClosed -> _state.value = ConnectionState.DISCONNECTED
            else -> Unit
        }
    }

    private suspend fun startKeyExchangeOverDataChannel() {
        val crypto = crypto ?: return
        val rtc = rtc ?: return
        runCatching {
            val pkt = crypto.beginHandshake()
            val encoded = KeyExchangePacket.encode(pkt)
            rtc.send(encoded.toByteArray(Charsets.UTF_8))
        }.onFailure { _state.value = ConnectionState.DISCONNECTED }
    }

    private suspend fun completeHandshake(pkt: KeyExchangePacket?) {
        val role = role ?: return
        val crypto = crypto ?: return
        pkt ?: return
        runCatching {
            if (role == Role.HOST) crypto.completeAsHost(pkt) else crypto.completeAsGuest(pkt)
            _state.value = ConnectionState.ENCRYPTED
            _peerIdentity.value = java.util.Base64.getDecoder().decode(pkt.identityKey)
            _safetyNumber.value = runCatching { crypto.safetyNumber() }.getOrNull()
        }
    }

    private suspend fun handleDataChannelMessage(data: ByteArray) {
        val crypto = crypto ?: return
        val text = String(data, Charsets.UTF_8)
        runCatching { KeyExchangePacket.decode(text) }.getOrNull()?.let { pkt ->
            if (pkt.type == "key-exchange") { completeHandshake(pkt); return }
        }
        runCatching { crypto.decrypt(text) }.onSuccess { plaintext ->
            _incomingText.tryEmit(plaintext)
        }
    }

    private fun emitSignal(payload: JsonObject) {
        val raw = json.encodeToString(JsonElement.serializer(), payload)
        runCatching { signaling?.sendSignal(raw) }
    }

    private fun kotlinx.serialization.json.JsonPrimitive.contentOrNull(): String? =
        if (isString) content else null
}
