package com.ghost.chat.features.chat

import android.content.Context
import android.os.Handler
import android.util.Log
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
import android.net.Uri
import com.ghost.chat.core.call.CallManager
import com.ghost.chat.core.filetransfer.FileTransferService
import com.ghost.chat.core.call.GhostConnectionService
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
import com.ghost.chat.core.notification.GhostFirebaseService
import com.ghost.chat.core.notification.NotificationHelper
import com.ghost.chat.models.ChatMessage
import com.ghost.chat.models.Contact
import com.ghost.chat.models.ControlMessage
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import org.webrtc.IceCandidate
import org.webrtc.MediaStream
import org.webrtc.SessionDescription
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.Timer
import kotlin.concurrent.fixedRateTimer

/// Debug log to file (works in release builds — Logcat is often filtered)
fun ghostLog(msg: String, context: Context? = null) {
    val ts = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US).format(Date())
    val line = "[$ts] $msg\n"
    Log.d("GhostChat", msg)
    try {
        val dir = context?.filesDir ?: return
        val file = File(dir, "ghost_debug.log")
        // Cap file at 1MB — rotate
        if (file.exists() && file.length() > 1_000_000) {
            val old = File(dir, "ghost_debug_old.log")
            old.delete()
            file.renameTo(old)
        }
        FileOutputStream(file, true).use { it.write(line.toByteArray()) }
    } catch (_: Exception) { /* best-effort */ }
}

/// Main orchestrator — port of iOS ChatViewModel (~1200 lines)
/// Manages: screen state, signaling, WebRTC, crypto, calls, contacts, settings
class ChatViewModel(private val appContext: Context) : ViewModel() {

    companion object {
        private const val SERVER_URL = "https://ghostchat.one"
        const val SAVED_MESSAGES_CONTACT_ID = "saved-messages"
    }

    val isSavedMessagesMode: Boolean
        get() = currentContactId == SAVED_MESSAGES_CONTACT_ID

    // MARK: - Screen State

    enum class Screen { WELCOME, WAITING, CONNECTING, CHAT }
    enum class CallUIState { IDLE, CALLING, RINGING, ACTIVE }

    /// Connection steps for progress animation (same as iOS)
    enum class ConnectionStep { CONNECTING_TO_SERVER, WAITING_FOR_PEER, EXCHANGING_KEYS, SECURED }

    /// Peer status states — shown in chat header
    enum class PeerStatus { ONLINE, CONNECTING, SEARCHING, RECENTLY_ONLINE, OFFLINE }

    var screen by mutableStateOf(Screen.WELCOME)
    var isConnected by mutableStateOf(false)
    var isVerified by mutableStateOf(false)
    var roomId by mutableStateOf<String?>(null)
    var fingerprint by mutableStateOf("")
    var isHost by mutableStateOf(false)
        private set

    // Connection step (for connecting screen progress)
    var connectionStep by mutableStateOf(ConnectionStep.CONNECTING_TO_SERVER)

    // Reply state (Telegram-style inline reply)
    var replyingTo by mutableStateOf<ChatMessage?>(null)

    // Peer disconnected banner
    var showPeerDisconnectedBanner by mutableStateOf(false)

    // Editing state
    var editingMessage by mutableStateOf<ChatMessage?>(null)

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

    // Typing indicator
    var peerIsTyping by mutableStateOf(false)

    // Peer status
    var peerStatus by mutableStateOf(PeerStatus.OFFLINE)
    private var peerLastSeenAt: Long = 0L
    private var peerStatusTransitionRunnable: Runnable? = null

    // Verification panel
    var showVerificationPanel by mutableStateOf(false)

    // Settings (persisted)
    var autoDeleteMinutes by mutableIntStateOf(0)
    var screenshotNotifications by mutableStateOf(true)
    var messageSoundEnabled by mutableStateOf(true)
    var vibrationEnabled by mutableStateOf(true)
    var privacyMode by mutableStateOf(true)
    var ringtoneId by mutableStateOf("fanfare")
    var messageSoundId by mutableStateOf("received")

    // Deep link
    var pendingDeepLinkRoom by mutableStateOf<String?>(null)

    // Message push — highlight contact in WelcomeScreen
    var pendingMessageContactId by mutableStateOf<String?>(null)
    var pendingMessageType by mutableStateOf<String?>(null)

    // MARK: - Private State

    private var signaling: SignalingClient? = null
    private var rtc: GhostRTC? = null
    private var crypto: GhostCrypto? = null
    private var voice: GhostVoice? = null
    private var securityMonitor: SecurityMonitor? = null
    private var turnService: TURNService? = null
    private var contactStore: ContactStore? = null
    private var messageStore: com.ghost.chat.core.storage.MessageStore? = null
    var currentContactId: String? = null
    var saveMessageHistory by mutableStateOf(false)
    var savedMessagesEnabled by mutableStateOf(false)

    private var pendingIceCandidates = mutableListOf<IceCandidate>()
    private val pendingSignals = mutableListOf<JSONObject>()
    private var pendingRenegotiationOffer: SessionDescription? = null
    private var pendingRemoteStream: MediaStream? = null
    private var keyExchangeCompleted = false

    private data class SentRecord(val id: String, val sentAt: Long)
    private val sentMessages = mutableMapOf<Int, SentRecord>() // counter -> (message ID, sent timestamp)

    private var peerIdentityKeyData: ByteArray? = null
    private var expectedPeerIdentityKey: ByteArray? = null
    private var peerPushToken: String? = null
    private var peerNotifyToken: String? = null
    private var tokensSentToPeerThisSession = false  // Dedup guard for mutual token exchange
    private var peerIsNativeApp = false
    val fileTransfer = FileTransferService(appContext)
    var peerSupportsFiles by mutableStateOf(false)

    /// True when the current session was initiated by an incoming FCM push
    /// (symmetric with iOS isFromPush). Used to decide whether to buffer acceptCall.
    private var isFromPush = false

    /// Buffered "user tapped Accept in system UI" when P2P isn't ready yet.
    /// Symmetric with iOS pendingAcceptCall. Flushed from completeKeyExchange.
    private var pendingAcceptCall = false
    private var localFcmToken: String? = null
    private var pushAuthToken: String? = null  // Auth token for push endpoints (from TURN credentials)

    private var messageCleanupTimer: Timer? = null
    private var connectionTimeout: Handler? = null
    private var roomRotationTimer: Timer? = null
    private var isRotatingRoom = false
    private var isCreatingRoom = false
    private var isLeaving = false
    private var connectionTimeoutRunnable: Runnable? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // Typing indicator — unified timings (same on iOS/Web)
    private var lastTypingSentAt: Long = 0
    private var typingCancelRunnable: Runnable? = null
    private var peerTypingCancelRunnable: Runnable? = null

    // Ringtone/vibration for incoming calls
    private var ringtoneTimer: Timer? = null
    private var ringingTimeoutRunnable: Runnable? = null
    private var callingTimeoutRunnable: Runnable? = null
    private var peerLeftRunnable: Runnable? = null
    private var pendingIceRestartOffer: org.webrtc.SessionDescription? = null

    // Auto-connect: pending room polling timer (5s interval)
    private var pendingRoomPollTimer: Timer? = null
    private var isAutoConnecting = false

    // Offline call: set true when startCall is waiting for connection
    var pendingCallAfterConnect by mutableStateOf(false)

    // MARK: - Init

    init {
        Log.d("GhostChat", "[ChatViewModel] init called")
        loadSettings()
        initDatabase()
        initCallManager()
        initFCM()
        Log.d("GhostChat", "[ChatViewModel] init complete")
    }

    private fun initDatabase() {
        Log.d("GhostChat", "[ChatViewModel] initDatabase called")
        val db = DatabaseService.getInstance(appContext)
        contactStore = ContactStore(db)
        messageStore = com.ghost.chat.core.storage.MessageStore(db)
        Log.d("GhostChat", "[ChatViewModel] initDatabase complete")
    }

    private fun initCallManager() {
        Log.d("GhostChat", "[ChatViewModel] initCallManager called")
        CallManager.initialize(appContext)
        // Wire up ConnectionService callbacks (system call UI → app)
        GhostConnectionService.onCallAnswer = { mainHandler.post { acceptCall() } }
        GhostConnectionService.onCallEnd = { mainHandler.post { endCall() } }
        GhostConnectionService.onCallMute = { muted -> mainHandler.post { voice?.setMuted(muted); isMuted = muted } }
        Log.d("GhostChat", "[ChatViewModel] initCallManager complete")
    }

    private fun initFCM() {
        Log.d("GhostChat", "[ChatViewModel] initFCM called")
        // Get current FCM token
        FirebaseMessaging.getInstance().token.addOnSuccessListener { token ->
            Log.d("GhostChat", "[ChatViewModel] initFCM — got FCM token, length=${token.length}")
            localFcmToken = token
        }

        // Handle token refresh — resend to peer if connected
        GhostFirebaseService.onTokenRefresh = { token ->
            Log.d("GhostChat", "[ChatViewModel] FCM token refreshed, length=${token.length}, keyExchangeCompleted=$keyExchangeCompleted, isConnected=$isConnected")
            localFcmToken = token
            if (keyExchangeCompleted && isConnected) {
                Log.d("GhostChat", "[ChatViewModel] FCM token refreshed — sending to peer")
                viewModelScope.launch {
                    sendEncryptedControl(ControlMessage.PushToken(token))
                    sendEncryptedControl(ControlMessage.NotifyToken(token))
                }
            } else {
                Log.d("GhostChat", "[ChatViewModel] FCM token refreshed — not connected, skipping send")
            }
        }

        // Handle incoming call push (app in background/killed).
        // Работает из ЛЮБОГО экрана — если юзер в другом чате, корректно выходим
        // и переходим на новый звонок (ранее silently dropped в .else).
        GhostFirebaseService.onIncomingCall = { roomId, callerName ->
            Log.d("GhostChat", "[ChatViewModel] onIncomingCall push — roomId=${roomId.take(8)}..., callerName=$callerName, screen=$screen")
            mainHandler.post {
                if (screen != Screen.WELCOME) {
                    Log.d("GhostChat", "[ChatViewModel] onIncomingCall — tearing down current session (screen=$screen) to handle push")
                    performLeave()
                }
                isFromPush = true
                Log.d("GhostChat", "[ChatViewModel] onIncomingCall — setting pendingDeepLinkRoom + isFromPush=true")
                pendingDeepLinkRoom = roomId
            }
        }

        // Handle chat invite push — тоже работает из любого экрана
        GhostFirebaseService.onChatInvite = { roomId, inviterName ->
            Log.d("GhostChat", "[ChatViewModel] onChatInvite push — roomId=${roomId.take(8)}..., inviterName=$inviterName, screen=$screen")
            mainHandler.post {
                if (screen != Screen.WELCOME) {
                    Log.d("GhostChat", "[ChatViewModel] onChatInvite — tearing down current session (screen=$screen) to handle push")
                    performLeave()
                }
                Log.d("GhostChat", "[ChatViewModel] onChatInvite — setting pendingDeepLinkRoom")
                pendingDeepLinkRoom = roomId
            }
        }

        // Handle message/missed-call push — highlight contact in UI
        GhostFirebaseService.onMessagePush = { type, senderName ->
            Log.d("GhostChat", "[ChatViewModel] onMessagePush — type=$type, senderName=$senderName")
            mainHandler.post {
                handleMessagePush(type, senderName)
            }
        }
        Log.d("GhostChat", "[ChatViewModel] initFCM complete")
    }

    private fun loadSettings() {
        Log.d("GhostChat", "[ChatViewModel] loadSettings called")
        autoDeleteMinutes = KeystoreService.loadInt("settings_auto_delete", 0)
        screenshotNotifications = KeystoreService.loadBool("settings_screenshot_notify", true)
        messageSoundEnabled = KeystoreService.loadBool("settings_sound", true)
        vibrationEnabled = KeystoreService.loadBool("settings_vibration", true)
        privacyMode = false // TURN disabled for now
        ringtoneId = KeystoreService.loadString("settings_ringtone") ?: "fanfare"
        messageSoundId = KeystoreService.loadString("settings_msg_sound") ?: "received"
        saveMessageHistory = KeystoreService.loadBool("settings_save_history", true)
        savedMessagesEnabled = KeystoreService.loadBool("settings_saved_messages", false)

        // Migration: reset auto-delete to 0 if it was previously set to a non-zero value
        // (same as iOS settings_auto_delete_v2_migrated)
        val migrated = KeystoreService.loadBool("settings_auto_delete_v2_migrated", false)
        if (!migrated && autoDeleteMinutes != 0) {
            Log.d("GhostChat", "[ChatViewModel] loadSettings — migrating auto-delete from $autoDeleteMinutes to 0")
            autoDeleteMinutes = 0
            KeystoreService.saveInt(0, "settings_auto_delete")
            KeystoreService.saveBool(true, "settings_auto_delete_v2_migrated")
        } else if (!migrated) {
            KeystoreService.saveBool(true, "settings_auto_delete_v2_migrated")
        }

        Log.d("GhostChat", "[ChatViewModel] loadSettings — autoDelete=$autoDeleteMinutes, privacyMode=$privacyMode, saveHistory=$saveMessageHistory, savedMessages=$savedMessagesEnabled")
    }

    fun saveSettings() {
        Log.d("GhostChat", "[ChatViewModel] saveSettings called")
        KeystoreService.saveInt(autoDeleteMinutes, "settings_auto_delete")
        KeystoreService.saveBool(screenshotNotifications, "settings_screenshot_notify")
        KeystoreService.saveBool(messageSoundEnabled, "settings_sound")
        KeystoreService.saveBool(vibrationEnabled, "settings_vibration")
        KeystoreService.saveBool(privacyMode, "settings_privacy_mode")
        KeystoreService.saveString(ringtoneId, "settings_ringtone")
        KeystoreService.saveString(messageSoundId, "settings_msg_sound")
        KeystoreService.saveBool(saveMessageHistory, "settings_save_history")
        KeystoreService.saveBool(savedMessagesEnabled, "settings_saved_messages")
    }

    /** Delete saved messages and disable the feature */
    fun disableSavedMessages() {
        Log.d("GhostChat", "[ChatViewModel] disableSavedMessages called")
        viewModelScope.launch(Dispatchers.IO) {
            messageStore?.deleteForContact(SAVED_MESSAGES_CONTACT_ID)
            withContext(Dispatchers.Main) {
                savedMessagesEnabled = false
                saveSettings()
                Log.d("GhostChat", "[ChatViewModel] disableSavedMessages complete")
            }
        }
    }

    // MARK: - Create Room (Host)

    fun createRoom() {
        Log.d("GhostChat", "[ChatViewModel] createRoom called, privacyMode=$privacyMode")
        isHost = true
        Log.d("GhostChat", "[ChatViewModel] createRoom — creating crypto + RTC + signaling")
        crypto = GhostCrypto().also { it.generateKeyPair() }
        rtc = GhostRTC(appContext).also { it.privacyMode = privacyMode }
        signaling = SignalingClient(SERVER_URL)
        turnService = TURNService(SERVER_URL)
        rtc?.setTurnService(turnService)

        setupSignalingCallbacks()
        setupRTCCallbacks()

        Log.d("GhostChat", "[ChatViewModel] createRoom — connecting signaling and creating room")
        signaling?.connect()
        signaling?.createRoom()
    }

    // MARK: - Join Room (Guest)

    fun joinRoom(inputRoomId: String) {
        Log.d("GhostChat", "[ChatViewModel] joinRoom called, inputLength=${inputRoomId.length}")
        val trimmed = inputRoomId.trim()
        // Extract room ID from full URL if needed
        val roomIdValue = if (trimmed.contains("?room=")) {
            Log.d("GhostChat", "[ChatViewModel] joinRoom — extracting roomId from URL")
            trimmed.substringAfter("?room=").substringBefore("&")
        } else {
            trimmed
        }
        Log.d("GhostChat", "[ChatViewModel] joinRoom — roomId=${roomIdValue.take(8)}..., length=${roomIdValue.length}")

        // Validate: base64url, 64 chars
        if (!roomIdValue.matches(Regex("^[A-Za-z0-9_-]{64}$"))) {
            Log.e("GhostChat", "[ChatViewModel] joinRoom — INVALID room ID format, length=${roomIdValue.length}")
            return
        }

        isHost = false
        Log.d("GhostChat", "[ChatViewModel] joinRoom — creating crypto + RTC + signaling, privacyMode=$privacyMode")
        crypto = GhostCrypto().also { it.generateKeyPair() }
        rtc = GhostRTC(appContext).also { it.privacyMode = privacyMode }
        signaling = SignalingClient(SERVER_URL)
        turnService = TURNService(SERVER_URL)
        rtc?.setTurnService(turnService)

        setupSignalingCallbacks()
        setupRTCCallbacks()

        Log.d("GhostChat", "[ChatViewModel] joinRoom — connecting signaling and joining room")
        signaling?.connect()
        signaling?.joinRoom(roomIdValue)
    }

    // MARK: - Signaling Callbacks

