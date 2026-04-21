package com.kordar.ghostchat.core.webrtc

import android.content.Context
import com.kordar.ghostchat.core.network.TURNCredentials
import com.kordar.ghostchat.models.Role
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import org.webrtc.DataChannel
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
import org.webrtc.EglBase
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpReceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Mirror of iOS [GhostRTCEvent]. */
sealed class GhostRTCEvent {
    data class IceCandidate(val sdp: String, val sdpMid: String?, val sdpMLineIndex: Int) : GhostRTCEvent()
    data class OfferReady(val sdp: String) : GhostRTCEvent()
    data class AnswerReady(val sdp: String) : GhostRTCEvent()
    data object DataChannelOpen : GhostRTCEvent()
    data object DataChannelClosed : GhostRTCEvent()
    data class DataChannelMessage(val data: ByteArray) : GhostRTCEvent()
    data class IceStateChanged(val description: String) : GhostRTCEvent()
    data class PeerConnectionStateChanged(val description: String) : GhostRTCEvent()
}

/**
 * Singleton [PeerConnectionFactory] — expensive to create; one per process.
 */
object GhostRTCFactory {
    @Volatile private var factory: PeerConnectionFactory? = null
    @Volatile private var eglBase: EglBase? = null

    @Synchronized
    fun get(context: Context): PeerConnectionFactory {
        factory?.let { return it }
        PeerConnectionFactory.initialize(
            PeerConnectionFactory.InitializationOptions.builder(context.applicationContext)
                .setEnableInternalTracer(false)
                .createInitializationOptions()
        )
        val egl = EglBase.create()
        eglBase = egl
        val options = PeerConnectionFactory.Options()
        val created = PeerConnectionFactory.builder()
            .setOptions(options)
            .setVideoEncoderFactory(DefaultVideoEncoderFactory(egl.eglBaseContext, true, true))
            .setVideoDecoderFactory(DefaultVideoDecoderFactory(egl.eglBaseContext))
            .createPeerConnectionFactory()
        factory = created
        return created
    }
}

/**
 * Owns a single [PeerConnection] + the `ghost-chat` data channel. Mirror of iOS GhostRTC.
 * HOST creates the data channel up front; GUEST receives it via the `onDataChannel` callback.
 */
