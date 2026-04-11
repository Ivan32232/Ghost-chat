package com.ghost.chat.core.webrtc

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.ghost.chat.core.network.TURNCredentials
import com.ghost.chat.core.network.TURNService
import kotlinx.coroutines.*

import org.json.JSONObject
import org.webrtc.*
import kotlin.coroutines.resume

/// WebRTC P2P module — port of GhostRTC.swift + webrtc.js
/// RTCPeerConnection + DataChannel + Trickle ICE
class GhostRTC(context: Context) {

    // MARK: - Properties

    var peerConnection: PeerConnection? = null
        private set
    private var dataChannel: DataChannel? = null
    val factory: PeerConnectionFactory
    private var isConnectedFlag = false
    private var isNegotiating = false
    private var disconnectRunnable: Runnable? = null

    private var turnCredentials: TURNCredentials? = null
    // Privacy mode OFF — TURN relay disabled for now (direct P2P)
    var privacyMode = false

    /// TURN credential refresh — обновление за 5 мин до истечения TTL
    private var turnRefreshJob: Job? = null
    private var turnService: TURNService? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    // MARK: - Callbacks

    var onMessage: ((String) -> Unit)? = null
    var onConnected: (() -> Unit)? = null
    var onDisconnected: (() -> Unit)? = null
    var onError: ((String) -> Unit)? = null
    var onIceCandidate: ((IceCandidate) -> Unit)? = null
    var onTrack: ((MediaStream) -> Unit)? = null
    var onRenegotiationNeeded: ((SessionDescription) -> Unit)? = null
    var onIceRestartNeeded: ((SessionDescription) -> Unit)? = null

    // MARK: - Init

    init {
        PeerConnectionFactory.initialize(
            PeerConnectionFactory.InitializationOptions.builder(context.applicationContext)
                .setEnableInternalTracer(false)
                .createInitializationOptions()
        )

        factory = PeerConnectionFactory.builder()
            .setAudioDeviceModule(
                org.webrtc.audio.JavaAudioDeviceModule.builder(context.applicationContext)
                    .setSampleRate(48000)
                    .setUseHardwareAcousticEchoCanceler(true)
                    .setUseHardwareNoiseSuppressor(true)
                    .createAudioDeviceModule()
            )
            .createPeerConnectionFactory()
    }

    // MARK: - ICE Configuration

