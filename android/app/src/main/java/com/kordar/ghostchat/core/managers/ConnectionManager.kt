package com.kordar.ghostchat.core.managers

import android.content.Context
import com.kordar.ghostchat.core.crypto.GhostChatCrypto
import com.kordar.ghostchat.core.crypto.IdentityKeyService
import com.kordar.ghostchat.core.crypto.KeyExchangePacket
import com.kordar.ghostchat.core.crypto.PqExchangePacket
import com.kordar.ghostchat.core.crypto.RatchetRole
import com.kordar.ghostchat.core.files.ChunkTimeoutTracker
import com.kordar.ghostchat.core.files.FileTransferService
import com.kordar.ghostchat.core.network.SignalingClient
import com.kordar.ghostchat.core.network.SignalingEvent
import com.kordar.ghostchat.core.network.TURNCredentials
import com.kordar.ghostchat.core.network.TURNService
import com.kordar.ghostchat.core.push.PushManager
import com.kordar.ghostchat.core.webrtc.GhostRTC
import com.kordar.ghostchat.core.webrtc.GhostRTCEvent
import com.kordar.ghostchat.models.ConnectionState
import com.kordar.ghostchat.models.ControlMessage
import com.kordar.ghostchat.models.Role
import kotlinx.coroutines.delay
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

    /**
     * Authoritative "a remote peer is in the room" signal — sourced ONLY from
     * signaling-server events ([SignalingEvent.PeerJoined] for host,
     * [SignalingEvent.RoomJoined] for guest). Local RTC events like
     * [GhostRTCEvent.DataChannelOpen] / [GhostRTCEvent.AnswerReady] MUST NOT
     * flip this flag — the WebRTC stack fires those once the local SCTP
     * association is up, even when no peer has connected. Keeping this flag
     * separate from [state] is what gates ChatView, fixing the regression
     * where host bypassed WaitingView.
     */
    private val _hasRemotePeer = MutableStateFlow(false)
    val hasRemotePeer: StateFlow<Boolean> = _hasRemotePeer.asStateFlow()

    private val _incomingText = MutableSharedFlow<String>(
        replay = 0, extraBufferCapacity = 64, onBufferOverflow = BufferOverflow.DROP_OLDEST
    )
    val incomingText: SharedFlow<String> = _incomingText.asSharedFlow()

    private val _incomingFile = MutableSharedFlow<FileTransferService.IncomingFile>(
        replay = 0, extraBufferCapacity = 8, onBufferOverflow = BufferOverflow.DROP_OLDEST
    )
    val incomingFile: SharedFlow<FileTransferService.IncomingFile> = _incomingFile.asSharedFlow()

    private val _fileTransferAborted = MutableSharedFlow<String>(
        replay = 0, extraBufferCapacity = 8, onBufferOverflow = BufferOverflow.DROP_OLDEST
    )
    val fileTransferAborted: SharedFlow<String> = _fileTransferAborted.asSharedFlow()

    /**
     * Peer's FCM push token, surfaced after the peer sends ControlMessage.PushToken
     * over the encrypted channel. Subscribers (typically ContactManager on
     * save-contact) persist these so we can later relay calls/messages via the
     * server while the peer is offline.
     */
    private val _peerPushTokens = MutableSharedFlow<String>(
        replay = 0, extraBufferCapacity = 4, onBufferOverflow = BufferOverflow.DROP_OLDEST
    )
    val peerPushTokens: SharedFlow<String> = _peerPushTokens.asSharedFlow()

    /** Same as [peerPushTokens] but for the iOS APNs alert / Android FCM notify channel. */
    private val _peerNotifyTokens = MutableSharedFlow<String>(
        replay = 0, extraBufferCapacity = 4, onBufferOverflow = BufferOverflow.DROP_OLDEST
    )
    val peerNotifyTokens: SharedFlow<String> = _peerNotifyTokens.asSharedFlow()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var signaling: SignalingClient? = null
    private var rtc: GhostRTC? = null
    private var crypto: GhostChatCrypto? = null
    private var role: Role? = null

    /** Session-bound saved-contact id. `leave()` uses this to trigger key rotation. */
    var currentContactId: String? = null
    /** App-wide [ContactManager]. Null when rotations are disabled (unit tests). */
    var contactManager: ContactManager? = null
    private var fileTransfer: FileTransferService = FileTransferService()
    private val chunkTimeout = ChunkTimeoutTracker().also {
        // onTimeout: 30 s with no chunk → ask peer to retransmit what's missing.
        it.onTimeout = { fileId ->
            val missing = fileTransfer.missingChunks(fileId) ?: emptyList()
            if (missing.isNotEmpty()) {
                scope.launch {
                    runCatching {
                        sendControl(ControlMessage.FileRetransmit(fileId, missing))
                    }
                }
            }
        }
        // onAbort: 3 retries exhausted → drop the incomplete inbound, surface to UI.
        it.onAbort = { fileId ->
            fileTransfer.cancelInbound(fileId)
            _fileTransferAborted.tryEmit(fileId)
        }
    }
    private val watchers = mutableListOf<Job>()

    companion object {
        /** Backpressure: pause file sends while the SCTP buffer holds > 16 KiB. */
        const val BACKPRESSURE_THRESHOLD_BYTES: Long = 16L * 1024
        /** 100 MiB hard cap on attachments. */
        const val MAX_FILE_BYTES: Int = 100 * 1024 * 1024
    }

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

    /** Encode, encrypt, send a [ControlMessage] over the DataChannel. */
    suspend fun sendControl(ctrl: ControlMessage) {
        val crypto = crypto ?: error("crypto not initialized")
        val rtc = rtc ?: error("rtc not initialized")
        check(_state.value == ConnectionState.ENCRYPTED) { "not encrypted yet" }
        val jsonStr = ControlMessage.encode(ctrl)
        val wire = crypto.encrypt(jsonStr)
        rtc.send(wire.toByteArray(Charsets.UTF_8))
    }

    /** Chunk `data`, stream it as encrypted file-chunk control messages with
     *  backpressure, then send file-complete. Returns the fileId. */
    suspend fun sendFile(data: ByteArray, name: String, mimeType: String): String {
        check(_state.value == ConnectionState.ENCRYPTED) { "not encrypted yet" }
        require(data.size <= MAX_FILE_BYTES) { "file too large: ${data.size}" }

        val out = fileTransfer.prepareOutbound(data, name, mimeType)
        sendControl(out.startMessage)
        for (chunk in out.chunkMessages) {
            awaitSendSlot()
            sendControl(chunk)
        }
        sendControl(out.completeMessage)
        return out.fileId
    }

    fun leave() {
        // Capture before reset() nukes crypto and currentContactId.
        val cid = currentContactId
        val cryptoRef = crypto
        val mgrRef = contactManager

        signaling?.leaveRoom()
        reset()

        // Fire-and-forget rotation — best-effort, silently drops if refs are gone.
        if (cid != null && cryptoRef != null && mgrRef != null) {
            scope.launch {
                runCatching {
                    val secret = cryptoRef.sessionSecret()
                    mgrRef.rotateKeys(cid, secret)
                }
            }
        }
    }

    /**
     * Test hook: synchronous variant of [leave] that awaits the rotation step so
     * assertions can observe the rotated contact state.
     */
    suspend fun leaveAndAwaitRotation() {
        val cid = currentContactId
        val cryptoRef = crypto
        val mgrRef = contactManager
        signaling?.leaveRoom()
        reset()
        if (cid != null && cryptoRef != null && mgrRef != null) {
            runCatching {
                val secret = cryptoRef.sessionSecret()
                mgrRef.rotateKeys(cid, secret)
            }
        }
    }

    /** Test hook: inject a pre-built crypto session without running signaling + WebRTC. */
    @Suppress("FunctionName")
    fun _testInjectReadyCrypto(c: GhostChatCrypto) {
        this.crypto = c
    }

    private fun reset() {
        watchers.forEach { it.cancel() }
        watchers.clear()
        signaling?.disconnect(); signaling = null
        rtc?.close();           rtc = null
        crypto = null
        fileTransfer = FileTransferService()
        chunkTimeout.cancelAll()
        _roomId.value = null
        _safetyNumber.value = null
        _peerIdentity.value = null
        _hasRemotePeer.value = false
        role = null
        _state.value = ConnectionState.DISCONNECTED
    }

    /** Pauses (via suspend) while the DataChannel buffer is above threshold. */
    private suspend fun awaitSendSlot() {
        while ((rtc?.bufferedAmount() ?: 0L) > BACKPRESSURE_THRESHOLD_BYTES) {
            delay(10)
        }
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
            is SignalingEvent.RoomJoined  -> {
                // Server only lets a guest into a non-empty room (server/src/signaling.ts
                // rejects with "Room not found" / "Room is full"), so receiving roomJoined
                // implicitly means the host is present.
                _roomId.value = event.roomId
                _hasRemotePeer.value = true
            }
            is SignalingEvent.PeerJoined  -> {
                _hasRemotePeer.value = true
                if (role == Role.HOST) rtc?.createOffer()
            }
            is SignalingEvent.Signal      -> handleSignalPayload(event.rawJSON)
            is SignalingEvent.PeerLeft -> {
                _hasRemotePeer.value = false
                _state.value = ConnectionState.DISCONNECTED
            }
            is SignalingEvent.Disconnected, is SignalingEvent.Error ->
                _state.value = ConnectionState.DISCONNECTED
            else -> Unit
        }
    }

    // MARK: - Test hooks

    /** Test-only re-entry into the signaling event handler. Lets unit tests inject
     *  [SignalingEvent]s directly without standing up a live WebSocket. */
    @Suppress("FunctionName")
    suspend fun _testDispatchSignaling(event: SignalingEvent) = handleSignaling(event)

    /** Test-only re-entry into the RTC event handler. Same reasoning as above —
     *  exists so tests can verify [GhostRTCEvent.DataChannelOpen] / [GhostRTCEvent.AnswerReady]
     *  do NOT flip [hasRemotePeer] (the regression test). */
    @Suppress("FunctionName")
    suspend fun _testDispatchRtc(event: GhostRTCEvent) = handleRtc(event)

    /** Test-only state setter — mirrors iOS `_set(state:)`. */
    @Suppress("FunctionName")
    fun _setState(s: ConnectionState) { _state.value = s }

    /** Test-only peer-identity setter — mirrors iOS `_set(peerIdentity:)`. */
    @Suppress("FunctionName")
    fun _setPeerIdentity(id: ByteArray?) { _peerIdentity.value = id }

    // MARK: - Push token exchange (P0 #1)

    /**
     * Build the list of [ControlMessage] token-broadcasts the local side has
     * available right now. Pure — depends only on `push.fcmToken`. Empty list
     * means nothing to forward (token not yet registered).
     */
    fun ownTokenControlMessages(): List<ControlMessage> {
        val out = mutableListOf<ControlMessage>()
        push.fcmToken?.let { out.add(ControlMessage.PushToken(it)) }
        return out
    }

    /**
     * Forward locally-known push tokens to the peer. Caller must invoke only
     * after `state == ENCRYPTED` (otherwise [sendControl] throws). Best-effort —
     * failures are swallowed so a transient send glitch doesn't tear down
     * the session.
     */
    suspend fun forwardOwnPushTokensToPeer() {
        if (_state.value != ConnectionState.ENCRYPTED) return
        for (msg in ownTokenControlMessages()) {
            runCatching { sendControl(msg) }
            android.util.Log.i("PushManager", "🔔 Push token forwarded to peer")
        }
    }

    /**
     * Inbound routing entrypoint for the two token control messages. Surfaces
     * to the appropriate [SharedFlow] so subscribers (e.g. ContactManager
     * during save-contact) can store them.
     */
    fun handlePeerToken(ctrl: ControlMessage) {
        when (ctrl) {
            is ControlMessage.PushToken -> {
                _peerPushTokens.tryEmit(ctrl.token)
                android.util.Log.i("PushManager", "🔔 Peer push token received and stored (length: ${ctrl.token.length} chars)")
            }
            is ControlMessage.NotifyToken -> {
                _peerNotifyTokens.tryEmit(ctrl.token)
                android.util.Log.i("PushManager", "🔔 Peer notify token received and stored (length: ${ctrl.token.length} chars)")
            }
            else -> Unit
        }
    }

    /**
     * Test-only re-entry into the control-message router. Lets unit tests
     * inject [ControlMessage.PushToken] / [ControlMessage.NotifyToken] without
     * standing up the full crypto + DC pipeline.
     */
    @Suppress("FunctionName")
    fun _testRouteControl(ctrl: ControlMessage) = handlePeerToken(ctrl)

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

    private val handshake = ConnectionHandshake(
        cryptoProvider    = { crypto },
        rtcProvider       = { rtc },
        roleProvider      = { role },
        stateFlow         = _state,
        safetyNumberFlow  = _safetyNumber,
        peerIdentityFlow  = _peerIdentity,
        onEncrypted       = { forwardOwnPushTokensToPeer() }
    )

    private suspend fun startKeyExchangeOverDataChannel() = handshake.startKeyExchangeOverDataChannel()
    private suspend fun completeHandshake(pkt: KeyExchangePacket?) = handshake.completeHandshake(pkt)
    private suspend fun completePqHandshake(pkt: PqExchangePacket) = handshake.completePq(pkt)

    private suspend fun handleDataChannelMessage(data: ByteArray) {
        val crypto = crypto ?: return
        val text = String(data, Charsets.UTF_8)
        // Plaintext handshake packets — either KeyExchangePacket or PqExchangePacket (Phase 7 hybrid).
        runCatching { KeyExchangePacket.decode(text) }.getOrNull()?.let { pkt ->
            if (pkt.type == "key-exchange") { completeHandshake(pkt); return }
        }
        runCatching { PqExchangePacket.decode(text) }.getOrNull()?.let { pqPkt ->
            if (pqPkt.type == "pq-exchange") { completePqHandshake(pqPkt); return }
        }
        val plaintext = runCatching { crypto.decrypt(text) }.getOrNull() ?: return

        // Try to parse as control message first; fallback to plain text.
        val ctrl = runCatching { ControlMessage.decode(plaintext) }.getOrNull()
        if (ctrl != null) {
            handleControl(ctrl)
        } else {
            _incomingText.tryEmit(plaintext)
        }
    }

    private val fileRouter = ConnectionFileTransferRouter(
        fileTransfer        = { fileTransfer },
        chunkTimeout        = chunkTimeout,
        incomingFile        = _incomingFile,
        fileTransferAborted = _fileTransferAborted,
        sendControl         = { ctrl -> sendControl(ctrl) },
        awaitSendSlot       = { awaitSendSlot() },
        onPeerPushToken     = { ctrl -> handlePeerToken(ctrl) }
    )

    private suspend fun handleControl(ctrl: ControlMessage) = fileRouter.route(ctrl)

    private fun emitSignal(payload: JsonObject) {
        val raw = json.encodeToString(JsonElement.serializer(), payload)
        runCatching { signaling?.sendSignal(raw) }
    }

    private fun kotlinx.serialization.json.JsonPrimitive.contentOrNull(): String? =
        if (isString) content else null
}
