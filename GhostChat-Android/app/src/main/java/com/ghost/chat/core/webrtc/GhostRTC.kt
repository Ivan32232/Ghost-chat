package com.ghost.chat.core.webrtc

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.ghost.chat.core.network.TURNCredentials
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
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
    var privacyMode = false

    private val mainHandler = Handler(Looper.getMainLooper())

    // MARK: - Callbacks

    var onMessage: ((String) -> Unit)? = null
    var onConnected: (() -> Unit)? = null
    var onDisconnected: (() -> Unit)? = null
    var onError: ((String) -> Unit)? = null
    var onIceCandidate: ((IceCandidate) -> Unit)? = null
    var onTrack: ((MediaStream) -> Unit)? = null
    var onRenegotiationNeeded: ((SessionDescription) -> Unit)? = null

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
        val iceServers = mutableListOf(
            PeerConnection.IceServer.builder("stun:stun.l.google.com:19302").createIceServer(),
            PeerConnection.IceServer.builder("stun:stun.cloudflare.com:3478").createIceServer()
        )

        turnCredentials?.let { creds ->
            for (url in creds.urls) {
                iceServers.add(
                    PeerConnection.IceServer.builder(url)
                        .setUsername(creds.username)
                        .setPassword(creds.credential)
                        .createIceServer()
                )
            }
        }

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
        this.turnCredentials = turnCredentials
        createPeerConnection()

        val pc = peerConnection ?: return null

        // Host creates DataChannel
        val dcInit = DataChannel.Init().apply { ordered = true }
        dataChannel = pc.createDataChannel("ghost-chat", dcInit)
        setupDataChannel()

        // Create offer
        return suspendCancellableCoroutine { cont ->
            val constraints = MediaConstraints()
            pc.createOffer(object : SdpObserverAdapter() {
                override fun onCreateSuccess(sdp: SessionDescription) {
                    pc.setLocalDescription(object : SdpObserverAdapter() {
                        override fun onSetSuccess() {
                            cont.resume(sdp)
                        }
                        override fun onSetFailure(error: String?) {
                            cont.resume(null)
                        }
                    }, sdp)
                }
                override fun onCreateFailure(error: String?) {
                    cont.resume(null)
                }
            }, constraints)
        }
    }

    // MARK: - Guest

    /** Initialize as guest */
    fun initAsGuest(turnCredentials: TURNCredentials?) {
        this.turnCredentials = turnCredentials
        createPeerConnection()
    }

    // MARK: - PeerConnection

    private fun createPeerConnection() {
        cleanupConnection()
        val config = buildConfig()
        peerConnection = factory.createPeerConnection(config, peerConnectionObserver)
    }

    private fun cleanupConnection() {
        disconnectRunnable?.let { mainHandler.removeCallbacks(it) }
        disconnectRunnable = null
        dataChannel?.close()
        dataChannel = null
        peerConnection?.close()
        peerConnection = null
        isConnectedFlag = false
    }

    // MARK: - DataChannel

    private fun setupDataChannel() {
        dataChannel?.registerObserver(dataChannelObserver)
    }

    private fun fireConnected() {
        if (isConnectedFlag) return
        if (dataChannel?.state() != DataChannel.State.OPEN) return
        isConnectedFlag = true
        mainHandler.post { onConnected?.invoke() }
    }

    // MARK: - Signaling

    /** Handle offer (for guest) */
    suspend fun handleOffer(sdp: SessionDescription): SessionDescription? {
        val pc = peerConnection ?: return null

        return suspendCancellableCoroutine { cont ->
            pc.setRemoteDescription(object : SdpObserverAdapter() {
                override fun onSetSuccess() {
                    val constraints = MediaConstraints()
                    pc.createAnswer(object : SdpObserverAdapter() {
                        override fun onCreateSuccess(answer: SessionDescription) {
                            pc.setLocalDescription(object : SdpObserverAdapter() {
                                override fun onSetSuccess() { cont.resume(answer) }
                                override fun onSetFailure(error: String?) { cont.resume(null) }
                            }, answer)
                        }
                        override fun onCreateFailure(error: String?) { cont.resume(null) }
                    }, constraints)
                }
                override fun onSetFailure(error: String?) { cont.resume(null) }
            }, sdp)
        }
    }

    /** Handle answer (for host) */
    suspend fun handleAnswer(sdp: SessionDescription) {
        suspendCancellableCoroutine { cont: kotlinx.coroutines.CancellableContinuation<Unit> ->
            peerConnection?.setRemoteDescription(object : SdpObserverAdapter() {
                override fun onSetSuccess() { cont.resume(Unit) }
                override fun onSetFailure(error: String?) { cont.resume(Unit) }
            }, sdp)
        }
    }

    /** Add ICE candidate */
    fun addIceCandidate(candidate: IceCandidate) {
        peerConnection?.addIceCandidate(candidate)
    }

    // MARK: - Data

    /** Send text via DataChannel */
    fun send(data: String): Boolean {
        val dc = dataChannel ?: return false
        if (dc.state() != DataChannel.State.OPEN) return false
        val buffer = DataChannel.Buffer(
            java.nio.ByteBuffer.wrap(data.toByteArray(Charsets.UTF_8)),
            false
        )
        return dc.send(buffer)
    }

    val isConnected: Boolean
        get() = dataChannel?.state() == DataChannel.State.OPEN

    // privacyMode is set directly via the property

    // MARK: - Audio Track Management

    fun addAudioTrack(track: AudioTrack, streamIds: List<String>): RtpSender? {
        return peerConnection?.addTrack(track, streamIds)
    }

    fun removeTrack(sender: RtpSender) {
        peerConnection?.removeTrack(sender)
    }

    // MARK: - Renegotiation

    suspend fun createOffer(): SessionDescription? {
        val pc = peerConnection ?: return null
        return suspendCancellableCoroutine { cont ->
            val constraints = MediaConstraints()
            pc.createOffer(object : SdpObserverAdapter() {
                override fun onCreateSuccess(sdp: SessionDescription) {
                    pc.setLocalDescription(object : SdpObserverAdapter() {
                        override fun onSetSuccess() { cont.resume(sdp) }
                        override fun onSetFailure(error: String?) { cont.resume(null) }
                    }, sdp)
                }
                override fun onCreateFailure(error: String?) { cont.resume(null) }
            }, constraints)
        }
    }

    // MARK: - Cleanup

    fun destroy() {
        disconnectRunnable?.let { mainHandler.removeCallbacks(it) }
        disconnectRunnable = null
        dataChannel?.close()
        dataChannel = null
        peerConnection?.close()
        peerConnection = null
        onMessage = null
        onConnected = null
        onDisconnected = null
        onError = null
        onIceCandidate = null
        onTrack = null
        onRenegotiationNeeded = null
        isConnectedFlag = false
        isNegotiating = false
        turnCredentials = null
    }

    // MARK: - PeerConnection Observer

    private val peerConnectionObserver = object : PeerConnection.Observer {
        override fun onSignalingChange(state: PeerConnection.SignalingState?) {}

        override fun onIceConnectionChange(state: PeerConnection.IceConnectionState?) {
            mainHandler.post {
                disconnectRunnable?.let { mainHandler.removeCallbacks(it) }
                disconnectRunnable = null

                when (state) {
                    PeerConnection.IceConnectionState.CONNECTED,
                    PeerConnection.IceConnectionState.COMPLETED -> fireConnected()

                    PeerConnection.IceConnectionState.FAILED -> {
                        onError?.invoke("ICE connection failed")
                        if (isConnectedFlag) {
                            isConnectedFlag = false
                            onDisconnected?.invoke()
                        }
                    }

                    PeerConnection.IceConnectionState.DISCONNECTED -> {
                        if (isConnectedFlag) {
                            // Delayed disconnect — ICE may reconnect (5s)
                            val runnable = Runnable {
                                if (peerConnection?.iceConnectionState() ==
                                    PeerConnection.IceConnectionState.DISCONNECTED
                                ) {
                                    isConnectedFlag = false
                                    onDisconnected?.invoke()
                                }
                            }
                            disconnectRunnable = runnable
                            mainHandler.postDelayed(runnable, 5000)
                        }
                    }

                    PeerConnection.IceConnectionState.CLOSED -> {
                        if (isConnectedFlag) {
                            isConnectedFlag = false
                            onDisconnected?.invoke()
                        }
                    }

                    else -> {}
                }
            }
        }

        override fun onIceConnectionReceivingChange(receiving: Boolean) {}

        override fun onIceGatheringChange(state: PeerConnection.IceGatheringState?) {}

        override fun onIceCandidate(candidate: IceCandidate) {
            // Filter candidates in privacy mode
            if (privacyMode && !candidate.sdp.contains("typ relay")) return
            mainHandler.post { this@GhostRTC.onIceCandidate?.invoke(candidate) }
        }

        override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>?) {}

        override fun onAddStream(stream: MediaStream) {
            mainHandler.post { onTrack?.invoke(stream) }
        }

        override fun onRemoveStream(stream: MediaStream?) {}

        override fun onDataChannel(channel: DataChannel) {
            // Guest receives DataChannel from host — validate label
            if (channel.label() != "ghost-chat") return
            mainHandler.post {
                dataChannel = channel
                setupDataChannel()
            }
        }

        override fun onRenegotiationNeeded() {
            if (isNegotiating || !isConnectedFlag) return
            isNegotiating = true

            kotlinx.coroutines.GlobalScope.launch(kotlinx.coroutines.Dispatchers.Main) {
                val offer = createOffer()
                isNegotiating = false
                offer?.let { onRenegotiationNeeded?.invoke(it) }
            }
        }

        override fun onAddTrack(receiver: RtpReceiver?, streams: Array<out MediaStream>?) {}

        override fun onConnectionChange(newState: PeerConnection.PeerConnectionState?) {
            mainHandler.post {
                when (newState) {
                    PeerConnection.PeerConnectionState.CONNECTED -> {
                        if (!isConnectedFlag) fireConnected()
                    }
                    PeerConnection.PeerConnectionState.FAILED,
                    PeerConnection.PeerConnectionState.CLOSED -> {
                        if (isConnectedFlag) {
                            isConnectedFlag = false
                            onDisconnected?.invoke()
                        }
                    }
                    else -> {}
                }
            }
        }
    }

    // MARK: - DataChannel Observer

    private val dataChannelObserver = object : DataChannel.Observer {
        override fun onBufferedAmountChange(previousAmount: Long) {}

        override fun onStateChange() {
            mainHandler.post {
                when (dataChannel?.state()) {
                    DataChannel.State.OPEN -> fireConnected()
                    DataChannel.State.CLOSED -> {
                        if (isConnectedFlag) {
                            isConnectedFlag = false
                            onDisconnected?.invoke()
                        }
                    }
                    else -> {}
                }
            }
        }

        override fun onMessage(buffer: DataChannel.Buffer) {
            val data = ByteArray(buffer.data.remaining())
            buffer.data.get(data)
            val text = String(data, Charsets.UTF_8)
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
