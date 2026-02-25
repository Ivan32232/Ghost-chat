package com.ghost.chat.core.webrtc

import android.content.Context
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
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

    // MARK: - Callbacks

    var onCallStateChange: ((CallState) -> Unit)? = null
    var onCallTimer: ((String) -> Unit)? = null

    enum class CallState { CALLING, ACTIVE, ENDED }

    // MARK: - Audio Session

    private fun configureAudioSession(speaker: Boolean = false) {
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        audioManager.isSpeakerphoneOn = speaker

        // Request audio focus
        @Suppress("DEPRECATION")
        audioManager.requestAudioFocus(
            null,
            AudioManager.STREAM_VOICE_CALL,
            AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
        )
    }

    // MARK: - Start Call

    fun startCall() {
        if (isInCall) return

        configureAudioSession(speaker = false)  // Earpiece by default

        // Create audio track
        val constraints = MediaConstraints().apply {
            optional.add(MediaConstraints.KeyValuePair("echoCancellation", "true"))
            optional.add(MediaConstraints.KeyValuePair("noiseSuppression", "true"))
            optional.add(MediaConstraints.KeyValuePair("autoGainControl", "false"))
        }
        audioSource = factory.createAudioSource(constraints)
        audioTrack = factory.createAudioTrack("ghost-audio-0", audioSource)

        val track = audioTrack ?: throw VoiceError.AudioInitFailed()

        // Add to PeerConnection
        audioSender = peerConnection.addTrack(track, listOf("ghost-audio-stream"))

        isInCall = true
        onCallStateChange?.invoke(CallState.CALLING)
    }

    fun acceptCall() {
        if (isInCall) return

        configureAudioSession(speaker = false)

        val constraints = MediaConstraints().apply {
            optional.add(MediaConstraints.KeyValuePair("echoCancellation", "true"))
            optional.add(MediaConstraints.KeyValuePair("noiseSuppression", "true"))
            optional.add(MediaConstraints.KeyValuePair("autoGainControl", "false"))
        }
        audioSource = factory.createAudioSource(constraints)
        audioTrack = factory.createAudioTrack("ghost-audio-0", audioSource)

        val track = audioTrack ?: throw VoiceError.AudioInitFailed()
        audioSender = peerConnection.addTrack(track, listOf("ghost-audio-stream"))

        isInCall = true
        callStartTime = System.currentTimeMillis()
        startCallTimer()
        onCallStateChange?.invoke(CallState.ACTIVE)
    }

    // MARK: - Call Active

    fun callAccepted() {
        callStartTime = System.currentTimeMillis()
        startCallTimer()
        onCallStateChange?.invoke(CallState.ACTIVE)
    }

    // MARK: - Mute

    fun toggleMute(): Boolean {
        isMuted = !isMuted
        audioTrack?.setEnabled(!isMuted)
        return isMuted
    }

    fun setMuted(muted: Boolean) {
        isMuted = muted
        audioTrack?.setEnabled(!muted)
    }

    // MARK: - Speaker / Earpiece

    fun toggleSpeaker(): Boolean {
        isSpeakerOn = !isSpeakerOn
        configureAudioSession(speaker = isSpeakerOn)
        return isSpeakerOn
    }

    fun setSpeaker(enabled: Boolean) {
        isSpeakerOn = enabled
        configureAudioSession(speaker = enabled)
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
        callTimerRunnable?.let { mainHandler.removeCallbacks(it) }
        callTimerRunnable = null

        // Remove track from PeerConnection
        audioSender?.let { sender ->
            peerConnection.removeTrack(sender)
        }
        audioSender = null

        // Stop audio track
        audioTrack?.setEnabled(false)
        audioTrack?.dispose()
        audioTrack = null

        audioSource?.dispose()
        audioSource = null

        // Release audio
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audioManager.mode = AudioManager.MODE_NORMAL
        audioManager.isSpeakerphoneOn = false
        @Suppress("DEPRECATION")
        audioManager.abandonAudioFocus(null)

        isInCall = false
        isMuted = false
        isSpeakerOn = false
        callStartTime = 0

        onCallStateChange?.invoke(CallState.ENDED)
    }

    // MARK: - Status

    val callDuration: Int
        get() = if (callStartTime > 0) ((System.currentTimeMillis() - callStartTime) / 1000).toInt() else 0

    // MARK: - Cleanup

    fun destroy() {
        endCall()
        onCallStateChange = null
        onCallTimer = null
    }
}

sealed class VoiceError : Exception() {
    class AudioInitFailed : VoiceError() {
        override val message = "Failed to initialize audio"
    }
}
