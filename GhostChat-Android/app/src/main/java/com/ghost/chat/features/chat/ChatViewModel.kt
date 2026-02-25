package com.ghost.chat.features.chat

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.ghost.chat.core.audio.SoundLibrary
import com.ghost.chat.core.crypto.DoubleRatchet
import com.ghost.chat.core.crypto.GhostCrypto
import com.ghost.chat.core.crypto.IdentityKeyService
import com.ghost.chat.core.network.SignalingClient
import com.ghost.chat.core.network.TURNService
import com.ghost.chat.core.security.BiometricAuthService
import com.ghost.chat.core.security.KeystoreService
import com.ghost.chat.core.security.SecurityMonitor
import com.ghost.chat.core.storage.ContactStore
import com.ghost.chat.core.storage.DatabaseService
import com.ghost.chat.core.webrtc.GhostRTC
import com.ghost.chat.core.webrtc.GhostVoice
import com.ghost.chat.models.ChatMessage
import com.ghost.chat.models.Contact
import com.ghost.chat.models.ControlMessage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.webrtc.IceCandidate
import org.webrtc.SessionDescription
import java.util.Date
import java.util.Timer
import kotlin.concurrent.fixedRateTimer

/// Main orchestrator — port of iOS ChatViewModel (~1200 lines)
/// Manages: screen state, signaling, WebRTC, crypto, calls, contacts, settings
class ChatViewModel(private val appContext: Context) : ViewModel() {

    companion object {
        private const val SERVER_URL = "https://gbskgs.xyz"
    }

    // MARK: - Screen State

    enum class Screen { WELCOME, WAITING, CONNECTING, CHAT }
    enum class CallUIState { IDLE, CALLING, RINGING, ACTIVE }

    var screen by mutableStateOf(Screen.WELCOME)
    var isConnected by mutableStateOf(false)
    var isVerified by mutableStateOf(false)
    var roomId by mutableStateOf<String?>(null)
    var fingerprint by mutableStateOf("")
    var isHost by mutableStateOf(false)
        private set

    // Messages
    val messages = mutableStateListOf<ChatMessage>()

    // Call State
    var callState by mutableStateOf(CallUIState.IDLE)
    var callTimer by mutableStateOf("00:00")
    var isMuted by mutableStateOf(false)
    var isSpeakerOn by mutableStateOf(false)

    // Security
    var securityAlert by mutableStateOf<String?>(null)

    // Contact
    var currentPeerContact by mutableStateOf<Contact?>(null)
    var showSaveContactPrompt by mutableStateOf(false)
    var pendingContactName by mutableStateOf("")

    // Verification panel
    var showVerificationPanel by mutableStateOf(false)

    // Settings (persisted)
    var autoDeleteMinutes by mutableIntStateOf(5)
    var screenshotNotifications by mutableStateOf(true)
    var messageSoundEnabled by mutableStateOf(true)
    var vibrationEnabled by mutableStateOf(true)
    var privacyMode by mutableStateOf(false)
    var ringtoneId by mutableStateOf("fanfare")
    var messageSoundId by mutableStateOf("received")

    // Deep link
    var pendingDeepLinkRoom by mutableStateOf<String?>(null)

    // MARK: - Private State

    private var signaling: SignalingClient? = null
    private var rtc: GhostRTC? = null
    private var crypto: GhostCrypto? = null
    private var voice: GhostVoice? = null
    private var securityMonitor: SecurityMonitor? = null
    private var turnService: TURNService? = null
    private var contactStore: ContactStore? = null

    private var pendingIceCandidates = mutableListOf<IceCandidate>()
    private var pendingRenegotiationOffer: SessionDescription? = null
    private var keyExchangeCompleted = false

    private val sentMessages = mutableMapOf<Int, String>() // counter -> message ID

    private var peerIdentityKeyData: ByteArray? = null
    private var expectedPeerIdentityKey: ByteArray? = null

