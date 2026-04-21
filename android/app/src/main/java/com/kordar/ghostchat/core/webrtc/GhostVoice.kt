package com.kordar.ghostchat.core.webrtc

import android.content.Context
import android.media.AudioManager
import org.webrtc.AudioSource
import org.webrtc.AudioTrack
import org.webrtc.MediaConstraints
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpSender

/**
 * Audio routing + track management for a live call.
 *
 * Mirror of iOS `GhostVoice`. Android doesn't use CallKit's audio-session ownership model;
 * instead we configure [AudioManager] directly when entering a call and restore it on
 * release. CRITICAL: call [configureAudioSession] only after [CallManager] reports the
 * call active (ConnectionService.onCallAudioStateChanged or equivalent).
 */
class GhostVoice(
    private val context: Context,
    private val factory: PeerConnectionFactory = GhostRTCFactory.get(context)
) {

    private var audioSource: AudioSource? = null
    var audioTrack: AudioTrack? = null
        private set
    private var audioSender: RtpSender? = null
    private var savedMode: Int = AudioManager.MODE_NORMAL
    private var savedSpeaker: Boolean = false

    // MARK: - Track

    /** Add a microphone track to the given peer connection. */
    fun attachMicrophone(peerConnection: PeerConnection): RtpSender {
        val constraints = MediaConstraints().apply {
            mandatory += MediaConstraints.KeyValuePair("googEchoCancellation", "true")
            mandatory += MediaConstraints.KeyValuePair("googAutoGainControl", "true")
            mandatory += MediaConstraints.KeyValuePair("googNoiseSuppression", "true")
            mandatory += MediaConstraints.KeyValuePair("googHighpassFilter", "true")
        }
        val source = factory.createAudioSource(constraints)
        val track = factory.createAudioTrack("ghost-audio-0", source)
        val sender = peerConnection.addTrack(track, listOf("ghost-audio-stream"))
            ?: error("addTrack returned null")
        audioSource = source
        audioTrack = track
        audioSender = sender
        return sender
    }

    fun detachMicrophone(peerConnection: PeerConnection) {
        audioSender?.let { peerConnection.removeTrack(it) }
        audioTrack = null
        audioSender = null
        audioSource?.dispose(); audioSource = null
    }

    // MARK: - Mute (transceiver-preserving)

    fun setMuted(muted: Boolean) {
        audioTrack?.setEnabled(!muted)
    }

    val isMuted: Boolean
        get() = audioTrack?.enabled() == false

    // MARK: - AudioManager session (Android equivalent of AVAudioSession)

    fun configureAudioSession() {
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        savedMode = audio.mode
        savedSpeaker = audio.isSpeakerphoneOn
        audio.mode = AudioManager.MODE_IN_COMMUNICATION
        audio.isSpeakerphoneOn = false
    }

    fun releaseAudioSession() {
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audio.mode = savedMode
        audio.isSpeakerphoneOn = savedSpeaker
    }

    fun setSpeaker(speakerOn: Boolean) {
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audio.isSpeakerphoneOn = speakerOn
    }
}