class GhostRTC(
    private val context: Context,
    val role: Role,
    private val turnCredentials: TURNCredentials? = null,
    private val privacyMode: Boolean = false,
    private val factory: PeerConnectionFactory = GhostRTCFactory.get(context)
) {

    companion object {
        const val DATA_CHANNEL_LABEL = "ghost-chat"

        /** Mirror of iOS `GhostRTC.shouldAcceptCandidate`. */
        fun shouldAcceptCandidate(sdp: String): Boolean {
            if (sdp.contains(" typ host ")) return false
            if (sdp.lowercase().contains(" fe80:")) return false
            return true
        }
    }

    private val _events = MutableSharedFlow<GhostRTCEvent>(
        replay = 0,
        extraBufferCapacity = 64,
        onBufferOverflow = BufferOverflow.DROP_OLDEST
    )
    val events: SharedFlow<GhostRTCEvent> = _events.asSharedFlow()

    var peerConnection: PeerConnection? = null
        private set

    var dataChannel: DataChannel? = null
        private set

    // MARK: - Lifecycle

    fun start() {
        if (peerConnection != null) return
        val config = PeerConnection.RTCConfiguration(makeIceServers()).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            bundlePolicy = PeerConnection.BundlePolicy.MAXBUNDLE
            rtcpMuxPolicy = PeerConnection.RtcpMuxPolicy.REQUIRE
            iceTransportsType = if (privacyMode) PeerConnection.IceTransportsType.RELAY
                                else PeerConnection.IceTransportsType.ALL
            continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
        }
        val pc = factory.createPeerConnection(config, observer)
            ?: error("failed to create PeerConnection")
        peerConnection = pc

        if (role == Role.HOST) {
            val init = DataChannel.Init().apply {
                ordered = true
                negotiated = false
            }
            dataChannel = pc.createDataChannel(DATA_CHANNEL_LABEL, init)
            dataChannel?.registerObserver(dcObserver)
        }
    }

    fun close() {
        dataChannel?.close(); dataChannel = null
        peerConnection?.close(); peerConnection = null
    }

    // MARK: - Signaling

    suspend fun createOffer(): Unit = suspendCancellableCoroutine { cont ->
        val pc = peerConnection ?: run { cont.resumeWithException(IllegalStateException("not started")); return@suspendCancellableCoroutine }
        val constraints = MediaConstraints()
        pc.createOffer(object : SdpObserver {
            override fun onCreateSuccess(sdp: SessionDescription) {
                pc.setLocalDescription(
                    object : SdpObserver {
                        override fun onSetSuccess() {
                            _events.tryEmit(GhostRTCEvent.OfferReady(sdp.description))
                            if (cont.isActive) cont.resume(Unit)
                        }
                        override fun onSetFailure(err: String) { if (cont.isActive) cont.resumeWithException(RuntimeException(err)) }
                        override fun onCreateSuccess(p0: SessionDescription?) = Unit
                        override fun onCreateFailure(p0: String?) = Unit
                    },
                    sdp
                )
            }
            override fun onCreateFailure(err: String) { if (cont.isActive) cont.resumeWithException(RuntimeException(err)) }
            override fun onSetSuccess() = Unit
            override fun onSetFailure(p0: String?) = Unit
        }, constraints)
    }

    suspend fun receiveOffer(sdpString: String): Unit = suspendCancellableCoroutine { cont ->
        val pc = peerConnection ?: run { cont.resumeWithException(IllegalStateException("not started")); return@suspendCancellableCoroutine }
        val offer = SessionDescription(SessionDescription.Type.OFFER, sdpString)
        pc.setRemoteDescription(object : SdpObserver {
            override fun onSetSuccess() {
                pc.createAnswer(object : SdpObserver {
                    override fun onCreateSuccess(sdp: SessionDescription) {
                        pc.setLocalDescription(object : SdpObserver {
                            override fun onSetSuccess() {
                                _events.tryEmit(GhostRTCEvent.AnswerReady(sdp.description))
                                if (cont.isActive) cont.resume(Unit)
                            }
                            override fun onSetFailure(err: String) { if (cont.isActive) cont.resumeWithException(RuntimeException(err)) }
                            override fun onCreateSuccess(p0: SessionDescription?) = Unit
                            override fun onCreateFailure(p0: String?) = Unit
                        }, sdp)
                    }
                    override fun onCreateFailure(err: String) { if (cont.isActive) cont.resumeWithException(RuntimeException(err)) }
                    override fun onSetSuccess() = Unit
                    override fun onSetFailure(p0: String?) = Unit
                }, MediaConstraints())
            }
            override fun onSetFailure(err: String) { if (cont.isActive) cont.resumeWithException(RuntimeException(err)) }
            override fun onCreateSuccess(p0: SessionDescription?) = Unit
            override fun onCreateFailure(p0: String?) = Unit
        }, offer)
    }

    suspend fun receiveAnswer(sdpString: String): Unit = suspendCancellableCoroutine { cont ->
        val pc = peerConnection ?: run { cont.resumeWithException(IllegalStateException("not started")); return@suspendCancellableCoroutine }
        val answer = SessionDescription(SessionDescription.Type.ANSWER, sdpString)
        pc.setRemoteDescription(object : SdpObserver {
            override fun onSetSuccess() { if (cont.isActive) cont.resume(Unit) }
            override fun onSetFailure(err: String) { if (cont.isActive) cont.resumeWithException(RuntimeException(err)) }
            override fun onCreateSuccess(p0: SessionDescription?) = Unit
            override fun onCreateFailure(p0: String?) = Unit
        }, answer)
    }

    fun addIceCandidate(sdp: String, sdpMid: String?, sdpMLineIndex: Int) {
        val candidate = IceCandidate(sdpMid ?: "", sdpMLineIndex, sdp)
        peerConnection?.addIceCandidate(candidate)
    }

    /** Send arbitrary bytes over the data channel. */
    fun send(data: ByteArray): Boolean {
        val dc = dataChannel ?: return false
        if (dc.state() != DataChannel.State.OPEN) return false
        val buf = DataChannel.Buffer(java.nio.ByteBuffer.wrap(data), true)
        return dc.send(buf)
    }

    // MARK: - Private

    private fun makeIceServers(): List<PeerConnection.IceServer> {
        val servers = mutableListOf(
            PeerConnection.IceServer.builder("stun:stun.l.google.com:19302").createIceServer(),
            PeerConnection.IceServer.builder("stun:stun.cloudflare.com:3478").createIceServer()
        )
        turnCredentials?.let { turn ->
            servers += PeerConnection.IceServer.builder(turn.urls)
                .setUsername(turn.username)
                .setPassword(turn.credential)
                .createIceServer()
        }
        return servers
    }

    private val observer = object : PeerConnection.Observer {
        override fun onSignalingChange(p0: PeerConnection.SignalingState?) = Unit
        override fun onIceConnectionChange(state: PeerConnection.IceConnectionState) {
            _events.tryEmit(GhostRTCEvent.IceStateChanged(state.name))
        }
        override fun onConnectionChange(state: PeerConnection.PeerConnectionState) {
            _events.tryEmit(GhostRTCEvent.PeerConnectionStateChanged(state.name))
        }
        override fun onIceConnectionReceivingChange(p0: Boolean) = Unit
        override fun onIceGatheringChange(p0: PeerConnection.IceGatheringState?) = Unit
        override fun onIceCandidate(candidate: IceCandidate) {
            if (!shouldAcceptCandidate(candidate.sdp)) return
            _events.tryEmit(
                GhostRTCEvent.IceCandidate(
                    sdp = candidate.sdp,
                    sdpMid = candidate.sdpMid,
                    sdpMLineIndex = candidate.sdpMLineIndex
                )
            )
        }
        override fun onIceCandidatesRemoved(p0: Array<out IceCandidate>?) = Unit
        override fun onAddStream(p0: MediaStream?) = Unit
        override fun onRemoveStream(p0: MediaStream?) = Unit
        override fun onDataChannel(dc: DataChannel) {
            if (dc.label() != DATA_CHANNEL_LABEL) { dc.close(); return }
            dataChannel = dc
            dc.registerObserver(dcObserver)
        }
        override fun onRenegotiationNeeded() = Unit
        override fun onAddTrack(p0: RtpReceiver?, p1: Array<out MediaStream>?) = Unit
    }

    private val dcObserver = object : DataChannel.Observer {
        override fun onBufferedAmountChange(p0: Long) = Unit
        override fun onStateChange() {
            when (dataChannel?.state()) {
                DataChannel.State.OPEN  -> _events.tryEmit(GhostRTCEvent.DataChannelOpen)
                DataChannel.State.CLOSED -> _events.tryEmit(GhostRTCEvent.DataChannelClosed)
                else -> Unit
            }
        }
        override fun onMessage(buffer: DataChannel.Buffer) {
            val bytes = ByteArray(buffer.data.remaining())
            buffer.data.get(bytes)
            _events.tryEmit(GhostRTCEvent.DataChannelMessage(bytes))
        }
    }
}