    private var messageCleanupTimer: Timer? = null
    private var connectionTimeout: Handler? = null
    private var connectionTimeoutRunnable: Runnable? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // Ringtone/vibration for incoming calls
    private var ringtoneTimer: Timer? = null

    // MARK: - Init

    init {
        loadSettings()
        initDatabase()
    }

    private fun initDatabase() {
        contactStore = ContactStore(DatabaseService.getInstance(appContext))
    }

    private fun loadSettings() {
        autoDeleteMinutes = KeystoreService.loadInt("settings_auto_delete", 5)
        screenshotNotifications = KeystoreService.loadBool("settings_screenshot_notify", true)
        messageSoundEnabled = KeystoreService.loadBool("settings_sound", true)
        vibrationEnabled = KeystoreService.loadBool("settings_vibration", true)
        privacyMode = KeystoreService.loadBool("settings_privacy_mode", false)
        ringtoneId = KeystoreService.loadString("settings_ringtone") ?: "fanfare"
        messageSoundId = KeystoreService.loadString("settings_msg_sound") ?: "received"
    }

    fun saveSettings() {
        KeystoreService.saveInt(autoDeleteMinutes, "settings_auto_delete")
        KeystoreService.saveBool(screenshotNotifications, "settings_screenshot_notify")
        KeystoreService.saveBool(messageSoundEnabled, "settings_sound")
        KeystoreService.saveBool(vibrationEnabled, "settings_vibration")
        KeystoreService.saveBool(privacyMode, "settings_privacy_mode")
        KeystoreService.saveString(ringtoneId, "settings_ringtone")
        KeystoreService.saveString(messageSoundId, "settings_msg_sound")
    }

    // MARK: - Create Room (Host)

    fun createRoom() {
        isHost = true
        crypto = GhostCrypto().also { it.generateKeyPair() }
        rtc = GhostRTC(appContext).also { it.privacyMode = privacyMode }
        signaling = SignalingClient(SERVER_URL)
        turnService = TURNService(SERVER_URL)

        setupSignalingCallbacks()
        setupRTCCallbacks()

        signaling?.connect()
        signaling?.createRoom()
    }

    // MARK: - Join Room (Guest)

    fun joinRoom(inputRoomId: String) {
        val trimmed = inputRoomId.trim()
        // Extract room ID from full URL if needed
        val roomIdValue = if (trimmed.contains("?room=")) {
            trimmed.substringAfter("?room=").substringBefore("&")
        } else {
            trimmed
        }

        // Validate: base64url, 64 chars
        if (!roomIdValue.matches(Regex("^[A-Za-z0-9_-]{64}$"))) return

        isHost = false
        crypto = GhostCrypto().also { it.generateKeyPair() }
        rtc = GhostRTC(appContext).also { it.privacyMode = privacyMode }
        signaling = SignalingClient(SERVER_URL)
        turnService = TURNService(SERVER_URL)

        setupSignalingCallbacks()
        setupRTCCallbacks()

        signaling?.connect()
        signaling?.joinRoom(roomIdValue)
    }

    // MARK: - Signaling Callbacks