    private fun setupSignalingCallbacks() {
        Log.d("GhostChat", "[ChatViewModel] setupSignalingCallbacks")
        signaling?.onRoomCreated = { id ->
            Log.d("GhostChat", "[ChatViewModel] onRoomCreated roomId=${id.take(8)}...")
            roomId = id
            saveSession()
            connectionStep = ConnectionStep.CONNECTING_TO_SERVER
            if (screen != Screen.CHAT) {
                screen = Screen.WAITING
            }
        }

        signaling?.onRoomJoined = { id ->
            Log.d("GhostChat", "[ChatViewModel] onRoomJoined roomId=${id.take(8)}...")
            roomId = id
            saveSession()
            connectionStep = ConnectionStep.CONNECTING_TO_SERVER
            if (screen != Screen.CHAT) {
                screen = Screen.CONNECTING
            }
            viewModelScope.launch { initAsGuest() }
        }

        signaling?.onRejoinOk = {
            Log.d("GhostChat", "[ChatViewModel] onRejoinOk — hasPendingIceRestart=${pendingIceRestartOffer != null}, rtcConnected=${rtc?.isConnected}")
            // Отправляем буферизованный ICE restart offer если есть
            val buffered = pendingIceRestartOffer
            if (buffered != null) {
                Log.d("GhostChat", "[ChatViewModel] onRejoinOk — sending buffered ICE restart offer")
                pendingIceRestartOffer = null
                signaling?.sendSignal(JSONObject().apply {
                    put("type", "offer")
                    put("sdp", GhostRTC.sdpToJson(buffered))
                })
            } else if (rtc?.isConnected == false) {
                Log.d("GhostChat", "[ChatViewModel] onRejoinOk — ICE not restored, retrying restart")
                // ICE до сих пор не восстановлен — повторяем restart
                viewModelScope.launch {
                    val offer = rtc?.restartIce()
                    if (offer != null) {
                        Log.d("GhostChat", "[ChatViewModel] onRejoinOk — restart offer created, sending")
                        signaling?.sendSignal(JSONObject().apply {
                            put("type", "offer")
                            put("sdp", GhostRTC.sdpToJson(offer))
                        })
                    } else {
                        Log.e("GhostChat", "[ChatViewModel] onRejoinOk — restart offer creation failed")
                    }
                }
            } else {
                Log.d("GhostChat", "[ChatViewModel] onRejoinOk — no action needed (already connected)")
            }
        }

        signaling?.onPeerJoined = {
            Log.d("GhostChat", "[ChatViewModel] onPeerJoined — isRotatingRoom=$isRotatingRoom, isHost=$isHost, screen=$screen")
            // Ignore peer-joined during room rotation (server sends it when peer rejoins new room)
            if (!isRotatingRoom) {
                Log.d("GhostChat", "[ChatViewModel] onPeerJoined — cancelling peerLeft timeout, moving to CONNECTING")
                // Пир вернулся — отменяем таймаут ожидания
                peerLeftRunnable?.let { mainHandler.removeCallbacks(it) }
                peerLeftRunnable = null
                isConnected = false
                showPeerDisconnectedBanner = false
                peerStatus = PeerStatus.CONNECTING
                peerStatusTransitionRunnable?.let { mainHandler.removeCallbacks(it) }
                peerStatusTransitionRunnable = null
                connectionStep = ConnectionStep.WAITING_FOR_PEER
                if (screen != Screen.CHAT) {
                    screen = Screen.CONNECTING
                }
                startConnectionTimeout()
                if (isHost) {
                    Log.d("GhostChat", "[ChatViewModel] onPeerJoined — isHost=true, starting WebRTC connection")
                    viewModelScope.launch { startWebRTCConnection() }
                } else {
                    Log.d("GhostChat", "[ChatViewModel] onPeerJoined — isHost=false, waiting for offer")
                }
            } else {
                Log.d("GhostChat", "[ChatViewModel] onPeerJoined — ignored (room rotation in progress)")
            }
        }

        signaling?.onPeerLeft = {
            Log.d("GhostChat", "[ChatViewModel] onPeerLeft — screen=$screen, isConnected=$isConnected, roomId=${roomId?.take(8)}")
            isConnected = false
            showPeerDisconnectedBanner = true
            addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_peer_disconnected))

            // Set peer status to recentlyOnline → offline after 5 min
            peerLastSeenAt = System.currentTimeMillis()
            peerStatus = PeerStatus.RECENTLY_ONLINE
            peerStatusTransitionRunnable?.let { mainHandler.removeCallbacks(it) }
            val statusRunnable = Runnable {
                if (!isConnected) peerStatus = PeerStatus.OFFLINE
            }
            peerStatusTransitionRunnable = statusRunnable
            mainHandler.postDelayed(statusRunnable, 300_000L)

