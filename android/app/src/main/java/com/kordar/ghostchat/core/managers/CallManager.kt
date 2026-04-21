package com.kordar.ghostchat.core.managers

import com.kordar.ghostchat.core.webrtc.GhostVoice
import com.kordar.ghostchat.models.CallState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * State machine + audio routing for voice calls.
 *
 * Mirror of iOS `CallManager`. The self-managed ConnectionService surface (system-level
 * incoming-call UI) is wired separately in [com.kordar.ghostchat.core.managers.GhostConnectionService].
 * [CallManager] keeps the audio lifecycle (GhostVoice.configure/release) and the call state
 * exposed to the UI through StateFlow.
 */
class CallManager(private val voice: GhostVoice) {

    private val _state = MutableStateFlow(CallState.IDLE)
    val state: StateFlow<CallState> = _state.asStateFlow()

    private val _muted = MutableStateFlow(false)
    val muted: StateFlow<Boolean> = _muted.asStateFlow()

    private val _speakerOn = MutableStateFlow(false)
    val speakerOn: StateFlow<Boolean> = _speakerOn.asStateFlow()

    private val _durationMs = MutableStateFlow(0L)
    val durationMs: StateFlow<Long> = _durationMs.asStateFlow()

    var currentCallId: UUID? = null
        private set
    var peerName: String = "Ghost Chat"
        private set

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var ticker: Job? = null
    private var startedAtMs: Long = 0L

    fun startOutgoing(peerName: String) {
        currentCallId = UUID.randomUUID()
        this.peerName = peerName
        _state.value = CallState.OUTGOING_PENDING
    }

    fun reportIncoming(id: UUID, peerName: String) {
        currentCallId = id
        this.peerName = peerName
        _state.value = CallState.INCOMING
    }

    fun answered() {
        _state.value = CallState.ACTIVE
        voice.configureAudioSession()
        startTicker()
    }

    fun rang() {
        _state.value = CallState.OUTGOING_RINGING
    }

    fun end() {
        stopTicker()
        voice.releaseAudioSession()
        _state.value = CallState.ENDED
        currentCallId = null
    }

    fun setMuted(value: Boolean) {
        _muted.value = value
        voice.setMuted(value)
    }

    fun setSpeaker(on: Boolean) {
        _speakerOn.value = on
        voice.setSpeaker(on)
    }

    private fun startTicker() {
        stopTicker()
        startedAtMs = System.currentTimeMillis()
        ticker = scope.launch {
            while (true) {
                _durationMs.value = System.currentTimeMillis() - startedAtMs
                delay(1000)
            }
        }
    }

    private fun stopTicker() {
        ticker?.cancel(); ticker = null
        _durationMs.value = 0L
        startedAtMs = 0L
    }
}