    private fun setupSignalingCallbacks() {
        signaling?.onRoomCreated = { id ->
            roomId = id
            saveSession()
            screen = Screen.WAITING
        }

        signaling?.onRoomJoined = { id ->
            roomId = id
            saveSession()
            screen = Screen.CONNECTING
            viewModelScope.launch { initAsGuest() }
        }

        signaling?.onRejoinOk = {
            // Reconnected successfully
        }

        signaling?.onPeerJoined = {
            isConnected = false
            screen = Screen.CONNECTING
            startConnectionTimeout()
            if (isHost) {
                viewModelScope.launch { startWebRTCConnection() }
            }
        }

        signaling?.onPeerLeft = {
            addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_peer_disconnected))
            leave()
        }

        signaling?.onSignal = { data ->
            viewModelScope.launch { handleSignal(data) }
        }

        signaling?.onError = { message ->
            addSystemMessage(message)
        }

        signaling?.onDisconnected = {
            val rid = roomId
            if (rid != null && !isConnected) {
                signaling?.scheduleReconnect(rid, isHost)
            }
        }
    }

    // MARK: - RTC Callbacks

    private fun setupRTCCallbacks() {
        rtc?.onConnected = onConnected@{
            cancelConnectionTimeout()
            // Exchange keys
            val pubKey = crypto?.exportPublicKey() ?: return@onConnected

            val msg = JSONObject().apply {
                put("type", "key-exchange")
                put("publicKey", pubKey)
                put("identityKey", IdentityKeyService.exportPublicKey())
                put("v", GhostCrypto.PROTOCOL_VERSION)
            }

            // Guest: DH ratchet key
            if (!isHost) {
                crypto?.exportDHRatchetKey()?.let { msg.put("dhRatchetKey", it) }
            }

            rtc?.send(msg.toString())
        }

        rtc?.onMessage = { data ->
            viewModelScope.launch { handleP2PMessage(data) }
        }

        rtc?.onDisconnected = {
            if (isConnected) {
                addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_connection_lost))
                isConnected = false
            }
        }

        rtc?.onIceCandidate = { candidate ->
            val candidateJson = GhostRTC.candidateToJson(candidate)
            signaling?.sendSignal(JSONObject().apply {
                put("type", "ice-candidate")
                put("candidate", candidateJson)
            })
        }

        rtc?.onError = { error ->
            addSystemMessage(error)
        }

        rtc?.onTrack = { stream ->
            // Remote audio track received (call)
        }

        rtc?.onRenegotiationNeeded = { offer ->
            viewModelScope.launch { handleLocalRenegotiationOffer(offer) }
        }
    }

    // MARK: - WebRTC Connection

    private suspend fun startWebRTCConnection() {
        val turnCreds = try {
            turnService?.fetchCredentials()
        } catch (e: Exception) { null }

        val offer = rtc?.initAsHost(turnCreds) ?: return

        signaling?.sendSignal(JSONObject().apply {
            put("type", "offer")
            put("sdp", GhostRTC.sdpToJson(offer))
        })
    }

    private suspend fun initAsGuest() {
        val turnCreds = try {
            turnService?.fetchCredentials()
        } catch (e: Exception) { null }

        rtc?.initAsGuest(turnCreds)
    }

    // MARK: - Signal Handling

    private suspend fun handleSignal(data: JSONObject) {
        when (data.optString("type", "")) {
            "offer" -> {
                val sdpJson = data.optJSONObject("sdp") ?: return
                val sdp = GhostRTC.jsonToSdp(sdpJson) ?: return
                val answer = rtc?.handleOffer(sdp) ?: return

                signaling?.sendSignal(JSONObject().apply {
                    put("type", "answer")
                    put("sdp", GhostRTC.sdpToJson(answer))
                })

                // Flush pending ICE candidates
                for (candidate in pendingIceCandidates) {
                    rtc?.addIceCandidate(candidate)
                }
                pendingIceCandidates.clear()
            }

            "answer" -> {
                val sdpJson = data.optJSONObject("sdp") ?: return
                val sdp = GhostRTC.jsonToSdp(sdpJson) ?: return
                rtc?.handleAnswer(sdp)
            }

            "ice-candidate" -> {
                val candidateJson = data.optJSONObject("candidate") ?: return
                val candidate = GhostRTC.jsonToCandidate(candidateJson) ?: return

                if (rtc?.peerConnection?.remoteDescription != null) {
                    rtc?.addIceCandidate(candidate)
                } else {
                    pendingIceCandidates.add(candidate)
                }
            }
        }
    }

    // MARK: - Key Exchange

    private suspend fun handleKeyExchange(json: JSONObject) {
        if (keyExchangeCompleted) return

        val peerPublicKey = json.optString("publicKey", "")
        if (peerPublicKey.isEmpty()) return

        // Version check
        val peerVersion = json.optInt("v", 1)
        if (peerVersion < 2) {
            addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_incompatible_version))
            return
        }

        // v3: Identity key for contact recognition
        val idKeyBase64 = json.optString("identityKey", "")
        if (idKeyBase64.isNotEmpty()) {
            try {
                val idKeyData = android.util.Base64.decode(idKeyBase64, android.util.Base64.DEFAULT)
                peerIdentityKeyData = idKeyData

                // Check if we know this peer
                val knownContact = contactStore?.fetchByIdentityKey(idKeyData)
                if (knownContact != null) {
                    currentPeerContact = knownContact
                    addSystemMessage(
                        appContext.getString(com.ghost.chat.R.string.system_known_peer, knownContact.label)
                    )
                }

                // Verify against expected peer
                val expected = expectedPeerIdentityKey
                if (expected != null && !expected.contentEquals(idKeyData)) {
                    addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_unexpected_peer))
                }
            } catch (_: Exception) {}
        }

        // Import peer's public key
        try {
            crypto?.importPeerPublicKey(peerPublicKey)
        } catch (e: Exception) {
            addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_key_exchange_error))
            return
        }

        // Derive shared key with Double Ratchet
        try {
            crypto?.deriveSharedKey(asHost = isHost)
        } catch (e: Exception) {
            addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_key_exchange_error))
            return
        }

        completeKeyExchange()
    }

    private fun completeKeyExchange() {
        keyExchangeCompleted = true
        fingerprint = try { crypto?.generateFingerprint() ?: "" } catch (_: Exception) { "" }
        screen = Screen.CHAT
        isConnected = true

        addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_secure_connection))
        addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_tap_shield))

        startSecurityMonitoring()
        startMessageCleanup()
        handleContactAutoSave()

        // HOST: Send bootstrap message to initialize guest's Double Ratchet
        if (isHost) {
            viewModelScope.launch { sendEncryptedControl(ControlMessage.Ready) }
        }
    }

    // MARK: - Message Sending

    fun sendMessage(text: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty() || !isConnected) return

        viewModelScope.launch {
            try {
                val encrypted = crypto?.encrypt(trimmed)
                    ?: throw Exception("Crypto not ready")

                val msg = JSONObject().apply {
                    put("type", "encrypted-message")
                    put("data", encrypted)
                    put("v", 2)
                }
                rtc?.send(msg.toString())

                // Add to UI
                val chatMsg = addMessage(trimmed, ChatMessage.MessageType.SENT)

                // Track for delivery ACK
                crypto?.messageCounter?.let { counter ->
                    sentMessages[counter] = chatMsg.id
                }
            } catch (e: Exception) {
                addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_send_error))
            }
        }
    }

    // MARK: - Message Receiving

    private suspend fun handleP2PMessage(data: String) {
        try {
            val json = JSONObject(data)
            when (json.optString("type", "")) {
                "key-exchange" -> handleKeyExchange(json)
                "encrypted-message" -> {
                    val encryptedData = json.optString("data", "")
                    if (encryptedData.isNotEmpty()) {
                        handleEncryptedMessage(encryptedData)
                    }
                }
            }
        } catch (_: Exception) {}
    }

    private suspend fun handleEncryptedMessage(encryptedData: String) {
        try {
            val plaintext = crypto?.decrypt(encryptedData) ?: return

            // Try parsing as control message
            try {
                val json = JSONObject(plaintext)
                val controlMsg = ControlMessage.from(json)
                if (controlMsg != null) {
                    handleControlMessage(controlMsg)
                    return
                }
            } catch (_: Exception) {
                // Not a control message — regular text
            }

            // Regular text message
            addMessage(plaintext, ChatMessage.MessageType.RECEIVED)

            // Play sound & vibrate
            if (messageSoundEnabled) {
                SoundLibrary.playMessageSound(appContext, messageSoundId, vibrationEnabled)
            } else if (vibrationEnabled) {
                vibrate()
            }

            // Send delivery ACK
            val counter = crypto?.messageCounter ?: return
            sendEncryptedControl(ControlMessage.MessageAck(counter))
        } catch (e: Exception) {
            addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_decryption_error))
        }
    }

    // MARK: - Control Messages

    private suspend fun handleControlMessage(msg: ControlMessage) {
        when (msg) {
            is ControlMessage.Renegotiate -> handleRenegotiation(msg.sdp)
            is ControlMessage.CallRequest -> handleIncomingCall()
            is ControlMessage.CallResponse -> handleCallResponse(msg.accepted)
            is ControlMessage.CallEnd -> handleCallEnded()
            is ControlMessage.CallSecurityAlert -> {
                val message = msg.alert.optString("message", "")
                addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_security_warning, message))
            }
            is ControlMessage.SecurityAlert -> handleSecurityAlertReceived(msg.alert)
            is ControlMessage.MessageAck -> handleMessageAck(msg.counter)
            is ControlMessage.Ready -> {
                // Bootstrap from host — decryption already triggered DH ratchet
            }
        }
    }

    suspend fun sendEncryptedControl(control: ControlMessage) {
        try {
            val json = control.toJSON().toString()
            val encrypted = crypto?.encrypt(json) ?: return
            val msg = JSONObject().apply {
                put("type", "encrypted-message")
                put("data", encrypted)
                put("v", 2)
            }
            rtc?.send(msg.toString())
        } catch (e: Exception) {
            // Silent fail for control messages
        }
    }

    private fun handleMessageAck(counter: Int) {
        val msgId = sentMessages[counter] ?: return
        val index = messages.indexOfFirst { it.id == msgId }
        if (index >= 0) {
            messages[index] = messages[index].copy(isDelivered = true)
            sentMessages.remove(counter)
        }
    }

    // MARK: - Voice Calls

    fun startCall() {
        if (!isConnected || callState != CallUIState.IDLE) return

        val pc = rtc?.peerConnection ?: return
        if (voice == null) {
            voice = GhostVoice(pc, rtc!!.factory, appContext)
            setupVoiceCallbacks()
        }

        try {
            voice?.startCall()
            callState = CallUIState.CALLING
            viewModelScope.launch {
                sendEncryptedControl(ControlMessage.CallRequest)
            }
            addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_calling))
        } catch (e: Exception) {
            addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_call_error))
            callState = CallUIState.IDLE
        }
    }

    private fun handleIncomingCall() {
        if (callState != CallUIState.IDLE) {
            viewModelScope.launch {
                sendEncryptedControl(ControlMessage.CallResponse(false))
            }
            return
        }

        callState = CallUIState.RINGING
        addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_incoming_call))
        startIncomingCallVibration()
    }

    fun acceptCall() {
        if (callState != CallUIState.RINGING) return
        stopIncomingCallVibration()

        val pc = rtc?.peerConnection ?: return
        if (voice == null) {
            voice = GhostVoice(pc, rtc!!.factory, appContext)
            setupVoiceCallbacks()
        }

        try {
            voice?.acceptCall()

            // Process pending renegotiation offer
            val pendingOffer = pendingRenegotiationOffer
            if (pendingOffer != null) {
                viewModelScope.launch {
                    processRenegotiationOffer(GhostRTC.sdpToJson(pendingOffer))
                    pendingRenegotiationOffer = null
                }
            }

            viewModelScope.launch {
                sendEncryptedControl(ControlMessage.CallResponse(true))
            }
            callState = CallUIState.ACTIVE
            addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_call_connected))
        } catch (e: Exception) {
            viewModelScope.launch {
                sendEncryptedControl(ControlMessage.CallResponse(false))
            }
            callState = CallUIState.IDLE
        }
    }

    fun declineCall() {
        stopIncomingCallVibration()
        viewModelScope.launch {
            sendEncryptedControl(ControlMessage.CallResponse(false))
        }
        callState = CallUIState.IDLE
    }

    private fun handleCallResponse(accepted: Boolean) {
        if (!accepted) {
            voice?.endCall()
            voice?.destroy()
            voice = null
            callState = CallUIState.IDLE
            addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_call_declined))
            return
        }

        voice?.callAccepted()
        callState = CallUIState.ACTIVE
        addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_call_connected))
    }

    private fun handleCallEnded() {
        stopIncomingCallVibration()
        voice?.endCall()
        voice?.destroy()
        voice = null
        callState = CallUIState.IDLE
        isMuted = false
        isSpeakerOn = false
        pendingRenegotiationOffer = null
        addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_call_ended))
    }

    fun endCall() {
        if (callState == CallUIState.IDLE) return
        stopIncomingCallVibration()
        voice?.endCall()
        voice?.destroy()
        voice = null

        viewModelScope.launch {
            sendEncryptedControl(ControlMessage.CallEnd)
        }

        callState = CallUIState.IDLE
        isMuted = false
        isSpeakerOn = false
        pendingRenegotiationOffer = null
        addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_call_ended))
    }

    fun toggleMute() {
        val muted = voice?.toggleMute() ?: return
        isMuted = muted
    }

    fun toggleSpeaker() {
        val speaker = voice?.toggleSpeaker() ?: return
        isSpeakerOn = speaker
    }

    private fun setupVoiceCallbacks() {
        voice?.onCallTimer = { time ->
            mainHandler.post { callTimer = time }
        }
    }

    // MARK: - Renegotiation (for audio track addition)

    private suspend fun handleRenegotiation(sdpJson: JSONObject) {
        val sdp = GhostRTC.jsonToSdp(sdpJson) ?: return

        if (sdp.type == SessionDescription.Type.OFFER) {
            // If we're ringing, store for later
            if (callState == CallUIState.RINGING) {
                pendingRenegotiationOffer = sdp
                return
            }
            processRenegotiationOffer(sdpJson)
        } else if (sdp.type == SessionDescription.Type.ANSWER) {
            rtc?.handleAnswer(sdp)
        }
    }

    private suspend fun processRenegotiationOffer(sdpJson: JSONObject) {
        val sdp = GhostRTC.jsonToSdp(sdpJson) ?: return
        val answer = rtc?.handleOffer(sdp) ?: return
        sendEncryptedControl(ControlMessage.Renegotiate(GhostRTC.sdpToJson(answer)))
    }

    private suspend fun handleLocalRenegotiationOffer(offer: SessionDescription) {
        sendEncryptedControl(ControlMessage.Renegotiate(GhostRTC.sdpToJson(offer)))
    }

    // MARK: - Incoming Call Vibration

    private fun startIncomingCallVibration() {
        if (vibrationEnabled) vibrate()
        SoundLibrary.playRingtone(appContext, ringtoneId)

        ringtoneTimer = fixedRateTimer("ringtone", period = 2500L) {
            mainHandler.post {
                if (callState == CallUIState.RINGING) {
                    if (vibrationEnabled) vibrate()
                    SoundLibrary.playRingtone(appContext, ringtoneId)
                }
            }
        }
    }

    private fun stopIncomingCallVibration() {
        ringtoneTimer?.cancel()
        ringtoneTimer = null
    }

    private fun vibrate() {
        val vibrator = appContext.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator ?: return
        vibrator.vibrate(VibrationEffect.createOneShot(200, VibrationEffect.DEFAULT_AMPLITUDE))
    }

    // MARK: - Security Monitoring

    private fun startSecurityMonitoring() {
        securityMonitor = SecurityMonitor(appContext).apply {
            onSecurityAlert = { alert ->
                mainHandler.post {
                    securityAlert = alert
                    addSystemMessage(alert)
                    viewModelScope.launch {
                        sendEncryptedControl(ControlMessage.SecurityAlert(alert))
                    }
                }
            }
            start()
        }
    }

    private fun handleSecurityAlertReceived(alert: String) {
        addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_peer_security_alert, alert))
    }

    // MARK: - Contact Management

    private fun handleContactAutoSave() {
        val idKey = peerIdentityKeyData ?: return
        val existingContact = contactStore?.fetchByIdentityKey(idKey)

        if (existingContact != null) {
            // Known contact — increment session count
            currentPeerContact = existingContact
            contactStore?.incrementSessionCount(existingContact.id)
        } else {
            // New peer — prompt to save
            showSaveContactPrompt = true
        }
    }

    fun saveContact(name: String) {
        val idKey = peerIdentityKeyData ?: return
        val pubKey = crypto?.exportPublicKey()?.let {
            android.util.Base64.decode(it, android.util.Base64.DEFAULT)
        } ?: return

        val contact = Contact(
            label = name,
            publicKey = pubKey,
            identityKey = idKey,
            ratchetState = null,
            sessionCount = 1,
            lastSessionAt = Date()
        )

        viewModelScope.launch(Dispatchers.IO) {
            contactStore?.save(contact)
            withContext(Dispatchers.Main) {
                currentPeerContact = contact
                showSaveContactPrompt = false
                pendingContactName = ""
            }
        }
    }

    fun dismissSavePrompt() {
        showSaveContactPrompt = false
        pendingContactName = ""
    }

    /** Persist ratchet state for current contact before leaving */
    private fun persistContactState() {
        val contact = currentPeerContact ?: return
        val ratchetState = crypto?.exportRatchetState() ?: return

        viewModelScope.launch(Dispatchers.IO) {
            try {
                val stateJson = JSONObject().apply {
                    put("dhSendingPrivateKey", android.util.Base64.encodeToString(
                        ratchetState.dhSendingPrivateKey, android.util.Base64.NO_WRAP))
                    put("dhSendingPublicKey", android.util.Base64.encodeToString(
                        ratchetState.dhSendingPublicKey, android.util.Base64.NO_WRAP))
                    ratchetState.dhReceivingPublicKey?.let {
                        put("dhReceivingPublicKey", android.util.Base64.encodeToString(it, android.util.Base64.NO_WRAP))
                    }
                    put("rootKey", android.util.Base64.encodeToString(ratchetState.rootKey, android.util.Base64.NO_WRAP))
                    ratchetState.sendChainKey?.let {
                        put("sendChainKey", android.util.Base64.encodeToString(it, android.util.Base64.NO_WRAP))
                    }
                    ratchetState.receiveChainKey?.let {
                        put("receiveChainKey", android.util.Base64.encodeToString(it, android.util.Base64.NO_WRAP))
                    }
                    ratchetState.sendHeaderKey?.let {
                        put("sendHeaderKey", android.util.Base64.encodeToString(it, android.util.Base64.NO_WRAP))
                    }
                    ratchetState.receiveHeaderKey?.let {
                        put("receiveHeaderKey", android.util.Base64.encodeToString(it, android.util.Base64.NO_WRAP))
                    }
                    ratchetState.nextSendHeaderKey?.let {
                        put("nextSendHeaderKey", android.util.Base64.encodeToString(it, android.util.Base64.NO_WRAP))
                    }
                    ratchetState.nextReceiveHeaderKey?.let {
                        put("nextReceiveHeaderKey", android.util.Base64.encodeToString(it, android.util.Base64.NO_WRAP))
                    }
                    put("sendMessageNumber", ratchetState.sendMessageNumber)
                    put("receiveMessageNumber", ratchetState.receiveMessageNumber)
                    put("previousChainLength", ratchetState.previousChainLength)
                }
                contactStore?.updateRatchetState(contact.id, stateJson.toString().toByteArray())

                // Save skipped keys
                val skippedKeys = crypto?.exportSkippedKeys() ?: emptyList()
                contactStore?.saveSkippedKeys(contact.id, skippedKeys)
            } catch (_: Exception) {}
        }
    }

    // MARK: - Session Persistence

    private fun saveSession() {
        val rid = roomId ?: return
        val sessionJson = JSONObject().apply {
            put("roomId", rid)
            put("isHost", isHost)
            put("ts", System.currentTimeMillis() / 1000)
        }
        KeystoreService.saveString(sessionJson.toString(), "ghost-room")
    }

    private fun clearSession() {
        KeystoreService.delete("ghost-room")
    }

    // MARK: - Messages

    fun addMessage(text: String, type: ChatMessage.MessageType): ChatMessage {
        val ttlMs = if (type == ChatMessage.MessageType.SYSTEM) {
            10 * 60 * 1000L  // System messages: 10 min
        } else {
            autoDeleteMinutes * 60 * 1000L
        }

        val msg = ChatMessage(
            text = text,
            type = type,
            expiresAt = Date(System.currentTimeMillis() + ttlMs)
        )
        messages.add(msg)
        return msg
    }

    private fun addSystemMessage(text: String) {
        addMessage(text, ChatMessage.MessageType.SYSTEM)
    }

    private fun startMessageCleanup() {
        messageCleanupTimer = fixedRateTimer("message-cleanup", period = 1000L) {
            mainHandler.post {
                val now = System.currentTimeMillis()
                messages.removeAll { it.expiresAt.time <= now }

                // Clean up sent message tracking for expired messages
                val validMessageIds = messages.map { it.id }.toSet()
                sentMessages.entries.removeAll { (_, msgId) -> msgId !in validMessageIds }
            }
        }
    }

    // MARK: - Connection Timeout

    private fun startConnectionTimeout() {
        cancelConnectionTimeout()
        connectionTimeout = Handler(Looper.getMainLooper())
        connectionTimeoutRunnable = Runnable {
            if (!isConnected) {
                addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_connection_timeout))
            }
        }
        connectionTimeout?.postDelayed(connectionTimeoutRunnable!!, 30_000)
    }

    private fun cancelConnectionTimeout() {
        connectionTimeoutRunnable?.let { connectionTimeout?.removeCallbacks(it) }
        connectionTimeout = null
        connectionTimeoutRunnable = null
    }

    // MARK: - Leave / Cleanup

    fun leave() {
        persistContactState()

        // End call if active
        if (callState != CallUIState.IDLE) {
            stopIncomingCallVibration()
            voice?.endCall()
            voice?.destroy()
            voice = null
            callState = CallUIState.IDLE
        }

        cancelConnectionTimeout()
        messageCleanupTimer?.cancel()
        messageCleanupTimer = null

        securityMonitor?.stop()
        securityMonitor = null

        signaling?.leaveRoom()
        signaling?.destroy()
        signaling = null

        rtc?.destroy()
        rtc = null

        crypto?.destroy()
        crypto = null

        clearSession()

        isConnected = false
        isVerified = false
        keyExchangeCompleted = false
        roomId = null
        fingerprint = ""
        messages.clear()
        sentMessages.clear()
        pendingIceCandidates.clear()
        pendingRenegotiationOffer = null
        currentPeerContact = null
        peerIdentityKeyData = null
        expectedPeerIdentityKey = null
        showSaveContactPrompt = false
        pendingContactName = ""
        securityAlert = null
        showVerificationPanel = false
        isMuted = false
        isSpeakerOn = false

        screen = Screen.WELCOME
    }

    // MARK: - Deep Link

    fun handleDeepLink(roomIdFromLink: String) {
        if (screen == Screen.CHAT || screen == Screen.CONNECTING) {
            pendingDeepLinkRoom = roomIdFromLink
        } else {
            joinRoom(roomIdFromLink)
        }
    }

    // MARK: - Settings Actions

    fun deleteAllContacts() {
        viewModelScope.launch(Dispatchers.IO) {
            contactStore?.deleteAll()
        }
    }

    fun destroyAllData() {
        viewModelScope.launch(Dispatchers.IO) {
            DatabaseService.getInstance(appContext).destroyAll()
            IdentityKeyService.destroy()
            KeystoreService.clear()
            withContext(Dispatchers.Main) {
                leave()
            }
        }
    }

    /** Start chat from saved contact */
    fun startChatWithContact(contact: Contact) {
        expectedPeerIdentityKey = contact.identityKey
        currentPeerContact = contact
        createRoom()
    }

    // MARK: - Cleanup

    override fun onCleared() {
        super.onCleared()
        leave()
    }
}