            // If still in connecting/waiting screen — peer left before connection established
            if ((screen == Screen.CONNECTING || screen == Screen.WAITING) && currentPeerContact == null) {
                Log.d("GhostChat", "[ChatViewModel] onPeerLeft — peer left during CONNECTING/WAITING, leaving room")
                addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_peer_gone))
                leave()
            } else {
                Log.d("GhostChat", "[ChatViewModel] onPeerLeft — scheduling 60s reconnect timeout, currentPeerContact=${currentPeerContact?.label}")

            // Ждём reconnect — пир может вернуться через rejoin-room (15s)
            peerLeftRunnable?.let { mainHandler.removeCallbacks(it) }
            val runnable = Runnable {
                peerLeftRunnable = null
                if (roomId != null && !isConnected) {
                    // Saved contact chat — stay in chat, just show disconnected banner
                    // Don't leave() — user can navigate back manually or peer will reconnect later
                    if (currentPeerContact != null || screen == Screen.CHAT) {
                        Log.d("GhostChat", "[ChatViewModel] onPeerLeft timeout — contact chat, staying in CHAT with banner")
                        showPeerDisconnectedBanner = true
                        peerStatus = PeerStatus.OFFLINE
                        // Cleanup signaling/rtc to allow fresh autoConnect on next interaction
                        signaling?.leaveRoom()
                        signaling?.disconnect()
                        signaling = null
                        rtc?.destroy()
                        rtc = null
                        crypto?.destroy()
                        crypto = null
                        keyExchangeCompleted = false
                        roomId = null
                        return@Runnable
                    }
                    addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_peer_gone))
                    leave()
                }
            }
            peerLeftRunnable = runnable
            mainHandler.postDelayed(runnable, 60000)
            }
        }

        signaling?.onSignal = { data ->
            val signalType = data.optString("type", "unknown")
            Log.d("GhostChat", "[ChatViewModel] onSignal type=$signalType")
            viewModelScope.launch { handleSignal(data) }
        }

        signaling?.onError = { message ->
            Log.e("GhostChat", "[ChatViewModel] signaling onError: $message")
            if (screen == Screen.CHAT && currentPeerContact != null) {
                Log.d("GhostChat", "[ChatViewModel] signaling onError — in CHAT with contact, silently ignoring")
            } else {
                addSystemMessage(message)
            }
        }

        signaling?.onDisconnected = {
            Log.d("GhostChat", "[ChatViewModel] signaling onDisconnected — roomId=${roomId?.take(8)}, isConnected=$isConnected")
            val rid = roomId
            if (rid != null && !isConnected) {
                Log.d("GhostChat", "[ChatViewModel] signaling onDisconnected — scheduling reconnect")
                signaling?.scheduleReconnect(rid, isHost)
            } else {
                Log.d("GhostChat", "[ChatViewModel] signaling onDisconnected — no reconnect (roomId=${rid != null}, isConnected=$isConnected)")
            }
        }
    }

    // MARK: - RTC Callbacks

    private fun setupRTCCallbacks() {
        Log.d("GhostChat", "[ChatViewModel] setupRTCCallbacks")
        rtc?.onConnected = onConnected@{
            Log.d("GhostChat", "[ChatViewModel] RTC onConnected, wasConnected=$isConnected, keyExchangeCompleted=$keyExchangeCompleted, isHost=$isHost")
            cancelConnectionTimeout()

            val wasConnected = isConnected
            isConnected = true

            if (!wasConnected && !keyExchangeCompleted) {
                Log.d("GhostChat", "[ChatViewModel] RTC onConnected — FIRST connection, starting key exchange")
                // First connection — exchange keys
                val pubKey = crypto?.exportPublicKey() ?: run {
                    Log.e("GhostChat", "[ChatViewModel] RTC onConnected — crypto.exportPublicKey() returned null, aborting")
                    return@onConnected
                }
                Log.d("GhostChat", "[ChatViewModel] RTC onConnected — publicKey exported, building key-exchange message")

                val msg = JSONObject().apply {
                    put("type", "key-exchange")
                    put("publicKey", pubKey)
                    put("identityKey", IdentityKeyService.exportPublicKey())
                    put("v", GhostCrypto.PROTOCOL_VERSION)
                    put("platform", "android")
                }

                // DTLS fingerprint for transport binding (anti-MITM)
                try {
                    val localSdp = rtc?.peerConnection?.localDescription?.description ?: ""
                    val regex = Regex("""a=fingerprint:sha-256\s+([^\r\n]+)""")
                    val dtlsFp = regex.find(localSdp)?.groupValues?.getOrNull(1)?.trim()
                    if (dtlsFp != null) {
                        msg.put("dtls", dtlsFp)
                        Log.d("GhostChat", "[ChatViewModel] RTC onConnected — DTLS fingerprint found")
                    } else {
                        Log.d("GhostChat", "[ChatViewModel] RTC onConnected — no DTLS fingerprint in SDP")
                    }
                } catch (e: Exception) {
                    Log.d("GhostChat", "[ChatViewModel] RTC onConnected — DTLS extraction error: ${e.message}")
                }

                // Guest: DH ratchet key
                if (!isHost) {
                    val dhKey = crypto?.exportDHRatchetKey()
                    Log.d("GhostChat", "[ChatViewModel] RTC onConnected — guest DH ratchet key: ${if (dhKey != null) "present" else "null"}")
                    dhKey?.let { msg.put("dhRatchetKey", it) }
                }

                Log.d("GhostChat", "[ChatViewModel] RTC onConnected — sending key-exchange message")
                rtc?.send(msg.toString())
            } else if (wasConnected || keyExchangeCompleted) {
                Log.d("GhostChat", "[ChatViewModel] RTC onConnected — RECONNECTION (wasConnected=$wasConnected, keyExchangeCompleted=$keyExchangeCompleted)")
                // Reconnection (ICE restart) — connection restored
                addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_connection_restored))
                // Peer reconnected — restore online status
                isConnected = true
                peerStatus = PeerStatus.ONLINE
                peerLastSeenAt = 0L
                peerStatusTransitionRunnable?.let { mainHandler.removeCallbacks(it) }
                peerStatusTransitionRunnable = null
                // Flush messages queued while disconnected (ICE restart reconnect)
                viewModelScope.launch { flushPendingMessages() }
            }
        }

        rtc?.onMessage = { data ->
            Log.d("GhostChat", "[ChatViewModel] RTC onMessage — dataSize=${data.length}")
            viewModelScope.launch { handleP2PMessage(data) }
        }

        rtc?.onDisconnected = {
            Log.d("GhostChat", "[ChatViewModel] RTC onDisconnected, wasConnected=$isConnected, callState=$callState")
            if (isConnected) {
                addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_connection_lost))
                isConnected = false
                // Clear active contact for push suppression — user is no longer in active chat
                GhostFirebaseService.activeContactChatId = null
                GhostFirebaseService.activeContactName = null
                // Reset typing indicator — peer can't be typing if disconnected
                peerIsTyping = false
                peerTypingCancelRunnable?.let { mainHandler.removeCallbacks(it) }
                peerTypingCancelRunnable = null
                // Set peer status to recentlyOnline → offline after 5 min
                peerLastSeenAt = System.currentTimeMillis()
                peerStatus = PeerStatus.RECENTLY_ONLINE
                peerStatusTransitionRunnable?.let { mainHandler.removeCallbacks(it) }
                val statusRunnable = Runnable {
                    if (!isConnected) peerStatus = PeerStatus.OFFLINE
                }
                peerStatusTransitionRunnable = statusRunnable
                mainHandler.postDelayed(statusRunnable, 300_000L)
                // End active call — audio resources leak if not cleaned up
                if (callState != CallUIState.IDLE) {
                    Log.d("GhostChat", "[ChatViewModel] RTC onDisconnected — ending active call (callState=$callState)")
                    stopIncomingCallVibration()
                    cancelRingingTimeout()
                    voice?.endCall()
                    voice?.destroy()
                    voice = null
                    callState = CallUIState.IDLE
                    isMuted = false
                    isSpeakerOn = false
                    GhostConnectionService.activeConnection?.remoteEnd()
                    addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_call_ended))
                }
            } else {
                Log.d("GhostChat", "[ChatViewModel] RTC onDisconnected — was not connected, ignoring")
            }
        }

        rtc?.onIceCandidate = { candidate ->
            Log.d("GhostChat", "[ChatViewModel] RTC onIceCandidate — sdpMid=${candidate.sdpMid}")
            val candidateJson = GhostRTC.candidateToJson(candidate)
            signaling?.sendSignal(JSONObject().apply {
                put("type", "ice-candidate")
                put("candidate", candidateJson)
            })
        }

        rtc?.onError = { error ->
            Log.e("GhostChat", "[ChatViewModel] RTC onError: $error")
            addSystemMessage(error)
        }

        rtc?.onTrack = { stream ->
            Log.d("GhostChat", "[ChatViewModel] RTC onTrack — audioTracks=${stream.audioTracks?.size}, hasVoice=${voice != null}")
            // Remote audio track received — WebRTC handles playback automatically on Android
            // Buffer the stream if voice not yet initialized
            if (voice != null) {
                Log.d("GhostChat", "[ChatViewModel] RTC onTrack — voice exists, WebRTC handles playback")
                // Voice exists, track will be handled by WebRTC layer
            } else {
                Log.d("GhostChat", "[ChatViewModel] RTC onTrack — voice not initialized, buffering stream")
                pendingRemoteStream = stream
            }
        }

        rtc?.onRenegotiationNeeded = { offer ->
            Log.d("GhostChat", "[ChatViewModel] RTC onRenegotiationNeeded — sending renegotiation offer")
            viewModelScope.launch { handleLocalRenegotiationOffer(offer) }
        }

        // ICE restart offer goes through signaling server (not DataChannel!)
        // DataChannel rides on the same ICE transport that just broke
        rtc?.onIceRestartNeeded = { offer ->
            Log.d("GhostChat", "[ChatViewModel] RTC onIceRestartNeeded — signalingConnected=${signaling?.isConnected}")
            if (signaling?.isConnected == true) {
                Log.d("GhostChat", "[ChatViewModel] RTC onIceRestartNeeded — sending ICE restart via signaling")
                signaling?.sendSignal(JSONObject().apply {
                    put("type", "offer")
                    put("sdp", GhostRTC.sdpToJson(offer))
                })
            } else {
                Log.d("GhostChat", "[ChatViewModel] RTC onIceRestartNeeded — WS not connected, buffering offer")
                // WS не подключен — буферизуем для отправки после reconnect
                pendingIceRestartOffer = offer
            }
        }
    }

    // MARK: - WebRTC Connection

    private suspend fun startWebRTCConnection() {
        Log.d("GhostChat", "[ChatViewModel] startWebRTCConnection called")
        val turnCreds = try {
            val creds = turnService?.fetchCredentials()
            Log.d("GhostChat", "[ChatViewModel] startWebRTCConnection — TURN creds fetched: ${creds != null}")
            // Save push auth token for authenticated push requests
            creds?.pushAuth?.let { pushAuthToken = it }
            creds
        } catch (e: Exception) {
            Log.e("GhostChat", "[ChatViewModel] startWebRTCConnection — TURN fetch failed: ${e.message}")
            null
        }

        val offer = rtc?.initAsHost(turnCreds) ?: run {
            Log.e("GhostChat", "[ChatViewModel] startWebRTCConnection — initAsHost returned null, aborting")
            return
        }
        Log.d("GhostChat", "[ChatViewModel] startWebRTCConnection — offer created, sending via signaling")

        signaling?.sendSignal(JSONObject().apply {
            put("type", "offer")
            put("sdp", GhostRTC.sdpToJson(offer))
        })
    }

    private suspend fun initAsGuest() {
        Log.d("GhostChat", "[ChatViewModel] initAsGuest called")
        val turnCreds = try {
            val creds = turnService?.fetchCredentials()
            Log.d("GhostChat", "[ChatViewModel] initAsGuest — TURN creds fetched: ${creds != null}")
            // Save push auth token for authenticated push requests
            creds?.pushAuth?.let { pushAuthToken = it }
            creds
        } catch (e: Exception) {
            Log.e("GhostChat", "[ChatViewModel] initAsGuest — TURN fetch failed: ${e.message}")
            null
        }

        rtc?.initAsGuest(turnCreds)

        // Flush signals that arrived while PeerConnection was being created
        val buffered = pendingSignals.toList()
        Log.d("GhostChat", "[ChatViewModel] initAsGuest — flushing ${buffered.size} buffered signals")
        pendingSignals.clear()
        for (signal in buffered) {
            handleSignal(signal)
        }
    }

    // MARK: - Signal Handling

    private suspend fun handleSignal(data: JSONObject) {
        val signalType = data.optString("type", "unknown")
        Log.d("GhostChat", "[ChatViewModel] handleSignal type=$signalType")
        // Buffer signals if PeerConnection not ready yet (race: offer arrives before initAsGuest completes)
        if (rtc?.peerConnection == null) {
            if (pendingSignals.size > 100) {
                Log.w("GhostChat", "[ChatViewModel] handleSignal — pendingSignals overflow (${pendingSignals.size}), clearing buffer")
                pendingSignals.clear()
            }
            Log.d("GhostChat", "[ChatViewModel] handleSignal buffered (PC not ready)")
            pendingSignals.add(data)
            return
        }

        when (signalType) {
            "offer" -> {
                Log.d("GhostChat", "[ChatViewModel] handleSignal — processing offer")
                val sdpJson = data.optJSONObject("sdp") ?: run {
                    Log.e("GhostChat", "[ChatViewModel] handleSignal offer — missing sdp field")
                    return
                }
                val sdp = GhostRTC.jsonToSdp(sdpJson) ?: run {
                    Log.e("GhostChat", "[ChatViewModel] handleSignal offer — failed to parse SDP")
                    return
                }
                val answer = rtc?.handleOffer(sdp) ?: run {
                    Log.e("GhostChat", "[ChatViewModel] handleSignal offer — handleOffer returned null")
                    return
                }
                Log.d("GhostChat", "[ChatViewModel] handleSignal offer — answer created, sending")

                signaling?.sendSignal(JSONObject().apply {
                    put("type", "answer")
                    put("sdp", GhostRTC.sdpToJson(answer))
                })

                // Flush pending ICE candidates
                Log.d("GhostChat", "[ChatViewModel] handleSignal offer — flushing ${pendingIceCandidates.size} pending ICE candidates")
                for (candidate in pendingIceCandidates) {
                    rtc?.addIceCandidate(candidate)
                }
                pendingIceCandidates.clear()
            }

            "answer" -> {
                Log.d("GhostChat", "[ChatViewModel] handleSignal — processing answer")
                val sdpJson = data.optJSONObject("sdp") ?: run {
                    Log.e("GhostChat", "[ChatViewModel] handleSignal answer — missing sdp field")
                    return
                }
                val sdp = GhostRTC.jsonToSdp(sdpJson) ?: run {
                    Log.e("GhostChat", "[ChatViewModel] handleSignal answer — failed to parse SDP")
                    return
                }
                rtc?.handleAnswer(sdp)
                Log.d("GhostChat", "[ChatViewModel] handleSignal answer — answer handled")
            }

            "ice-candidate" -> {
                val candidateJson = data.optJSONObject("candidate") ?: run {
                    Log.e("GhostChat", "[ChatViewModel] handleSignal ice-candidate — missing candidate field")
                    return
                }
                val candidate = GhostRTC.jsonToCandidate(candidateJson) ?: run {
                    Log.e("GhostChat", "[ChatViewModel] handleSignal ice-candidate — failed to parse candidate")
                    return
                }

                val hasRemoteDesc = rtc?.peerConnection?.remoteDescription != null
                Log.d("GhostChat", "[ChatViewModel] handleSignal ice-candidate — hasRemoteDescription=$hasRemoteDesc")
                if (hasRemoteDesc) {
                    rtc?.addIceCandidate(candidate)
                } else {
                    Log.d("GhostChat", "[ChatViewModel] handleSignal ice-candidate — queued (no remote description yet)")
                    pendingIceCandidates.add(candidate)
                }
            }

            else -> {
                Log.d("GhostChat", "[ChatViewModel] handleSignal — unknown signal type: $signalType")
            }
        }
    }

    // MARK: - Key Exchange

    private suspend fun handleKeyExchange(json: JSONObject) {
        Log.d("GhostChat", "[ChatViewModel] handleKeyExchange called, alreadyCompleted=$keyExchangeCompleted")
        connectionStep = ConnectionStep.EXCHANGING_KEYS
        if (keyExchangeCompleted) return

        val peerPublicKey = json.optString("publicKey", "")
        if (peerPublicKey.isEmpty()) {
            Log.e("GhostChat", "[ChatViewModel] handleKeyExchange — empty publicKey")
            return
        }

        // Version check
        val peerVersion = json.optInt("v", 1)
        Log.d("GhostChat", "[ChatViewModel] handleKeyExchange — peerVersion=$peerVersion (min required=2)")
        if (peerVersion < 2) {
            Log.e("GhostChat", "[ChatViewModel] handleKeyExchange — incompatible version $peerVersion, aborting")
            addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_incompatible_version))
            return
        }

        // Detect native app peer (iOS/Android send 'ios'/'android', web sends 'web')
        val platform = json.optString("platform", "")
        Log.d("GhostChat", "[ChatViewModel] handleKeyExchange — platform='$platform'")
        if (platform.isNotEmpty()) {
            peerIsNativeApp = (platform != "web")
            Log.d("GhostChat", "[ChatViewModel] handleKeyExchange — peerIsNativeApp=$peerIsNativeApp")
        }

        // v3: Identity key for contact recognition
        val idKeyBase64 = json.optString("identityKey", "")
        Log.d("GhostChat", "[ChatViewModel] handleKeyExchange — identityKey present=${idKeyBase64.isNotEmpty()}")
        if (idKeyBase64.isNotEmpty()) {
            try {
                val idKeyData = android.util.Base64.decode(idKeyBase64, android.util.Base64.DEFAULT)
                peerIdentityKeyData = idKeyData
                Log.d("GhostChat", "[ChatViewModel] handleKeyExchange — identity key decoded, size=${idKeyData.size}")

                // Check if we know this peer
                val knownContact = contactStore?.fetchByIdentityKey(idKeyData)
                if (knownContact != null) {
                    Log.d("GhostChat", "[ChatViewModel] handleKeyExchange — KNOWN contact: ${knownContact.label} (id=${knownContact.id.take(8)})")
                    currentPeerContact = knownContact
                    currentContactId = knownContact.id
                    GhostFirebaseService.activeContactChatId = knownContact.id
                    GhostFirebaseService.activeContactName = knownContact.label
                    addSystemMessage(
                        appContext.getString(com.ghost.chat.R.string.system_known_peer, knownContact.label)
                    )
                } else {
                    Log.d("GhostChat", "[ChatViewModel] handleKeyExchange — UNKNOWN peer (no matching contact)")
                }

                // Verify against expected peer — abort on mismatch (MITM protection)
                val expected = expectedPeerIdentityKey
                Log.d("GhostChat", "[ChatViewModel] handleKeyExchange — expectedPeerIdentityKey present=${expected != null}")
                if (expected != null && !expected.contentEquals(idKeyData)) {
                    Log.e("GhostChat", "[ChatViewModel] handleKeyExchange — IDENTITY KEY MISMATCH! Possible MITM. Aborting.")
                    addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_unexpected_peer))
                    securityAlert = appContext.getString(com.ghost.chat.R.string.system_unexpected_peer)
                    addSystemMessage("⛔ Identity key mismatch — соединение разорвано для безопасности")
                    leave()
                    return
                } else if (expected != null) {
                    Log.d("GhostChat", "[ChatViewModel] handleKeyExchange — identity key MATCHES expected peer")
                }
            } catch (e: Exception) {
                Log.e("GhostChat", "[ChatViewModel] handleKeyExchange — identity key processing error: ${e.message}")
            }
        }

        // Import peer's public key
        try {
            crypto?.importPeerPublicKey(peerPublicKey)
            Log.d("GhostChat", "[ChatViewModel] handleKeyExchange — peer key imported")
        } catch (e: Exception) {
            Log.e("GhostChat", "[ChatViewModel] handleKeyExchange — import key error: ${e.message}")
            addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_key_exchange_error))
            return
        }

        // Derive shared key with Double Ratchet
        try {
            crypto?.deriveSharedKey(asHost = isHost)
            Log.d("GhostChat", "[ChatViewModel] handleKeyExchange — shared key derived")
        } catch (e: Exception) {
            Log.e("GhostChat", "[ChatViewModel] handleKeyExchange — derive key error: ${e.message}")
            addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_key_exchange_error))
            return
        }

        Log.d("GhostChat", "[ChatViewModel] handleKeyExchange — completing key exchange")
        completeKeyExchange()
    }

    private fun completeKeyExchange() {
        Log.d("GhostChat", "[ChatViewModel] completeKeyExchange called, isHost=$isHost, hasVoice=${voice != null}")

        // CRITICAL: Destroy old GhostVoice on every new key exchange.
        // After reconnect, PeerConnection is NEW but old voice holds reference to dead PC.
        // Clearing voice ensures startCall() creates fresh GhostVoice with new PeerConnection.
        if (voice != null) {
            Log.d("GhostChat", "[ChatViewModel] completeKeyExchange: destroying stale voice (reconnect)")
            voice?.endCall()
            voice?.destroy()
            voice = null
        }
        keyExchangeCompleted = true
        fingerprint = try { crypto?.generateFingerprint() ?: "" } catch (e: Exception) { Log.e("GhostChat", "[ChatViewModel] completeKeyExchange — fingerprint generation failed: ${e.message}"); "" }
        Log.d("GhostChat", "[ChatViewModel] completeKeyExchange — fingerprint generated: ${fingerprint.take(12)}...")
        connectionStep = ConnectionStep.SECURED
        showPeerDisconnectedBanner = false
        isConnected = true
        peerStatus = PeerStatus.ONLINE
        peerLastSeenAt = 0L
        peerStatusTransitionRunnable?.let { mainHandler.removeCallbacks(it) }
        peerStatusTransitionRunnable = null
        // Brief delay to show "secured" step before transitioning to chat (same as iOS)
        // Guard: only transition if still in connecting/waiting — if already CHAT (reconnect) or
        // if user left (WELCOME), don't override
        mainHandler.postDelayed({
            if (screen == Screen.CONNECTING || screen == Screen.WAITING) {
                screen = Screen.CHAT
            }
        }, 800)
        Log.d("GhostChat", "[ChatViewModel] completeKeyExchange — connectionStep=SECURED, isConnected=true")

        addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_secure_connection))
        addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_tap_shield))

        Log.d("GhostChat", "[ChatViewModel] completeKeyExchange — starting security monitoring + message cleanup")
        startSecurityMonitoring()
        startMessageCleanup()

        // Contact auto-save — platform field in key-exchange is already available
        Log.d("GhostChat", "[ChatViewModel] completeKeyExchange — handling contact auto-save")
        handleContactAutoSave()

        // HOST: Send bootstrap message to initialize guest's Double Ratchet
        if (isHost) {
            Log.d("GhostChat", "[ChatViewModel] completeKeyExchange — HOST: sending Ready bootstrap message")
            viewModelScope.launch { sendEncryptedControl(ControlMessage.Ready) }
        }

        // Send FCM push token to peer (for offline calls/invites)
        // Android uses same FCM token for both VoIP-style calls and chat invites
        Log.d("GhostChat", "[ChatViewModel] completeKeyExchange — hasFCMToken=${localFcmToken != null}")
        localFcmToken?.let { token ->
            Log.d("GhostChat", "[ChatViewModel] completeKeyExchange — sending push + notify tokens to peer")
            tokensSentToPeerThisSession = true
            viewModelScope.launch {
                sendEncryptedControl(ControlMessage.PushToken(token))
                sendEncryptedControl(ControlMessage.NotifyToken(token))
            }
        }

        // Send capabilities (file-transfer support)
        Log.d("GhostChat", "[ChatViewModel] completeKeyExchange — sending capabilities")
        viewModelScope.launch { sendEncryptedControl(ControlMessage.Capabilities(listOf("file-transfer"))) }

        // Wire up file transfer callbacks
        setupFileTransferCallbacks()

        // Flush pending messages that were queued while offline
        Log.d("GhostChat", "[ChatViewModel] completeKeyExchange — flushing pending messages")
        viewModelScope.launch { flushPendingMessages() }

        // If user tapped Accept in system call UI before P2P was ready, fire the
        // buffered accept now (symmetric with iOS pendingAcceptCall flush).
        if (pendingAcceptCall) {
            Log.d("GhostChat", "[ChatViewModel] completeKeyExchange — flushing pendingAcceptCall")
            pendingAcceptCall = false
            mainHandler.postDelayed({ acceptCall() }, 200)
        }

        // Start room rotation timer (host only — forward secrecy at signaling level)
        if (isHost) {
            Log.d("GhostChat", "[ChatViewModel] completeKeyExchange — HOST: starting room rotation timer")
            startRoomRotationTimer()
        }
        Log.d("GhostChat", "[ChatViewModel] completeKeyExchange complete")
    }

    // MARK: - Typing Indicator

    /** Called on every keystroke in the input field */
    fun userIsTyping() {
        Log.d("GhostChat", "[ChatViewModel] userIsTyping called, isConnected=$isConnected, keyExchangeCompleted=$keyExchangeCompleted")
        if (!isConnected || !keyExchangeCompleted) {
            return
        }

        val now = System.currentTimeMillis()
        // Throttle: send at most every 3 seconds
        if (now - lastTypingSentAt >= 3000) {
            lastTypingSentAt = now
            viewModelScope.launch { sendEncryptedControl(ControlMessage.Typing(true)) }
        }

        // Auto-cancel after 5 seconds of no typing
        typingCancelRunnable?.let { mainHandler.removeCallbacks(it) }
        typingCancelRunnable = Runnable { stopTyping() }
        mainHandler.postDelayed(typingCancelRunnable!!, 5000)
    }

    /** Send typing:false immediately */
    fun stopTyping() {
        Log.d("GhostChat", "[ChatViewModel] stopTyping called")
        typingCancelRunnable?.let { mainHandler.removeCallbacks(it) }
        typingCancelRunnable = null
        lastTypingSentAt = 0
        if (isConnected && keyExchangeCompleted) {
            viewModelScope.launch { sendEncryptedControl(ControlMessage.Typing(false)) }
        }
    }

    /** Handle peer typing indicator */
    private fun handlePeerTyping(isTyping: Boolean) {
        Log.d("GhostChat", "[ChatViewModel] handlePeerTyping called, isTyping=$isTyping")
        peerIsTyping = isTyping
        // Auto-clear after 6 seconds without update
        peerTypingCancelRunnable?.let { mainHandler.removeCallbacks(it) }
        if (isTyping) {
            peerTypingCancelRunnable = Runnable { peerIsTyping = false }
            mainHandler.postDelayed(peerTypingCancelRunnable!!, 6000)
        }
    }

    // MARK: - Message Sending

    fun sendMessage(text: String) {
        Log.d("GhostChat", "[ChatViewModel] sendMessage called, textLength=${text.trim().length}, isConnected=$isConnected, keyExchangeCompleted=$keyExchangeCompleted, cryptoReady=${crypto?.isReady}, isSavedMessagesMode=$isSavedMessagesMode")
        val trimmed = text.trim()
        if (trimmed.isEmpty()) {
            Log.d("GhostChat", "[ChatViewModel] sendMessage — empty text, returning")
            return
        }

        // Capture reply state before clearing
        val reply = replyingTo
        replyingTo = null

        // Saved Messages mode — just save locally, no P2P
        if (isSavedMessagesMode) {
            Log.d("GhostChat", "[ChatViewModel] sendMessage — saved messages mode, saving locally")
            addMessage(trimmed, ChatMessage.MessageType.SENT,
                replyToId = reply?.senderMessageId ?: reply?.id,
                replyToText = reply?.text?.take(100))
            return
        }

        // Offline mode — peer not connected, queue message
        // Room is already created by autoConnectToContact(), just queue
        if (!isConnected) {
            ghostLog("[ChatViewModel] sendMessage — not connected, queuing message", appContext)
            queuePendingMessage(trimmed)
            // If no room yet (shouldn't happen), create one
            if (roomId == null) {
                val contact = currentPeerContact
                if (contact != null) {
                    viewModelScope.launch { autoConnectToContact(contact) }
                }
            }
            // Send push notification to wake peer up about pending message
            viewModelScope.launch { sendOfflineMessagePush() }
            return
        }

        // Stop typing indicator on send
        stopTyping()

        // Sender's message UUID for cross-device delete/edit correlation
        val senderMsgId = java.util.UUID.randomUUID().toString()

        viewModelScope.launch {
            try {
                val options = mutableMapOf<String, Any>("id" to senderMsgId)
                if (reply != null) {
                    options["r"] = JSONObject().apply {
                        put("id", reply.senderMessageId ?: reply.id)
                        put("t", reply.text.take(100))
                    }
                }

                val encrypted = crypto?.encrypt(trimmed, options)
                    ?: throw Exception("Crypto not ready")

                val msg = JSONObject().apply {
                    put("type", "encrypted-message")
                    put("data", encrypted)
                    put("v", 2)
                }
                rtc?.send(msg.toString())

                // Add to UI
                val chatMsg = addMessage(trimmed, ChatMessage.MessageType.SENT,
                    replyToId = reply?.senderMessageId ?: reply?.id,
                    replyToText = reply?.text?.take(100),
                    senderMessageId = senderMsgId)

                // Track for delivery ACK
                crypto?.messageCounter?.let { counter ->
                    sentMessages[counter.toInt()] = SentRecord(chatMsg.id, System.currentTimeMillis())
                }
            } catch (e: Exception) {
                Log.e("GhostChat", "[ChatViewModel] sendMessage error: ${e.message}")
                addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_send_error))
            }
        }
    }

    // MARK: - File Transfer

    fun sendFile(uri: Uri) {
        Log.d("GhostChat", "[ChatViewModel] sendFile called, uri=$uri, isSavedMessages=$isSavedMessagesMode, isConnected=$isConnected")
        // Saved Messages mode — save locally without P2P
        if (isSavedMessagesMode) {
            Log.d("GhostChat", "[ChatViewModel] sendFile — saved messages mode")
            val resolver = appContext.contentResolver
            val data = resolver.openInputStream(uri)?.use { it.readBytes() } ?: return
            val fileName = fileTransfer.let {
                var name = "file"
                resolver.query(uri, null, null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val idx = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                        if (idx >= 0) name = cursor.getString(idx)
                    }
                }
                name
            }
            val result = fileTransfer.saveFileLocally(data, fileName) ?: return
            val chatMsg = ChatMessage(
                contactId = currentContactId,
                text = "$fileName (${FileTransferService.formatSize(data.size.toLong())})",
                type = ChatMessage.MessageType.SENT,
                fileName = fileName,
                fileSize = data.size.toLong(),
                fileMimeType = result.mimeType,
                fileLocalPath = result.localPath,
                fileId = result.fileId
            )
            messages.add(chatMsg)
            viewModelScope.launch(Dispatchers.IO) {
                messageStore?.save(chatMsg)
            }
            return
        }

        if (!isConnected) {
            Log.d("GhostChat", "[ChatViewModel] sendFile — BLOCKED: not connected")
            addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_not_connected))
            return
        }
        if (!peerSupportsFiles) {
            Log.d("GhostChat", "[ChatViewModel] sendFile — BLOCKED: peer does not support files")
            addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_peer_no_files))
            return
        }

        Log.d("GhostChat", "[ChatViewModel] sendFile — starting file transfer, crypto=${crypto != null}, rtcConnected=${rtc?.isConnected}")
        val result = fileTransfer.sendFile(uri) ?: run {
            Log.e("GhostChat", "[ChatViewModel] sendFile — fileTransfer.sendFile returned null")
            return
        }
        Log.d("GhostChat", "[ChatViewModel] sendFile — started fileId=${result.fileId}, name=${result.fileName}, size=${result.fileSize}")

        val ttlMs = autoDeleteMinutes * 60_000L
        val chatMsg = ChatMessage(
            contactId = currentContactId,
            text = "${result.fileName} (${FileTransferService.formatSize(result.fileSize)})",
            type = ChatMessage.MessageType.SENT,
            expiresAt = if (isSavedMessagesMode || ttlMs <= 0) null else Date(System.currentTimeMillis() + ttlMs),
            fileName = result.fileName,
            fileSize = result.fileSize,
            fileMimeType = result.mimeType,
            fileLocalPath = result.localPath,
            fileTransferProgress = 0.0,
            fileId = result.fileId
        )
        messages.add(chatMsg)
    }

    private fun setupFileTransferCallbacks() {
        Log.d("GhostChat", "[ChatViewModel] setupFileTransferCallbacks called")
        fileTransfer.onSendControl = { control ->
            viewModelScope.launch { sendEncryptedControl(control) }
        }
        // CRITICAL: async callback for file chunks — actually AWAITS encrypt+send.
        // Previously sendFile queued all chunks onto Main dispatcher without real
        // backpressure; large files blew up the coroutine queue.
        fileTransfer.onSendControlAsync = { control ->
            sendEncryptedControl(control)
        }
        // Backpressure: provide DataChannel bufferedAmount for file transfer throttling
        fileTransfer.bufferedAmountProvider = {
            rtc?.bufferedAmount ?: 0L
        }

        fileTransfer.onSendProgress = { fileId, progress ->
            mainHandler.post {
                val idx = messages.indexOfFirst { it.fileId == fileId && it.type == ChatMessage.MessageType.SENT }
                if (idx >= 0) {
                    messages[idx] = messages[idx].copy(fileTransferProgress = if (progress < 1.0) progress else null)
                }
            }
        }

        fileTransfer.onReceiveProgress = { fileId, progress ->
            mainHandler.post {
                val idx = messages.indexOfFirst { it.fileId == fileId && it.type == ChatMessage.MessageType.RECEIVED }
                if (idx >= 0) {
                    messages[idx] = messages[idx].copy(fileTransferProgress = progress)
                }
            }
        }

        fileTransfer.onFileReceived = { fileId, localPath, fileName, fileSize, mimeType ->
            mainHandler.post {
                val idx = messages.indexOfFirst { it.fileId == fileId && it.type == ChatMessage.MessageType.RECEIVED }
                if (idx >= 0) {
                    messages[idx] = messages[idx].copy(fileLocalPath = localPath, fileTransferProgress = null)
                    if (saveMessageHistory) {
                        viewModelScope.launch(Dispatchers.IO) {
                            messageStore?.save(messages[idx])
                        }
                    }
                }
            }
        }

        fileTransfer.onFileSent = { fileId ->
            mainHandler.post {
                val idx = messages.indexOfFirst { it.fileId == fileId && it.type == ChatMessage.MessageType.SENT }
                if (idx >= 0) {
                    messages[idx] = messages[idx].copy(fileTransferProgress = null)
                    if (saveMessageHistory) {
                        viewModelScope.launch(Dispatchers.IO) {
                            messageStore?.save(messages[idx])
                        }
                    }
                }
            }
        }

        fileTransfer.onFileError = { fileId, errorMsg ->
            Log.e("GhostChat", "[ChatViewModel] File transfer error — fileId=$fileId, error=$errorMsg")
            mainHandler.post {
                addSystemMessage("⚠️ File transfer error: $errorMsg")
                // Clear progress on the failed file message
                val idx = messages.indexOfFirst { it.fileId == fileId }
                if (idx >= 0) {
                    messages[idx] = messages[idx].copy(fileTransferProgress = null)
                }
            }
        }
    }

    // MARK: - Message Receiving

    private suspend fun handleP2PMessage(data: String) {
        try {
            val json = JSONObject(data)
            val msgType = json.optString("type", "")
            Log.d("GhostChat", "[ChatViewModel] handleP2PMessage — type='$msgType'")
            when (msgType) {
                "key-exchange" -> {
                    Log.d("GhostChat", "[ChatViewModel] handleP2PMessage — dispatching to handleKeyExchange")
                    handleKeyExchange(json)
                }
                "encrypted-message" -> {
                    val encryptedData = json.optString("data", "")
                    val version = json.optInt("v", 0)
                    Log.d("GhostChat", "[ChatViewModel] handleP2PMessage — encrypted-message, dataLength=${encryptedData.length}, v=$version")
                    if (encryptedData.isNotEmpty()) {
                        handleEncryptedMessage(encryptedData)
                    } else {
                        Log.e("GhostChat", "[ChatViewModel] handleP2PMessage — encrypted-message with empty data")
                    }
                }
                else -> {
                    Log.d("GhostChat", "[ChatViewModel] handleP2PMessage — unknown type: '$msgType'")
                }
            }
        } catch (e: Exception) {
            Log.e("GhostChat", "[ChatViewModel] handleP2PMessage — parse error: ${e.message}")
        }
    }

    private suspend fun handleEncryptedMessage(encryptedData: String) {
        Log.d("GhostChat", "[ChatViewModel] handleEncryptedMessage called, dataLength=${encryptedData.length}")
        try {
            val plaintext = crypto?.decrypt(encryptedData) ?: run {
                Log.e("GhostChat", "[ChatViewModel] handleEncryptedMessage — crypto.decrypt returned null")
                return
            }
            Log.d("GhostChat", "[ChatViewModel] handleEncryptedMessage — decrypted, plaintextLength=${plaintext.length}")

            // Try parsing as JSON (control message or new wire format)
            try {
                val json = JSONObject(plaintext)
                val isCtrl = json.optBoolean("_ctrl", false)
                Log.d("GhostChat", "[ChatViewModel] handleEncryptedMessage — _ctrl=$isCtrl")
                if (isCtrl) {
                    // _ctrl=true — это control message, НИКОГДА не показываем как текст
                    val controlMsg = ControlMessage.from(json)
                    if (controlMsg != null) {
                        Log.d("GhostChat", "[ChatViewModel] handleEncryptedMessage — control message: ${controlMsg::class.simpleName}")
                        handleControlMessage(controlMsg)
                    } else {
                        Log.e("GhostChat", "[ChatViewModel] handleEncryptedMessage — _ctrl=true but unknown type, ignoring")
                    }
                    return
                }

                // New wire format: {"m": "text", "id": "uuid", "r": {"id": ..., "t": ...}}
                val messageText = json.optString("m", "")
                if (messageText.isNotEmpty()) {
                    val senderMsgId = json.optString("id", "").ifEmpty { null }
                    var replyId: String? = null
                    var replyText: String? = null
                    val replyObj = json.optJSONObject("r")
                    if (replyObj != null) {
                        replyId = replyObj.optString("id", "").ifEmpty { null }
                        replyText = replyObj.optString("t", "").ifEmpty { null }
                    }

                    peerIsTyping = false
                    addMessage(messageText, ChatMessage.MessageType.RECEIVED,
                        replyToId = replyId, replyToText = replyText,
                        senderMessageId = senderMsgId)

                    // Play sound & vibrate
                    if (messageSoundEnabled) {
                        SoundLibrary.playMessageSound(appContext, messageSoundId, vibrationEnabled)
                    } else if (vibrationEnabled) {
                        vibrate()
                    }

                    // Send delivery ACK + read receipt using peer's counter
                    val counter = crypto?.lastDecryptedCounter?.toInt() ?: return
                    sendEncryptedControl(ControlMessage.MessageAck(counter))
                    if (screen == Screen.CHAT) {
                        sendEncryptedControl(ControlMessage.MessageRead(counter))
                    }
                    return
                }
            } catch (_: Exception) {
                // Not a control message — regular text (backward compat)
                Log.d("GhostChat", "[ChatViewModel] handleEncryptedMessage — not JSON or no _ctrl, treating as text message")
            }

            // Fallback: raw text (backward compat with old clients)
            Log.d("GhostChat", "[ChatViewModel] handleEncryptedMessage — text message received (fallback)")
            peerIsTyping = false
            addMessage(plaintext, ChatMessage.MessageType.RECEIVED)

            // Play sound & vibrate
            if (messageSoundEnabled) {
                SoundLibrary.playMessageSound(appContext, messageSoundId, vibrationEnabled)
            } else if (vibrationEnabled) {
                vibrate()
            }

            // Send delivery ACK + read receipt using peer's counter
            val counter = crypto?.lastDecryptedCounter?.toInt() ?: return
            sendEncryptedControl(ControlMessage.MessageAck(counter))
            if (screen == Screen.CHAT) {
                sendEncryptedControl(ControlMessage.MessageRead(counter))
            }
        } catch (e: com.ghost.chat.core.crypto.GhostCryptoError) {
            Log.e("GhostChat", "[ChatViewModel] handleEncryptedMessage crypto error: ${e.message}")
            when (e) {
                is com.ghost.chat.core.crypto.GhostCryptoError.ReplayAttack ->
                    addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_replay_attack))
                is com.ghost.chat.core.crypto.GhostCryptoError.MessageTooOld ->
                    addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_message_too_old))
                is com.ghost.chat.core.crypto.GhostCryptoError.CounterTooOld ->
                    addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_counter_too_old))
                else ->
                    addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_decryption_error))
            }
        } catch (e: Exception) {
            Log.e("GhostChat", "[ChatViewModel] handleEncryptedMessage error: ${e.message}")
            addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_decryption_error))
        }
    }

    // MARK: - Control Messages

    private suspend fun handleControlMessage(msg: ControlMessage) {
        Log.d("GhostChat", "[ChatViewModel] handleControlMessage — type=${msg::class.simpleName}")
        when (msg) {
            is ControlMessage.Renegotiate -> {
                Log.d("GhostChat", "[ChatViewModel] handleControlMessage — Renegotiate")
                handleRenegotiation(msg.sdp)
            }
            is ControlMessage.CallRequest -> {
                Log.d("GhostChat", "[ChatViewModel] handleControlMessage — CallRequest")
                handleIncomingCall()
            }
            is ControlMessage.CallResponse -> {
                Log.d("GhostChat", "[ChatViewModel] handleControlMessage — CallResponse accepted=${msg.accepted}")
                handleCallResponse(msg.accepted)
            }
            is ControlMessage.CallEnd -> {
                Log.d("GhostChat", "[ChatViewModel] handleControlMessage — CallEnd")
                handleCallEnded()
            }
            is ControlMessage.CallSecurityAlert -> {
                val message = msg.alert.optString("message", "")
                Log.d("GhostChat", "[ChatViewModel] handleControlMessage — CallSecurityAlert: $message")
                addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_security_warning, message))
            }
            is ControlMessage.SecurityAlert -> {
                Log.d("GhostChat", "[ChatViewModel] handleControlMessage — SecurityAlert: ${msg.alert}")
                handleSecurityAlertReceived(msg.alert)
            }
            is ControlMessage.MessageAck -> {
                Log.d("GhostChat", "[ChatViewModel] handleControlMessage — MessageAck counter=${msg.counter}")
                handleMessageAck(msg.counter)
            }
            is ControlMessage.MessageRead -> {
                Log.d("GhostChat", "[ChatViewModel] handleControlMessage — MessageRead counter=${msg.counter}")
                handleMessageRead(msg.counter)
            }
            is ControlMessage.Ready -> {
                Log.d("GhostChat", "[ChatViewModel] handleControlMessage — Ready (bootstrap from host, DH ratchet triggered by decrypt)")
                // Bootstrap from host — decryption already triggered DH ratchet
            }
            is ControlMessage.PushToken -> {
                Log.d("GhostChat", "[ChatViewModel] handleControlMessage — PushToken received, tokenLength=${msg.token.length}")
                peerPushToken = msg.token
                // Persist token in contact for offline calls (UTF-8 encoded)
                currentPeerContact?.let { contact ->
                    Log.d("GhostChat", "[ChatViewModel] handleControlMessage — persisting pushToken for contact ${contact.label}")
                    contact.pushToken = msg.token.toByteArray(Charsets.UTF_8)
                    viewModelScope.launch(Dispatchers.IO) {
                        contactStore?.save(contact)
                    }
                }
                // MUTUAL EXCHANGE: if we haven't sent OUR tokens yet this session, send now.
                // Guarded so we don't ping-pong ACKs.
                if (!tokensSentToPeerThisSession) {
                    localFcmToken?.let { myToken ->
                        tokensSentToPeerThisSession = true
                        Log.d("GhostChat", "[ChatViewModel] PushToken recv — mutual ACK, sending OUR tokens now")
                        viewModelScope.launch {
                            sendEncryptedControl(ControlMessage.PushToken(myToken))
                            sendEncryptedControl(ControlMessage.NotifyToken(myToken))
                        }
                    }
                }
            }
            is ControlMessage.NotifyToken -> {
                Log.d("GhostChat", "[ChatViewModel] handleControlMessage — NotifyToken received, tokenLength=${msg.token.length}")
                peerNotifyToken = msg.token
                // Persist notify token in contact for chat invites (UTF-8 encoded)
                currentPeerContact?.let { contact ->
                    Log.d("GhostChat", "[ChatViewModel] handleControlMessage — persisting notifyToken for contact ${contact.label}")
                    contact.notifyToken = msg.token.toByteArray(Charsets.UTF_8)
                    viewModelScope.launch(Dispatchers.IO) {
                        contactStore?.save(contact)
                    }
                }
                // MUTUAL EXCHANGE: dedup via shared flag
                if (!tokensSentToPeerThisSession) {
                    localFcmToken?.let { myToken ->
                        tokensSentToPeerThisSession = true
                        Log.d("GhostChat", "[ChatViewModel] NotifyToken recv — mutual ACK, sending OUR tokens now")
                        viewModelScope.launch {
                            sendEncryptedControl(ControlMessage.PushToken(myToken))
                            sendEncryptedControl(ControlMessage.NotifyToken(myToken))
                        }
                    }
                }
            }
            is ControlMessage.Typing -> {
                Log.d("GhostChat", "[ChatViewModel] handleControlMessage — Typing isTyping=${msg.isTyping}")
                mainHandler.post { handlePeerTyping(msg.isTyping) }
            }
            is ControlMessage.Capabilities -> {
                Log.d("GhostChat", "[ChatViewModel] handleControlMessage — Capabilities features=${msg.features}")
                if (msg.features.contains("file-transfer")) {
                    mainHandler.post { peerSupportsFiles = true }
                }
            }
            is ControlMessage.RoomRotate -> {
                Log.d("GhostChat", "[ChatViewModel] handleControlMessage — RoomRotate newRoomId=${msg.roomId.take(8)}...")
                mainHandler.post { handleRoomRotate(msg.roomId) }
            }
            is ControlMessage.FileStart -> {
                Log.d("GhostChat", "[ChatViewModel] handleControlMessage — FileStart fileId=${msg.fileId}, name=${msg.name}, size=${msg.size}")
                fileTransfer.handleFileStart(msg.fileId, msg.name, msg.size, msg.mimeType, msg.totalChunks)
                mainHandler.post {
                    val chatMsg = ChatMessage(
                        contactId = currentContactId,
                        text = "${msg.name} (${FileTransferService.formatSize(msg.size)})",
                        type = ChatMessage.MessageType.RECEIVED,
                        fileName = msg.name,
                        fileSize = msg.size,
                        fileMimeType = msg.mimeType,
                        fileTransferProgress = 0.0,
                        fileId = msg.fileId
                    )
                    messages.add(chatMsg)
                }
            }
            is ControlMessage.FileChunk -> {
                Log.d("GhostChat", "[ChatViewModel] handleControlMessage — FileChunk fileId=${msg.fileId}, index=${msg.index}")
                fileTransfer.handleFileChunk(msg.fileId, msg.index, msg.data)
            }
            is ControlMessage.FileComplete -> {
                Log.d("GhostChat", "[ChatViewModel] handleControlMessage — FileComplete fileId=${msg.fileId}")
                fileTransfer.handleFileComplete(msg.fileId)
            }
            is ControlMessage.FileRetransmit -> {
                Log.d("GhostChat", "[ChatViewModel] handleControlMessage — FileRetransmit fileId=${msg.fileId}, indices=${msg.indices.size}")
                fileTransfer.handleRetransmitRequest(msg.fileId, msg.indices)
            }
            is ControlMessage.MessageDelete -> {
                Log.d("GhostChat", "[ChatViewModel] handleControlMessage — MessageDelete messageId=${msg.messageId}")
                mainHandler.post { handleRemoteMessageDelete(msg.messageId) }
            }
            is ControlMessage.MessageEdit -> {
                Log.d("GhostChat", "[ChatViewModel] handleControlMessage — MessageEdit messageId=${msg.messageId}")
                mainHandler.post { handleRemoteMessageEdit(msg.messageId, msg.newText) }
            }
        }
    }

    // MARK: - Remote Delete / Edit

    private fun handleRemoteMessageDelete(senderMessageId: String) {
        Log.d("GhostChat", "[ChatViewModel] handleRemoteMessageDelete: $senderMessageId")
        // Remove from UI
        messages.removeAll { it.senderMessageId == senderMessageId }
        // Remove from DB
        viewModelScope.launch(Dispatchers.IO) {
            messageStore?.deleteBySenderMessageId(senderMessageId)
        }
    }

    private fun handleRemoteMessageEdit(senderMessageId: String, newText: String) {
        Log.d("GhostChat", "[ChatViewModel] handleRemoteMessageEdit: $senderMessageId")
        // Update in UI
        val idx = messages.indexOfFirst { it.senderMessageId == senderMessageId }
        if (idx >= 0) {
            messages[idx] = messages[idx].copy(text = newText, isEdited = true)
        }
        // Update in DB
        viewModelScope.launch(Dispatchers.IO) {
            messageStore?.updateText(senderMessageId, newText)
        }
    }

    // MARK: - Delete / Edit for Both Sides

    fun deleteMessageForEveryone(message: ChatMessage) {
        Log.d("GhostChat", "[ChatViewModel] deleteMessageForEveryone called, messageId=${message.id}")
        val senderMsgId = message.senderMessageId ?: return
        if (message.type != ChatMessage.MessageType.SENT) return
        // Remove locally
        messages.removeAll { it.id == message.id }
        viewModelScope.launch(Dispatchers.IO) {
            messageStore?.deleteBySenderMessageId(senderMsgId)
        }
        // Notify peer
        viewModelScope.launch {
            sendEncryptedControl(ControlMessage.MessageDelete(senderMsgId))
        }
    }

    fun editMessage(message: ChatMessage, newText: String) {
        Log.d("GhostChat", "[ChatViewModel] editMessage called, messageId=${message.id}, newLen=${newText.length}")
        val senderMsgId = message.senderMessageId ?: return
        if (message.type != ChatMessage.MessageType.SENT) return
        // Update locally
        val idx = messages.indexOfFirst { it.id == message.id }
        if (idx >= 0) {
            messages[idx] = messages[idx].copy(text = newText, isEdited = true)
        }
        viewModelScope.launch(Dispatchers.IO) {
            messageStore?.updateText(senderMsgId, newText)
        }
        // Notify peer
        viewModelScope.launch {
            sendEncryptedControl(ControlMessage.MessageEdit(senderMsgId, newText))
        }
    }

    suspend fun sendEncryptedControl(control: ControlMessage) {
        val typeName = control::class.simpleName ?: "unknown"
        val isFileControl = typeName.startsWith("File")
        if (isFileControl) {
            Log.d("GhostChat", "[ChatViewModel] sendEncryptedControl — FILE control: $typeName, crypto=${crypto != null}, rtcConnected=${rtc?.isConnected}")
        } else {
            Log.d("GhostChat", "[ChatViewModel] sendEncryptedControl — type=$typeName")
        }
        try {
            val jsonObj = control.toJSON()
            jsonObj.put("_ctrl", true)  // Маркер: управляющее сообщение, не текст
            val json = jsonObj.toString()
            val encrypted = crypto?.encrypt(json) ?: run {
                Log.e("GhostChat", "[ChatViewModel] sendEncryptedControl — crypto.encrypt returned null for $typeName")
                return
            }
            val msg = JSONObject().apply {
                put("type", "encrypted-message")
                put("data", encrypted)
                put("v", 2)
            }
            val sent = rtc?.send(msg.toString())
            if (isFileControl) {
                Log.d("GhostChat", "[ChatViewModel] sendEncryptedControl — FILE control $typeName sent=$sent")
            }
        } catch (e: Exception) {
            Log.e("GhostChat", "[ChatViewModel] sendEncryptedControl — error ($typeName): ${e.message}")
            // Silent fail for control messages
        }
    }

    private fun handleMessageAck(counter: Int) {
        Log.d("GhostChat", "[ChatViewModel] handleMessageAck called, counter=$counter")
        val record = sentMessages[counter] ?: return
        val index = messages.indexOfFirst { it.id == record.id }
        if (index >= 0) {
            messages[index] = messages[index].copy(isDelivered = true)
            // Don't remove from sentMessages — keep for read receipt tracking
            if (saveMessageHistory) {
                val msgId = record.id
                viewModelScope.launch(Dispatchers.IO) {
                    messageStore?.markDelivered(msgId)
                }
            }
        }
    }

    private fun handleMessageRead(counter: Int) {
        Log.d("GhostChat", "[ChatViewModel] handleMessageRead called, counter=$counter")
        val record = sentMessages[counter] ?: return
        val index = messages.indexOfFirst { it.id == record.id }
        if (index >= 0) {
            messages[index] = messages[index].copy(isDelivered = true, isRead = true)
            sentMessages.remove(counter)
            // Persist read status to DB
            if (saveMessageHistory) {
                val msgId = record.id
                viewModelScope.launch(Dispatchers.IO) {
                    messageStore?.markDelivered(msgId)
                }
            }
        }
    }

    // MARK: - Voice Calls

    /** Callback for requesting RECORD_AUDIO permission from the UI layer */
    var onRequestMicPermission: ((onGranted: () -> Unit) -> Unit)? = null

    private fun hasMicPermission(): Boolean {
        return androidx.core.content.ContextCompat.checkSelfPermission(
            appContext, android.Manifest.permission.RECORD_AUDIO
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
    }

    fun startCall() {
        ghostLog("[ChatViewModel] startCall called, isConnected=$isConnected, callState=$callState, keyExchangeCompleted=$keyExchangeCompleted", appContext)
        if (callState != CallUIState.IDLE) {
            ghostLog("[ChatViewModel] startCall — skipped (callState=$callState)", appContext)
            return
        }

        // Reset timer display so old value doesn't flash briefly
        callTimer = "00:00"

        val hasMic = hasMicPermission()
        ghostLog("[ChatViewModel] startCall — hasMicPermission=$hasMic", appContext)
        if (!hasMic) {
            ghostLog("[ChatViewModel] startCall — requesting mic permission", appContext)
            onRequestMicPermission?.invoke { startCallAfterPermission() }
            return
        }

        // If not connected — create room (if needed), wait for peer, then call
        if (!isConnected) {
            startOfflineCall()
        } else {
            startCallInternal()
        }
    }

    /** Offline call: set calling UI, ensure room exists, wait for peer to connect */
    private fun startOfflineCall() {
        ghostLog("[ChatViewModel] startOfflineCall called", appContext)
        callState = CallUIState.CALLING
        CallManager.reportOutgoingCall(appContext)
        addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_calling))

        // Warn if peer has no push token — they won't receive the call notification
        val contact = currentPeerContact
        if (contact != null && contact.pushToken == null && contact.notifyToken == null) {
            ghostLog("[ChatViewModel] startOfflineCall: peer has NO push token, they won't be notified", appContext)
            addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_no_push_token))
        }

        pendingCallAfterConnect = true

        viewModelScope.launch {
            // Room should already exist from autoConnectToContact
            // If not, create now
            if (roomId == null) {
                val contact = currentPeerContact
                if (contact != null) {
                    autoConnectToContact(contact)
                }
            }

            // Send VoIP push to peer to wake them up
            val contact = currentPeerContact
            val tokenData = contact?.pushToken
            if (tokenData != null && roomId != null) {
                val token = String(tokenData, Charsets.UTF_8)
                if (token.length >= 10) {
                    val endpoint = if (token.length <= 80) "api/send-push" else "api/send-push-android"
                    sendCallPush(token, roomId!!, contact.label, endpoint)
                }
            }

            // Wait up to 30 seconds for peer to connect + complete key exchange
            for (i in 0 until 60) {
                kotlinx.coroutines.delay(500)
                if (isConnected && keyExchangeCompleted) break
                if (callState != CallUIState.CALLING) return@launch // User cancelled
            }

            if (!isConnected || !keyExchangeCompleted) {
                // Cancel connection timeout to prevent leave() during cleanup
                cancelConnectionTimeout()
                callState = CallUIState.IDLE
                pendingCallAfterConnect = false
                addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_no_answer))
                // Send missed call push
                sendMissedCallPush()
                GhostConnectionService.activeConnection?.remoteEnd()
                return@launch
            }

            pendingCallAfterConnect = false
            // Now connected — proceed with normal call
            startCallInternal()
        }
    }

    /** Called after mic permission granted */
    private fun startCallAfterPermission() {
        Log.d("GhostChat", "[ChatViewModel] startCallAfterPermission called, isConnected=$isConnected")
        if (!isConnected) {
            startOfflineCall()
        } else {
            startCallInternal()
        }
    }

    private fun startCallInternal() {
        Log.d("GhostChat", "[ChatViewModel] startCallInternal called")
        val currentRtc = rtc ?: run {
            Log.e("GhostChat", "[ChatViewModel] startCallInternal — rtc is null")
            return
        }
        val pc = currentRtc.peerConnection ?: run {
            Log.e("GhostChat", "[ChatViewModel] startCallInternal — peerConnection is null")
            return
        }
        // Reuse voice if exists (same P2P session) — sender/transceiver preserved for second call
        if (voice == null) {
            voice = GhostVoice(pc, currentRtc.factory, appContext)
            setupVoiceCallbacks()
            Log.d("GhostChat", "[ChatViewModel] startCallInternal: new GhostVoice created (first call)")
        } else {
            Log.d("GhostChat", "[ChatViewModel] startCallInternal: reusing existing GhostVoice (second call)")
        }

        // Single ordered coroutine: callRequest → startCall → (if reused) renegotiation offer.
        // Prevents fire-and-forget race where `call-request` and `renegotiate` arrived in wrong
        // order at the callee, causing one-way audio on second call.
        callState = CallUIState.CALLING
        CallManager.reportOutgoingCall(appContext)
        addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_calling))

        viewModelScope.launch {
            try {
                // 1. callRequest FIRST — ensures peer enters RINGING state before any SDP arrives
                sendEncryptedControl(ControlMessage.CallRequest)

                // 2. Create or reuse audio track (may trigger onRenegotiationNeeded for first call)
                val didReuseSender = voice?.startCall() ?: false

                // 3. For second call: onRenegotiationNeeded does NOT fire (same transceiver).
                //    MUST manually send renegotiation offer — awaited so wire order is deterministic.
                if (didReuseSender) {
                    Log.d("GhostChat", "[ChatViewModel] startCallInternal: sender reused — awaiting manual renegotiation")
                    val offer = rtc?.createOffer()
                    if (offer != null) {
                        handleLocalRenegotiationOffer(offer)
                    } else {
                        Log.e("GhostChat", "[ChatViewModel] startCallInternal: createOffer returned null on reused sender")
                    }
                }
            } catch (e: Exception) {
                Log.e("GhostChat", "[ChatViewModel] startCallInternal: exception during call setup: ${e.message}")
                mainHandler.post {
                    addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_call_error))
                    callState = CallUIState.IDLE
                    callingTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
                    callingTimeoutRunnable = null
                }
            }
        }

        // Caller-side timeout — cancel call after 45s of no answer
        callingTimeoutRunnable = Runnable {
            if (callState == CallUIState.CALLING) {
                addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_no_answer))
                viewModelScope.launch { sendMissedCallPush() }
                endCall()
            }
        }
        mainHandler.postDelayed(callingTimeoutRunnable!!, 45_000)
    }

    private fun handleIncomingCall() {
        Log.d("GhostChat", "[ChatViewModel] handleIncomingCall called, callState=$callState")
        if (callState != CallUIState.IDLE) {
            Log.d("GhostChat", "[ChatViewModel] handleIncomingCall — not IDLE (callState=$callState), declining")
            viewModelScope.launch {
                sendEncryptedControl(ControlMessage.CallResponse(false))
            }
            return
        }

        callState = CallUIState.RINGING
        addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_incoming_call))
        // Report incoming call to system (ConnectionService)
        val callerName = currentPeerContact?.label ?: "Ghost Chat"
        CallManager.reportIncomingCall(appContext, callerName)
        startIncomingCallVibration()

        // 30-second ringing timeout — auto-decline if not answered
        ringingTimeoutRunnable = Runnable {
            if (callState == CallUIState.RINGING) {
                declineCall()
            }
        }
        mainHandler.postDelayed(ringingTimeoutRunnable!!, 30_000)
    }

    fun acceptCall() {
        Log.d("GhostChat", "[ChatViewModel] acceptCall called, callState=$callState, hasMicPermission=${hasMicPermission()}, isFromPush=$isFromPush, isConnected=$isConnected, keyExchangeCompleted=$keyExchangeCompleted")

        // Cold-start push: user taps Accept in system call UI BEFORE P2P is established.
        // Buffer the intent — completeKeyExchange will flush it.
        val rtcReady = rtc?.peerConnection != null && isConnected && keyExchangeCompleted
        if (isFromPush && !rtcReady) {
            Log.d("GhostChat", "[ChatViewModel] acceptCall — P2P not ready (rtcReady=$rtcReady), buffering as pendingAcceptCall")
            pendingAcceptCall = true
            addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_connecting))
            return
        }

        if (callState != CallUIState.RINGING) {
            Log.d("GhostChat", "[ChatViewModel] acceptCall — not RINGING (callState=$callState), skipping")
            return
        }

        // Reset timer display so old value doesn't flash briefly
        callTimer = "00:00"

        cancelRingingTimeout()

        if (!hasMicPermission()) {
            onRequestMicPermission?.invoke { acceptCallInternal() }
            return
        }
        acceptCallInternal()
    }

    private fun acceptCallInternal() {
        Log.d("GhostChat", "[ChatViewModel] acceptCallInternal called")
        stopIncomingCallVibration()

        val currentRtc = rtc ?: run {
            Log.e("GhostChat", "[ChatViewModel] acceptCallInternal — rtc is null")
            return
        }
        val pc = currentRtc.peerConnection ?: run {
            Log.e("GhostChat", "[ChatViewModel] acceptCallInternal — peerConnection is null")
            return
        }
        // Reuse voice if exists (same P2P session) — sender/transceiver preserved for second call
        if (voice == null) {
            voice = GhostVoice(pc, currentRtc.factory, appContext)
            setupVoiceCallbacks()
            Log.d("GhostChat", "[ChatViewModel] acceptCallInternal: new GhostVoice created (first call)")
        } else {
            Log.d("GhostChat", "[ChatViewModel] acceptCallInternal: reusing existing GhostVoice (second call)")
        }

        try {
            // Only initialize audio (create track), don't add to PC yet
            voice?.initializeAudio()

            // Process pending renegotiation offer with correct ordering:
            // setRemoteDescription → addTrack → createAnswer
            val pendingOffer = pendingRenegotiationOffer
            if (pendingOffer != null) {
                viewModelScope.launch {
                    processRenegotiationOffer(GhostRTC.sdpToJson(pendingOffer))
                    pendingRenegotiationOffer = null

                    // Mark call as active after renegotiation completes
                    voice?.markCallActive()
                    sendEncryptedControl(ControlMessage.CallResponse(true))
                    callState = CallUIState.ACTIVE
                    addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_call_connected))
                }
            } else {
                // No pending offer — add track and renegotiate to inform peer
                voice?.addAudioTrack()

                // Renegotiate to inform peer about new audio track
                // (onRenegotiationNeeded may not fire reliably on second call)
                viewModelScope.launch {
                    val offer = rtc?.createOffer()
                    if (offer != null) {
                        handleLocalRenegotiationOffer(offer)
                    }

                    voice?.markCallActive()
                    sendEncryptedControl(ControlMessage.CallResponse(true))
                    callState = CallUIState.ACTIVE
                    addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_call_connected))
                }
            }
        } catch (e: Exception) {
            viewModelScope.launch {
                sendEncryptedControl(ControlMessage.CallResponse(false))
            }
            callState = CallUIState.IDLE
        }
    }

    fun declineCall() {
        Log.d("GhostChat", "[ChatViewModel] declineCall called, callState=$callState")
        cancelRingingTimeout()
        stopIncomingCallVibration()
        viewModelScope.launch {
            sendEncryptedControl(ControlMessage.CallResponse(false))
        }
        callState = CallUIState.IDLE
    }

    private fun cancelRingingTimeout() {
        Log.d("GhostChat", "[ChatViewModel] cancelRingingTimeout called")
        ringingTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        ringingTimeoutRunnable = null
    }

    private fun handleCallResponse(accepted: Boolean) {
        Log.d("GhostChat", "[ChatViewModel] handleCallResponse called, accepted=$accepted, callState=$callState")
        if (callState != CallUIState.CALLING) {
            Log.d("GhostChat", "[ChatViewModel] handleCallResponse — not CALLING (callState=$callState), skipping")
            return
        }

        // Clear caller-side timeout
        callingTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        callingTimeoutRunnable = null

        if (!accepted) {
            voice?.endCall()
            voice?.destroy()
            voice = null
            callState = CallUIState.IDLE
            CallManager.endCall()
            addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_call_declined))
            return
        }

        voice?.callAccepted()
        callState = CallUIState.ACTIVE
        CallManager.markCallActive()
        addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_call_connected))
    }

    private fun handleCallEnded() {
        Log.d("GhostChat", "[ChatViewModel] handleCallEnded called, callState=$callState")
        callingTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        callingTimeoutRunnable = null
        stopIncomingCallVibration()
        voice?.endCall()
        // Keep voice for second call in same P2P session
        callState = CallUIState.IDLE
        isMuted = false
        isSpeakerOn = false
        pendingRenegotiationOffer = null
        // Notify system that remote party ended the call
        GhostConnectionService.activeConnection?.remoteEnd()
        addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_call_ended))
    }

    fun endCall() {
        Log.d("GhostChat", "[ChatViewModel] endCall called, callState=$callState, hasVoice=${voice != null}")
        if (callState == CallUIState.IDLE) {
            Log.d("GhostChat", "[ChatViewModel] endCall — already IDLE, skipping")
            return
        }
        callingTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        callingTimeoutRunnable = null
        stopIncomingCallVibration()
        voice?.endCall()
        // DON'T destroy voice — keep for second call in same P2P session
        // voice will be destroyed in performLeave/destroy when P2P ends

        viewModelScope.launch {
            sendEncryptedControl(ControlMessage.CallEnd)
        }

        callState = CallUIState.IDLE
        isMuted = false
        isSpeakerOn = false
        pendingRenegotiationOffer = null
        CallManager.endCall()
        addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_call_ended))
    }

    /** Call an offline contact via push → server relay (FCM for Android, APNs for iOS) */
    fun callOfflineContact(contact: Contact) {
        Log.d("GhostChat", "[ChatViewModel] callOfflineContact called, label=${contact.label}")
        val pushToken = contact.pushToken?.let { String(it, Charsets.UTF_8) } ?: run {
            Log.d("GhostChat", "[ChatViewModel] callOfflineContact — no pushToken, skipping")
            return
        }
        if (pushToken.length < 10) {
            Log.d("GhostChat", "[ChatViewModel] callOfflineContact — pushToken too short (${pushToken.length}), skipping")
            return
        }

        expectedPeerIdentityKey = contact.identityKey
        currentPeerContact = contact

        // Detect platform: FCM tokens are long (100+ chars), APNs tokens are 64 hex chars
        val isIOSPeer = pushToken.length <= 80

        // Create room, then send push so peer joins
        isHost = true
        crypto = GhostCrypto().also { it.generateKeyPair() }
        rtc = GhostRTC(appContext).also { it.privacyMode = privacyMode }
        signaling = SignalingClient(SERVER_URL)
        turnService = TURNService(SERVER_URL)
        rtc?.setTurnService(turnService)

        setupSignalingCallbacks()
        setupRTCCallbacks()

        // Override onRoomCreated to send push after room is ready
        val originalCallback = signaling?.onRoomCreated
        signaling?.onRoomCreated = { id ->
            roomId = id
            saveSession()
            if (screen != Screen.CHAT) {
                screen = Screen.WAITING
            }

            viewModelScope.launch {
                val endpoint = if (isIOSPeer) "api/send-push" else "api/send-push-android"
                sendCallPush(pushToken, id, contact.label, endpoint)
            }
        }

        signaling?.connect()
        signaling?.createRoom()
    }

    /** Send an invite push to an offline contact */
    fun inviteOfflineContact(contact: Contact) {
        Log.d("GhostChat", "[ChatViewModel] inviteOfflineContact called, label=${contact.label}")
        val notifyToken = contact.notifyToken?.let { String(it, Charsets.UTF_8) }
            ?: contact.pushToken?.let { String(it, Charsets.UTF_8) }
            ?: run {
                Log.d("GhostChat", "[ChatViewModel] inviteOfflineContact — no push/notify token, skipping")
                return
            }
        if (notifyToken.length < 10) {
            Log.d("GhostChat", "[ChatViewModel] inviteOfflineContact — token too short (${notifyToken.length}), skipping")
            return
        }

        expectedPeerIdentityKey = contact.identityKey
        currentPeerContact = contact

        // Detect platform: FCM tokens are long (100+ chars), APNs tokens are 64 hex chars
        val platform = if (notifyToken.length <= 80) "ios" else "android"

        // Create room infrastructure
        isHost = true
        crypto = GhostCrypto().also { it.generateKeyPair() }
        rtc = GhostRTC(appContext).also { it.privacyMode = privacyMode }
        signaling = SignalingClient(SERVER_URL)
        turnService = TURNService(SERVER_URL)
        rtc?.setTurnService(turnService)

        setupSignalingCallbacks()
        setupRTCCallbacks()

        // Override onRoomCreated BEFORE connecting to avoid race condition
        signaling?.onRoomCreated = { id ->
            roomId = id
            saveSession()
            if (screen != Screen.CHAT) {
                screen = Screen.WAITING
            }

            viewModelScope.launch {
                sendInvitePush(notifyToken, id, contact.label, platform)
            }
        }

        signaling?.connect()
        signaling?.createRoom()
    }

    private suspend fun sendCallPush(token: String, roomId: String, callerName: String, endpoint: String = "api/send-push-android") {
        withContext(Dispatchers.IO) {
            try {
                // Fetch push auth token if not yet available
                if (pushAuthToken == null) {
                    pushAuthToken = try { turnService?.fetchCredentials()?.pushAuth } catch (_: Exception) { null }
                }

                val url = URL("$SERVER_URL/$endpoint")
                val conn = url.openConnection() as HttpURLConnection
                conn.requestMethod = "POST"
                conn.setRequestProperty("Content-Type", "application/json")
                conn.doOutput = true
                conn.connectTimeout = 10_000
                conn.readTimeout = 10_000

                val body = JSONObject().apply {
                    put("token", token)
                    put("payload", JSONObject().apply {
                        put("roomId", roomId)
                        put("callerName", callerName)
                    })
                    pushAuthToken?.let { put("auth", it) }
                }

                OutputStreamWriter(conn.outputStream).use { it.write(body.toString()) }
                val code = conn.responseCode
                if (code != 200) {
                    val errBody = try { conn.errorStream?.bufferedReader()?.readText() } catch (_: Exception) { null }
                    android.util.Log.w("GhostPush", "[CallPush] Server returned $code: $errBody")
                }
                conn.disconnect()
            } catch (e: Exception) {
                android.util.Log.w("GhostPush", "[CallPush] Failed: ${e.message}")
            }
        }
    }

    private suspend fun sendInvitePush(token: String, roomId: String, inviterName: String, platform: String = "android") {
        withContext(Dispatchers.IO) {
            try {
                // Fetch push auth token if not yet available
                if (pushAuthToken == null) {
                    pushAuthToken = try { turnService?.fetchCredentials()?.pushAuth } catch (_: Exception) { null }
                }

                val url = URL("$SERVER_URL/api/send-invite")
                val conn = url.openConnection() as HttpURLConnection
                conn.requestMethod = "POST"
                conn.setRequestProperty("Content-Type", "application/json")
                conn.doOutput = true
                conn.connectTimeout = 10_000
                conn.readTimeout = 10_000

                val body = JSONObject().apply {
                    put("token", token)
                    put("platform", platform)
                    put("payload", JSONObject().apply {
                        put("roomId", roomId)
                        put("inviterName", inviterName)
                    })
                    pushAuthToken?.let { put("auth", it) }
                }

                OutputStreamWriter(conn.outputStream).use { it.write(body.toString()) }
                val code = conn.responseCode
                if (code != 200) {
                    val errBody = try { conn.errorStream?.bufferedReader()?.readText() } catch (_: Exception) { null }
                    android.util.Log.w("GhostPush", "[InvitePush] Server returned $code: $errBody")
                }
                conn.disconnect()
            } catch (e: Exception) {
                android.util.Log.w("GhostPush", "[InvitePush] Failed: ${e.message}")
            }
        }
    }

    // MARK: - Offline Message Push

    /** Queue a pending message locally (peer is offline) */
    private fun queuePendingMessage(text: String) {
        Log.d("GhostChat", "[ChatViewModel] queuePendingMessage called, textLength=${text.length}, contactId=${currentContactId?.take(8)}")
        val contactId = currentContactId ?: run {
            Log.d("GhostChat", "[ChatViewModel] queuePendingMessage — no contactId, skipping")
            return
        }
        val msgId = java.util.UUID.randomUUID().toString()
        val ttlMs = autoDeleteMinutes * 60 * 1000L
        val msg = ChatMessage(
            id = msgId,
            contactId = contactId,
            text = text,
            type = ChatMessage.MessageType.SENT,
            isPending = true,
            expiresAt = if (saveMessageHistory || ttlMs <= 0) null else Date(System.currentTimeMillis() + ttlMs)
        )
        // Сохраняем в БД только если история включена — иначе только in-memory
        // При saveMessageHistory=false лучше потерять сообщение при крахе,
        // чем нарушить гарантию zero-trace
        if (saveMessageHistory || isSavedMessagesMode) {
            viewModelScope.launch(Dispatchers.IO) { messageStore?.save(msg) }
        }
        messages.add(msg)
    }

    /** Create room lazily (on first message) and send invite push to peer */
    private suspend fun ensureRoomAndInvitePeer() {
        Log.d("GhostChat", "[ChatViewModel] ensureRoomAndInvitePeer called, roomId=${roomId?.take(8)}, hasSignaling=${signaling != null}, isCreatingRoom=$isCreatingRoom")
        if (roomId != null || signaling != null) {
            Log.d("GhostChat", "[ChatViewModel] ensureRoomAndInvitePeer — room/signaling already exists, skipping")
            return
        }
        if (isCreatingRoom) {
            Log.d("GhostChat", "[ChatViewModel] ensureRoomAndInvitePeer — already creating room, skipping")
            return
        }
        isCreatingRoom = true

        val contact = currentPeerContact ?: return

        // Create room infrastructure
        isHost = true
        crypto = GhostCrypto().also { it.generateKeyPair() }
        rtc = GhostRTC(appContext).also { it.privacyMode = privacyMode }
        signaling = SignalingClient(SERVER_URL)
        turnService = TURNService(SERVER_URL)
        rtc?.setTurnService(turnService)

        setupSignalingCallbacks()
        setupRTCCallbacks()

        // Override onRoomCreated: register pending room + send push
        signaling?.onRoomCreated = { id ->
            isCreatingRoom = false
            roomId = id
            saveSession()

            viewModelScope.launch {
                // Register pending room so peer can find it
                val myHash = identityKeyHash()
                val peerHash = identityKeyHash(contact)
                if (myHash != null && peerHash != null) {
                    registerPendingRoom(peerHash, id, myHash)
                }

                // Send push if we have a token
                val tokenData = contact.notifyToken ?: contact.pushToken
                if (tokenData != null) {
                    val token = String(tokenData, Charsets.UTF_8)
                    if (token.length >= 10) {
                        val platform = if (token.length <= 80) "ios" else "android"
                        sendInvitePush(token, id, contact.label, platform)
                    }
                }
            }
        }

        signaling?.connect()
        signaling?.createRoom()
    }

    /** Flush pending messages after P2P connection + key exchange established */
    private suspend fun flushPendingMessages() {
        Log.d("GhostChat", "[ChatViewModel] flushPendingMessages called")
        val contact = currentPeerContact ?: run {
            Log.d("GhostChat", "[ChatViewModel] flushPendingMessages — no currentPeerContact, skipping")
            return
        }
        val expectedKey = contact.identityKey ?: run {
            Log.d("GhostChat", "[ChatViewModel] flushPendingMessages — no identityKey on contact, skipping")
            return
        }
        val peerKey = peerIdentityKeyData ?: run {
            Log.d("GhostChat", "[ChatViewModel] flushPendingMessages — no peerIdentityKeyData, skipping")
            return
        }
        if (!expectedKey.contentEquals(peerKey)) {
            Log.e("GhostChat", "[ChatViewModel] flushPendingMessages — identity key MISMATCH, not sending pending messages")
            // Identity key mismatch — не отправляем сообщения чужому пиру
            return
        }
        Log.d("GhostChat", "[ChatViewModel] flushPendingMessages — identity key matches")

        val contactId = currentContactId ?: return
        val c = crypto ?: return

        val pending = if (saveMessageHistory || isSavedMessagesMode) {
            // Pending messages stored in DB
            withContext(Dispatchers.IO) { messageStore?.fetchPending(contactId) ?: emptyList() }
        } else {
            // No DB storage — read pending from in-memory list
            messages.filter { it.isPending && it.type == ChatMessage.MessageType.SENT }
        }
        if (pending.isEmpty()) return

        for (msg in pending) {
            try {
                val encrypted = c.encrypt(msg.text)
                val payload = JSONObject().apply {
                    put("type", "encrypted-message")
                    put("data", encrypted)
                    put("v", 2)
                }
                rtc?.send(payload.toString())
                c.messageCounter?.let { counter ->
                    sentMessages[counter.toInt()] = SentRecord(msg.id, System.currentTimeMillis())
                }
                withContext(Dispatchers.IO) { messageStore?.markSent(msg.id) }

                // Update in-memory list
                val idx = messages.indexOfFirst { it.id == msg.id }
                if (idx >= 0) {
                    messages[idx] = messages[idx].copy(isPending = false)
                }
            } catch (e: Exception) {
                Log.e("GhostChat", "[ChatViewModel] flushPendingMessages — encrypt/send error for msg=${msg.id.take(8)}: ${e.message}")
                continue // Skip failed message, try remaining
            }
        }
    }

    /** Send push notification about new offline message */
    private suspend fun sendOfflineMessagePush() {
        val contact = currentPeerContact ?: run {
            Log.d("GhostChat", "[NotifyPush] sendOfflineMessagePush — no currentPeerContact, skipping")
            return
        }
        val tokenData = contact.notifyToken ?: contact.pushToken ?: run {
            Log.d("GhostChat", "[NotifyPush] sendOfflineMessagePush — no notify/push token for ${contact.label}, skipping")
            return
        }
        val token = String(tokenData, Charsets.UTF_8)
        if (token.length < 10) {
            Log.d("GhostChat", "[NotifyPush] sendOfflineMessagePush — token too short (${token.length}), skipping")
            return
        }
        val platform = if (token.length <= 80) "ios" else "android"
        // Имя отправителя — наше имя (не получателя)
        val senderName = contact.label
        Log.d("GhostChat", "[NotifyPush] sendOfflineMessagePush — sending to ${contact.label}, token=${token.take(8)}..., platform=$platform")
        sendNotifyPush(token, platform, "new-message", senderName)
    }

    /** Send missed call push notification */
    private suspend fun sendMissedCallPush() {
        val contact = currentPeerContact ?: run {
            Log.d("GhostChat", "[NotifyPush] sendMissedCallPush — no currentPeerContact, skipping")
            return
        }
        val tokenData = contact.notifyToken ?: contact.pushToken ?: run {
            Log.d("GhostChat", "[NotifyPush] sendMissedCallPush — no notify/push token for ${contact.label}, skipping")
            return
        }
        val token = String(tokenData, Charsets.UTF_8)
        if (token.length < 10) {
            Log.d("GhostChat", "[NotifyPush] sendMissedCallPush — token too short (${token.length}), skipping")
            return
        }
        val platform = if (token.length <= 80) "ios" else "android"
        val senderName = contact.label
        Log.d("GhostChat", "[NotifyPush] sendMissedCallPush — sending to ${contact.label}, token=${token.take(8)}..., platform=$platform")
        sendNotifyPush(token, platform, "missed-call", senderName)
    }

    /** Universal push notification sender via server proxy */
    private suspend fun sendNotifyPush(token: String, platform: String, type: String, senderName: String) {
        Log.d("GhostChat", "[NotifyPush] sendNotifyPush called: type=$type, platform=$platform, token=${token.take(8)}..., auth=${pushAuthToken != null}")
        withContext(Dispatchers.IO) {
            try {
                // Fetch push auth token if not yet available
                if (pushAuthToken == null) {
                    pushAuthToken = try { turnService?.fetchCredentials()?.pushAuth } catch (_: Exception) { null }
                    Log.d("GhostChat", "[NotifyPush] Fetched push auth: ${pushAuthToken != null}")
                }

                val url = URL("$SERVER_URL/api/push/notify")
                val conn = url.openConnection() as HttpURLConnection
                conn.requestMethod = "POST"
                conn.setRequestProperty("Content-Type", "application/json")
                conn.doOutput = true
                conn.connectTimeout = 10_000
                conn.readTimeout = 10_000

                val body = JSONObject().apply {
                    put("token", token)
                    put("platform", platform)
                    put("type", type)
                    put("senderName", senderName)
                    pushAuthToken?.let { put("auth", it) }
                }

                Log.d("GhostChat", "[NotifyPush] Sending POST to $url")
                OutputStreamWriter(conn.outputStream).use { it.write(body.toString()) }
                val code = conn.responseCode
                if (code == 200) {
                    Log.d("GhostChat", "[NotifyPush] Success: type=$type")
                } else {
                    val errBody = try { conn.errorStream?.bufferedReader()?.readText() } catch (_: Exception) { null }
                    Log.w("GhostChat", "[NotifyPush] Server returned $code: $errBody")
                }
                conn.disconnect()
            } catch (e: Exception) {
                android.util.Log.w("GhostPush", "[NotifyPush] Failed: ${e.message}")
            }
        }
    }

    fun toggleMute() {
        Log.d("GhostChat", "[ChatViewModel] toggleMute called, currentMuted=$isMuted")
        val muted = voice?.toggleMute() ?: return
        isMuted = muted
        Log.d("GhostChat", "[ChatViewModel] toggleMute — isMuted=$isMuted")
    }

    fun toggleSpeaker() {
        Log.d("GhostChat", "[ChatViewModel] toggleSpeaker called, currentSpeaker=$isSpeakerOn")
        val speaker = voice?.toggleSpeaker() ?: return
        isSpeakerOn = speaker
        Log.d("GhostChat", "[ChatViewModel] toggleSpeaker — isSpeakerOn=$isSpeakerOn")
    }

    private fun setupVoiceCallbacks() {
        Log.d("GhostChat", "[ChatViewModel] setupVoiceCallbacks called")
        voice?.onCallTimer = { time ->
            mainHandler.post { callTimer = time }
        }
    }

    // MARK: - Renegotiation (for audio track addition)

    private suspend fun handleRenegotiation(sdpJson: JSONObject) {
        val sdp = GhostRTC.jsonToSdp(sdpJson) ?: run {
            Log.e("GhostChat", "[ChatViewModel] handleRenegotiation — failed to parse SDP")
            return
        }
        Log.d("GhostChat", "[ChatViewModel] handleRenegotiation — type=${sdp.type}, callState=$callState")

        if (sdp.type == SessionDescription.Type.OFFER) {
            // If we're ringing, store for later
            if (callState == CallUIState.RINGING) {
                Log.d("GhostChat", "[ChatViewModel] handleRenegotiation — RINGING, buffering offer")
                pendingRenegotiationOffer = sdp
                return
            }
            Log.d("GhostChat", "[ChatViewModel] handleRenegotiation — processing offer")
            processRenegotiationOffer(sdpJson)
        } else if (sdp.type == SessionDescription.Type.ANSWER) {
            Log.d("GhostChat", "[ChatViewModel] handleRenegotiation — processing answer")
            rtc?.handleAnswer(sdp)
            // Auto-transition: receiving a renegotiation answer means callee accepted
            // and sent their audio. Start timer without waiting for explicit call-response
            // (which may be delayed due to ratchet timing)
            if (callState == CallUIState.CALLING) {
                Log.d("GhostChat", "[ChatViewModel] handleRenegotiation — auto-transitioning call to active")
                handleCallResponse(true)
            }
        }
    }

    /// CRITICAL: Order matters for bidirectional audio!
    /// 1. setRemoteDescription(offer) — creates transceiver from offer's audio m-line
    /// 2. addTrack — reuses existing transceiver (direction becomes sendrecv)
    /// 3. createAnswer — includes our audio as sendrecv
    private suspend fun processRenegotiationOffer(sdpJson: JSONObject) {
        Log.d("GhostChat", "[ChatViewModel] processRenegotiationOffer called")
        val sdp = GhostRTC.jsonToSdp(sdpJson) ?: run {
            Log.e("GhostChat", "[ChatViewModel] processRenegotiationOffer — failed to parse SDP")
            return
        }
        val rtc = rtc ?: run {
            Log.e("GhostChat", "[ChatViewModel] processRenegotiationOffer — rtc is null")
            return
        }

        // Step 1: Set remote description — creates transceiver from offer
        Log.d("GhostChat", "[ChatViewModel] processRenegotiationOffer — Step 1: setRemoteOffer")
        if (!rtc.setRemoteOffer(sdp)) {
            Log.e("GhostChat", "[ChatViewModel] processRenegotiationOffer — setRemoteOffer FAILED")
            return
        }

        // Step 2: Add our audio track — reuses the offer's transceiver (sendrecv)
        Log.d("GhostChat", "[ChatViewModel] processRenegotiationOffer — Step 2: addAudioTrack")
        voice?.addAudioTrack()

        // Step 3: Create answer with our audio included as sendrecv
        Log.d("GhostChat", "[ChatViewModel] processRenegotiationOffer — Step 3: createAndSetAnswer")
        val answer = rtc.createAndSetAnswer() ?: run {
            Log.e("GhostChat", "[ChatViewModel] processRenegotiationOffer — createAndSetAnswer returned null")
            return
        }
        Log.d("GhostChat", "[ChatViewModel] processRenegotiationOffer — sending renegotiation answer")
        sendEncryptedControl(ControlMessage.Renegotiate(GhostRTC.sdpToJson(answer)))
    }

    private suspend fun handleLocalRenegotiationOffer(offer: SessionDescription) {
        Log.d("GhostChat", "[ChatViewModel] handleLocalRenegotiationOffer — sending offer via encrypted control")
        sendEncryptedControl(ControlMessage.Renegotiate(GhostRTC.sdpToJson(offer)))
    }

    // MARK: - Incoming Call Vibration

    private fun startIncomingCallVibration() {
        Log.d("GhostChat", "[ChatViewModel] startIncomingCallVibration called, vibrationEnabled=$vibrationEnabled")
        if (vibrationEnabled) vibrate()
        SoundLibrary.playRingtone(appContext, ringtoneId)
        val currentTag = ringtoneTag  // capture tag for this session

        ringtoneTimer = fixedRateTimer("ringtone", period = 2500L) {
            mainHandler.post {
                if (ringtoneTag !== currentTag) return@post  // stale callback
                if (callState == CallUIState.RINGING) {
                    if (vibrationEnabled) vibrate()
                    SoundLibrary.playRingtone(appContext, ringtoneId)
                }
            }
        }
    }

    private var ringtoneTag = Any()  // unique tag per ringtone session

    private fun stopIncomingCallVibration() {
        Log.d("GhostChat", "[ChatViewModel] stopIncomingCallVibration called")
        ringtoneTimer?.cancel()
        ringtoneTimer = null
        ringtoneTag = Any()  // invalidate any pending handler posts
        SoundLibrary.stopPreview()  // stops active MediaPlayer (ringtone)
    }

    private fun vibrate() {
        val vibrator = appContext.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator ?: return
        vibrator.vibrate(VibrationEffect.createOneShot(200, VibrationEffect.DEFAULT_AMPLITUDE))
    }

    // MARK: - Security Monitoring

    // Activity reference for screen capture detection (API 34+)
    private var activityRef: java.lang.ref.WeakReference<android.app.Activity>? = null

    /** Set Activity reference for screen capture detection — call from MainActivity */
    fun setActivity(activity: android.app.Activity) {
        Log.d("GhostChat", "[ChatViewModel] setActivity called, hasSecurityMonitor=${securityMonitor != null}")
        activityRef = java.lang.ref.WeakReference(activity)
        // If monitoring already started, register screen capture detection
        securityMonitor?.let { monitor ->
            monitor.registerScreenCaptureDetection(activity)
        }
    }

    private fun startSecurityMonitoring() {
        Log.d("GhostChat", "[ChatViewModel] startSecurityMonitoring called")
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
            // Register screen capture detection if Activity is available
            activityRef?.get()?.let { activity ->
                registerScreenCaptureDetection(activity)
            }
        }
    }

    private fun handleSecurityAlertReceived(alert: String) {
        Log.d("GhostChat", "[ChatViewModel] handleSecurityAlertReceived: $alert")
        addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_peer_security_alert, alert))
    }

    // MARK: - Contact Management

    private fun handleContactAutoSave() {
        Log.d("GhostChat", "[ChatViewModel] handleContactAutoSave called, hasPeerIdentityKey=${peerIdentityKeyData != null}, currentPeerContact=${currentPeerContact?.label}, peerIsNativeApp=$peerIsNativeApp")
        peerIdentityKeyData ?: run {
            Log.d("GhostChat", "[ChatViewModel] handleContactAutoSave — no peerIdentityKeyData, skipping")
            return
        }
        val existing = currentPeerContact

        if (existing != null) {
            Log.d("GhostChat", "[ChatViewModel] handleContactAutoSave — known contact: ${existing.label}, incrementing session count")
            // Known contact — already set in handleKeyExchange, just increment
            try {
                contactStore?.incrementSessionCount(existing.id)
            } catch (e: Exception) {
                Log.e("GhostChat", "[ChatViewModel] handleContactAutoSave — incrementSessionCount failed: ${e.message}, retrying after DB reopen")
                try {
                    val db = DatabaseService.getInstance(appContext)
                    db.close()
                    db.getDb() // Force reopen
                    contactStore = ContactStore(db)
                    contactStore?.incrementSessionCount(existing.id)
                    Log.d("GhostChat", "[ChatViewModel] handleContactAutoSave — retry succeeded")
                } catch (e2: Exception) {
                    Log.e("GhostChat", "[ChatViewModel] handleContactAutoSave — retry also failed: ${e2.message}")
                }
            }
        } else if (peerIsNativeApp) {
            Log.d("GhostChat", "[ChatViewModel] handleContactAutoSave — new native app peer, auto-saving with default name")
            // New native app peer — auto-save with default name (like iOS), show rename prompt
            val idKey = peerIdentityKeyData ?: return
            val fpShort = fingerprint.replace(" ", "").take(4)
            val defaultName = if (fpShort.isEmpty()) "Ghost" else "Ghost $fpShort"

            val contact = Contact(
                label = defaultName,
                publicKey = idKey,
                identityKey = idKey,
                ratchetState = null,
                pushToken = peerPushToken?.toByteArray(Charsets.UTF_8),
                notifyToken = peerNotifyToken?.toByteArray(Charsets.UTF_8),
                sessionCount = 1,
                lastSessionAt = Date()
            )

            viewModelScope.launch(Dispatchers.IO) {
                try {
                    contactStore?.save(contact)
                    withContext(Dispatchers.Main) {
                        currentPeerContact = contact
                        currentContactId = contact.id
                        GhostFirebaseService.activeContactChatId = contact.id
                        GhostFirebaseService.activeContactName = contact.label
                        Log.d("GhostChat", "[ChatViewModel] handleContactAutoSave — auto-saved: name='$defaultName', id=${contact.id.take(8)}")
                        // Show rename prompt after 2s delay (iOS-style: first meeting only)
                        mainHandler.postDelayed({
                            if (screen == Screen.CHAT && isConnected) {
                                pendingContactName = defaultName
                                showSaveContactPrompt = true
                            }
                        }, 2000)
                    }
                } catch (e: Exception) {
                    Log.e("GhostChat", "[ChatViewModel] handleContactAutoSave — auto-save failed: ${e.message}")
                }
            }
        } else {
            Log.d("GhostChat", "[ChatViewModel] handleContactAutoSave — web peer, skipping save prompt")
        }
        // Web peer (no platform field) — skip, contacts only for native apps
    }

    fun saveContact(name: String) {
        Log.d("GhostChat", "[ChatViewModel] saveContact called, name='$name', hasExisting=${currentPeerContact != null}")
        val trimmedName = name.trim()
        if (trimmedName.isBlank()) {
            Log.d("GhostChat", "[ChatViewModel] saveContact — blank name, skipping")
            return
        }

        // If contact was already auto-saved, just rename it (don't create duplicate)
        val existing = currentPeerContact
        if (existing != null) {
            Log.d("GhostChat", "[ChatViewModel] saveContact — renaming existing contact ${existing.id.take(8)} to '$trimmedName'")
            val updated = existing.copy(label = trimmedName)
            viewModelScope.launch(Dispatchers.IO) {
                try {
                    contactStore?.save(updated)
                } catch (e: Exception) {
                    Log.e("GhostChat", "[ChatViewModel] saveContact — rename failed: ${e.message}")
                }
                withContext(Dispatchers.Main) {
                    currentPeerContact = updated
                    GhostFirebaseService.activeContactName = trimmedName
                    showSaveContactPrompt = false
                    pendingContactName = ""
                    Log.d("GhostChat", "[ChatViewModel] saveContact — renamed, pendingLeave=$pendingLeave")
                    if (pendingLeave) { pendingLeave = false; performLeave() }
                }
            }
            return
        }

        // New contact (fallback — shouldn't happen after auto-save, but kept for safety)
        val idKey = peerIdentityKeyData ?: return
        val pubKey = crypto?.exportPublicKey()?.let {
            android.util.Base64.decode(it, android.util.Base64.DEFAULT)
        } ?: return

        val contact = Contact(
            label = trimmedName,
            publicKey = pubKey,
            identityKey = idKey,
            ratchetState = null,
            pushToken = peerPushToken?.toByteArray(Charsets.UTF_8),
            notifyToken = peerNotifyToken?.toByteArray(Charsets.UTF_8),
            sessionCount = 1,
            lastSessionAt = Date()
        )

        Log.d("GhostChat", "[ChatViewModel] saveContact — saving NEW contact id=${contact.id.take(8)}")
        viewModelScope.launch(Dispatchers.IO) {
            try {
                contactStore?.save(contact)
            } catch (e: Exception) {
                Log.e("GhostChat", "[ChatViewModel] saveContact — save failed: ${e.message}, retrying after DB reopen")
                try {
                    val db = DatabaseService.getInstance(appContext)
                    db.close()
                    db.getDb() // Force reopen
                    contactStore = ContactStore(db)
                    contactStore?.save(contact)
                    Log.d("GhostChat", "[ChatViewModel] saveContact — retry succeeded")
                } catch (e2: Exception) {
                    Log.e("GhostChat", "[ChatViewModel] saveContact — retry also failed: ${e2.message}")
                }
            }
            withContext(Dispatchers.Main) {
                currentPeerContact = contact
                currentContactId = contact.id
                showSaveContactPrompt = false
                pendingContactName = ""
                Log.d("GhostChat", "[ChatViewModel] saveContact — saved, pendingLeave=$pendingLeave")
                if (pendingLeave) { pendingLeave = false; performLeave() }
            }
        }
    }

    fun dismissSavePrompt() {
        Log.d("GhostChat", "[ChatViewModel] dismissSavePrompt called, pendingLeave=$pendingLeave")
        showSaveContactPrompt = false
        pendingContactName = ""
        if (pendingLeave) { pendingLeave = false; performLeave() }
    }

    /** Persist ratchet state for current contact before leaving.
     *  Captures state synchronously to avoid race with leave() destroying crypto. */
    private fun persistContactState() {
        Log.d("GhostChat", "[ChatViewModel] persistContactState called, hasContact=${currentPeerContact != null}, hasCrypto=${crypto != null}")
        val contact = currentPeerContact ?: run {
            Log.d("GhostChat", "[ChatViewModel] persistContactState — no currentPeerContact, skipping")
            return
        }
        val ratchetState = crypto?.exportRatchetState() ?: run {
            Log.d("GhostChat", "[ChatViewModel] persistContactState — no ratchet state to export, skipping")
            return
        }
        val skippedKeys = crypto?.exportSkippedKeys() ?: emptyList()
        Log.d("GhostChat", "[ChatViewModel] persistContactState — exporting state for contact ${contact.label}, skippedKeys=${skippedKeys.size}")

        // Serialize JSON synchronously (fast in-memory operation) before crypto is destroyed
        val stateJson = try {
            JSONObject().apply {
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
        } catch (e: Exception) {
            Log.e("GhostChat", "[ChatViewModel] persistContactState — ratchet state serialization failed: ${e.message}")
            return
        }

        val stateBytes = stateJson.toString().toByteArray()

        // IO coroutine only writes to DB — no dependency on crypto or currentPeerContact
        viewModelScope.launch(Dispatchers.IO) {
            try {
                contactStore?.updateRatchetState(contact.id, stateBytes)
                contactStore?.saveSkippedKeys(contact.id, skippedKeys)
            } catch (e: Exception) {
                Log.e("GhostChat", "[ChatViewModel] persistContactState — DB write failed: ${e.message}")
            }
        }
    }

    // MARK: - Session Persistence

    private fun saveSession() {
        Log.d("GhostChat", "[ChatViewModel] saveSession called, roomId=${roomId?.take(8)}")
        val rid = roomId ?: return
        val sessionJson = JSONObject().apply {
            put("roomId", rid)
            put("isHost", isHost)
            put("ts", System.currentTimeMillis() / 1000)
        }
        KeystoreService.saveString(sessionJson.toString(), "ghost-room")
    }

    private fun clearSession() {
        Log.d("GhostChat", "[ChatViewModel] clearSession called")
        KeystoreService.delete("ghost-room")
    }

    // MARK: - Messages

    fun addMessage(
        text: String,
        type: ChatMessage.MessageType,
        replyToId: String? = null,
        replyToText: String? = null,
        senderMessageId: String? = null
    ): ChatMessage {
        Log.d("GhostChat", "[ChatViewModel] addMessage called, type=$type, textLen=${text.length}")
        // Saved Messages — no auto-delete, persist immediately
        if (isSavedMessagesMode) {
            val msg = ChatMessage(
                contactId = SAVED_MESSAGES_CONTACT_ID,
                text = text,
                type = type,
                isDelivered = true,
                expiresAt = null,
                replyToId = replyToId,
                replyToText = replyToText,
                senderMessageId = senderMessageId
            )
            messages.add(msg)
            viewModelScope.launch(Dispatchers.IO) { messageStore?.save(msg) }
            return msg
        }

        val ttlMs = if (type == ChatMessage.MessageType.SYSTEM) {
            10 * 60 * 1000L  // System messages: 10 min
        } else {
            autoDeleteMinutes * 60 * 1000L
        }

        val msg = ChatMessage(
            text = text,
            type = type,
            expiresAt = if (ttlMs > 0) Date(System.currentTimeMillis() + ttlMs) else null,
            replyToId = replyToId,
            replyToText = replyToText,
            senderMessageId = senderMessageId
        )
        messages.add(msg)

        // Ghost Threads: persist to DB if history enabled
        if (saveMessageHistory && currentContactId != null && type != ChatMessage.MessageType.SYSTEM) {
            // Received messages viewed in open chat are immediately "delivered" (read)
            val isDeliveredForDB = msg.isDelivered || (type == ChatMessage.MessageType.RECEIVED && screen == Screen.CHAT)
            val persistMsg = ChatMessage(
                id = msg.id,
                contactId = currentContactId,
                text = text,
                type = type,
                timestamp = msg.timestamp,
                isDelivered = isDeliveredForDB,
                replyToId = replyToId,
                replyToText = replyToText,
                senderMessageId = senderMessageId
            )
            viewModelScope.launch(Dispatchers.IO) { messageStore?.save(persistMsg) }
        }

        return msg
    }

    private fun addSystemMessage(text: String) {
        Log.d("GhostChat", "[ChatViewModel] addSystemMessage called, text='${text.take(40)}'")
        addMessage(text, ChatMessage.MessageType.SYSTEM)
    }

    /// Load message history from DB for current contact
    /// Guard: verify contactId hasn't changed during fetch (fast switch protection)
    fun loadMessageHistory() {
        Log.d("GhostChat", "[ChatViewModel] loadMessageHistory called, contactId=${currentContactId?.take(8)}, isSavedMessages=$isSavedMessagesMode, saveHistory=$saveMessageHistory")
        val contactId = currentContactId ?: run {
            Log.d("GhostChat", "[ChatViewModel] loadMessageHistory — no contactId, skipping")
            return
        }
        // Always load for saved messages; otherwise only if history is enabled
        if (!isSavedMessagesMode && !saveMessageHistory) {
            Log.d("GhostChat", "[ChatViewModel] loadMessageHistory — history disabled, skipping")
            return
        }
        viewModelScope.launch(Dispatchers.IO) {
            val history = messageStore?.fetchForContact(contactId) ?: return@launch
            withContext(Dispatchers.Main) {
                // Verify contact hasn't changed during fetch
                if (currentContactId != contactId) return@withContext
                if (history.isNotEmpty()) {
                    messages.addAll(0, history)
                }
            }
        }
    }

    fun deleteHistory(contactId: String) {
        Log.d("GhostChat", "[ChatViewModel] deleteHistory called, contactId=${contactId.take(8)}")
        viewModelScope.launch(Dispatchers.IO) { messageStore?.deleteForContact(contactId) }
    }

    private var lastTTLCleanupAt = 0L

    private fun startMessageCleanup() {
        Log.d("GhostChat", "[ChatViewModel] startMessageCleanup called")
        messageCleanupTimer?.cancel()
        messageCleanupTimer = fixedRateTimer("message-cleanup", period = 1000L) {
            mainHandler.post {
                val now = System.currentTimeMillis()
                messages.removeAll { it.expiresAt != null && it.expiresAt.time <= now }

                // Clean up sentMessages — remove for expired messages + stale entries (>5 min)
                val validMessageIds = messages.map { it.id }.toSet()
                val cutoff = now - 300_000L // 5 minutes
                sentMessages.entries.removeAll { (_, rec) ->
                    rec.id !in validMessageIds || rec.sentAt < cutoff
                }

                // Per-contact TTL cleanup from DB (every 60 seconds)
                if (saveMessageHistory && now - lastTTLCleanupAt >= 60_000L) {
                    lastTTLCleanupAt = now
                    viewModelScope.launch(Dispatchers.IO) {
                        cleanupExpiredMessages()
                    }
                }
            }
        }
    }

    /** Clean up expired messages from DB based on per-contact TTL */
    private fun cleanupExpiredMessages() {
        Log.d("GhostChat", "[ChatViewModel] cleanupExpiredMessages called")
        val store = contactStore ?: return
        val msgStore = messageStore ?: return
        val allContacts = store.fetchAll()

        for (contact in allContacts) {
            val ttl = contact.messageTTL ?: continue
            if (ttl <= 0) continue
            msgStore.deleteExpired(contact.id, ttl)
        }

        // Also remove from in-memory messages if current contact has TTL
        val cId = currentContactId ?: return
        val contact = allContacts.firstOrNull { it.id == cId } ?: return
        val ttl = contact.messageTTL ?: return
        if (ttl <= 0) return
        val cutoffMs = System.currentTimeMillis() - (ttl * 1000L)
        mainHandler.post {
            messages.removeAll { it.contactId == cId && it.timestamp.time < cutoffMs }
        }
    }

    // MARK: - Room Rotation (Forward Secrecy at signaling level)

    /** Start periodic room rotation (host only). Random 10-25 min interval. */
    private fun startRoomRotationTimer() {
        Log.d("GhostChat", "[ChatViewModel] startRoomRotationTimer called")
        roomRotationTimer?.cancel()
        val interval = (600_000L..1_500_000L).random() // 10-25 minutes
        roomRotationTimer = fixedRateTimer("room-rotation", initialDelay = interval, period = Long.MAX_VALUE) {
            mainHandler.post {
                viewModelScope.launch { rotateRoom() }
            }
            // One-shot: cancel after first fire
            roomRotationTimer?.cancel()
        }
    }

    /** Perform room rotation: create new room on existing WS, notify peer, update local state.
     *  CRITICAL: Does NOT reinitialize signaling/rtc/crypto — preserves active P2P session. */
    private suspend fun rotateRoom() {
        Log.d("GhostChat", "[ChatViewModel] rotateRoom called, isHost=$isHost, isConnected=$isConnected, callState=$callState")
        if (!isHost || !isConnected || callState != CallUIState.IDLE) {
            Log.d("GhostChat", "[ChatViewModel] rotateRoom — conditions not met, skipping")
            return
        }
        val sig = signaling ?: run {
            Log.d("GhostChat", "[ChatViewModel] rotateRoom — signaling is null, skipping")
            return
        }
        if (!sig.isConnected) {
            Log.d("GhostChat", "[ChatViewModel] rotateRoom — signaling not connected, skipping")
            return
        }

        isRotatingRoom = true

        // Temporarily override onRoomCreated to capture new room ID
        val deferred = CompletableDeferred<String?>()
        val originalCallback = sig.onRoomCreated
        sig.onRoomCreated = { id ->
            deferred.complete(id)
        }

        // Send create-room on existing WebSocket (no reconnect, no new SignalingClient)
        sig.createRoom()

        // Wait for room-created response (10s timeout)
        val newRoomId = withTimeoutOrNull(10_000) { deferred.await() }

        // Restore original callback
        sig.onRoomCreated = originalCallback

        if (newRoomId == null) {
            isRotatingRoom = false
            return
        }

        // Notify peer via encrypted P2P channel
        sendEncryptedControl(ControlMessage.RoomRotate(newRoomId))

        // Update local room ID
        roomId = newRoomId
        isRotatingRoom = false

        // Schedule next rotation
        startRoomRotationTimer()
    }

    /** Peer received room-rotate from host — switch to new room for re-signaling */
    private fun handleRoomRotate(newRoomId: String) {
        Log.d("GhostChat", "[ChatViewModel] handleRoomRotate called, newRoomId=${newRoomId.take(8)}...")
        if (newRoomId.isEmpty()) {
            Log.d("GhostChat", "[ChatViewModel] handleRoomRotate — empty roomId, skipping")
            return
        }

        isRotatingRoom = true
        roomId = newRoomId
        Log.d("GhostChat", "[ChatViewModel] handleRoomRotate — rejoining signaling as guest")

        // Rejoin signaling server with new room
        signaling?.rejoinRoom(newRoomId, "guest")

        // Clear flag after delay (ignore peer-joined from rejoin)
        mainHandler.postDelayed({ isRotatingRoom = false }, 2000)
    }

    // MARK: - Connection Timeout

    private fun startConnectionTimeout() {
        Log.d("GhostChat", "[ChatViewModel] startConnectionTimeout called (30s)")
        cancelConnectionTimeout()
        connectionTimeout = Handler(Looper.getMainLooper())
        connectionTimeoutRunnable = Runnable {
            Log.d("GhostChat", "[ChatViewModel] connectionTimeout fired — isConnected=$isConnected, currentPeerContact=${currentPeerContact?.label}, screen=$screen")
            if (!isConnected) {
                // Если мы в чате с контактом — НЕ leave(), просто показать что peer оффлайн
                if (currentPeerContact != null || screen == Screen.CHAT) {
                    Log.d("GhostChat", "[ChatViewModel] connectionTimeout: peer offline, staying in chat")
                    showPeerDisconnectedBanner = true
                    return@Runnable
                }
                addSystemMessage(appContext.getString(com.ghost.chat.R.string.system_connection_timeout))
                leave()
            }
        }
        connectionTimeout?.postDelayed(connectionTimeoutRunnable!!, 30_000)
    }

    private fun cancelConnectionTimeout() {
        Log.d("GhostChat", "[ChatViewModel] cancelConnectionTimeout called")
        connectionTimeoutRunnable?.let { connectionTimeout?.removeCallbacks(it) }
        connectionTimeout = null
        connectionTimeoutRunnable = null
    }

    // MARK: - Leave / Cleanup

    var pendingLeave by mutableStateOf(false)
        private set

    fun leave() {
        val caller = Thread.currentThread().stackTrace.take(8).joinToString("\n") { "${it.className}.${it.methodName}:${it.lineNumber}" }
        Log.d("GhostChat", "[ChatViewModel] leave called from:\n$caller")
        Log.d("GhostChat", "[ChatViewModel] leave called, screen=$screen, isConnected=$isConnected, currentPeerContact=${currentPeerContact?.label}, keyExchangeCompleted=$keyExchangeCompleted, peerIsNativeApp=$peerIsNativeApp, pendingLeave=$pendingLeave, isLeaving=$isLeaving")
        if (isLeaving) {
            Log.d("GhostChat", "[ChatViewModel] leave — already leaving, skipping")
            return
        }
        isLeaving = true
        if (isSavedMessagesMode) {
            Log.d("GhostChat", "[ChatViewModel] leave — saved messages mode, leaving saved messages")
            leaveSavedMessages()
            return
        }
        // Если новый native peer (не из контактов) и был key exchange — спросить имя перед выходом
        // Как на iOS: prompt on leave if contact is new and not auto-saved yet
        if (currentPeerContact == null && keyExchangeCompleted && peerIdentityKeyData != null && peerIsNativeApp) {
            Log.d("GhostChat", "[ChatViewModel] leave — new native peer detected, showing save contact prompt")
            showSaveContactPrompt = true
            pendingLeave = true
            return
        }
        Log.d("GhostChat", "[ChatViewModel] leave — no save prompt needed, performing leave")
        performLeave()
    }

    private fun performLeave() {
        Log.d("GhostChat", "[ChatViewModel] performLeave called, callState=$callState, hasRTC=${rtc != null}, hasSignaling=${signaling != null}, hasCrypto=${crypto != null}")
        isAutoConnecting = false
        stopTyping()
        peerIsTyping = false
        peerTypingCancelRunnable?.let { mainHandler.removeCallbacks(it) }
        peerTypingCancelRunnable = null

        persistContactState()

        // End call if active
        if (callState != CallUIState.IDLE) {
            stopIncomingCallVibration()
            callingTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
            callingTimeoutRunnable = null
            ringingTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
            ringingTimeoutRunnable = null
            voice?.endCall()
            voice?.destroy()
            voice = null
            callState = CallUIState.IDLE
        }

        cancelConnectionTimeout()
        messageCleanupTimer?.cancel()
        messageCleanupTimer = null
        pendingRoomPollTimer?.cancel()
        pendingRoomPollTimer = null
        pendingCallAfterConnect = false

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

        peerLeftRunnable?.let { mainHandler.removeCallbacks(it) }
        peerLeftRunnable = null
        isConnected = false
        isVerified = false
        keyExchangeCompleted = false
        roomId = null
        fingerprint = ""
        messages.clear()
        sentMessages.clear()
        roomRotationTimer?.cancel()
        roomRotationTimer = null
        isRotatingRoom = false
        pendingIceCandidates.clear()
        pendingSignals.clear()
        pendingRenegotiationOffer = null
        pendingIceRestartOffer = null
        currentPeerContact = null
        currentContactId = null
        GhostFirebaseService.activeContactChatId = null
        GhostFirebaseService.activeContactName = null
        peerIdentityKeyData = null
        expectedPeerIdentityKey = null
        peerPushToken = null
        peerNotifyToken = null
        tokensSentToPeerThisSession = false
        isFromPush = false
        pendingAcceptCall = false
        peerIsNativeApp = false
        peerSupportsFiles = false
        fileTransfer.cancelAll()
        showSaveContactPrompt = false
        pendingContactName = ""
        securityAlert = null
        showVerificationPanel = false
        isMuted = false
        isSpeakerOn = false
        replyingTo = null
        editingMessage = null
        showPeerDisconnectedBanner = false
        connectionStep = ConnectionStep.CONNECTING_TO_SERVER
        peerStatus = PeerStatus.OFFLINE
        peerLastSeenAt = 0L
        peerStatusTransitionRunnable?.let { mainHandler.removeCallbacks(it) }
        peerStatusTransitionRunnable = null

        screen = Screen.WELCOME
        Log.d("GhostChat", "[ChatViewModel] performLeave — state reset complete, screen=WELCOME")

        // Don't auto-join pending deep link — user already navigated away.
        // They'll see it on WelcomeScreen and can join manually.
        if (pendingDeepLinkRoom != null) {
            Log.d("GhostChat", "[ChatViewModel] performLeave — pending deep link room exists, keeping for WelcomeScreen (not auto-joining)")
        }

        isLeaving = false
        isCreatingRoom = false
    }

    // MARK: - Deep Link

    fun handleDeepLink(roomIdFromLink: String) {
        Log.d("GhostChat", "[ChatViewModel] handleDeepLink called, roomId=${roomIdFromLink.take(8)}..., screen=$screen")
        if (screen == Screen.CHAT || screen == Screen.CONNECTING) {
            Log.d("GhostChat", "[ChatViewModel] handleDeepLink — currently in $screen, queuing as pendingDeepLinkRoom")
            pendingDeepLinkRoom = roomIdFromLink
        } else {
            Log.d("GhostChat", "[ChatViewModel] handleDeepLink — joining room immediately")
            joinRoom(roomIdFromLink)
        }
    }

    // MARK: - Settings Actions

    fun deleteAllContacts() {
        Log.d("GhostChat", "[ChatViewModel] deleteAllContacts called")
        viewModelScope.launch(Dispatchers.IO) {
            contactStore?.deleteAll()
            Log.d("GhostChat", "[ChatViewModel] deleteAllContacts complete")
        }
    }

    fun destroyAllData() {
        Log.d("GhostChat", "[ChatViewModel] destroyAllData called — HARD RESET")
        viewModelScope.launch(Dispatchers.IO) {
            DatabaseService.getInstance(appContext).destroyAll()
            IdentityKeyService.destroy()
            KeystoreService.clear()
            Log.d("GhostChat", "[ChatViewModel] destroyAllData — all data destroyed, leaving")
            withContext(Dispatchers.Main) {
                leave()
            }
        }
    }

    // MARK: - Saved Messages

    /** Open local "Saved Messages" chat — like Telegram favorites */
    fun openSavedMessages() {
        Log.d("GhostChat", "[ChatViewModel] openSavedMessages called")
        currentContactId = SAVED_MESSAGES_CONTACT_ID
        // Prevent push suppression — Saved Messages is not a real contact chat
        GhostFirebaseService.activeContactChatId = null
        GhostFirebaseService.activeContactName = null
        messages.clear()
        loadMessageHistory()
        screen = Screen.CHAT
    }

    private fun leaveSavedMessages() {
        Log.d("GhostChat", "[ChatViewModel] leaveSavedMessages called")
        currentContactId = null
        messages.clear()
        screen = Screen.WELCOME
        isLeaving = false
    }

    /** Start chat from saved contact — auto-connect: create room or join pending (port of iOS) */
    fun startChatWithContact(contact: Contact) {
        ghostLog("[ChatViewModel] startChatWithContact label=${contact.label}", appContext)

        // Idempotent: if we're already in this contact's chat with active room → just return
        // Prevents double-create race when screen re-renders or user taps twice
        if (currentPeerContact?.id == contact.id && screen == Screen.CHAT && roomId != null) {
            ghostLog("[ChatViewModel] startChatWithContact: already in this contact's chat with active room, skipping", appContext)
            return
        }

        // Clear old connection state — room may have expired
        roomId = null
        signaling?.disconnect()
        signaling = null
        rtc?.destroy()
        rtc = null
        crypto = null
        voice = null
        keyExchangeCompleted = false
        isConnected = false
        showPeerDisconnectedBanner = false
        pendingRoomPollTimer?.cancel()
        pendingRoomPollTimer = null

        expectedPeerIdentityKey = contact.identityKey
        currentPeerContact = contact
        currentContactId = contact.id
        GhostFirebaseService.activeContactChatId = contact.id
        GhostFirebaseService.activeContactName = contact.label
        pendingMessageContactId = null
        pendingMessageType = null
        // Clear previous messages to avoid duplicates on re-open
        messages.clear()
        loadMessageHistory()
        // Mark all received messages as read (clears unread badge)
        viewModelScope.launch(Dispatchers.IO) {
            messageStore?.markAllDelivered(contact.id)
        }
        // Show chat UI immediately — no room yet
        screen = Screen.CHAT
        startMessageCleanup()

        // Auto-connect: check for pending room from peer, or create our own
        viewModelScope.launch { autoConnectToContact(contact) }
    }

    /** Auto-connect logic: check pending -> join OR create -> register -> poll */
    private suspend fun autoConnectToContact(contact: Contact) {
        if (currentPeerContact?.id != contact.id) return
        // Prevent double-call from startChatWithContact + sendMessage
        if (isAutoConnecting) {
            ghostLog("[ChatViewModel] autoConnect: already in progress, skipping", appContext)
            return
        }
        // If already connected or have a room, skip
        if (isConnected || roomId != null) {
            ghostLog("[ChatViewModel] autoConnect: already connected or have room, skipping", appContext)
            return
        }
        isAutoConnecting = true
        try {
            autoConnectToContactInner(contact)
        } finally {
            isAutoConnecting = false
        }
    }

    private suspend fun autoConnectToContactInner(contact: Contact) {
        ghostLog("[ChatViewModel] autoConnectToContact: ${contact.label}", appContext)

        // Deterministic role: compare identity key hashes
        // Lower hash = HOST (creates room and waits)
        // Higher hash = GUEST (only checks pending room and joins)
        val myHash = identityKeyHash() ?: ""
        val peerHash = identityKeyHash(contact) ?: ""
        val iAmHost = myHash < peerHash
        ghostLog("[ChatViewModel] autoConnect: role=${if (iAmHost) "HOST" else "GUEST"}, myHash=${myHash.take(8)}, peerHash=${peerHash.take(8)}", appContext)

        // GUEST: only check pending room, never create own
        if (!iAmHost) {
            ghostLog("[ChatViewModel] GUEST: waiting for host to create room", appContext)
            startPendingRoomPolling(contact)
            return
        }

        // HOST: check if peer already has a room (they might have been first), else create
        val pendingRoomId = checkPendingRoom(contact)
        if (pendingRoomId != null) {
            ghostLog("[ChatViewModel] HOST found existing pending room, joining ${pendingRoomId.take(8)}", appContext)
            joinRoomById(pendingRoomId)
            return
        }

        // HOST: create room and register pending
        ghostLog("[ChatViewModel] HOST: creating room", appContext)
        peerStatus = PeerStatus.CONNECTING
        isHost = true
        if (crypto == null) {
            crypto = GhostCrypto().also { it.generateKeyPair() }
        }
        rtc = GhostRTC(appContext).also { it.privacyMode = privacyMode }
        turnService = TURNService(SERVER_URL)
        rtc?.setTurnService(turnService)

        // Initialize signaling if needed (may be null on first auto-connect)
        if (signaling == null) {
            signaling = SignalingClient(SERVER_URL)
        }

        setupSignalingCallbacks()
        setupRTCCallbacks()

        signaling?.connect()

        // Wait for WebSocket to connect before creating room (up to 3s)
        for (i in 0 until 30) {
            kotlinx.coroutines.delay(100)
            if (signaling?.isConnected == true) break
        }
        if (signaling?.isConnected != true) {
            ghostLog("[ChatViewModel] autoConnect: signaling connection failed", appContext)
            return
        }

        signaling?.createRoom()

        // Wait for room creation (up to 5 seconds)
        for (i in 0 until 50) {
            kotlinx.coroutines.delay(100)
            if (roomId != null) break
        }

        val myRoomId = roomId
        if (myRoomId == null || currentPeerContact?.id != contact.id) {
            ghostLog("[ChatViewModel] autoConnect: room creation failed or contact changed", appContext)
            return
        }

        // Register pending room so peer can find us
        if (peerHash.isNotEmpty() && myHash.isNotEmpty()) {
            registerPendingRoom(peerHash, myRoomId, myHash)
        }

        // Send invite push if we have a token
        val tokenData = contact.notifyToken ?: contact.pushToken
        if (tokenData != null) {
            val token = String(tokenData, Charsets.UTF_8)
            if (token.length >= 10) {
                val platform = if (token.length <= 80) "ios" else "android"
                sendInvitePush(token, myRoomId, contact.label, platform)
            }
        }

        // Start polling — peer might create their room before finding ours
        startPendingRoomPolling(contact)
    }

    /** Poll every 5s for pending room from peer (in case they created before us) */
    private fun startPendingRoomPolling(contact: Contact) {
        Log.d("GhostChat", "[ChatViewModel] startPendingRoomPolling called, contact=${contact.label}")
        peerStatus = PeerStatus.SEARCHING
        pendingRoomPollTimer?.cancel()
        pendingRoomPollTimer = fixedRateTimer("pendingRoomPoll", initialDelay = 5000L, period = 5000L) {
            viewModelScope.launch {
                // Stop polling if connected or contact changed or left chat
                if (isConnected || currentPeerContact?.id != contact.id || screen != Screen.CHAT) {
                    pendingRoomPollTimer?.cancel()
                    pendingRoomPollTimer = null
                    return@launch
                }

                // HOST already has a room — don't switch, wait for peer to find us
                if (isHost && roomId != null) {
                    ghostLog("[ChatViewModel] Poll skipped — HOST already has room ${roomId?.take(8)}", appContext)
                    return@launch
                }

                val pendingId = checkPendingRoom(contact)
                if (pendingId != null) {
                    ghostLog("[ChatViewModel] Poll found pending room, joining ${pendingId.take(8)}", appContext)
                    pendingRoomPollTimer?.cancel()
                    pendingRoomPollTimer = null

                    // Disconnect from our room and join peer's
                    signaling?.leaveRoom()
                    signaling?.disconnect()
                    signaling = null
                    rtc?.destroy()
                    rtc = null
                    roomId = null

                    joinRoomById(pendingId)
                }
            }
        }
    }

    // MARK: - Pending Room (offline contact reconnection)

    private fun identityKeyHash(): String? {
        return try {
            val keyData = IdentityKeyService.publicKeyData ?: return null
            MessageDigest.getInstance("SHA-256").digest(keyData).joinToString("") { "%02x".format(it) }
        } catch (e: Exception) { null }
    }

    private fun identityKeyHash(contact: Contact): String? {
        val data = contact.identityKey ?: return null
        return MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) }
    }

    private suspend fun registerPendingRoom(peerHash: String, roomId: String, creatorHash: String) {
        withContext(Dispatchers.IO) {
            try {
                val url = URL("$SERVER_URL/api/pending-room")
                val conn = (url.openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"
                    setRequestProperty("Content-Type", "application/json")
                    doOutput = true
                }
                OutputStreamWriter(conn.outputStream).use {
                    it.write(JSONObject().apply {
                        put("peerHash", peerHash)
                        put("roomId", roomId)
                        put("creatorHash", creatorHash)
                    }.toString())
                }
                val code = conn.responseCode
                if (code in 200..299) {
                    Log.d("GhostChat", "[ChatViewModel] registerPendingRoom: OK status=$code, peerHash=${peerHash.take(8)}, roomId=${roomId.take(8)}")
                } else {
                    val body = try { conn.errorStream?.bufferedReader()?.readText() ?: "" } catch (_: Exception) { "" }
                    Log.e("GhostChat", "[ChatViewModel] registerPendingRoom: FAILED status=$code, body=$body, peerHash=${peerHash.take(8)}")
                }
                conn.disconnect()
            } catch (e: Exception) {
                Log.e("GhostChat", "[ChatViewModel] registerPendingRoom error: ${e.message}")
            }
        }
    }

    private suspend fun checkPendingRoom(contact: Contact): String? = withContext(Dispatchers.IO) {
        try {
            val myHash = identityKeyHash() ?: return@withContext null
            val url = URL("$SERVER_URL/api/pending-room?myHash=$myHash")
            val conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 5000
            }
            if (conn.responseCode == 200) {
                val json = JSONObject(conn.inputStream.bufferedReader().use { it.readText() })
                val rid = json.optString("roomId", "")
                conn.disconnect()
                if (rid.isNotEmpty() && rid != "null") rid else null
            } else {
                conn.disconnect()
                null
            }
        } catch (e: Exception) {
            Log.e("GhostChat", "[ChatViewModel] checkPendingRoom error: ${e.message}")
            null
        }
    }

    private fun joinRoomById(roomId: String) {
        Log.d("GhostChat", "[ChatViewModel] joinRoomById called, roomId=${roomId.take(8)}")
        if (signaling != null) return
        Log.d("GhostChat", "[ChatViewModel] joinRoomById: ${roomId.take(8)}")

        // CRITICAL: joining = guest, never host
        isHost = false

        crypto = GhostCrypto().also { it.generateKeyPair() }
        rtc = GhostRTC(appContext).also { it.privacyMode = privacyMode }
        signaling = SignalingClient(SERVER_URL)
        turnService = TURNService(SERVER_URL)
        rtc?.setTurnService(turnService)

        setupSignalingCallbacks()
        setupRTCCallbacks()

        signaling?.connect()
        signaling?.joinRoom(roomId)
    }

    /** Navigate back to contacts without disconnecting (preserves active P2P session) */
    fun navigateBack() {
        Log.d("GhostChat", "[ChatViewModel] navigateBack called, screen=$screen, isConnected=$isConnected, currentPeerContact=${currentPeerContact?.label}, keyExchangeCompleted=$keyExchangeCompleted, peerIsNativeApp=$peerIsNativeApp, pendingLeave=$pendingLeave")
        // Если новый native peer (не из контактов) и был key exchange — спросить имя
        if (currentPeerContact == null && keyExchangeCompleted && peerIdentityKeyData != null && peerIsNativeApp) {
            Log.d("GhostChat", "[ChatViewModel] navigateBack — new native peer, showing save contact prompt")
            showSaveContactPrompt = true
            pendingLeave = true
            return
        }
        Log.d("GhostChat", "[ChatViewModel] navigateBack — returning to WELCOME")
        GhostFirebaseService.activeContactChatId = null
        GhostFirebaseService.activeContactName = null
        screen = Screen.WELCOME
    }

    /** Handle incoming push notification — highlight contact in UI */
    private fun handleMessagePush(type: String, senderName: String) {
        Log.d("GhostChat", "[ChatViewModel] handleMessagePush — type=$type, senderName=$senderName")
        viewModelScope.launch(Dispatchers.IO) {
            val contacts = contactStore?.fetchAll() ?: return@launch
            val contact = contacts.find { it.label == senderName } ?: run {
                Log.d("GhostChat", "[ChatViewModel] handleMessagePush — no contact found for '$senderName'")
                return@launch
            }
            Log.d("GhostChat", "[ChatViewModel] handleMessagePush — highlighting contact ${contact.id.take(8)}")
            withContext(Dispatchers.Main) {
                pendingMessageContactId = contact.id
                pendingMessageType = type
            }
        }
    }

    /** Handle notification tap — open contact's chat by sender name */
    fun handleMessagePushTap(senderName: String) {
        Log.d("GhostChat", "[ChatViewModel] handleMessagePushTap called, senderName=$senderName")
        viewModelScope.launch(Dispatchers.IO) {
            val contacts = contactStore?.fetchAll() ?: return@launch
            val contact = contacts.find { it.label == senderName } ?: return@launch
            withContext(Dispatchers.Main) {
                startChatWithContact(contact)
            }
        }
    }

    // MARK: - Cleanup

    override fun onCleared() {
        Log.d("GhostChat", "[ChatViewModel] onCleared called — ViewModel being destroyed")
        super.onCleared()
        leave()
        runCatching { fileTransfer.shutdown() }
        Log.d("GhostChat", "[ChatViewModel] onCleared complete")
    }
}
