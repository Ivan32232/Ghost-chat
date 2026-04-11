package com.ghost.chat.core.webrtc

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import org.webrtc.*

/// Voice calls — port of GhostVoice.swift / voice.js
/// AudioManager for earpiece/speaker routing (main reason for native app)
class GhostVoice(
    private val peerConnection: PeerConnection,
    private val factory: PeerConnectionFactory,
    private val context: Context
) {

    // MARK: - Properties

    private var audioTrack: AudioTrack? = null
    private var audioSender: RtpSender? = null
    private var audioSource: AudioSource? = null

    var isMuted = false
        private set
    var isInCall = false
        private set
    var isSpeakerOn = false
        private set

    private var callStartTime: Long = 0
    private var callTimerRunnable: Runnable? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var audioFocusRequest: AudioFocusRequest? = null

    // Proximity sensor — экран гаснет при поднесении к уху
    private var proximityWakeLock: PowerManager.WakeLock? = null

    // Audio focus change listener — восстановление после прерываний
    private val audioFocusChangeListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
        android.util.Log.d("GhostChat", "[GhostVoice] audioFocusChange: focusChange=$focusChange, isInCall=$isInCall")
        when (focusChange) {
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                android.util.Log.d("GhostChat", "[GhostVoice] audioFocusChange: LOSS_TRANSIENT — no action")
                // Временная потеря — ничего не делаем, звук восстановится
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                android.util.Log.d("GhostChat", "[GhostVoice] audioFocusChange: GAIN — reconfiguring audio")
                // Фокус восстановлен — пересоздаём аудио конфигурацию
                if (isInCall) {
                    configureAudioSession(speaker = isSpeakerOn)
                    audioTrack?.setEnabled(!isMuted)
                }
            }
            AudioManager.AUDIOFOCUS_LOSS -> {
                android.util.Log.d("GhostChat", "[GhostVoice] audioFocusChange: LOSS — call continues")
                // Полная потеря — ничего не делаем, звонок продолжается
            }
        }
    }

    // MARK: - Callbacks

    var onCallStateChange: ((CallState) -> Unit)? = null
    var onCallTimer: ((String) -> Unit)? = null

    enum class CallState { CALLING, ACTIVE, ENDED }

    // MARK: - Audio Session

    private fun configureAudioSession(speaker: Boolean = false) {
        android.util.Log.d("GhostChat", "[GhostVoice] configureAudioSession ENTER, speaker=$speaker")
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        audioManager.isSpeakerphoneOn = speaker

        // Request audio focus with listener for focus changes
        val focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setOnAudioFocusChangeListener(audioFocusChangeListener)
            .build()
        audioFocusRequest = focusRequest
        val focusResult = audioManager.requestAudioFocus(focusRequest)
        android.util.Log.d("GhostChat", "[GhostVoice] configureAudioSession EXIT: mode=IN_COMMUNICATION, speaker=$speaker, focusResult=$focusResult")
    }

    // MARK: - Proximity Sensor

    private fun enableProximitySensor() {
        android.util.Log.d("GhostChat", "[GhostVoice] enableProximitySensor called")
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        if (proximityWakeLock == null) {
            proximityWakeLock = powerManager.newWakeLock(
                PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
                "GhostChat:ProximityWakeLock"
            )
        }
        proximityWakeLock?.let {
            if (!it.isHeld) {
                it.acquire(4 * 60 * 60 * 1000L) // 4 hours max
                android.util.Log.d("GhostChat", "[GhostVoice] proximityWakeLock acquired")
            }
        }
    }

    private fun disableProximitySensor() {
        android.util.Log.d("GhostChat", "[GhostVoice] disableProximitySensor called, isHeld=${proximityWakeLock?.isHeld}")
        proximityWakeLock?.let {
            if (it.isHeld) it.release(PowerManager.RELEASE_FLAG_WAIT_FOR_NO_PROXIMITY)
        }
        proximityWakeLock = null
    }

    // MARK: - Start Call

    /**
     * Start outgoing call. Returns `true` if sender was reused (manual renegotiation needed).
     */
    fun startCall(): Boolean {
        android.util.Log.d("GhostChat", "[GhostVoice] startCall: isInCall=$isInCall, audioTrack=${audioTrack != null}, audioSender=${audioSender != null}")

        // Audio reset between calls — clean up stale state from previous call
        if (isInCall) {
            android.util.Log.d("GhostChat", "[GhostVoice] startCall — already in call, ending previous call first")
            endCall()
        }

        // Reset AudioManager mode before starting new call
        try {
            val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioManager.mode = AudioManager.MODE_NORMAL
            audioManager.isSpeakerphoneOn = false
            android.util.Log.d("GhostChat", "[GhostVoice] startCall — audio mode reset to NORMAL before configuring")
        } catch (e: Exception) {
            android.util.Log.e("GhostChat", "[GhostVoice] startCall — audio reset failed: ${e.message}")
        }

        configureAudioSession(speaker = false)  // Earpiece by default
        enableProximitySensor()

        // ALWAYS create brand new audio track
        val constraints = MediaConstraints().apply {
            optional.add(MediaConstraints.KeyValuePair("echoCancellation", "true"))
            optional.add(MediaConstraints.KeyValuePair("noiseSuppression", "true"))
            optional.add(MediaConstraints.KeyValuePair("autoGainControl", "false"))
        }
        audioSource = factory.createAudioSource(constraints)
        audioTrack = factory.createAudioTrack("ghost-audio-${System.nanoTime()}", audioSource)

        val track = audioTrack ?: throw VoiceError.AudioInitFailed()

        // Reuse existing sender (preserves transceiver) or create new one
        var didReuseSender = false
        val existingSender = audioSender
        if (existingSender != null) {
            existingSender.setTrack(track, false)
            didReuseSender = true
            android.util.Log.d("GhostChat", "[GhostVoice] startCall — reused existing sender (MANUAL renegotiation needed)")
        } else {
            audioSender = peerConnection.addTrack(track, listOf("ghost-audio-stream"))
            android.util.Log.d("GhostChat", "[GhostVoice] startCall — created new audioSender (first call)")
        }

        isInCall = true
        onCallStateChange?.invoke(CallState.CALLING)
        return didReuseSender
    }

    /// Initialize audio without adding to PeerConnection
    /// For callee: initializeAudio → setRemoteDescription → addAudioTrack → createAnswer
    /// Creates fresh track, keeps existing sender if available for reuse
    fun initializeAudio() {
        android.util.Log.d("GhostChat", "[GhostVoice] initializeAudio ENTER, hasTrack=${audioTrack != null}, hasSender=${audioSender != null}")
        // Detach old track from sender (don't remove sender — preserves transceiver)
        audioTrack?.setEnabled(false)
        audioSender?.setTrack(null, false)
        audioTrack = null
        audioSource = null

        configureAudioSession(speaker = false)
        enableProximitySensor()

        val constraints = MediaConstraints().apply {
            optional.add(MediaConstraints.KeyValuePair("echoCancellation", "true"))
            optional.add(MediaConstraints.KeyValuePair("noiseSuppression", "true"))
            optional.add(MediaConstraints.KeyValuePair("autoGainControl", "false"))
        }
        audioSource = factory.createAudioSource(constraints)
        audioTrack = factory.createAudioTrack("ghost-audio-${System.nanoTime()}", audioSource)

        if (audioTrack == null) {
            android.util.Log.e("GhostChat", "[GhostVoice] initializeAudio FAILED: track is null")
            throw VoiceError.AudioInitFailed()
        }
        android.util.Log.d("GhostChat", "[GhostVoice] initializeAudio EXIT: track created, id=${audioTrack?.id()}")
    }

    /// Add audio track to PeerConnection (after setRemoteDescription)
    /// Reuses existing sender if available (preserves transceiver, avoids SDP conflicts)
    fun addAudioTrack() {
        val track = audioTrack ?: return
        val existingSender = audioSender
        if (existingSender != null) {
            existingSender.setTrack(track, false)
            android.util.Log.d("GhostChat", "[GhostVoice] addAudioTrack — reused existing sender (transceiver preserved)")
        } else {
            audioSender = peerConnection.addTrack(track, listOf("ghost-audio-stream"))
            android.util.Log.d("GhostChat", "[GhostVoice] addAudioTrack — created new sender (first call)")
        }
    }

    /// Mark call as active (callee after accepting)
    fun markCallActive() {
        android.util.Log.d("GhostChat", "[GhostVoice] markCallActive ENTER, wasInCall=$isInCall")
        isInCall = true
        callStartTime = System.currentTimeMillis()
        startCallTimer()
        onCallStateChange?.invoke(CallState.ACTIVE)
        android.util.Log.d("GhostChat", "[GhostVoice] markCallActive EXIT: state=ACTIVE")
    }

    /// Legacy acceptCall — when no pending offer exists
    fun acceptCall() {
        android.util.Log.d("GhostChat", "[GhostVoice] acceptCall ENTER, isInCall=$isInCall")
        if (isInCall) {
            android.util.Log.d("GhostChat", "[GhostVoice] acceptCall: already in call, skipping")
            return
        }

        initializeAudio()
        addAudioTrack()

        isInCall = true
        callStartTime = System.currentTimeMillis()
        startCallTimer()
        onCallStateChange?.invoke(CallState.ACTIVE)
        android.util.Log.d("GhostChat", "[GhostVoice] acceptCall EXIT: state=ACTIVE")
    }

    // MARK: - Call Active

    fun callAccepted() {
        android.util.Log.d("GhostChat", "[GhostVoice] callAccepted ENTER")
        callStartTime = System.currentTimeMillis()
        startCallTimer()
        onCallStateChange?.invoke(CallState.ACTIVE)
        android.util.Log.d("GhostChat", "[GhostVoice] callAccepted EXIT: state=ACTIVE")
    }

    // MARK: - Mute

    fun toggleMute(): Boolean {
        isMuted = !isMuted
        audioTrack?.setEnabled(!isMuted)
        android.util.Log.d("GhostChat", "[GhostVoice] toggleMute: isMuted=$isMuted, trackEnabled=${!isMuted}")
        return isMuted
    }

    fun setMuted(muted: Boolean) {
        isMuted = muted
        audioTrack?.setEnabled(!muted)
        android.util.Log.d("GhostChat", "[GhostVoice] setMuted: isMuted=$muted")
    }

    // MARK: - Speaker / Earpiece

    fun toggleSpeaker(): Boolean {
        isSpeakerOn = !isSpeakerOn
        android.util.Log.d("GhostChat", "[GhostVoice] toggleSpeaker: isSpeakerOn=$isSpeakerOn")
        switchSpeakerOutput(isSpeakerOn)
        return isSpeakerOn
    }

    fun setSpeaker(enabled: Boolean) {
        isSpeakerOn = enabled
        android.util.Log.d("GhostChat", "[GhostVoice] setSpeaker: isSpeakerOn=$enabled")
        switchSpeakerOutput(enabled)
    }

    /// Lightweight speaker toggle — only changes output route, no audio focus re-request
    private fun switchSpeakerOutput(speaker: Boolean) {
        if (!isInCall) return
        try {
            val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioManager.isSpeakerphoneOn = speaker
        } catch (e: Exception) {
            // Prevent crash if audio system is unavailable
        }
    }

    // MARK: - Timer

    private fun startCallTimer() {
        val runnable = object : Runnable {
            override fun run() {
                if (!isInCall) return
                val elapsed = ((System.currentTimeMillis() - callStartTime) / 1000).toInt()
                val minutes = elapsed / 60
                val seconds = elapsed % 60
                val formatted = String.format("%02d:%02d", minutes, seconds)
                onCallTimer?.invoke(formatted)
                mainHandler.postDelayed(this, 1000)
            }
        }
        callTimerRunnable = runnable
        mainHandler.postDelayed(runnable, 1000)
    }

    // MARK: - End Call

    fun endCall() {
        android.util.Log.d("GhostChat", "[GhostVoice] endCall ENTER, isInCall=$isInCall, hasTrack=${audioTrack != null}, hasSender=${audioSender != null}")
        callTimerRunnable?.let { mainHandler.removeCallbacks(it) }
        callTimerRunnable = null

        disableProximitySensor()

        // DON'T removeTrack — that puts transceiver in "stopped" state permanently.
        // Instead: disable track + set sender.track = nil. Sender stays alive for reuse.
        audioTrack?.setEnabled(false)
        audioSender?.setTrack(null, false)
        android.util.Log.d("GhostChat", "[GhostVoice] endCall: detached track from sender (transceiver preserved)")
        // Keep audioSender reference — reuse on next startCall

        // Dispose old track/source after delay (WebRTC may still reference internally)
        val trackToDispose = audioTrack
        val sourceToDispose = audioSource
        audioTrack = null
        audioSource = null
        mainHandler.postDelayed({
            trackToDispose?.dispose()
            sourceToDispose?.dispose()
        }, 500)

        // DON'T abandon audio focus between calls — WebRTC AudioDeviceModule
        // won't restart properly after abandonAudioFocusRequest on some devices.
        // Keep audio session active for future calls in same P2P session.
        mainHandler.postDelayed({
            val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioManager.mode = AudioManager.MODE_NORMAL
            audioManager.isSpeakerphoneOn = false
        }, 300)

        isInCall = false
        isMuted = false
        isSpeakerOn = false
        callStartTime = 0

        onCallStateChange?.invoke(CallState.ENDED)
        android.util.Log.d("GhostChat", "[GhostVoice] endCall EXIT: state=ENDED")
    }

    // MARK: - Status

    val callDuration: Int
        get() = if (callStartTime > 0) ((System.currentTimeMillis() - callStartTime) / 1000).toInt() else 0

    // MARK: - Cleanup

    fun destroy() {
        callTimerRunnable?.let { mainHandler.removeCallbacks(it) }
        callTimerRunnable = null
        disableProximitySensor()

        // On destroy, actually remove track+sender (voice object is being discarded)
        audioSender?.let { sender ->
            peerConnection.removeTrack(sender)
            android.util.Log.d("GhostChat", "[GhostVoice] destroy: removed sender from PeerConnection")
        }
        audioSender = null
        audioTrack?.setEnabled(false)
        audioTrack?.dispose()
        audioTrack = null
        audioSource?.dispose()
        audioSource = null

        isInCall = false
        isMuted = false
        isSpeakerOn = false
        callStartTime = 0

        onCallStateChange = null
        onCallTimer = null
    }
}

sealed class VoiceError : Exception() {
    class AudioInitFailed : VoiceError() {
        override val message = "Failed to initialize audio"
    }
}
