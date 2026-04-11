package com.ghost.chat.core.webrtc

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
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

    // Bluetooth SCO state — true when we started SCO and need to stop on teardown
    private var scoStarted: Boolean = false

    // Tracks user intent for speaker so route changes respect it
    private var userPrefersSpeaker: Boolean = false

    // Audio device callback — fires on bluetooth/wired/usb device plug+unplug mid-call.
    // Reroute audio automatically without dropping the call.
    private val audioDeviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) {
            if (!isInCall || addedDevices == null) return
            val bt = addedDevices.firstOrNull { isBluetoothDevice(it) }
            val wired = addedDevices.firstOrNull { isWiredHeadset(it) }
            android.util.Log.d("GhostChat", "[GhostVoice] onAudioDevicesAdded: bt=${bt != null}, wired=${wired != null}")
            when {
                bt != null -> {
                    // Bluetooth headset connected mid-call → route to it (SCO for in-call voice)
                    routeToBluetooth()
                }
                wired != null -> {
                    // Wired headphones connected → route to them (earpiece-like behavior)
                    try {
                        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        am.isSpeakerphoneOn = false
                        stopBluetoothSco()
                        android.util.Log.d("GhostChat", "[GhostVoice] onAudioDevicesAdded: routed to wired headset")
                    } catch (e: Exception) {
                        android.util.Log.e("GhostChat", "[GhostVoice] wired route failed: ${e.message}")
                    }
                }
            }
        }

        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) {
            if (!isInCall || removedDevices == null) return
            val lostBt = removedDevices.any { isBluetoothDevice(it) }
            val lostWired = removedDevices.any { isWiredHeadset(it) }
            android.util.Log.d("GhostChat", "[GhostVoice] onAudioDevicesRemoved: lostBt=$lostBt, lostWired=$lostWired")
            if (lostBt || lostWired) {
                // Fall back to user preference (speaker if they toggled it, else earpiece)
                try {
                    stopBluetoothSco()
                    val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    am.isSpeakerphoneOn = userPrefersSpeaker
                    android.util.Log.d("GhostChat", "[GhostVoice] device removed, fell back to speaker=$userPrefersSpeaker")
                } catch (e: Exception) {
                    android.util.Log.e("GhostChat", "[GhostVoice] fallback after removal failed: ${e.message}")
                }
            }
        }
    }

    private fun isBluetoothDevice(device: AudioDeviceInfo): Boolean =
        device.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
        device.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
        (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && device.type == AudioDeviceInfo.TYPE_BLE_HEADSET)

    private fun isWiredHeadset(device: AudioDeviceInfo): Boolean =
        device.type == AudioDeviceInfo.TYPE_WIRED_HEADSET ||
        device.type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES ||
        device.type == AudioDeviceInfo.TYPE_USB_HEADSET

    /// Start Bluetooth SCO for in-call voice (A2DP alone is unsuitable for full-duplex audio)
    private fun routeToBluetooth() {
        try {
            val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            am.isSpeakerphoneOn = false
            if (am.isBluetoothScoAvailableOffCall) {
                if (!scoStarted) {
                    am.startBluetoothSco()
                    am.isBluetoothScoOn = true
                    scoStarted = true
                    android.util.Log.d("GhostChat", "[GhostVoice] routeToBluetooth: SCO started")
                }
            } else {
                android.util.Log.d("GhostChat", "[GhostVoice] routeToBluetooth: SCO not available off-call")
            }
        } catch (e: Exception) {
            android.util.Log.e("GhostChat", "[GhostVoice] routeToBluetooth failed: ${e.message}")
        }
    }

    private fun stopBluetoothSco() {
        if (!scoStarted) return
        try {
            val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            am.isBluetoothScoOn = false
            am.stopBluetoothSco()
            scoStarted = false
            android.util.Log.d("GhostChat", "[GhostVoice] stopBluetoothSco: SCO stopped")
        } catch (e: Exception) {
            android.util.Log.e("GhostChat", "[GhostVoice] stopBluetoothSco failed: ${e.message}")
        }
    }

    /// Check if a bluetooth device is currently connected (on call start)
    private fun hasBluetoothDeviceConnected(): Boolean {
        return try {
            val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val devices = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            devices.any { isBluetoothDevice(it) }
        } catch (e: Exception) {
            false
        }
    }

    // MARK: - Telegram-style Audio Route Picker API

    /// Abstract audio route type for the UI picker (Telegram parity)
    enum class AudioRoute { EARPIECE, SPEAKER, BLUETOOTH, WIRED_HEADSET }

    data class AudioRouteOption(val route: AudioRoute, val name: String, val isActive: Boolean)

    /// Returns available audio routes for the current call.
    /// Always includes EARPIECE + SPEAKER. Adds BLUETOOTH / WIRED_HEADSET only if connected.
    fun availableAudioRoutes(): List<AudioRouteOption> {
        val result = mutableListOf<AudioRouteOption>()
        val am = try {
            context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        } catch (e: Exception) { return result }

        val current = currentAudioRoute(am)

        val devices = try {
            am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        } catch (e: Exception) { emptyArray() }

        // Earpiece always available
        result.add(AudioRouteOption(AudioRoute.EARPIECE, "Earpiece", current == AudioRoute.EARPIECE))
        // Speaker always available
        result.add(AudioRouteOption(AudioRoute.SPEAKER, "Speaker", current == AudioRoute.SPEAKER))
        // Bluetooth — include if connected
        val bt = devices.firstOrNull { isBluetoothDevice(it) }
        if (bt != null) {
            val name = try { bt.productName?.toString() } catch (_: Exception) { null } ?: "Bluetooth"
            result.add(AudioRouteOption(AudioRoute.BLUETOOTH, name, current == AudioRoute.BLUETOOTH))
        }
        // Wired headset — include if connected
        val wired = devices.firstOrNull { isWiredHeadset(it) }
        if (wired != null) {
            val name = try { wired.productName?.toString() } catch (_: Exception) { null } ?: "Headset"
            result.add(AudioRouteOption(AudioRoute.WIRED_HEADSET, name, current == AudioRoute.WIRED_HEADSET))
        }
        return result
    }

    private fun currentAudioRoute(am: AudioManager): AudioRoute {
        return when {
            am.isBluetoothScoOn || scoStarted -> AudioRoute.BLUETOOTH
            am.isSpeakerphoneOn -> AudioRoute.SPEAKER
            else -> {
                // Detect wired headset via connected devices
                val devices = try { am.getDevices(AudioManager.GET_DEVICES_OUTPUTS) } catch (_: Exception) { emptyArray() }
                if (devices.any { isWiredHeadset(it) }) AudioRoute.WIRED_HEADSET
                else AudioRoute.EARPIECE
            }
        }
    }

    /// Force a specific audio route. Returns true on success.
    fun selectAudioRoute(route: AudioRoute): Boolean {
        if (!isInCall) return false
        val am = try {
            context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        } catch (e: Exception) { return false }

        android.util.Log.d("GhostChat", "[GhostVoice] selectAudioRoute -> $route")
        return try {
            when (route) {
                AudioRoute.EARPIECE -> {
                    stopBluetoothSco()
                    am.isSpeakerphoneOn = false
                    isSpeakerOn = false
                    userPrefersSpeaker = false
                }
                AudioRoute.SPEAKER -> {
                    stopBluetoothSco()
                    am.isSpeakerphoneOn = true
                    isSpeakerOn = true
                    userPrefersSpeaker = true
                }
                AudioRoute.BLUETOOTH -> {
                    am.isSpeakerphoneOn = false
                    isSpeakerOn = false
                    userPrefersSpeaker = false
                    routeToBluetooth()
                }
                AudioRoute.WIRED_HEADSET -> {
                    // Wired headset is routed automatically when plugged; just make sure
                    // speaker is off and SCO is stopped so audio flows through the headset.
                    stopBluetoothSco()
                    am.isSpeakerphoneOn = false
                    isSpeakerOn = false
                    userPrefersSpeaker = false
                }
            }
            true
        } catch (e: Exception) {
            android.util.Log.e("GhostChat", "[GhostVoice] selectAudioRoute failed: ${e.message}")
            false
        }
    }

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

        // Register AudioDeviceCallback for mid-call bluetooth/wired hotplug.
        try {
            val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            am.registerAudioDeviceCallback(audioDeviceCallback, mainHandler)
        } catch (e: Exception) {
            android.util.Log.e("GhostChat", "[GhostVoice] registerAudioDeviceCallback failed: ${e.message}")
        }

        // If bluetooth is already connected at call start, route to it immediately
        if (hasBluetoothDeviceConnected()) {
            android.util.Log.d("GhostChat", "[GhostVoice] startCall: BT already connected, routing to BT")
            routeToBluetooth()
        }

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

        // Register hot-plug callback for callee as well
        try {
            val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            am.registerAudioDeviceCallback(audioDeviceCallback, mainHandler)
        } catch (e: Exception) {
            android.util.Log.e("GhostChat", "[GhostVoice] registerAudioDeviceCallback (accept) failed: ${e.message}")
        }
        if (hasBluetoothDeviceConnected()) {
            android.util.Log.d("GhostChat", "[GhostVoice] initializeAudio: BT already connected, routing to BT")
            routeToBluetooth()
        }

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
        userPrefersSpeaker = isSpeakerOn
        android.util.Log.d("GhostChat", "[GhostVoice] toggleSpeaker: isSpeakerOn=$isSpeakerOn")
        switchSpeakerOutput(isSpeakerOn)
        return isSpeakerOn
    }

    fun setSpeaker(enabled: Boolean) {
        isSpeakerOn = enabled
        userPrefersSpeaker = enabled
        android.util.Log.d("GhostChat", "[GhostVoice] setSpeaker: isSpeakerOn=$enabled")
        switchSpeakerOutput(enabled)
    }

    /// Lightweight speaker toggle — only changes output route, no audio focus re-request.
    /// If bluetooth SCO is active and user toggles speaker ON, stop SCO first.
    /// If user toggles speaker OFF and bluetooth is still connected, route back to BT.
    private fun switchSpeakerOutput(speaker: Boolean) {
        if (!isInCall) return
        try {
            val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (speaker) {
                stopBluetoothSco()
                audioManager.isSpeakerphoneOn = true
            } else {
                audioManager.isSpeakerphoneOn = false
                if (hasBluetoothDeviceConnected()) {
                    routeToBluetooth()
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("GhostChat", "[GhostVoice] switchSpeakerOutput failed: ${e.message}")
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

        // Unregister audio device hot-plug callback + stop SCO if we started it
        try {
            val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            am.unregisterAudioDeviceCallback(audioDeviceCallback)
        } catch (e: Exception) {
            android.util.Log.e("GhostChat", "[GhostVoice] unregisterAudioDeviceCallback failed: ${e.message}")
        }
        stopBluetoothSco()
        userPrefersSpeaker = false

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