    private fun buildConfig(): PeerConnection.RTCConfiguration {
        Log.d("GhostChat", "[GhostRTC] buildConfig called, privacyMode=$privacyMode, hasTurnCreds=${turnCredentials != null}")
        val iceServers = mutableListOf(
            PeerConnection.IceServer.builder("stun:stun.l.google.com:19302").createIceServer(),
            PeerConnection.IceServer.builder("stun:stun.cloudflare.com:3478").createIceServer()
        )

        turnCredentials?.let { creds ->
            Log.d("GhostChat", "[GhostRTC] buildConfig — adding ${creds.urls.size} TURN servers")
            for (url in creds.urls) {
                iceServers.add(
                    PeerConnection.IceServer.builder(url)
                        .setUsername(creds.username)
                        .setPassword(creds.credential)
                        .createIceServer()
                )
            }
        }

        Log.d("GhostChat", "[GhostRTC] buildConfig — totalIceServers=${iceServers.size}, transportPolicy=${if (privacyMode) "RELAY" else "ALL"}")
        return PeerConnection.RTCConfiguration(iceServers).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
            iceTransportsType = if (privacyMode) PeerConnection.IceTransportsType.RELAY
            else PeerConnection.IceTransportsType.ALL
        }
    }

    // MARK: - Host

    /** Initialize as host (room creator) */
    suspend fun initAsHost(turnCredentials: TURNCredentials?): SessionDescription? {
        Log.d("GhostChat", "[GhostRTC] initAsHost called, hasTURN=${turnCredentials != null}")
        this.turnCredentials = turnCredentials
        createPeerConnection()
        scheduleTurnRefresh()

        val pc = peerConnection ?: run {
            Log.e("GhostChat", "[GhostRTC] initAsHost failed — peerConnection is null")
            return null
        }

        // Host creates DataChannel
        val dcInit = DataChannel.Init().apply { ordered = true }
        dataChannel = pc.createDataChannel("ghost-chat", dcInit)
        setupDataChannel()

        // Create offer
        return suspendCancellableCoroutine { cont ->
            val constraints = MediaConstraints()
            pc.createOffer(object : SdpObserverAdapter() {
                override fun onCreateSuccess(sdp: SessionDescription) {
                    Log.d("GhostChat", "[GhostRTC] initAsHost offer created")
                    pc.setLocalDescription(object : SdpObserverAdapter() {
                        override fun onSetSuccess() {
                            Log.d("GhostChat", "[GhostRTC] initAsHost local description set")
                            cont.resume(sdp)
                        }
                        override fun onSetFailure(error: String?) {
                            Log.e("GhostChat", "[GhostRTC] initAsHost setLocalDescription failed: $error")
                            cont.resume(null)
                        }
                    }, sdp)
                }
                override fun onCreateFailure(error: String?) {
                    Log.e("GhostChat", "[GhostRTC] initAsHost createOffer failed: $error")
                    cont.resume(null)
                }
            }, constraints)
        }
    }

    // MARK: - Guest

    /** Initialize as guest */
    fun initAsGuest(turnCredentials: TURNCredentials?) {
        Log.d("GhostChat", "[GhostRTC] initAsGuest called, hasTURN=${turnCredentials != null}")
        this.turnCredentials = turnCredentials
        createPeerConnection()
        scheduleTurnRefresh()
        Log.d("GhostChat", "[GhostRTC] initAsGuest complete")
    }

    // MARK: - PeerConnection

    private fun createPeerConnection() {
        Log.d("GhostChat", "[GhostRTC] createPeerConnection called")
        cleanupConnection()
        val config = buildConfig()
        peerConnection = factory.createPeerConnection(config, peerConnectionObserver)
        Log.d("GhostChat", "[GhostRTC] createPeerConnection — PC created, isNull=${peerConnection == null}")
    }

    private fun cleanupConnection() {
        Log.d("GhostChat", "[GhostRTC] cleanupConnection called, hasDisconnectRunnable=${disconnectRunnable != null}, hasDataChannel=${dataChannel != null}, hasPeerConnection=${peerConnection != null}")
        disconnectRunnable?.let { mainHandler.removeCallbacks(it) }
        disconnectRunnable = null
        dataChannel?.close()
        dataChannel = null
        peerConnection?.close()
        peerConnection = null
        isConnectedFlag = false
        Log.d("GhostChat", "[GhostRTC] cleanupConnection complete")
    }

    // MARK: - DataChannel

    private fun setupDataChannel() {
        Log.d("GhostChat", "[GhostRTC] setupDataChannel called, hasDataChannel=${dataChannel != null}")
        dataChannel?.registerObserver(dataChannelObserver)
    }

    private fun fireConnected() {
        Log.d("GhostChat", "[GhostRTC] fireConnected called, isConnectedFlag=$isConnectedFlag, dataChannelState=${dataChannel?.state()}")
        if (isConnectedFlag) {
            Log.d("GhostChat", "[GhostRTC] fireConnected — already connected, skipping")
            return
        }
        if (dataChannel?.state() != DataChannel.State.OPEN) {
            Log.d("GhostChat", "[GhostRTC] fireConnected — DataChannel not OPEN (state=${dataChannel?.state()}), skipping")
            return
        }
        Log.d("GhostChat", "[GhostRTC] fireConnected — DataChannel OPEN, P2P connected, invoking onConnected callback")
        isConnectedFlag = true
        mainHandler.post { onConnected?.invoke() }
    }

    // MARK: - Signaling

    /** Handle offer (for guest) */
    suspend fun handleOffer(sdp: SessionDescription): SessionDescription? {
        Log.d("GhostChat", "[GhostRTC] handleOffer called")
        val pc = peerConnection ?: run {
            Log.e("GhostChat", "[GhostRTC] handleOffer failed — peerConnection is null")
            return null
        }

        return suspendCancellableCoroutine { cont ->
            pc.setRemoteDescription(object : SdpObserverAdapter() {
                override fun onSetSuccess() {
                    Log.d("GhostChat", "[GhostRTC] handleOffer remote description set")
                    val constraints = MediaConstraints()
                    pc.createAnswer(object : SdpObserverAdapter() {
                        override fun onCreateSuccess(answer: SessionDescription) {
                            Log.d("GhostChat", "[GhostRTC] handleOffer answer created")
                            pc.setLocalDescription(object : SdpObserverAdapter() {
                                override fun onSetSuccess() {
                                    Log.d("GhostChat", "[GhostRTC] handleOffer local description set")
                                    cont.resume(answer)
                                }
                                override fun onSetFailure(error: String?) {
                                    Log.e("GhostChat", "[GhostRTC] handleOffer setLocal failed: $error")
                                    cont.resume(null)
                                }
                            }, answer)
                        }
                        override fun onCreateFailure(error: String?) {
                            Log.e("GhostChat", "[GhostRTC] handleOffer createAnswer failed: $error")
                            cont.resume(null)
                        }
                    }, constraints)
                }
                override fun onSetFailure(error: String?) {
                    Log.e("GhostChat", "[GhostRTC] handleOffer setRemote failed: $error")
                    cont.resume(null)
                }
            }, sdp)
        }
    }

    /** Only setRemoteDescription (for renegotiation — addTrack between steps) */
    suspend fun setRemoteOffer(sdp: SessionDescription): Boolean {
        Log.d("GhostChat", "[GhostRTC] setRemoteOffer called, type=${sdp.type}")
        val pc = peerConnection ?: run {
            Log.e("GhostChat", "[GhostRTC] setRemoteOffer — peerConnection is null")
            return false
        }

        return suspendCancellableCoroutine { cont ->
            pc.setRemoteDescription(object : SdpObserverAdapter() {
                override fun onSetSuccess() {
                    Log.d("GhostChat", "[GhostRTC] setRemoteOffer — success")
                    cont.resume(true)
                }
                override fun onSetFailure(error: String?) {
                    Log.e("GhostChat", "[GhostRTC] setRemoteOffer — FAILED: $error")
                    cont.resume(false)
                }
            }, sdp)
        }
    }

    /** Only createAnswer + setLocalDescription (after setRemoteOffer + addTrack) */
    suspend fun createAndSetAnswer(): SessionDescription? {
        Log.d("GhostChat", "[GhostRTC] createAndSetAnswer called")
        val pc = peerConnection ?: run {
            Log.e("GhostChat", "[GhostRTC] createAndSetAnswer — peerConnection is null")
            return null
        }

        return suspendCancellableCoroutine { cont ->
            val constraints = MediaConstraints()
            pc.createAnswer(object : SdpObserverAdapter() {
                override fun onCreateSuccess(answer: SessionDescription) {
                    Log.d("GhostChat", "[GhostRTC] createAndSetAnswer — answer created")
                    pc.setLocalDescription(object : SdpObserverAdapter() {
                        override fun onSetSuccess() {
                            Log.d("GhostChat", "[GhostRTC] createAndSetAnswer — local desc set, success")
                            cont.resume(answer)
                        }
                        override fun onSetFailure(error: String?) {
                            Log.e("GhostChat", "[GhostRTC] createAndSetAnswer — setLocal FAILED: $error")
                            cont.resume(null)
                        }
                    }, answer)
                }
                override fun onCreateFailure(error: String?) {
                    Log.e("GhostChat", "[GhostRTC] createAndSetAnswer — createAnswer FAILED: $error")
                    cont.resume(null)
                }
            }, constraints)
        }
    }

    /** Handle answer (for host) */
    suspend fun handleAnswer(sdp: SessionDescription) {
        Log.d("GhostChat", "[GhostRTC] handleAnswer called")
        val pc = peerConnection ?: run {
            Log.e("GhostChat", "[GhostRTC] handleAnswer failed — peerConnection is null")
            return
        }
        suspendCancellableCoroutine { cont: kotlinx.coroutines.CancellableContinuation<Unit> ->
            pc.setRemoteDescription(object : SdpObserverAdapter() {
                override fun onSetSuccess() {
                    Log.d("GhostChat", "[GhostRTC] handleAnswer remote description set")
                    cont.resume(Unit)
                }
                override fun onSetFailure(error: String?) {
                    Log.e("GhostChat", "[GhostRTC] handleAnswer setRemote failed: $error")
                    cont.resume(Unit)
                }
            }, sdp)
        }
    }

    /** Add ICE candidate */
    fun addIceCandidate(candidate: IceCandidate) {
        Log.d("GhostChat", "[GhostRTC] addIceCandidate sdpMid=${candidate.sdpMid}")
        peerConnection?.addIceCandidate(candidate)
    }

    // MARK: - Data

    /** Send text via DataChannel */
    fun send(data: String): Boolean {
        val dc = dataChannel ?: run {
            Log.e("GhostChat", "[GhostRTC] send failed — dataChannel is null")
            return false
        }
        if (dc.state() != DataChannel.State.OPEN) {
            Log.e("GhostChat", "[GhostRTC] send failed — dataChannel state=${dc.state()}")
            return false
        }

        // Backpressure: wait if DataChannel buffer is too full (1MB threshold)
        val maxBuffered = 1024L * 1024 // 1MB
        var waitCount = 0
        while (dc.bufferedAmount() > maxBuffered && waitCount < 100) {
            Log.d("GhostChat", "[GhostRTC] send — backpressure, buffered=${dc.bufferedAmount()}, waiting... ($waitCount)")
            Thread.sleep(50)
            waitCount++
        }
        if (waitCount >= 100) {
            Log.e("GhostChat", "[GhostRTC] send — backpressure timeout, buffered=${dc.bufferedAmount()}, dropping message")
            return false
        }

        val buffer = DataChannel.Buffer(
            java.nio.ByteBuffer.wrap(data.toByteArray(Charsets.UTF_8)),
            false
        )
        val sent = dc.send(buffer)
        Log.d("GhostChat", "[GhostRTC] send result=$sent, size=${data.length}")
        return sent
    }

    val isConnected: Boolean
        get() = dataChannel?.state() == DataChannel.State.OPEN

    /// DataChannel buffered amount — used for backpressure in file transfer
    val bufferedAmount: Long
        get() = dataChannel?.bufferedAmount() ?: 0L

    // privacyMode is set directly via the property

    // MARK: - Audio Track Management

    fun addAudioTrack(track: AudioTrack, streamIds: List<String>): RtpSender? {
        Log.d("GhostChat", "[GhostRTC] addAudioTrack called, streamIds=$streamIds, hasPC=${peerConnection != null}")
        val sender = peerConnection?.addTrack(track, streamIds)
        Log.d("GhostChat", "[GhostRTC] addAudioTrack — result sender=${sender != null}")
        return sender
    }

    fun removeTrack(sender: RtpSender) {
        Log.d("GhostChat", "[GhostRTC] removeTrack called")
        peerConnection?.removeTrack(sender)
    }

    private var iceRestartAttempted = false

    // MARK: - Renegotiation

    suspend fun createOffer(): SessionDescription? {
        Log.d("GhostChat", "[GhostRTC] createOffer called")
        val pc = peerConnection ?: run {
            Log.e("GhostChat", "[GhostRTC] createOffer failed — peerConnection is null")
            return null
        }
        return suspendCancellableCoroutine { cont ->
            val constraints = MediaConstraints()
            pc.createOffer(object : SdpObserverAdapter() {
                override fun onCreateSuccess(sdp: SessionDescription) {
                    Log.d("GhostChat", "[GhostRTC] createOffer success")
                    pc.setLocalDescription(object : SdpObserverAdapter() {
                        override fun onSetSuccess() { cont.resume(sdp) }
                        override fun onSetFailure(error: String?) {
                            Log.e("GhostChat", "[GhostRTC] createOffer setLocal failed: $error")
                            cont.resume(null)
                        }
                    }, sdp)
                }
                override fun onCreateFailure(error: String?) {
                    Log.e("GhostChat", "[GhostRTC] createOffer failed: $error")
                    cont.resume(null)
                }
            }, constraints)
        }
    }

    // MARK: - ICE Restart

    suspend fun restartIce(): SessionDescription? {
        Log.d("GhostChat", "[GhostRTC] restartIce called")
        val pc = peerConnection ?: run {
            Log.e("GhostChat", "[GhostRTC] restartIce — peerConnection is null")
            return null
        }
        return suspendCancellableCoroutine { cont ->
            val constraints = MediaConstraints().apply {
                mandatory.add(MediaConstraints.KeyValuePair("IceRestart", "true"))
            }
            pc.createOffer(object : SdpObserverAdapter() {
                override fun onCreateSuccess(sdp: SessionDescription) {
                    Log.d("GhostChat", "[GhostRTC] restartIce — offer created")
                    pc.setLocalDescription(object : SdpObserverAdapter() {
                        override fun onSetSuccess() {
                            Log.d("GhostChat", "[GhostRTC] restartIce — local desc set, success")
                            cont.resume(sdp)
                        }
                        override fun onSetFailure(error: String?) {
                            Log.e("GhostChat", "[GhostRTC] restartIce — setLocal FAILED: $error")
                            cont.resume(null)
                        }
                    }, sdp)
                }
                override fun onCreateFailure(error: String?) {
                    Log.e("GhostChat", "[GhostRTC] restartIce — createOffer FAILED: $error")
                    cont.resume(null)
                }
            }, constraints)
        }
    }

    // MARK: - TURN Credential Refresh

    /** Установить TURNService для автоматического обновления credentials */
    fun setTurnService(service: TURNService?) {
        Log.d("GhostChat", "[GhostRTC] setTurnService called, hasService=${service != null}")
        this.turnService = service
    }

    /** Запланировать обновление TURN credentials за 5 мин до истечения TTL */
    private fun scheduleTurnRefresh() {
        Log.d("GhostChat", "[GhostRTC] scheduleTurnRefresh called")
        turnRefreshJob?.cancel()
        turnRefreshJob = null

        val creds = turnCredentials ?: run {
            Log.d("GhostChat", "[GhostRTC] scheduleTurnRefresh — no turnCredentials, skipping")
            return
        }
        if (turnService == null) {
            Log.d("GhostChat", "[GhostRTC] scheduleTurnRefresh — no turnService, skipping")
            return
        }

        // Обновляем за 300 секунд (5 мин) до истечения, минимум 60 секунд
        val refreshDelay = maxOf((creds.ttl - 300).toLong(), 60L) * 1000L
        Log.d("GhostChat", "[GhostRTC] scheduleTurnRefresh — scheduling refresh in ${refreshDelay}ms (ttl=${creds.ttl})")

        turnRefreshJob = scope.launch {
            delay(refreshDelay)
            refreshTurnCredentials()
        }
    }

    /** Обновить TURN credentials и применить к PeerConnection */
    private suspend fun refreshTurnCredentials() {
        Log.d("GhostChat", "[GhostRTC] refreshTurnCredentials called")
        val service = turnService ?: run {
            Log.d("GhostChat", "[GhostRTC] refreshTurnCredentials — turnService is null, skipping")
            return
        }

        try {
            val newCreds = service.fetchCredentials()
            turnCredentials = newCreds
            Log.d("GhostChat", "[GhostRTC] refreshTurnCredentials — got new creds, ttl=${newCreds.ttl}")

            // Обновляем ICE серверы на живом PeerConnection
            peerConnection?.let { pc ->
                val config = buildConfig()
                pc.setConfiguration(config)
                Log.d("GhostChat", "[GhostRTC] refreshTurnCredentials — applied new config to PeerConnection")
            }

            // Планируем следующее обновление
            scheduleTurnRefresh()
        } catch (e: Exception) {
            Log.e("GhostChat", "[GhostRTC] refreshTurnCredentials — FAILED: ${e.message}, retrying in 5 min")
            // Retry через 5 минут
            turnRefreshJob = scope.launch {
                delay(300_000L)
                refreshTurnCredentials()
            }
        }
    }

    // MARK: - Cleanup

    fun destroy() {
        Log.d("GhostChat", "[GhostRTC] destroy called, isConnected=$isConnectedFlag, hasDataChannel=${dataChannel != null}, hasPC=${peerConnection != null}")
        turnRefreshJob?.cancel()
        turnRefreshJob = null
        scope.cancel()
        disconnectRunnable?.let { mainHandler.removeCallbacks(it) }
        disconnectRunnable = null
        dataChannel?.close()
        dataChannel = null
        peerConnection?.close()
        peerConnection = null
        factory.dispose()
        onMessage = null
        onConnected = null
        onDisconnected = null
        onError = null
        onIceCandidate = null
        onTrack = null
        onRenegotiationNeeded = null
        onIceRestartNeeded = null
        isConnectedFlag = false
        isNegotiating = false
        iceRestartAttempted = false
        turnCredentials = null
        turnService = null
        Log.d("GhostChat", "[GhostRTC] destroy complete — all resources cleaned up")
    }

    // MARK: - PeerConnection Observer

    private val peerConnectionObserver = object : PeerConnection.Observer {
        override fun onSignalingChange(state: PeerConnection.SignalingState?) {
            Log.d("GhostChat", "[GhostRTC] onSignalingChange: $state")
        }

        override fun onIceConnectionChange(state: PeerConnection.IceConnectionState?) {
            Log.d("GhostChat", "[GhostRTC] ICE state changed: $state, isConnectedFlag=$isConnectedFlag, iceRestartAttempted=$iceRestartAttempted")
            mainHandler.post {
                disconnectRunnable?.let { mainHandler.removeCallbacks(it) }
                disconnectRunnable = null

                when (state) {
                    PeerConnection.IceConnectionState.CONNECTED,
                    PeerConnection.IceConnectionState.COMPLETED -> {
                        Log.d("GhostChat", "[GhostRTC] ICE CONNECTED/COMPLETED — resetting iceRestartAttempted, calling fireConnected")
                        iceRestartAttempted = false
                        fireConnected()
                    }

                    PeerConnection.IceConnectionState.FAILED -> {
                        Log.e("GhostChat", "[GhostRTC] ICE FAILED — isConnectedFlag=$isConnectedFlag, iceRestartAttempted=$iceRestartAttempted")
                        // Attempt ICE restart before disconnecting
                        if (isConnectedFlag && !iceRestartAttempted) {
                            Log.d("GhostChat", "[GhostRTC] ICE FAILED — attempting ICE restart")
                            iceRestartAttempted = true
                            scope.launch {
                                val offer = restartIce()
                                if (offer != null) {
                                    Log.d("GhostChat", "[GhostRTC] ICE FAILED — restart offer created, sending via signaling")
                                    // ICE restart offer MUST go through signaling (not DataChannel!)
                                    onIceRestartNeeded?.invoke(offer)
                                } else {
                                    Log.e("GhostChat", "[GhostRTC] ICE FAILED — restart offer creation failed, disconnecting")
                                    onError?.invoke("ICE connection failed")
                                    isConnectedFlag = false
                                    onDisconnected?.invoke()
                                }
                            }
                        } else {
                            Log.e("GhostChat", "[GhostRTC] ICE FAILED — no restart possible (wasConnected=$isConnectedFlag, alreadyAttempted=$iceRestartAttempted)")
                            onError?.invoke("ICE connection failed")
                            if (isConnectedFlag) {
                                isConnectedFlag = false
                                onDisconnected?.invoke()
                            }
                        }
                    }

                    PeerConnection.IceConnectionState.DISCONNECTED -> {
                        Log.d("GhostChat", "[GhostRTC] ICE DISCONNECTED — isConnectedFlag=$isConnectedFlag")
                        if (isConnectedFlag) {
                            Log.d("GhostChat", "[GhostRTC] ICE DISCONNECTED — scheduling delayed disconnect (5s)")
                            // Delayed disconnect — ICE may reconnect (5s)
                            val runnable = Runnable {
                                val currentState = peerConnection?.iceConnectionState()
                                Log.d("GhostChat", "[GhostRTC] ICE DISCONNECTED delayed check — currentState=$currentState, iceRestartAttempted=$iceRestartAttempted")
                                if (currentState == PeerConnection.IceConnectionState.DISCONNECTED) {
                                    // Try ICE restart before giving up
                                    if (!iceRestartAttempted) {
                                        Log.d("GhostChat", "[GhostRTC] ICE DISCONNECTED — attempting ICE restart after delay")
                                        iceRestartAttempted = true
                                        scope.launch {
                                            val offer = restartIce()
                                            if (offer != null) {
                                                Log.d("GhostChat", "[GhostRTC] ICE DISCONNECTED — restart offer created")
                                                // ICE restart via signaling (not DataChannel!)
                                                onIceRestartNeeded?.invoke(offer)
                                            } else {
                                                Log.e("GhostChat", "[GhostRTC] ICE DISCONNECTED — restart failed, disconnecting")
                                                isConnectedFlag = false
                                                onDisconnected?.invoke()
                                            }
                                        }
                                    } else {
                                        Log.e("GhostChat", "[GhostRTC] ICE DISCONNECTED — already attempted restart, disconnecting")
                                        isConnectedFlag = false
                                        onDisconnected?.invoke()
                                    }
                                } else {
                                    Log.d("GhostChat", "[GhostRTC] ICE DISCONNECTED delayed check — state recovered to $currentState")
                                }
                            }
                            disconnectRunnable = runnable
                            mainHandler.postDelayed(runnable, 5000)
                        } else {
                            Log.d("GhostChat", "[GhostRTC] ICE DISCONNECTED — was not connected, ignoring")
                        }
                    }

                    PeerConnection.IceConnectionState.CLOSED -> {
                        Log.d("GhostChat", "[GhostRTC] ICE CLOSED — isConnectedFlag=$isConnectedFlag")
                        if (isConnectedFlag) {
                            isConnectedFlag = false
                            onDisconnected?.invoke()
                        }
                    }

                    else -> {
                        Log.d("GhostChat", "[GhostRTC] ICE state (unhandled): $state")
                    }
                }
            }
        }

        override fun onIceConnectionReceivingChange(receiving: Boolean) {
            Log.d("GhostChat", "[GhostRTC] onIceConnectionReceivingChange: receiving=$receiving")
        }

        override fun onIceGatheringChange(state: PeerConnection.IceGatheringState?) {
            Log.d("GhostChat", "[GhostRTC] onIceGatheringChange: $state")
        }

        override fun onIceCandidate(candidate: IceCandidate) {
            Log.d("GhostChat", "[GhostRTC] onIceCandidate sdpMid=${candidate.sdpMid}, privacyMode=$privacyMode, isRelay=${candidate.sdp.contains("typ relay")}")
            // Filter candidates in privacy mode
            if (privacyMode && !candidate.sdp.contains("typ relay")) {
                Log.d("GhostChat", "[GhostRTC] onIceCandidate — filtered non-relay candidate in privacy mode")
                return
            }
            mainHandler.post { this@GhostRTC.onIceCandidate?.invoke(candidate) }
        }

        override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>?) {
            Log.d("GhostChat", "[GhostRTC] onIceCandidatesRemoved count=${candidates?.size}")
        }

        override fun onAddStream(stream: MediaStream) {
            Log.d("GhostChat", "[GhostRTC] onAddStream audioTracks=${stream.audioTracks?.size}, videoTracks=${stream.videoTracks?.size}")
            mainHandler.post { onTrack?.invoke(stream) }
        }

        override fun onRemoveStream(stream: MediaStream?) {
            Log.d("GhostChat", "[GhostRTC] onRemoveStream")
        }

        override fun onDataChannel(channel: DataChannel) {
            Log.d("GhostChat", "[GhostRTC] onDataChannel label=${channel.label()}, state=${channel.state()}")
            // Guest receives DataChannel from host — validate label
            if (channel.label() != "ghost-chat") {
                Log.d("GhostChat", "[GhostRTC] onDataChannel — wrong label '${channel.label()}', ignoring")
                return
            }
            // Register observer immediately on WebRTC thread to avoid missing messages
            // that arrive before mainHandler.post executes (key-exchange race on fast networks)
            Log.d("GhostChat", "[GhostRTC] onDataChannel — registering observer for 'ghost-chat'")
            dataChannel = channel
            channel.registerObserver(dataChannelObserver)
        }

        override fun onRenegotiationNeeded() {
            Log.d("GhostChat", "[GhostRTC] onRenegotiationNeeded — isNegotiating=$isNegotiating, isConnectedFlag=$isConnectedFlag")
            if (isNegotiating || !isConnectedFlag) {
                Log.d("GhostChat", "[GhostRTC] onRenegotiationNeeded — skipping (negotiating=$isNegotiating, connected=$isConnectedFlag)")
                return
            }
            isNegotiating = true
            Log.d("GhostChat", "[GhostRTC] onRenegotiationNeeded — starting renegotiation")

            scope.launch {
                try {
                    val offer = createOffer()
                    if (offer != null) {
                        Log.d("GhostChat", "[GhostRTC] onRenegotiationNeeded — offer created, invoking callback")
                        onRenegotiationNeeded?.invoke(offer)
                    } else {
                        Log.e("GhostChat", "[GhostRTC] onRenegotiationNeeded — createOffer returned null")
                    }
                } finally {
                    isNegotiating = false
                }
            }
        }

        override fun onAddTrack(receiver: RtpReceiver?, streams: Array<out MediaStream>?) {
            Log.d("GhostChat", "[GhostRTC] onAddTrack receiver=${receiver != null}, streamsCount=${streams?.size}")
        }

        override fun onConnectionChange(newState: PeerConnection.PeerConnectionState?) {
            Log.d("GhostChat", "[GhostRTC] onConnectionChange: $newState, isConnectedFlag=$isConnectedFlag")
            mainHandler.post {
                when (newState) {
                    PeerConnection.PeerConnectionState.CONNECTED -> {
                        Log.d("GhostChat", "[GhostRTC] PeerConnectionState.CONNECTED — isConnectedFlag=$isConnectedFlag")
                        if (!isConnectedFlag) fireConnected()
                    }
                    PeerConnection.PeerConnectionState.FAILED,
                    PeerConnection.PeerConnectionState.CLOSED -> {
                        Log.d("GhostChat", "[GhostRTC] PeerConnectionState ${newState} — isConnectedFlag=$isConnectedFlag")
                        if (isConnectedFlag) {
                            isConnectedFlag = false
                            onDisconnected?.invoke()
                        }
                    }
                    else -> {
                        Log.d("GhostChat", "[GhostRTC] PeerConnectionState (unhandled): $newState")
                    }
                }
            }
        }
    }

    // MARK: - DataChannel Observer

    private val dataChannelObserver = object : DataChannel.Observer {
        override fun onBufferedAmountChange(previousAmount: Long) {
            Log.d("GhostChat", "[GhostRTC] DataChannel onBufferedAmountChange: previous=$previousAmount, current=${dataChannel?.bufferedAmount()}")
        }

        override fun onStateChange() {
            val state = dataChannel?.state()
            Log.d("GhostChat", "[GhostRTC] DataChannel onStateChange: $state, isConnectedFlag=$isConnectedFlag")
            mainHandler.post {
                when (state) {
                    DataChannel.State.OPEN -> {
                        Log.d("GhostChat", "[GhostRTC] DataChannel OPEN — calling fireConnected")
                        fireConnected()
                    }
                    DataChannel.State.CLOSED -> {
                        Log.d("GhostChat", "[GhostRTC] DataChannel CLOSED — isConnectedFlag=$isConnectedFlag")
                        if (isConnectedFlag) {
                            Log.d("GhostChat", "[GhostRTC] DataChannel CLOSED — was connected, invoking onDisconnected")
                            isConnectedFlag = false
                            onDisconnected?.invoke()
                        }
                    }
                    DataChannel.State.CLOSING -> {
                        Log.d("GhostChat", "[GhostRTC] DataChannel CLOSING")
                    }
                    DataChannel.State.CONNECTING -> {
                        Log.d("GhostChat", "[GhostRTC] DataChannel CONNECTING")
                    }
                    else -> {
                        Log.d("GhostChat", "[GhostRTC] DataChannel state unhandled: $state")
                    }
                }
            }
        }

        override fun onMessage(buffer: DataChannel.Buffer) {
            val data = ByteArray(buffer.data.remaining())
            buffer.data.get(data)
            val text = String(data, Charsets.UTF_8)
            Log.d("GhostChat", "[GhostRTC] DataChannel onMessage received, size=${text.length}, isBinary=${buffer.binary}")
            mainHandler.post { onMessage?.invoke(text) }
        }
    }

    // MARK: - SDP Helpers

    companion object {
        fun sdpToJson(sdp: SessionDescription): JSONObject {
            val typeStr = when (sdp.type) {
                SessionDescription.Type.OFFER -> "offer"
                SessionDescription.Type.ANSWER -> "answer"
                SessionDescription.Type.PRANSWER -> "pranswer"
                else -> "unknown"
            }
            return JSONObject().apply {
                put("type", typeStr)
                put("sdp", sdp.description)
            }
        }

        fun jsonToSdp(json: JSONObject): SessionDescription? {
            val typeStr = json.optString("type", "")
            val sdpStr = json.optString("sdp", "")
            if (sdpStr.isEmpty()) return null

            val type = when (typeStr) {
                "offer" -> SessionDescription.Type.OFFER
                "answer" -> SessionDescription.Type.ANSWER
                "pranswer" -> SessionDescription.Type.PRANSWER
                else -> return null
            }
            return SessionDescription(type, sdpStr)
        }

        fun candidateToJson(candidate: IceCandidate): JSONObject {
            return JSONObject().apply {
                put("candidate", candidate.sdp)
                put("sdpMLineIndex", candidate.sdpMLineIndex)
                put("sdpMid", candidate.sdpMid ?: "")
            }
        }

        fun jsonToCandidate(json: JSONObject): IceCandidate? {
            val sdp = json.optString("candidate", "")
            if (sdp.isEmpty()) return null
            val sdpMLineIndex = json.optInt("sdpMLineIndex", 0)
            val sdpMid = json.optString("sdpMid", "")
            return IceCandidate(sdpMid, sdpMLineIndex, sdp)
        }
    }
}

/** Adapter for SdpObserver to avoid implementing all methods */
open class SdpObserverAdapter : SdpObserver {
    override fun onCreateSuccess(sdp: SessionDescription) {}
    override fun onSetSuccess() {}
    override fun onCreateFailure(error: String?) {}
    override fun onSetFailure(error: String?) {}
}
