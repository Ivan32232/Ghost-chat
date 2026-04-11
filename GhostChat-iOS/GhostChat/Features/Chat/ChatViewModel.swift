import Foundation
import Combine
import CryptoKit
import WebRTC
import AudioToolbox
import UIKit
import os.log

/// Debug log to file (works in TestFlight/release — NSLog is filtered on iOS 26)
private let _ghostLogger = Logger(subsystem: "com.ivanpokhvalitov.ghostchat", category: "Debug")

#if DEBUG
extension Notification.Name {
    static let ghostDebugLog = Notification.Name("ghostDebugLog")
}
#endif

func ghostLog(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(msg)\n"
    // Triple logging: os_log .fault (always visible) + NSLog + file
    _ghostLogger.fault("🔴 \(msg, privacy: .public)")
    NSLog("🔴 %@", msg)
    #if DEBUG
    // Feed debug overlay (capped at 50 lines, newest on top)
    Task { @MainActor in
        NotificationCenter.default.post(name: .ghostDebugLog, object: msg)
    }
    #endif
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let file = dir.appendingPathComponent("ghost_debug.log")
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: file.path) {
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: file)
        }
    }
}

/// Главный orchestrator — порт app.js (GhostChat class)
/// Связывает SignalingClient + GhostRTC + GhostCrypto + GhostVoice
@MainActor
final class ChatViewModel: ObservableObject {

    private let logger = Logger(subsystem: "com.ivanpokhvalitov.ghostchat", category: "ChatViewModel")

    // MARK: - Configuration

    static let serverURL = URL(string: "https://ghostchat.one")!
    static let savedMessagesContactId = "saved-messages"

    /// Whether we're in "Saved Messages" mode (local notepad, no P2P)
    var isSavedMessagesMode: Bool {
        currentContactId == Self.savedMessagesContactId
    }

    /// Auto-delete time derived from user setting. 0 = no auto-delete.
    private var messageAutoDeleteTime: TimeInterval {
        autoDeleteMinutes > 0 ? TimeInterval(autoDeleteMinutes) * 60 : 0
    }

    // MARK: - Published State

    @Published var screen: Screen = .welcome
    @Published var messages: [ChatMessage] = []
    @Published var roomId: String?
    @Published var fingerprint: String = ""
    @Published var isConnected = false
    @Published var isVerified = false
    @Published var privacyMode: Bool {
        didSet { Self.saveSetting(privacyMode, forKey: "settings_privacy_mode") }
    }

    // MARK: - Settings (persisted via Keychain)

    @Published var autoDeleteMinutes: Int {
        didSet { Self.saveSetting(autoDeleteMinutes, forKey: "settings_auto_delete") }
    }
    @Published var screenshotNotifications: Bool {
        didSet { Self.saveSetting(screenshotNotifications, forKey: "settings_screenshot_notify") }
    }
    @Published var messageSoundEnabled: Bool {
        didSet { Self.saveSetting(messageSoundEnabled, forKey: "settings_sound") }
    }
    @Published var vibrationEnabled: Bool {
        didSet { Self.saveSetting(vibrationEnabled, forKey: "settings_vibration") }
    }
    @Published var ringtoneId: String {
        didSet { Self.saveStringSetting(ringtoneId, forKey: "settings_ringtone") }
    }
    @Published var messageSoundId: String {
        didSet { Self.saveStringSetting(messageSoundId, forKey: "settings_msg_sound") }
    }

    // Debug overlay log (only in DEBUG builds)
    #if DEBUG
    @Published var debugLog: [String] = []
    #endif

    // Reply state (Telegram-style swipe-to-reply)
    @Published var replyingTo: ChatMessage?

    // Peer disconnected banner
    @Published var showPeerDisconnectedBanner = false

    // Call state
    @Published var callState: CallUIState = .idle
    @Published var callTimer: String = "00:00"
    @Published var isMuted = false
    @Published var isSpeakerOn = false
    var pendingCallAfterConnect = false

    // Security alerts
    @Published var securityAlert: SecurityMonitor.SecurityAlert?

    // H3: Deep link confirmation
    @Published var pendingDeepLinkRoom: String?

    // Contacts
    @Published var currentPeerContact: Contact?
    @Published var showSaveContactPrompt = false
    private var pendingLeave = false
    @Published var pendingContactName: String = ""

    // Chat invite push
    @Published var pendingInviteRoom: String?
    @Published var pendingInviterName: String?

    // Message push — подсветка чата на WelcomeScreen
    @Published var pendingMessageContactId: String?
    @Published var pendingMessageType: String?

    enum Screen {
        case welcome, waiting, connecting, chat
    }

    /// Этапы подключения — для анимации и progress steps
    enum ConnectionStep: Int, CaseIterable {
        case connectingToServer = 0
        case waitingForPeer = 1
        case exchangingKeys = 2
        case secured = 3
    }

    @Published var connectionStep: ConnectionStep = .connectingToServer

    enum CallUIState {
        case idle, calling, ringing, active
    }

    /// Peer status states — shown in chat header
    enum PeerStatus: String {
        case online          // isConnected && keyExchangeCompleted
        case connecting      // signaling connected but !isConnected (room exists, waiting for P2P)
        case searching       // pendingRoomPollTimer active (polling for peer's room)
        case recentlyOnline  // peer disconnected less than 5 minutes ago
        case offline         // peer disconnected more than 5 minutes ago or never connected

        var localizedName: String {
            switch self {
            case .online:         return String(localized: "status.online")
            case .connecting:     return String(localized: "status.connecting")
            case .searching:      return String(localized: "status.searching")
            case .recentlyOnline: return String(localized: "status.recentlyOnline")
            case .offline:        return String(localized: "status.offline")
            }
        }
    }

    // MARK: - Private Properties

    private var signaling: SignalingClient?
    private var rtc: GhostRTC?
    private var crypto: GhostCrypto?
    private var voice: GhostVoice?
    private var securityMonitor = SecurityMonitor()
    private var turnService: TURNService?
    private let messageStore = MessageStore()
    var currentContactId: String?    // Contact we're chatting with (Ghost Threads)

    /// Whether message history is enabled (persisted in Keychain)
    @Published var saveMessageHistory: Bool {
        didSet { Self.saveSetting(saveMessageHistory, forKey: "settings_save_history") }
    }

    /// Whether "Saved Messages" (Избранное) is enabled
    @Published var savedMessagesEnabled: Bool {
        didSet { Self.saveSetting(savedMessagesEnabled, forKey: "settings_saved_messages") }
    }

    private var isHost = false
    private var pendingIceCandidates: [RTCIceCandidate] = []
    private var pendingSignals: [[String: Any]] = []
    private var pendingRenegotiationOffer: RTCSessionDescription?
    private var pendingIceRestartOffer: RTCSessionDescription?
    private var pendingRemoteStream: RTCMediaStream?
    private var sentMessages: [Int: (id: UUID, sentAt: Date)] = [:] // counter → (message ID, sent timestamp)
    private var keyExchangeCompleted = false    // C2: prevent re-exchange
    private var pendingPQDerivation = false     // C1: host waits for PQ exchange
    private var messageCleanupTimer: Timer?
    private var connectionTimeout: Timer?
    private var vibrationTimer: Timer?
    private var peerIdentityKeyData: Data?
    private var expectedPeerIdentityKey: Data?
    private var screenshotObserver: NSObjectProtocol?
    private var activeCallUUID: UUID?
    private var localVoIPToken: Data?
    private var pushAuthToken: String?  // Auth token for push endpoints (from TURN credentials)
    private var pushAuthIssuedAt: Date?  // When pushAuthToken was fetched — used to detect staleness
    private var tokensSentToPeerThisSession = false  // Dedup guard for mutual token exchange (prevents ACK ping-pong)

    /// Fetch fresh pushAuth if cache is nil or older than 4 minutes (server window is 5 min)
    private func ensureFreshPushAuth() async {
        let age = pushAuthIssuedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        if pushAuthToken == nil || age > 240 {
            ghostLog("[PushAuth] Refreshing (age=\(Int(age))s, wasNil=\(pushAuthToken == nil))")
            if let fresh = (try? await turnService?.fetchCredentials())?.pushAuth {
                pushAuthToken = fresh
                pushAuthIssuedAt = Date()
            } else {
                ghostLog("[PushAuth] Refresh FAILED")
            }
        }
    }
    private var localRegularPushToken: Data?
    private var peerPushToken: Data?
    private var peerNotifyToken: Data?
    private var peerIsNativeApp = false
    private var fileTransfer = FileTransferService()
    @Published var peerSupportsFiles = false
    private var typingTimer: Timer?
    private var peerTypingTimer: Timer?
    private var peerLeftTimer: Timer?
    private var lastTypingSentAt: Date?
    private var isFromPush = false  // incoming VoIP push initiated this session
    private var roomCreatedContinuation: CheckedContinuation<String?, Never>?
    private var roomRotationTimer: Timer?
    private var ringingTimeout: Timer?
    private var callingTimeout: Timer?
    private var isRotatingRoom = false
    private var isCreatingRoom = false
    private var isLeaving = false

    // Typing indicator
    @Published var peerIsTyping = false

    // Peer status
    @Published var peerStatus: PeerStatus = .offline
    private var peerLastSeenDate: Date?
    private var peerStatusTransitionTimer: Timer?

    // MARK: - Lifecycle

    init() {
        // Load persisted settings from Keychain
        self.privacyMode = Self.loadBoolSetting(forKey: "settings_privacy_mode", default: false)
        // Force reset auto-delete to 0 (fix stale Keychain from old builds)
        let autoDelMigrated = Self.loadBoolSetting(forKey: "settings_auto_delete_v2_migrated", default: false)
        if !autoDelMigrated {
            Self.saveSetting(0, forKey: "settings_auto_delete")
            Self.saveSetting(true, forKey: "settings_auto_delete_v2_migrated")
        }
        self.autoDeleteMinutes = Self.loadIntSetting(forKey: "settings_auto_delete", default: 0)
        self.screenshotNotifications = Self.loadBoolSetting(forKey: "settings_screenshot_notify", default: true)
        self.messageSoundEnabled = Self.loadBoolSetting(forKey: "settings_sound", default: true)
        self.vibrationEnabled = Self.loadBoolSetting(forKey: "settings_vibration", default: true)
        self.ringtoneId = Self.loadStringSetting(forKey: "settings_ringtone", default: SoundLibrary.defaultRingtoneId)
        self.messageSoundId = Self.loadStringSetting(forKey: "settings_msg_sound", default: SoundLibrary.defaultMessageSoundId)
        self.saveMessageHistory = Self.loadBoolSetting(forKey: "settings_save_history", default: true)
        self.savedMessagesEnabled = Self.loadBoolSetting(forKey: "settings_saved_messages", default: false)

        // Initialize encrypted database (SQLCipher)
        do {
            try DatabaseService.shared.setup()
            ghostLog("[ChatViewModel] Database initialized OK")
        } catch {
            ghostLog("[ChatViewModel] ERROR: Database setup failed: \(error)")
        }

        startMessageCleanup()

        #if DEBUG
        // Subscribe to debug log notifications
        NotificationCenter.default.addObserver(forName: .ghostDebugLog, object: nil, queue: .main) { [weak self] notif in
            guard let msg = notif.object as? String else { return }
            Task { @MainActor in
                self?.debugLog.insert(msg, at: 0)
                if (self?.debugLog.count ?? 0) > 50 { self?.debugLog.removeLast() }
            }
        }
        #endif
    }

    deinit {
        // Invalidate ALL timers to prevent zombie callbacks after dealloc
        // Timer.invalidate() is thread-safe, so direct access is OK in deinit
        messageCleanupTimer?.invalidate()
        connectionTimeout?.invalidate()
        callingTimeout?.invalidate()
        ringingTimeout?.invalidate()
        typingTimer?.invalidate()
        peerTypingTimer?.invalidate()
        peerLeftTimer?.invalidate()
        roomRotationTimer?.invalidate()
        vibrationTimer?.invalidate()
        ringtoneTimer?.invalidate()
        // Remove notification observers
        if let obs = screenshotObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    /// Invalidate ALL active timers — called from destroy() and other cleanup paths
    private func invalidateAllTimers() {
        ghostLog("[ChatViewModel] invalidateAllTimers called")
        messageCleanupTimer?.invalidate()
        messageCleanupTimer = nil
        connectionTimeout?.invalidate()
        connectionTimeout = nil
        callingTimeout?.invalidate()
        callingTimeout = nil
        ringingTimeout?.invalidate()
        ringingTimeout = nil
        typingTimer?.invalidate()
        typingTimer = nil
        peerTypingTimer?.invalidate()
        peerTypingTimer = nil
        peerLeftTimer?.invalidate()
        peerLeftTimer = nil
        roomRotationTimer?.invalidate()
        roomRotationTimer = nil
        vibrationTimer?.invalidate()
        vibrationTimer = nil
        ringtoneTimer?.invalidate()
        ringtoneTimer = nil
        peerStatusTransitionTimer?.invalidate()
        peerStatusTransitionTimer = nil
    }

    // MARK: - Push Notifications

    /// Связать callbacks от AppDelegate для VoIP push
    func setupPushCallbacks() {
        guard let appDelegate = AppDelegate.shared ?? (UIApplication.shared.delegate as? AppDelegate) else {
            ghostLog("[Push] setupPushCallbacks — AppDelegate not found!")
            return
        }

        ghostLog("[Push] setupPushCallbacks — starting, voipToken=\(appDelegate.voipToken != nil), regularToken=\(appDelegate.regularPushToken != nil)")

        // Получить VoIP токен если уже доступен
        if let existing = appDelegate.voipToken {
            localVoIPToken = existing
            ghostLog("[Push] VoIP token already available, len=\(existing.count)")
        } else {
            ghostLog("[Push] VoIP token NOT available yet (PushKit registration pending)")
        }

        // Получить regular APNs токен если уже доступен
        if let existing = appDelegate.regularPushToken {
            localRegularPushToken = existing
            ghostLog("[Push] Regular APNs token already available, len=\(existing.count)")
        } else {
            ghostLog("[Push] Regular APNs token NOT available yet (registration pending)")
        }

        appDelegate.onVoIPTokenReceived = { [weak self] token in
            Task { @MainActor [weak self] in
                guard let self else { return }
                ghostLog("[Push] onVoIPTokenReceived callback fired, len=\(token.count), keyExchangeCompleted=\(self.keyExchangeCompleted), isConnected=\(self.isConnected)")
                self.localVoIPToken = token
                // Resend to peer if key exchange already completed
                if self.keyExchangeCompleted, self.isConnected {
                    ghostLog("[Push] Sending late VoIP token to peer")
                    await self.sendEncryptedControl(.pushToken(token: token.hexString))
                }
            }
        }

        appDelegate.onRegularTokenReceived = { [weak self] token in
            Task { @MainActor [weak self] in
                guard let self else { return }
                ghostLog("[Push] onRegularTokenReceived callback fired, len=\(token.count), keyExchangeCompleted=\(self.keyExchangeCompleted), isConnected=\(self.isConnected)")
                self.localRegularPushToken = token
                // Resend to peer if key exchange already completed
                if self.keyExchangeCompleted, self.isConnected {
                    ghostLog("[Push] Sending late APNs token to peer")
                    await self.sendEncryptedControl(.notifyToken(token: token.hexString))
                }
            }
        }

        appDelegate.onPushReceived = { [weak self] roomId, callUUID, callerName in
            Task { @MainActor [weak self] in
                await self?.handleIncomingPush(roomId: roomId, callUUID: callUUID, callerName: callerName)
            }
        }

        appDelegate.onInviteReceived = { [weak self] roomId, inviterName in
            Task { @MainActor [weak self] in
                self?.handleIncomingInvite(roomId: roomId, inviterName: inviterName)
            }
        }

        // Message/missed-call push — подсветить чат с отправителем
        appDelegate.onMessagePushReceived = { [weak self] pushType, senderName in
            Task { @MainActor [weak self] in
                self?.handleMessagePush(type: pushType, senderName: senderName)
            }
        }
    }

    /// Обработка входящего VoIP push — присоединиться к комнате звонящего.
    /// Работает из ЛЮБОГО экрана: если юзер уже в другом чате — корректно выходит и переходит на новый звонок.
    private func handleIncomingPush(roomId: String?, callUUID: UUID, callerName: String) async {
        ghostLog("[ChatViewModel] handleIncomingPush called, roomId=\(roomId?.prefix(8) ?? "nil"), caller=\(callerName), screen=\(screen)")
        guard let roomId else {
            ghostLog("[ChatViewModel] handleIncomingPush: no roomId in push payload")
            return
        }

        // If user is actively in a different chat/call — tear it down cleanly before joining new
        if screen != .welcome {
            ghostLog("[ChatViewModel] handleIncomingPush: tearing down current session (screen=\(screen)) to handle incoming push")
            performLeave()
            // Give state a tick to settle
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        isFromPush = true
        activeCallUUID = callUUID

        // Настроим CallKit callbacks
        guard let appDelegate = AppDelegate.shared ?? (UIApplication.shared.delegate as? AppDelegate) else { return }
        appDelegate.onCallAnswer = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.acceptCall()
            }
        }
        appDelegate.onCallEnd = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.declineCall()
            }
        }
        appDelegate.onCallMute = { [weak self] in
            Task { @MainActor [weak self] in
                self?.toggleMute()
            }
        }

        // Присоединяемся к комнате
        await joinRoom(roomId)
    }

    /// Позвонить офлайн-контакту через VoIP push
    func callOfflineContact(_ contact: Contact) async {
        ghostLog("[ChatViewModel] callOfflineContact called, contact=\(contact.label), hasToken=\(contact.pushToken != nil)")
        guard let pushToken = contact.pushToken else { return }

        expectedPeerIdentityKey = contact.identityKey
        currentPeerContact = contact

        // Создаём комнату и ЖДЁМ roomId от сервера
        guard let roomId = await createRoomAndWait() else { return }

        // Detect platform: APNs hex tokens are ≤80 chars, FCM tokens are 100+ chars
        let token = tokenString(pushToken)
        let isAndroidPeer = token.count > 80

        if isAndroidPeer {
            await sendPushNotification(token: token, roomId: roomId, callerName: contact.label, endpoint: "api/send-push-android")
        } else {
            await sendPushNotification(token: token, roomId: roomId, callerName: contact.label, endpoint: "api/send-push")
        }
    }

    /// Отправить VoIP/call push через серверный proxy
    private func sendPushNotification(token: String, roomId: String, callerName: String, endpoint: String) async {
        await ensureFreshPushAuth()
        ghostLog("[CallPush] Sending to \(endpoint), token=\(token.prefix(8))..., roomId=\(roomId.prefix(8))..., auth=\(pushAuthToken != nil ? "present" : "missing")")
        var request = URLRequest(url: Self.serverURL.appendingPathComponent(endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "token": token,
            "payload": ["roomId": roomId, "callerName": callerName]
        ]
        if let auth = pushAuthToken { body["auth"] = auth }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    ghostLog("[CallPush] Success for \(endpoint)")
                } else if httpResponse.statusCode == 410 {
                    ghostLog("[CallPush] 410 stale token — clearing pushToken for contact")
                    dropStalePeerTokens()
                } else if httpResponse.statusCode == 403 {
                    ghostLog("[CallPush] 403 auth — refreshing pushAuthToken")
                    pushAuthToken = nil
                    pushAuthIssuedAt = nil
                } else {
                    let respBody = String(data: data, encoding: .utf8) ?? ""
                    ghostLog("[CallPush] Server returned \(httpResponse.statusCode): \(respBody)")
                }
            }
        } catch {
            ghostLog("[CallPush] Failed to send: \(error.localizedDescription)")
        }
    }

    // MARK: - Typing Indicator

    /// Вызывается когда пользователь печатает
    func userIsTyping() {
        ghostLog("[ChatViewModel] userIsTyping called, isConnected=\(isConnected)")
        guard isConnected else { return }

        // Throttle: не чаще раза в 3 секунды
        if let last = lastTypingSentAt, Date().timeIntervalSince(last) < 3 { return }
        lastTypingSentAt = Date()

        Task { await sendEncryptedControl(.typing(isTyping: true)) }

        // Автоотмена через 5 секунд если нет нового ввода
        typingTimer?.invalidate()
        typingTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.sendEncryptedControl(.typing(isTyping: false))
            }
        }
    }

    /// Отправить стоп-typing при отправке сообщения
    func stopTyping() {
        ghostLog("[ChatViewModel] stopTyping called")
        typingTimer?.invalidate()
        typingTimer = nil
        if lastTypingSentAt != nil {
            lastTypingSentAt = nil
            Task { await sendEncryptedControl(.typing(isTyping: false)) }
        }
    }

    // MARK: - Create Room

    /// Create room and return immediately (UI flow — roomId comes via callback)
    func createRoom() async {
        ghostLog("[ChatViewModel] createRoom called")
        await createRoomInternal(waitForRoomId: false)
    }

    /// Create room and wait for server to respond with roomId (push/invite flow)
    private func createRoomAndWait() async -> String? {
        ghostLog("[ChatViewModel] createRoomAndWait called")
        return await createRoomInternal(waitForRoomId: true)
    }

    @discardableResult
    private func createRoomInternal(waitForRoomId: Bool) async -> String? {
        ghostLog("[ChatViewModel] createRoomInternal called, waitForRoomId=\(waitForRoomId)")
        isHost = true
        crypto = GhostCrypto()
        crypto?.generateKeyPair()

        rtc = GhostRTC()
        rtc?.setPrivacyMode(privacyMode)

        signaling = SignalingClient(serverURL: Self.serverURL)
        turnService = TURNService(baseURL: Self.serverURL)
        rtc?.setTurnService(turnService)

        setupSignalingCallbacks()
        setupRTCCallbacks()

        signaling?.connect()

        if waitForRoomId {
            // Wait for onRoomCreated callback with 10s timeout
            let roomId = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                self.roomCreatedContinuation = continuation
                self.signaling?.createRoom()

                // Timeout after 10 seconds
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    if let pending = self.roomCreatedContinuation {
                        self.roomCreatedContinuation = nil
                        pending.resume(returning: nil)
                    }
                }
            }
            return roomId
        } else {
            signaling?.createRoom()
            return nil
        }
    }

    // MARK: - Join Room

    func joinRoom(_ inputRoomId: String) async {
        ghostLog("[ChatViewModel] joinRoom called")
        let trimmed = inputRoomId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            logger.warning("[ChatViewModel] joinRoom: empty room ID")
            return
        }

        // M3: Validate room ID format (base64url, 64 chars)
        let roomIdPattern = "^[A-Za-z0-9_-]{64}$"
        guard trimmed.range(of: roomIdPattern, options: .regularExpression) != nil else {
            ghostLog("[ChatViewModel] joinRoom: invalid room ID format")
            return
        }

        isHost = false
        crypto = GhostCrypto()
        crypto?.generateKeyPair()

        rtc = GhostRTC()
        rtc?.setPrivacyMode(privacyMode)

        signaling = SignalingClient(serverURL: Self.serverURL)
        turnService = TURNService(baseURL: Self.serverURL)
        rtc?.setTurnService(turnService)

        setupSignalingCallbacks()
        setupRTCCallbacks()

        signaling?.connect()
        signaling?.joinRoom(trimmed)
    }

    // MARK: - Signaling Callbacks

    private func setupSignalingCallbacks() {
        ghostLog("[ChatViewModel] setupSignalingCallbacks called")
        signaling?.onRoomCreated = { [weak self] roomId in
            guard let self else { return }
            ghostLog("[ChatViewModel] onRoomCreated callback")

            // During room rotation, only resume the continuation —
            // don't change screen or roomId (the active P2P session continues)
            if self.isRotatingRoom {
                if let continuation = self.roomCreatedContinuation {
                    self.roomCreatedContinuation = nil
                    continuation.resume(returning: roomId)
                }
                return
            }

            self.roomId = roomId
            self.saveSession()

            // Don't change screen if already in chat (offline contact sends message → creates room silently)
            if self.screen != .chat {
                self.connectionStep = .connectingToServer
                self.screen = .waiting
            }

            // Resume continuation if waiting (push/invite flow)
            if let continuation = self.roomCreatedContinuation {
                self.roomCreatedContinuation = nil
                continuation.resume(returning: roomId)
            }
        }

        signaling?.onRoomJoined = { [weak self] roomId in
            Task { @MainActor [weak self] in
                guard let self else { return }
                ghostLog("[ChatViewModel] onRoomJoined callback")
                self.roomId = roomId
                self.saveSession()
                if self.screen != .chat {
                    self.connectionStep = .connectingToServer
                    self.screen = .connecting
                }
                await self.initAsGuest()
            }
        }

        signaling?.onRejoinOk = { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Отправляем буферизованный ICE restart offer если есть
                if let offer = self.pendingIceRestartOffer {
                    self.pendingIceRestartOffer = nil
                    self.signaling?.sendSignal([
                        "type": "offer",
                        "sdp": GhostRTC.sdpToDict(offer)
                    ])
                } else if self.rtc?.isConnected == false {
                    // ICE до сих пор не восстановлен — повторяем restart
                    Task {
                        if let offer = await self.rtc?.restartIce() {
                            self.signaling?.sendSignal([
                                "type": "offer",
                                "sdp": GhostRTC.sdpToDict(offer)
                            ])
                        }
                    }
                }
            }
        }

        signaling?.onPeerJoined = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                ghostLog("[ChatViewModel] onPeerJoined callback")
                // Ignore peer-joined during room rotation (server sends it when peer rejoins new room)
                guard !self.isRotatingRoom else { return }
                // Пир вернулся — отменяем таймаут ожидания
                self.peerLeftTimer?.invalidate()
                self.peerLeftTimer = nil
                self.isConnected = false
                self.showPeerDisconnectedBanner = false
                self.peerStatus = .connecting
                self.peerStatusTransitionTimer?.invalidate()
                self.peerStatusTransitionTimer = nil
                if self.screen != .chat {
                    self.connectionStep = .waitingForPeer
                    self.screen = .connecting
                }
                self.startConnectionTimeout()

                // Ensure crypto is ready for key exchange (may be nil after session restore)
                if self.crypto == nil {
                    self.crypto = GhostCrypto()
                    self.crypto?.generateKeyPair()
                }

                if self.isHost {
                    await self.startWebRTCConnection()
                }
            }
        }

        signaling?.onPeerLeft = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                ghostLog("[ChatViewModel] onPeerLeft callback, screen=\(self.screen)")

                // Immediately mark as disconnected — UI shows status + banner
                self.isConnected = false
                self.peerIsTyping = false
                self.showPeerDisconnectedBanner = true
                self.addSystemMessage(String(localized: "system.peerDisconnected"))

                // Set peer status to recentlyOnline and start 5-min timer to transition to offline
                self.peerLastSeenDate = Date()
                self.peerStatus = .recentlyOnline
                self.peerStatusTransitionTimer?.invalidate()
                self.peerStatusTransitionTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, !self.isConnected else { return }
                        self.peerStatus = .offline
                    }
                }

                // If still in connecting/waiting screen — peer left before connection established
                // But NOT if we're in chat with saved contact (offline mode)
                if (self.screen == .connecting || self.screen == .waiting) && self.currentPeerContact == nil {
                    self.addSystemMessage(String(localized: "system.peerGone"))
                    self.leave()
                    return
                }

                // Ждём reconnect — пир может вернуться через rejoin-room (60s)
                self.peerLeftTimer?.invalidate()
                self.peerLeftTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if self.roomId != nil && !self.isConnected {
                            // If we have a saved contact — stay in chat, show banner
                            // But cleanup stale connection state so autoConnect can create fresh room
                            if self.currentPeerContact != nil {
                                self.showPeerDisconnectedBanner = true
                                self.peerStatus = .offline
                                ghostLog("[ChatViewModel] peerLeftTimer: staying in chat (saved contact), cleaning up stale connection")
                                self.signaling?.leaveRoom()
                                self.signaling?.disconnect()
                                self.signaling = nil
                                self.rtc?.destroy()
                                self.rtc = nil
                                self.voice?.destroy()
                                self.voice = nil
                                self.crypto?.destroy()
                                self.crypto = nil
                                self.keyExchangeCompleted = false
                                self.roomId = nil
                            } else {
                                self.addSystemMessage(String(localized: "system.peerGone"))
                                self.showPeerDisconnectedBanner = false
                                self.leave()
                            }
                        }
                    }
                }
            }
        }

        signaling?.onSignal = { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self else { return }
                ghostLog("[ChatViewModel] onSignal callback")
                await self.handleSignal(data)
            }
        }

        signaling?.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self else { return }
                ghostLog("[ChatViewModel] onError callback: \(message), screen=\(self.screen)")
                // Don't leave if we're in chat with a saved contact (offline mode)
                if self.screen == .chat && self.currentPeerContact != nil {
                    ghostLog("[ChatViewModel] onError: suppressed leave() — offline contact chat")
                    // Silently cleanup signaling
                    self.signaling?.disconnect()
                    self.signaling = nil
                    self.rtc?.destroy()
                    self.rtc = nil
                    self.crypto?.destroy()
                    self.crypto = nil
                    self.roomId = nil
                    return
                }
                self.addSystemMessage(message)
                self.leave()
            }
        }

        signaling?.onDisconnected = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let roomId = self.roomId, !self.isConnected {
                    self.signaling?.scheduleReconnect(roomId: roomId, isHost: self.isHost)
                }
            }
        }
    }

    // MARK: - RTC Callbacks

    private func setupRTCCallbacks() {
        ghostLog("[ChatViewModel] setupRTCCallbacks called")
        rtc?.onIceCandidate = { [weak self] candidate in
            self?.signaling?.sendSignal([
                "type": "ice-candidate",
                "candidate": GhostRTC.candidateToDict(candidate)
            ])
        }

        rtc?.onConnected = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                ghostLog("[ChatViewModel] RTC onConnected callback")

                self.connectionTimeout?.invalidate()
                self.connectionTimeout = nil

                let wasConnected = self.isConnected
                self.isConnected = true

                if !wasConnected && !self.keyExchangeCompleted {
                    // FIRST connection — exchange keys
                    ghostLog("[ChatViewModel] RTC onConnected — FIRST connection, starting key exchange")

                    // Ensure crypto is ready (may be nil after session restore for guest)
                    if self.crypto == nil {
                        self.crypto = GhostCrypto()
                        self.crypto?.generateKeyPair()
                    }

                    // First connection — exchange keys (v3 Double Ratchet + Identity Key)
                    guard let pubKey = self.crypto?.exportPublicKey() else { return }
                    var msg: [String: Any] = [
                        "type": "key-exchange",
                        "publicKey": pubKey,
                        "identityKey": IdentityKeyService.shared.exportPublicKey(),
                        "v": GhostCrypto.protocolVersion,
                        "platform": "ios"
                    ]

                    // Guest: include PQ capability so host knows whether to wait
                    if !self.isHost {
                        msg["pqSupported"] = GhostCrypto.isPQAvailable
                    }

                    // C1: Include DTLS fingerprint for transport binding (anti-MITM)
                    if let localSdp = self.rtc?.peerConnection?.localDescription?.sdp,
                       let range = localSdp.range(of: #"a=fingerprint:sha-256\s+([^\r\n]+)"#, options: .regularExpression) {
                        let match = localSdp[range]
                        let fpStart = match.range(of: #"\s+([^\r\n]+)$"#, options: .regularExpression)
                        if let fpStart {
                            let fp = String(match[fpStart]).trimmingCharacters(in: .whitespaces)
                            msg["dtls"] = fp
                        }
                    }

                    // Host: include ML-KEM768 encapsulation key (PQ)
                    if self.isHost && GhostCrypto.isPQAvailable {
                        self.crypto?.generatePQKeyPair()
                        if let pqKey = self.crypto?.exportPQEncapsulationKey() {
                            msg["pqKey"] = pqKey
                        }
                    }

                    if let data = try? JSONSerialization.data(withJSONObject: msg),
                       let text = String(data: data, encoding: .utf8) {
                        _ = self.rtc?.send(text)
                    }
                } else if wasConnected || self.keyExchangeCompleted {
                    // RECONNECTION — ICE restart restored connection
                    ghostLog("[ChatViewModel] RTC onConnected — RECONNECTION (wasConnected=\(wasConnected), keyExchangeCompleted=\(self.keyExchangeCompleted))")
                    self.addSystemMessage(String(localized: "system.connectionRestored"))
                    // Peer reconnected — restore online status
                    self.peerStatus = .online
                    self.peerLastSeenDate = nil
                    self.peerStatusTransitionTimer?.invalidate()
                    self.peerStatusTransitionTimer = nil
                    // Flush messages queued while disconnected (ICE restart reconnect)
                    Task { await self.flushPendingMessages() }
                }
            }
        }

        rtc?.onDisconnected = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                ghostLog("[ChatViewModel] RTC onDisconnected callback")
                self.addSystemMessage(String(localized: "system.connectionLost"))
                self.isConnected = false
                // Clear active contact for push suppression
                self.updateActiveChat(contactId: nil)
                self.peerIsTyping = false
                self.peerTypingTimer?.invalidate()
                self.peerTypingTimer = nil

                // Set peer status to recentlyOnline → offline after 5 min
                self.peerLastSeenDate = Date()
                self.peerStatus = .recentlyOnline
                self.peerStatusTransitionTimer?.invalidate()
                self.peerStatusTransitionTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, !self.isConnected else { return }
                        self.peerStatus = .offline
                    }
                }

                // End call if active
                if self.voice != nil {
                    self.voice?.destroy()
                    self.voice = nil
                    self.callState = .idle
                }
            }
        }

        rtc?.onMessage = { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.handleP2PMessage(data)
            }
        }

        rtc?.onTrack = { [weak self] stream in
            // Handle remote audio stream — buffer if voice not yet initialized
            if let audioTrack = stream.audioTracks.first, let voice = self?.voice {
                voice.onRemoteAudioTrack?(audioTrack)
            } else {
                self?.pendingRemoteStream = stream
            }
        }

        rtc?.onRenegotiationNeeded = { [weak self] offer in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.sendRenegotiationOffer(offer)
            }
        }

        // ICE restart offer goes through signaling server (not DataChannel!)
        // DataChannel rides on the same ICE transport that just broke
        rtc?.onIceRestartNeeded = { [weak self] offer in
            guard let self else { return }
            if self.signaling?.isConnected == true {
                self.signaling?.sendSignal([
                    "type": "offer",
                    "sdp": GhostRTC.sdpToDict(offer)
                ])
            } else {
                // WS не подключен — буферизуем для отправки после reconnect
                self.pendingIceRestartOffer = offer
            }
        }
    }

    // MARK: - WebRTC Connection

    private func startWebRTCConnection() async {
        ghostLog("[ChatViewModel] startWebRTCConnection called, isHost=\(isHost)")
        var turnCreds: TURNCredentials?
        do {
            turnCreds = try await turnService?.fetchCredentials()
            // Save push auth token for authenticated push requests
            pushAuthToken = turnCreds?.pushAuth
        } catch {
            #if DEBUG
            print("[ChatViewModel] TURN fetch failed: \(error)")
            #endif
        }

        guard let offer = await rtc?.initAsHost(turnCredentials: turnCreds) else { return }

        signaling?.sendSignal([
            "type": "offer",
            "sdp": GhostRTC.sdpToDict(offer)
        ])
    }

    private func initAsGuest() async {
        ghostLog("[ChatViewModel] initAsGuest called")
        var turnCreds: TURNCredentials?
        do {
            turnCreds = try await turnService?.fetchCredentials()
        } catch {
            #if DEBUG
            print("[ChatViewModel] TURN fetch failed: \(error)")
            #endif
        }

        rtc?.initAsGuest(turnCredentials: turnCreds)

        // Flush signals that arrived while PeerConnection was being created
        let buffered = pendingSignals
        pendingSignals.removeAll()
        for signal in buffered {
            await handleSignal(signal)
        }
    }

    // MARK: - Signal Handling

    private func handleSignal(_ signal: [String: Any]) async {
        let signalType = signal["type"] as? String ?? "unknown"
        ghostLog("[ChatViewModel] handleSignal type=\(signalType)")
        // Buffer signals if PeerConnection not ready yet (race: offer arrives before initAsGuest completes)
        if rtc?.peerConnection == nil {
            ghostLog("[ChatViewModel] handleSignal: PC not ready, buffering signal")
            pendingSignals.append(signal)
            return
        }

        guard let type = signal["type"] as? String else { return }

        switch type {
        case "offer":
            guard let sdpDict = signal["sdp"] as? [String: Any],
                  let sdp = GhostRTC.dictToSdp(sdpDict) else { return }

            guard let answer = await rtc?.handleOffer(sdp) else { return }

            signaling?.sendSignal([
                "type": "answer",
                "sdp": GhostRTC.sdpToDict(answer)
            ])

            // Flush pending ICE candidates
            for candidate in pendingIceCandidates {
                rtc?.addIceCandidate(candidate)
            }
            pendingIceCandidates.removeAll()

        case "answer":
            guard let sdpDict = signal["sdp"] as? [String: Any],
                  let sdp = GhostRTC.dictToSdp(sdpDict) else { return }
            await rtc?.handleAnswer(sdp)

        case "ice-candidate":
            guard let candidateDict = signal["candidate"] as? [String: Any],
                  let candidate = GhostRTC.dictToCandidate(candidateDict) else { return }

            if rtc?.peerConnection?.remoteDescription != nil {
                rtc?.addIceCandidate(candidate)
            } else {
                pendingIceCandidates.append(candidate)
            }

        default:
            break
        }
    }

    // MARK: - P2P Messages

    private func handleP2PMessage(_ data: String) async {
        ghostLog("[ChatViewModel] handleP2PMessage called, len=\(data.count)")
        guard let jsonData = data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "key-exchange":
            await handleKeyExchange(json)

        case "pq-exchange":
            await handlePQExchange(json)

        case "encrypted-message":
            if let encryptedData = json["data"] as? String {
                await handleEncryptedMessage(encryptedData)
            }

        default:
            break
        }
    }

    private func handleKeyExchange(_ json: [String: Any]) async {
        ghostLog("[ChatViewModel] handleKeyExchange called")
        connectionStep = .exchangingKeys
        // C2: reject re-exchange after initial key exchange
        guard !keyExchangeCompleted else {
            logger.warning("[ChatViewModel] handleKeyExchange: rejected, already completed")
            return
        }

        guard let peerPublicKey = json["publicKey"] as? String else {
            ghostLog("[ChatViewModel] handleKeyExchange: no publicKey in message")
            return
        }

        // Accept v2+ (backward compatible with v2 web client)
        let peerVersion = json["v"] as? Int ?? 1
        guard peerVersion >= 2 else {
            addSystemMessage(String(localized: "system.incompatibleVersion"))
            return
        }

        // Detect native app peer (iOS/Android send 'ios'/'android', web sends 'web')
        if let platform = json["platform"] as? String, !platform.isEmpty {
            peerIsNativeApp = (platform != "web")
        }

        // v3: DTLS fingerprint verification (anti-MITM transport binding)
        let peerDtlsFingerprint = json["dtls"] as? String
        if peerVersion >= 3 && (peerDtlsFingerprint == nil || peerDtlsFingerprint!.isEmpty) {
            addSystemMessage(String(localized: "security_dtls_missing"))
            leave()
            return
        }
        if let peerDtls = peerDtlsFingerprint,
           let remoteSdp = rtc?.peerConnection?.remoteDescription?.sdp,
           let range = remoteSdp.range(of: #"a=fingerprint:sha-256\s+([^\r\n]+)"#, options: .regularExpression) {
            let match = remoteSdp[range]
            let fpStart = match.range(of: #"\s+([^\r\n]+)$"#, options: .regularExpression)
            if let fpStart {
                let expectedFp = String(match[fpStart]).trimmingCharacters(in: .whitespaces)
                if peerDtls != expectedFp {
                    addSystemMessage(String(localized: "security_dtls_mismatch"))
                    leave()
                    return
                }
            }
        }

        // v3: Extract and lookup identity key
        if let idKeyBase64 = json["identityKey"] as? String,
           let idKeyData = Data(base64Encoded: idKeyBase64) {
            self.peerIdentityKeyData = idKeyData

            let store = ContactStore()
            if let knownContact = try? store.fetchByIdentityKey(idKeyData) {
                self.currentPeerContact = knownContact
                self.currentContactId = knownContact.id.uuidString
                self.updateActiveChat(contactId: knownContact.id.uuidString, contactName: knownContact.label)
                addSystemMessage(String(format: String(localized: "system.knownPeer"), knownContact.label))
            }

            // Update contact's identity key if changed (ephemeral keys rotate each session)
            if let expected = expectedPeerIdentityKey, expected != idKeyData {
                ghostLog("[ChatViewModel] Peer identity key changed — updating contact")
                if var contact = currentPeerContact {
                    contact.publicKey = idKeyData
                    contact.identityKey = idKeyData
                    let store = ContactStore()
                    do {
                        try store.save(contact)
                    } catch {
                        ghostLog("[ChatViewModel] ERROR: failed to update contact identity key: \(error)")
                    }
                    currentPeerContact = contact
                }
            }
        }

        do {
            try crypto?.importPeerPublicKey(peerPublicKey)

            // Guest: если host прислал pqKey → encapsulate и отправить ciphertext
            if !isHost, let pqKeyBase64 = json["pqKey"] as? String {
                let result = crypto?.pqEncapsulate(encapsKeyBase64: pqKeyBase64)
                if let result, result.success {
                    let pqMsg: [String: Any] = ["type": "pq-exchange", "pqCiphertext": result.ciphertext]
                    if let data = try? JSONSerialization.data(withJSONObject: pqMsg),
                       let text = String(data: data, encoding: .utf8) {
                        _ = rtc?.send(text)
                    }
                }
            }

            // C1: Host defers derivation if PQ was offered and guest supports it
            if isHost, crypto?.mlkemEncapsulationKeyData != nil {
                let guestSupportsPQ = json["pqSupported"] as? Bool ?? false
                if guestSupportsPQ {
                    pendingPQDerivation = true
                    return
                }
            }

            // Derive shared key with Double Ratchet initialization
            try crypto?.deriveSharedKey(asHost: isHost)
            completeKeyExchange()
        } catch {
            addSystemMessage(String(localized: "system.keyExchangeError"))
        }
    }

    /// Host receives PQ ciphertext from guest → decapsulate → derive keys
    private func handlePQExchange(_ json: [String: Any]) async {
        ghostLog("[ChatViewModel] handlePQExchange called, isHost=\(isHost), pendingPQDerivation=\(pendingPQDerivation)")
        // C2: only accept if key exchange is pending PQ
        guard isHost, pendingPQDerivation, !keyExchangeCompleted else { return }
        guard let pqCt = json["pqCiphertext"] as? String else { return }

        let success = crypto?.pqDecapsulate(ciphertextBase64: pqCt) ?? false
        guard success else { return }

        do {
            try crypto?.deriveSharedKey(asHost: isHost)
            pendingPQDerivation = false
            completeKeyExchange()
        } catch {
            addSystemMessage(String(localized: "system.keyExchangeError"))
        }
    }

    /// Common completion after key derivation (used by both paths)
    private func completeKeyExchange() {
        ghostLog("[ChatViewModel] completeKeyExchange called, hasVoice=\(voice != nil)")

        // CRITICAL: Destroy old GhostVoice on every new key exchange.
        // After reconnect, PeerConnection is NEW but old voice holds reference to dead PC.
        // Clearing voice ensures startCall() creates fresh GhostVoice with new PeerConnection.
        if voice != nil {
            ghostLog("[ChatViewModel] completeKeyExchange: destroying stale voice (reconnect)")
            voice?.destroy()
            voice = nil
        }

        keyExchangeCompleted = true
        fingerprint = (try? crypto?.generateFingerprint()) ?? ""
        connectionStep = .secured
        showPeerDisconnectedBanner = false
        peerStatus = .online
        peerLastSeenDate = nil
        peerStatusTransitionTimer?.invalidate()
        peerStatusTransitionTimer = nil
        // Brief delay to show "secured" step before transitioning to chat
        // Guard: only transition if still in connecting/waiting — if already chat (reconnect) or
        // if user left (welcome), don't override
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            if self.screen == .connecting || self.screen == .waiting {
                self.screen = .chat
            }
        }
        isConnected = true

        let pqStatus = (crypto?.isPQEnabled == true) ? " (PQ)" : ""
        ghostLog("[ChatViewModel] key exchange completed, PQ=\(self.crypto?.isPQEnabled == true)")
        addSystemMessage(String(localized: "system.secureConnection") + pqStatus)

        startSecurityMonitoring()

        // Contact auto-save — platform field in key-exchange is already available
        handleContactAutoSave()

        // Отправить VoIP push token peer'у для офлайн-звонков
        ghostLog("[Push] Sending tokens to peer: VoIP=\(localVoIPToken != nil ? "\(localVoIPToken!.count)b" : "nil"), APNs=\(localRegularPushToken != nil ? "\(localRegularPushToken!.count)b" : "nil")")
        if let token = localVoIPToken {
            tokensSentToPeerThisSession = true
            Task { await sendEncryptedControl(.pushToken(token: token.hexString)) }
        }

        // Отправить regular APNs token для chat invite push
        if let token = localRegularPushToken {
            tokensSentToPeerThisSession = true
            Task { await sendEncryptedControl(.notifyToken(token: token.hexString)) }
        }

        // Retry: if tokens are nil, PushKit/APNs registration may still be in progress
        // Poll up to 10s — actively re-read from AppDelegate in case callbacks fired
        // before setupPushCallbacks wired them up
        if localVoIPToken == nil || localRegularPushToken == nil {
            ghostLog("[Push] Some tokens are nil — starting delayed retry (up to 10s)")
            Task { @MainActor [weak self] in
                let appDelegate = AppDelegate.shared ?? (UIApplication.shared.delegate as? AppDelegate)
                for attempt in 1...10 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                    guard let self, self.isConnected, self.keyExchangeCompleted else { return }

                    // Re-read tokens from AppDelegate — they may have arrived after
                    // setupPushCallbacks but before our callback was set
                    if self.localVoIPToken == nil, let token = appDelegate?.voipToken {
                        ghostLog("[Push] Retry #\(attempt): found VoIP token on AppDelegate, len=\(token.count)")
                        self.localVoIPToken = token
                        await self.sendEncryptedControl(.pushToken(token: token.hexString))
                    }
                    if self.localRegularPushToken == nil, let token = appDelegate?.regularPushToken {
                        ghostLog("[Push] Retry #\(attempt): found APNs token on AppDelegate, len=\(token.count)")
                        self.localRegularPushToken = token
                        await self.sendEncryptedControl(.notifyToken(token: token.hexString))
                    }

                    if self.localVoIPToken != nil && self.localRegularPushToken != nil {
                        ghostLog("[Push] All tokens available after \(attempt)s retry")
                        break
                    }
                    if attempt == 10 {
                        ghostLog("[Push] WARNING: tokens still nil after 10s retry — VoIP=\(self.localVoIPToken != nil), APNs=\(self.localRegularPushToken != nil)")
                    }
                }
            }
        }

        // Host sends bootstrap message to initialize guest's send chain
        // (guest's Double Ratchet needs to receive at least one message
        // to trigger DH ratchet and initialize the send chain)
        if isHost {
            Task { await sendEncryptedControl(.ready) }
        }

        // Send capabilities (file-transfer support)
        Task { await sendEncryptedControl(.capabilities(features: ["file-transfer"])) }

        // Wire up file transfer callbacks
        setupFileTransferCallbacks()

        // Flush pending messages that were queued while offline
        Task { await flushPendingMessages() }

        // If user tapped Accept in CallKit before P2P was ready, fire the buffered accept now
        if pendingAcceptCall {
            ghostLog("[ChatViewModel] completeKeyExchange: flushing pendingAcceptCall")
            pendingAcceptCall = false
            Task { @MainActor [weak self] in
                // Small delay to let state propagate
                try? await Task.sleep(nanoseconds: 200_000_000)
                await self?.acceptCall()
            }
        }

        // Start room rotation timer (host only — forward secrecy at signaling level)
        if isHost {
            startRoomRotationTimer()
        }
    }

    /// Auto-save or update contact after successful key exchange
    private func handleContactAutoSave() {
        ghostLog("[ChatViewModel] handleContactAutoSave called, hasExistingContact=\(currentPeerContact != nil)")
        if let existingContact = currentPeerContact {
            // Known contact — increment session count
            let store = ContactStore()
            do {
                try store.incrementSessionCount(contactId: existingContact.id)
                ghostLog("[ChatViewModel] Incremented session count for: \(existingContact.label)")
            } catch {
                ghostLog("[ChatViewModel] ERROR incrementing session: \(error)")
            }
            return
        }

        // New peer — автосохраняем с дефолтным именем + показываем prompt для переименования
        // Fallback: use peer public key if identity key not available (e.g. web peers)
        ghostLog("[ChatViewModel] handleContactAutoSave: peerIdentityKeyData=\(peerIdentityKeyData != nil), peerPublicKeyData=\(crypto?.peerPublicKeyData != nil), cryptoReady=\(crypto?.isReady ?? false)")
        let peerIdKey: Data
        if let idKey = peerIdentityKeyData {
            peerIdKey = idKey
            ghostLog("[ChatViewModel] Using peerIdentityKeyData, len=\(idKey.count)")
        } else if let pubKey = crypto?.peerPublicKeyData {
            peerIdKey = pubKey
            ghostLog("[ChatViewModel] Using peerPublicKeyData as fallback, len=\(pubKey.count)")
        } else {
            // Last resort: use fingerprint hash as dummy key so contact at least saves
            ghostLog("[ChatViewModel] WARNING: no peer key data, using fingerprint hash as placeholder")
            peerIdKey = Data(SHA256.hash(data: Data(fingerprint.utf8)).prefix(32))
        }
        // Default name: "Ghost XXXX" using first 4 chars of fingerprint
        let fpShort = fingerprint.replacingOccurrences(of: " ", with: "").prefix(4)
        let defaultName = fpShort.isEmpty ? "Ghost" : "Ghost \(fpShort)"
        ghostLog("[ChatViewModel] Auto-saving contact: name='\(defaultName)', keyLen=\(peerIdKey.count)")
        var contact = Contact(
            label: defaultName,
            publicKey: peerIdKey,
            identityKey: peerIdKey,
            sessionCount: 1,
            lastSessionAt: Date()
        )
        contact.pushToken = peerPushToken
        contact.notifyToken = peerNotifyToken

        let store = ContactStore()
        do {
            // Retry DB setup if needed (can be notOpen after app backgrounding)
            try? DatabaseService.shared.setup()
            try store.save(contact)
            currentPeerContact = contact
            currentContactId = contact.id.uuidString
            ghostLog("[ChatViewModel] Auto-saved new contact: \(defaultName), id: \(contact.id)")
        } catch {
            ghostLog("[ChatViewModel] ERROR saving contact: \(error)")
            // Last resort: retry once after fresh DB setup
            do {
                try DatabaseService.shared.setup()
                try store.save(contact)
                currentPeerContact = contact
                currentContactId = contact.id.uuidString
                ghostLog("[ChatViewModel] Auto-saved contact on retry: \(defaultName)")
            } catch {
                ghostLog("[ChatViewModel] FATAL: contact save failed after retry: \(error)")
            }
        }

        // Показать prompt для переименования через 2 секунды
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.screen == .chat, self.isConnected else { return }
            self.pendingContactName = defaultName
            self.showSaveContactPrompt = true
        }
    }

    /// Save/rename contact from the save prompt
    func saveNewContact(name: String) {
        ghostLog("[ChatViewModel] saveNewContact called")
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        // If contact already exists — just rename
        if var existing = currentPeerContact {
            existing.label = trimmedName
            let store = ContactStore()
            do {
                try store.save(existing)
            } catch {
                ghostLog("[ChatViewModel] ERROR: failed to rename contact: \(error)")
            }
            currentPeerContact = existing
            showSaveContactPrompt = false
            pendingContactName = ""
            if pendingLeave { pendingLeave = false; performLeave() }
            return
        }

        // Fallback: create new if auto-save didn't work
        guard let peerIdKey = peerIdentityKeyData else { return }
        var contact = Contact(
            label: trimmedName,
            publicKey: peerIdKey,
            identityKey: peerIdKey,
            sessionCount: 1,
            lastSessionAt: Date()
        )
        contact.pushToken = peerPushToken
        contact.notifyToken = peerNotifyToken
        let store = ContactStore()
        do {
            try store.save(contact)
        } catch {
            ghostLog("[ChatViewModel] ERROR: failed to save new contact: \(error)")
        }
        currentPeerContact = contact
        showSaveContactPrompt = false
        pendingContactName = ""
        // Если ждали выхода — выходим после сохранения
        if pendingLeave {
            pendingLeave = false
            performLeave()
        }
    }

    func skipSaveContact() {
        ghostLog("[ChatViewModel] skipSaveContact called")
        showSaveContactPrompt = false
        pendingContactName = ""
        // Если ждали выхода — выходим без сохранения
        if pendingLeave {
            pendingLeave = false
            performLeave()
        }
    }

    /// Open chat with a contact — auto-connect: create room or join pending
    func startChatWithContact(_ contact: Contact) async {
        ghostLog("[ChatViewModel] startChatWithContact: \(contact.label)")

        // Clear old connection state — room may have expired
        roomId = nil
        signaling?.disconnect()
        signaling = nil
        rtc?.destroy()
        rtc = nil
        crypto = nil
        voice = nil
        keyExchangeCompleted = false
        isConnected = false
        showPeerDisconnectedBanner = false
        pendingRoomPollTimer?.invalidate()
        pendingRoomPollTimer = nil

        expectedPeerIdentityKey = contact.identityKey
        currentPeerContact = contact
        currentContactId = contact.id.uuidString
        updateActiveChat(contactId: contact.id.uuidString, contactName: contact.label)
        messages.removeAll()
        loadMessageHistory()
        // Mark all received messages as read (clears unread badge)
        try? messageStore.markAllDelivered(for: contact.id.uuidString)
        screen = .chat
        startMessageCleanup()

        // Auto-connect: check for pending room from peer, or create our own
        await autoConnectToContact(contact)
    }

    /// Auto-connect logic: check pending → join OR create → register → poll
    private var isAutoConnecting = false

    private func autoConnectToContact(_ contact: Contact) async {
        ghostLog("[ChatViewModel] autoConnectToContact called, contact=\(contact.label)")
        guard currentPeerContact?.id == contact.id else { return }
        // Prevent double-call from startChatWithContact + sendMessage
        guard !isAutoConnecting else {
            ghostLog("[ChatViewModel] autoConnect: already in progress, skipping")
            return
        }
        // If already connected or have a room, skip
        guard !isConnected, roomId == nil else {
            ghostLog("[ChatViewModel] autoConnect: already connected or have room, skipping")
            return
        }
        isAutoConnecting = true
        defer { isAutoConnecting = false }

        // Deterministic role: compare identity key hashes
        // Lower hash = HOST (creates room and waits)
        // Higher hash = GUEST (only checks pending room and joins)
        let myHash = identityKeyHash() ?? ""
        let peerHash = identityKeyHash(for: contact) ?? ""
        let iAmHost = myHash < peerHash
        ghostLog("[ChatViewModel] autoConnect: role=\(iAmHost ? "HOST" : "GUEST"), myHash=\(myHash.prefix(8)), peerHash=\(peerHash.prefix(8))")

        // GUEST: only check pending room, never create own
        if !iAmHost {
            // Poll for pending room from host
            ghostLog("[ChatViewModel] GUEST: waiting for host to create room")
            startPendingRoomPolling(for: contact)
            return
        }

        // HOST: check if peer already has a room (they might have been first), else create
        if let pendingRoomId = await checkPendingRoom(for: contact) {
            ghostLog("[ChatViewModel] HOST found existing pending room, joining \(pendingRoomId.prefix(8))")
            await joinRoomById(pendingRoomId)
            return
        }

        // HOST: create room and register pending
        ghostLog("[ChatViewModel] HOST: creating room")
        peerStatus = .connecting

        // CRITICAL: set isHost BEFORE anything else — onPeerJoined checks this
        isHost = true

        // Initialize crypto for new session
        if crypto == nil {
            crypto = GhostCrypto()
            crypto?.generateKeyPair()
        }

        // Initialize RTC (needed for startWebRTCConnection on peer join)
        if rtc == nil {
            rtc = GhostRTC()
            rtc?.setPrivacyMode(privacyMode)
        }

        // Initialize signaling if needed
        if signaling == nil {
            signaling = SignalingClient(serverURL: Self.serverURL)
        }
        setupSignalingCallbacks()
        setupRTCCallbacks()
        signaling?.connect()

        // Wait for WebSocket to connect before creating room
        for _ in 0..<30 { // 3 seconds max
            try? await Task.sleep(nanoseconds: 100_000_000)
            if signaling?.isConnected == true { break }
        }
        guard signaling?.isConnected == true else {
            ghostLog("[ChatViewModel] autoConnect: signaling connection failed")
            return
        }

        signaling?.createRoom()

        // Wait for room creation
        for _ in 0..<50 { // 5 seconds max
            try? await Task.sleep(nanoseconds: 100_000_000)
            if roomId != nil { break }
        }

        guard let myRoomId = roomId, currentPeerContact?.id == contact.id else {
            ghostLog("[ChatViewModel] autoConnect: room creation failed or contact changed")
            return
        }

        // Register pending room so peer can find us
        if let peerHash = identityKeyHash(for: contact),
           let myHash = identityKeyHash() {
            await registerPendingRoom(peerHash: peerHash, roomId: myRoomId, creatorHash: myHash)
        }

        // Send invite push if we have a token — wake peer's device
        if let tokenData = contact.notifyToken ?? contact.pushToken {
            let token = tokenString(tokenData)
            if token.count >= 10 {
                let platform = token.count <= 80 ? "ios" : "android"
                let myName = Self.loadStringSetting(forKey: "settings_display_name", default: String(localized: "notification.yourContact"))
                ghostLog("[ChatViewModel] autoConnect: sending invite push, platform=\(platform)")
                await sendInvitePush(token: token, roomId: myRoomId, inviterName: myName, platform: platform)
            }
        }

        // Step 3: Start polling — peer might create their room before finding ours
        startPendingRoomPolling(for: contact)
    }

    private var pendingRoomPollTimer: Timer?

    /// Poll every 5s for pending room from peer (in case they created before us)
    private func startPendingRoomPolling(for contact: Contact) {
        ghostLog("[ChatViewModel] startPendingRoomPolling called, contact=\(contact.label)")
        peerStatus = .searching
        pendingRoomPollTimer?.invalidate()
        pendingRoomPollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      !self.isConnected,
                      self.currentPeerContact?.id == contact.id,
                      self.screen == .chat else {
                    self?.pendingRoomPollTimer?.invalidate()
                    self?.pendingRoomPollTimer = nil
                    return
                }

                // HOST already has a room — don't switch, wait for peer to find us
                if self.isHost && self.roomId != nil {
                    ghostLog("[ChatViewModel] Poll skipped — HOST already has room \(self.roomId?.prefix(8) ?? "")")
                    return
                }

                if let pendingRoomId = await self.checkPendingRoom(for: contact) {
                    ghostLog("[ChatViewModel] Poll found pending room, joining \(pendingRoomId.prefix(8))")
                    self.pendingRoomPollTimer?.invalidate()
                    self.pendingRoomPollTimer = nil

                    // Disconnect from our room and join peer's
                    self.signaling?.leaveRoom()
                    self.signaling?.disconnect()
                    self.signaling = nil
                    self.rtc?.destroy()
                    self.rtc = nil
                    self.roomId = nil

                    await self.joinRoomById(pendingRoomId)
                }
            }
        }
    }

    /// Join a specific room by ID (for pending room reconnection)
    private func joinRoomById(_ roomId: String) async {
        ghostLog("[ChatViewModel] joinRoomById called, roomId=\(roomId.prefix(8))")
        guard signaling == nil else { return }

        // CRITICAL: joining = guest, never host
        isHost = false

        crypto = GhostCrypto()
        crypto?.generateKeyPair()

        rtc = GhostRTC()
        rtc?.setPrivacyMode(privacyMode)

        signaling = SignalingClient(serverURL: Self.serverURL)
        turnService = TURNService(baseURL: Self.serverURL)
        rtc?.setTurnService(turnService)

        setupSignalingCallbacks()
        setupRTCCallbacks()

        signaling?.connect()
        signaling?.joinRoom(roomId)
        ghostLog("[ChatViewModel] joinRoomById: joining \(roomId.prefix(8))")
    }

    /// Navigate back to contacts without disconnecting (preserves active P2P session)
    func navigateBack() {
        ghostLog("[ChatViewModel] navigateBack called")
        // Если новый native peer (не web, не из контактов) и был key exchange — спросить имя
        if currentPeerContact == nil && keyExchangeCompleted && peerIdentityKeyData != nil && peerIsNativeApp {
            showSaveContactPrompt = true
            pendingLeave = true
            return
        }

        // Cleanup P2P + signaling when leaving chat (but keep contact)
        pendingRoomPollTimer?.invalidate()
        pendingRoomPollTimer = nil
        isAutoConnecting = false
        connectionTimeout?.invalidate()
        connectionTimeout = nil

        // Destroy P2P and signaling — room will be recreated on next open
        signaling?.leaveRoom()
        signaling?.disconnect()
        signaling = nil
        rtc?.destroy()
        rtc = nil
        voice?.destroy()
        voice = nil
        crypto = nil
        roomId = nil
        isConnected = false
        keyExchangeCompleted = false
        peerStatus = .offline
        peerLastSeenDate = nil
        peerStatusTransitionTimer?.invalidate()
        peerStatusTransitionTimer = nil

        updateActiveChat(contactId: nil)
        screen = .welcome
    }

    private func startSecurityMonitoring() {
        ghostLog("[ChatViewModel] startSecurityMonitoring called")
        // SecurityMonitor — запись экрана, bluetooth устройства
        securityMonitor.onAlert = { [weak self] alert in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.addSystemMessage(String(format: String(localized: "system.securityWarning"), alert.message))
                self.securityAlert = alert

                // Уведомляем собеседника
                await self.sendEncryptedControl(.securityAlert(alert: alert.type))
            }
        }
        securityMonitor.startMonitoring()

        // Детекция скриншотов — iOS нативное API
        screenshotObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.userDidTakeScreenshotNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.addSystemMessage(String(localized: "system.screenshotTaken"))
                // Уведомляем собеседника (если включено в настройках)
                if self.screenshotNotifications {
                    await self.sendEncryptedControl(.securityAlert(alert: "screenshot-attempt"))
                }
            }
        }
    }

    private func handleEncryptedMessage(_ encryptedData: String) async {
        ghostLog("[ChatViewModel] handleEncryptedMessage called")
        do {
            let plaintext = try crypto?.decrypt(encryptedData) ?? ""

            // Пробуем как JSON (control message или новый wire format)
            if let data = plaintext.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                // Control message — _ctrl=true
                if json["_ctrl"] as? Bool == true {
                    if let controlMsg = ControlMessage.from(json) {
                        await handleControlMessage(controlMsg)
                    }
                    return
                }

                // New wire format: {"m": "text", "id": "uuid", "r": {"id": ..., "t": ...}}
                if let messageText = json["m"] as? String {
                    let senderMsgId = json["id"] as? String
                    var replyId: String?
                    var replyText: String?
                    if let replyInfo = json["r"] as? [String: Any] {
                        replyId = replyInfo["id"] as? String
                        replyText = replyInfo["t"] as? String
                    }
                    addMessage(messageText, type: .received,
                              replyToId: replyId, replyToText: replyText,
                              senderMessageId: senderMsgId)

                    // Звук и вибрация
                    if messageSoundEnabled {
                        let sound = SoundLibrary.messageSound(forId: messageSoundId)
                        SoundLibrary.playMessageSound(sound, withVibration: vibrationEnabled)
                    } else if vibrationEnabled {
                        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                    }

                    // ACK + read
                    if let counter = crypto?.lastDecryptedCounter {
                        await sendEncryptedControl(.messageAck(counter: counter))
                        if screen == .chat {
                            await sendEncryptedControl(.messageRead(counter: counter))
                        }
                    }
                    return
                }
            }

            // Fallback: raw text (backward compat with old clients)
            addMessage(plaintext, type: .received)

            // Звук и вибрация при получении
            if messageSoundEnabled {
                let sound = SoundLibrary.messageSound(forId: messageSoundId)
                SoundLibrary.playMessageSound(sound, withVibration: vibrationEnabled)
            } else if vibrationEnabled {
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }

            // Подтверждение доставки + прочтения (используем counter отправителя из расшифрованного сообщения)
            if let counter = crypto?.lastDecryptedCounter {
                await sendEncryptedControl(.messageAck(counter: counter))
                // Если чат открыт — сразу отправляем подтверждение прочтения
                if screen == .chat {
                    await sendEncryptedControl(.messageRead(counter: counter))
                }
            }
        } catch let error as GhostCryptoError {
            switch error {
            case .replayAttack:
                addSystemMessage(String(localized: "system.replayAttack"))
            case .messageTooOld:
                addSystemMessage(String(localized: "system.messageTooOld"))
            case .counterTooOld:
                addSystemMessage(String(localized: "system.counterTooOld"))
            default:
                addSystemMessage(String(localized: "system.decryptionError"))
            }
        } catch {
            addSystemMessage(String(localized: "system.decryptionError"))
        }
    }

    // MARK: - Control Messages

    private func handleControlMessage(_ msg: ControlMessage) async {
        ghostLog("[ChatViewModel] handleControlMessage called: \(String(describing: msg))")
        switch msg {
        case .renegotiate(let sdp):
            ghostLog("[ChatViewModel] handleControlMessage case=renegotiate")
            await handleRenegotiation(sdp)

        case .callRequest:
            ghostLog("[ChatViewModel] handleControlMessage case=callRequest")
            handleIncomingCall()

        case .callResponse(let accepted):
            ghostLog("[ChatViewModel] handleControlMessage case=callResponse accepted=\(accepted)")
            handleCallResponse(accepted)

        case .callEnd:
            ghostLog("[ChatViewModel] handleControlMessage case=callEnd")
            handleCallEnded()

        case .callSecurityAlert(let alert):
            ghostLog("[ChatViewModel] handleControlMessage case=callSecurityAlert")
            if let message = alert["message"] as? String {
                addSystemMessage(String(format: String(localized: "system.securityWarning"), message))
            }

        case .securityAlert(let alert):
            ghostLog("[ChatViewModel] handleControlMessage case=securityAlert alert=\(alert)")
            handleSecurityAlert(alert)

        case .messageAck(let counter):
            ghostLog("[ChatViewModel] handleControlMessage case=messageAck counter=\(counter)")
            handleMessageAck(counter)

        case .messageRead(let counter):
            ghostLog("[ChatViewModel] handleControlMessage case=messageRead counter=\(counter)")
            handleMessageRead(counter)

        case .ready:
            ghostLog("[ChatViewModel] handleControlMessage case=ready")
            // Bootstrap from host — decryption already triggered DH ratchet
            break

        case .pushToken(let tokenHex):
            ghostLog("[ChatViewModel] handleControlMessage case=pushToken len=\(tokenHex.count)")
            handlePeerPushToken(tokenHex)

        case .notifyToken(let tokenHex):
            ghostLog("[ChatViewModel] handleControlMessage case=notifyToken len=\(tokenHex.count)")
            handlePeerNotifyToken(tokenHex)

        case .typing(let isTyping):
            ghostLog("[ChatViewModel] handleControlMessage case=typing isTyping=\(isTyping)")
            handlePeerTyping(isTyping)

        case .capabilities(let features):
            ghostLog("[ChatViewModel] handleControlMessage case=capabilities features=\(features)")
            if features.contains("file-transfer") {
                peerSupportsFiles = true
            }

        case .roomRotate(let newRoomId):
            ghostLog("[ChatViewModel] handleControlMessage case=roomRotate")
            handleRoomRotate(newRoomId)

        case .fileStart(let fileId, let name, let size, let mimeType, let totalChunks):
            ghostLog("[ChatViewModel] handleControlMessage case=fileStart name=\(name) size=\(size)")
            fileTransfer.handleFileStart(fileId: fileId, name: name, size: size, mimeType: mimeType, totalChunks: totalChunks)
            // Add placeholder message for incoming file
            let msg = ChatMessage(
                contactId: currentContactId,
                text: "\(name) (\(FileTransferService.formatSize(size)))",
                type: .received,
                expiresAt: nil,
                fileName: name,
                fileSize: size,
                fileMimeType: mimeType,
                fileTransferProgress: 0.0,
                fileId: fileId
            )
            messages.append(msg)

        case .fileChunk(let fileId, let index, let data):
            if index % 10 == 0 {
                ghostLog("[ChatViewModel] Received fileChunk \(index) for \(fileId.prefix(8)), dataLen=\(data.count)")
            }
            fileTransfer.handleFileChunk(fileId: fileId, index: index, base64Data: data)

        case .fileComplete(let fileId):
            ghostLog("[ChatViewModel] Received fileComplete for \(fileId.prefix(8))")
            fileTransfer.handleFileComplete(fileId: fileId)

        case .fileRetransmit(let fileId, let indices):
            ghostLog("[ChatViewModel] Retransmit request for \(fileId): \(indices.count) chunks")
            fileTransfer.handleRetransmitRequest(fileId: fileId, indices: indices)

        case .messageDelete(let messageId):
            ghostLog("[ChatViewModel] handleControlMessage case=messageDelete")
            handleRemoteMessageDelete(messageId)

        case .messageEdit(let messageId, let newText):
            ghostLog("[ChatViewModel] handleControlMessage case=messageEdit")
            handleRemoteMessageEdit(messageId, newText: newText)
        }
    }

    // MARK: - Remote Delete / Edit

    private func handleRemoteMessageDelete(_ senderMessageId: String) {
        ghostLog("[ChatViewModel] handleRemoteMessageDelete called: \(senderMessageId)")
        // Remove from UI
        messages.removeAll { $0.senderMessageId == senderMessageId }
        // Remove from DB
        if currentContactId != nil {
            do {
                try messageStore.deleteBySenderMessageId(senderMessageId)
            } catch {
                ghostLog("[ChatViewModel] ERROR: failed to delete message from DB: \(error)")
            }
        }
    }

    private func handleRemoteMessageEdit(_ senderMessageId: String, newText: String) {
        ghostLog("[ChatViewModel] handleRemoteMessageEdit: \(senderMessageId)")
        // Update in UI
        if let idx = messages.firstIndex(where: { $0.senderMessageId == senderMessageId }) {
            messages[idx] = ChatMessage(
                id: messages[idx].id,
                contactId: messages[idx].contactId,
                text: newText,
                type: messages[idx].type,
                timestamp: messages[idx].timestamp,
                isDelivered: messages[idx].isDelivered,
                isRead: messages[idx].isRead,
                isPending: messages[idx].isPending,
                expiresAt: messages[idx].expiresAt,
                replyToId: messages[idx].replyToId,
                replyToText: messages[idx].replyToText,
                isEdited: true,
                senderMessageId: messages[idx].senderMessageId,
                fileName: messages[idx].fileName,
                fileSize: messages[idx].fileSize,
                fileMimeType: messages[idx].fileMimeType,
                fileLocalPath: messages[idx].fileLocalPath,
                fileId: messages[idx].fileId
            )
        }
        // Update in DB
        do {
            try messageStore.updateText(senderMessageId: senderMessageId, newText: newText)
        } catch {
            ghostLog("[ChatViewModel] ERROR: failed to update message text in DB: \(error)")
        }
    }

    // MARK: - Delete / Edit for Both Sides

    func deleteMessageForEveryone(_ message: ChatMessage) async {
        ghostLog("[ChatViewModel] deleteMessageForEveryone called, msgId=\(message.id)")
        guard message.type == .sent, let senderMsgId = message.senderMessageId else { return }
        // Remove locally
        messages.removeAll { $0.id == message.id }
        do {
            try messageStore.deleteBySenderMessageId(senderMsgId)
        } catch {
            ghostLog("[ChatViewModel] ERROR: failed to delete message for everyone: \(error)")
        }
        // Notify peer
        await sendEncryptedControl(.messageDelete(messageId: senderMsgId))
    }

    func editMessage(_ message: ChatMessage, newText: String) async {
        ghostLog("[ChatViewModel] editMessage called, msgId=\(message.id), newLen=\(newText.count)")
        guard message.type == .sent, let senderMsgId = message.senderMessageId else { return }
        // Update locally
        if let idx = messages.firstIndex(where: { $0.id == message.id }) {
            var updated = messages[idx]
            updated = ChatMessage(
                id: updated.id,
                contactId: updated.contactId,
                text: newText,
                type: updated.type,
                timestamp: updated.timestamp,
                isDelivered: updated.isDelivered,
                isRead: updated.isRead,
                isPending: updated.isPending,
                expiresAt: updated.expiresAt,
                replyToId: updated.replyToId,
                replyToText: updated.replyToText,
                isEdited: true,
                senderMessageId: updated.senderMessageId,
                fileName: updated.fileName,
                fileSize: updated.fileSize,
                fileMimeType: updated.fileMimeType,
                fileLocalPath: updated.fileLocalPath,
                fileId: updated.fileId
            )
            messages[idx] = updated
        }
        do {
            try messageStore.updateText(senderMessageId: senderMsgId, newText: newText)
        } catch {
            ghostLog("[ChatViewModel] ERROR: failed to update edited message in DB: \(error)")
        }
        // Notify peer
        await sendEncryptedControl(.messageEdit(messageId: senderMsgId, newText: newText))
    }

    // MARK: - Send Messages

    func sendMessage(_ text: String) async {
        ghostLog("[ChatViewModel] sendMessage called")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Capture reply state before clearing
        let reply = replyingTo
        replyingTo = nil

        // Saved Messages mode — just save locally, no P2P
        if isSavedMessagesMode {
            addMessage(trimmed, type: .sent, replyToId: reply?.senderMessageId ?? reply?.id.uuidString, replyToText: reply.flatMap { String($0.text.prefix(100)) })
            return
        }

        // Offline mode — peer not connected, queue message
        // Room is already created by autoConnectToContact(), just queue
        if !isConnected {
            queuePendingMessage(trimmed)
            // If no room yet (shouldn't happen), create one
            if roomId == nil, let contact = currentPeerContact {
                await autoConnectToContact(contact)
            }
            // Send push notification to wake peer up about pending message
            await sendOfflineMessagePush()
            return
        }

        guard let crypto else { return }

        // Sender's message UUID for cross-device delete/edit correlation
        let senderMsgId = UUID().uuidString

        // Добавляем сообщение оптимистично до шифрования
        let chatMsg = addMessage(trimmed, type: .sent,
                                 replyToId: reply?.senderMessageId ?? reply?.id.uuidString,
                                 replyToText: reply.flatMap { String($0.text.prefix(100)) },
                                 senderMessageId: senderMsgId)

        do {
            // crypto.encrypt wraps in {m, t, c} — pass raw text + options for id/r
            var options: [String: Any] = ["id": senderMsgId]
            if let reply {
                options["r"] = [
                    "id": reply.senderMessageId ?? reply.id.uuidString,
                    "t": String(reply.text.prefix(100))
                ]
            }

            let encrypted = try crypto.encrypt(trimmed, options: options)
            let msg: [String: Any] = ["type": "encrypted-message", "data": encrypted]

            if let data = try? JSONSerialization.data(withJSONObject: msg),
               let jsonStr = String(data: data, encoding: .utf8) {
                _ = rtc?.send(jsonStr)
            }

            sentMessages[crypto.messageCounter] = (id: chatMsg.id, sentAt: Date())
        } catch {
            addSystemMessage(String(localized: "system.sendError"))
        }
    }

    func sendEncryptedControl(_ message: ControlMessage) async {
        ghostLog("[ChatViewModel] sendEncryptedControl called")
        guard let crypto, crypto.isReady, rtc?.isConnected == true else {
            // Log when file transfer controls are silently dropped
            let desc = String(describing: message)
            if desc.contains("file") || desc.contains("File") {
                ghostLog("[sendEncryptedControl] DROPPED file control — crypto.isReady=\(crypto?.isReady ?? false), rtc.isConnected=\(rtc?.isConnected ?? false): \(desc.prefix(80))")
            }
            return
        }

        do {
            var json = message.toJSON()
            json["_ctrl"] = true  // Маркер: это управляющее сообщение, не текст пользователя
            let jsonData = try JSONSerialization.data(withJSONObject: json)
            guard let jsonStr = String(data: jsonData, encoding: .utf8) else { return }

            let encrypted = try crypto.encrypt(jsonStr)
            let msg: [String: Any] = ["type": "encrypted-message", "data": encrypted]

            if let data = try? JSONSerialization.data(withJSONObject: msg),
               let text = String(data: data, encoding: .utf8) {
                let sent = rtc?.send(text) ?? false
                // Log file transfer control send results
                let desc = String(describing: message)
                if desc.contains("fileStart") || desc.contains("fileComplete") || desc.contains("FileStart") || desc.contains("FileComplete") {
                    ghostLog("[sendEncryptedControl] File control SENT (result=\(sent)): \(desc.prefix(80))")
                }
            }
        } catch {
            ghostLog("[sendEncryptedControl] ENCRYPT ERROR: \(error)")
        }
    }

    // MARK: - File Transfer

    func sendFile(url: URL) {
        ghostLog("[ChatViewModel] sendFile called, isConnected=\(isConnected), cryptoReady=\(crypto?.isReady ?? false), url=\(url.lastPathComponent)")

        // Saved Messages mode — save locally without P2P
        if isSavedMessagesMode {
            guard let data = try? Data(contentsOf: url) else { return }
            let fileName = url.lastPathComponent
            guard let result = fileTransfer.saveFileLocally(data: data, fileName: fileName) else { return }

            let msg = ChatMessage(
                contactId: currentContactId,
                text: "\(fileName) (\(FileTransferService.formatSize(Int64(data.count))))",
                type: .sent,
                expiresAt: nil,
                fileName: fileName,
                fileSize: Int64(data.count),
                fileMimeType: result.mimeType,
                fileLocalPath: result.localPath,
                fileId: result.fileId
            )
            messages.append(msg)
            if saveMessageHistory || isSavedMessagesMode {
                try? messageStore.save(msg)
            }
            return
        }

        guard isConnected, peerSupportsFiles else {
            ghostLog("[FileTransfer] sendFile: BLOCKED — isConnected=\(isConnected), peerSupportsFiles=\(peerSupportsFiles)")
            addSystemMessage(peerSupportsFiles ? String(localized: "system.notConnected") : String(localized: "system.peerNoFiles"))
            return
        }

        ghostLog("[FileTransfer] sendFile: starting, url=\(url.lastPathComponent), isConnected=\(isConnected), cryptoReady=\(crypto?.isReady ?? false), rtcConnected=\(rtc?.isConnected ?? false)")
        guard let result = fileTransfer.sendFile(url: url) else {
            ghostLog("[FileTransfer] sendFile: FAILED — fileTransfer.sendFile returned nil")
            return
        }
        ghostLog("[FileTransfer] sendFile: started fileId=\(result.fileId), name=\(result.fileName), size=\(result.fileSize)")

        let msg = ChatMessage(
            contactId: currentContactId,
            text: "\(result.fileName) (\(FileTransferService.formatSize(result.fileSize)))",
            type: .sent,
            expiresAt: (isSavedMessagesMode || messageAutoDeleteTime <= 0) ? nil : Date().addingTimeInterval(messageAutoDeleteTime),
            fileName: result.fileName,
            fileSize: result.fileSize,
            fileMimeType: result.mimeType,
            fileLocalPath: "\(result.fileId)_\(result.fileName)",
            fileTransferProgress: 0.0,
            fileId: result.fileId
        )
        messages.append(msg)
    }

    private func setupFileTransferCallbacks() {
        ghostLog("[ChatViewModel] setupFileTransferCallbacks called")
        fileTransfer.onSendControl = { [weak self] control in
            guard let self else { return }
            Task { @MainActor in
                await self.sendEncryptedControl(control)
            }
        }
        // Async version — waits for encrypt+send, used by chunk sender
        fileTransfer.onSendControlAsync = { [weak self] control in
            guard let self else { return }
            await self.sendEncryptedControl(control)
        }
        // Backpressure: provide DataChannel bufferedAmount for file transfer throttling
        fileTransfer.bufferedAmountProvider = { [weak self] in
            self?.rtc?.dataChannel?.bufferedAmount ?? 0
        }

        fileTransfer.onSendProgress = { [weak self] fileId, progress in
            guard let self else { return }
            Task { @MainActor in
                if let idx = self.messages.firstIndex(where: { $0.fileId == fileId && $0.type == .sent }) {
                    self.messages[idx].fileTransferProgress = progress < 1.0 ? progress : nil
                }
            }
        }

        fileTransfer.onReceiveProgress = { [weak self] fileId, progress in
            guard let self else { return }
            Task { @MainActor in
                if let idx = self.messages.firstIndex(where: { $0.fileId == fileId && $0.type == .received }) {
                    self.messages[idx].fileTransferProgress = progress
                }
            }
        }

        fileTransfer.onFileReceived = { [weak self] fileId, localPath, fileName, fileSize, mimeType in
            guard let self else { return }
            Task { @MainActor in
                if let idx = self.messages.firstIndex(where: { $0.fileId == fileId && $0.type == .received }) {
                    self.messages[idx].fileLocalPath = localPath
                    self.messages[idx].fileTransferProgress = nil
                    if self.saveMessageHistory {
                        try? self.messageStore.save(self.messages[idx])
                    }
                }
            }
        }

        fileTransfer.onFileSent = { [weak self] fileId in
            guard let self else { return }
            Task { @MainActor in
                if let idx = self.messages.firstIndex(where: { $0.fileId == fileId && $0.type == .sent }) {
                    self.messages[idx].fileTransferProgress = nil
                    if self.saveMessageHistory {
                        try? self.messageStore.save(self.messages[idx])
                    }
                }
            }
        }

        fileTransfer.onFileError = { [weak self] fileId, error in
            guard let self else { return }
            Task { @MainActor in
                ghostLog("[FileTransfer] Error for \(fileId): \(error)")
                // Remove progress from failed file message
                if let idx = self.messages.firstIndex(where: { $0.fileId == fileId && $0.type == .received }) {
                    self.messages[idx].fileTransferProgress = nil
                }
                self.addSystemMessage("⚠️ " + String(localized: "system.fileError"))
            }
        }
    }

    // MARK: - Renegotiation

    private func sendRenegotiationOffer(_ offer: RTCSessionDescription) async {
        ghostLog("[ChatViewModel] sendRenegotiationOffer called")
        let sdpDict = GhostRTC.sdpToDict(offer)
        await sendEncryptedControl(.renegotiate(sdp: sdpDict))
    }

    private func handleRenegotiation(_ sdp: [String: Any]) async {
        ghostLog("[ChatViewModel] handleRenegotiation called, type=\(sdp["type"] ?? "nil")")
        guard let typeStr = sdp["type"] as? String else { return }

        if typeStr == "offer" {
            if callState == .ringing {
                // Store offer for when call is accepted
                if let rtcSdp = GhostRTC.dictToSdp(sdp) {
                    pendingRenegotiationOffer = rtcSdp
                }
                return
            }

            await processRenegotiationOffer(sdp)
        } else if typeStr == "answer" {
            if let rtcSdp = GhostRTC.dictToSdp(sdp) {
                await rtc?.handleAnswer(rtcSdp)
            }
            // DON'T auto-transition to .active here — wait for explicit
            // callResponse(accepted: true) control message from the callee.
            // Renegotiation answers can also occur for non-call scenarios
            // (e.g. adding data tracks). The callee sends callResponse after
            // acceptCall() which is the authoritative signal.
        }
    }

    /// CRITICAL: Order matters for bidirectional audio!
    /// 1. setRemoteDescription(offer) — creates transceiver from offer's audio m-line
    /// 2. addTrack — reuses existing transceiver (direction becomes sendrecv)
    /// 3. createAnswer — includes our audio as sendrecv
    private func processRenegotiationOffer(_ sdp: [String: Any]) async {
        ghostLog("[ChatViewModel] processRenegotiationOffer called")
        guard let rtcSdp = GhostRTC.dictToSdp(sdp), let rtc else {
            ghostLog("[ChatViewModel] processRenegotiationOffer FAILED: sdp or rtc nil")
            return
        }

        // Step 1: Set remote description — creates transceiver from offer
        guard await rtc.setRemoteOffer(rtcSdp) else {
            ghostLog("[ChatViewModel] processRenegotiationOffer FAILED: setRemoteOffer returned false")
            return
        }
        ghostLog("[ChatViewModel] processRenegotiationOffer: setRemoteOffer OK")

        // Step 2: Add our audio track — reuses the offer's transceiver (sendrecv)
        voice?.addAudioTrack()
        ghostLog("[ChatViewModel] processRenegotiationOffer: addAudioTrack done")

        // Step 3: Create answer with our audio included as sendrecv
        guard let answer = await rtc.createAndSetAnswer() else {
            ghostLog("[ChatViewModel] processRenegotiationOffer FAILED: createAndSetAnswer returned nil")
            return
        }
        ghostLog("[ChatViewModel] processRenegotiationOffer: answer created, sending")

        let answerDict = GhostRTC.sdpToDict(answer)
        await sendEncryptedControl(.renegotiate(sdp: answerDict))
        ghostLog("[ChatViewModel] processRenegotiationOffer: answer sent")
    }

    // MARK: - Voice Calls

    func startCall() async {
        ghostLog("[ChatViewModel] startCall called, connected=\(self.isConnected), callState=\(String(describing: self.callState))")
        guard callState == .idle else { return }

        // Reset timer display so old value doesn't flash briefly
        callTimer = "00:00"

        // If not connected — create room, send VoIP push, wait for peer
        if !isConnected {
            callState = .calling
            addSystemMessage(String(localized: "system.calling"))

            // Warn if peer has no push token — they won't receive the call notification
            if let contact = currentPeerContact, contact.pushToken == nil && contact.notifyToken == nil {
                ghostLog("[ChatViewModel] startCall: offline call — peer has NO push token, they won't be notified")
                addSystemMessage(String(localized: "system.noPushToken"))
            }

            // Report outgoing call to system (Dynamic Island)
            let uuid = UUID()
            activeCallUUID = uuid
            let callerName = currentPeerContact?.label ?? "Ghost Chat"
            if let appDelegate = AppDelegate.shared ?? (UIApplication.shared.delegate as? AppDelegate) {
                appDelegate.reportOutgoingCall(uuid: uuid, handle: callerName)
            }

            // Room should already exist from autoConnectToContact
            // If not, create now
            pendingCallAfterConnect = true
            if roomId == nil, let contact = currentPeerContact {
                await autoConnectToContact(contact)
            }

            // Wait up to 30 seconds for peer to connect + complete key exchange
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if isConnected && keyExchangeCompleted { break }
                if callState != .calling { return } // User cancelled
            }

            guard isConnected, keyExchangeCompleted else {
                // Cancel connection timeout to prevent leave() during cleanup
                connectionTimeout?.invalidate()
                connectionTimeout = nil
                callState = .idle
                addSystemMessage(String(localized: "system.callNoAnswer"))
                if let appDelegate = AppDelegate.shared ?? (UIApplication.shared.delegate as? AppDelegate), let uuid = activeCallUUID {
                    appDelegate.endSystemCall(uuid: uuid)
                }
                activeCallUUID = nil
                pendingCallAfterConnect = false
                // Cleanup signaling/rtc created by ensureRoomAndInvitePeer but stay in chat
                signaling?.leaveRoom()
                signaling?.disconnect()
                signaling = nil
                rtc?.destroy()
                rtc = nil
                crypto?.destroy()
                crypto = nil
                roomId = nil
                return
            }
            pendingCallAfterConnect = false
        }

        guard let rtc, let pc = rtc.peerConnection else {
            callState = .idle
            return
        }

        // Reuse voice if exists (same P2P session) — replaceTrack handles second call
        // Only create new if nil (first call or after reconnect)
        if voice == nil {
            voice = GhostVoice(peerConnection: pc, factory: rtc.factory)
            setupVoiceCallbacks()
            ghostLog("[ChatViewModel] startCall: new GhostVoice created (first call)")
        } else {
            ghostLog("[ChatViewModel] startCall: reusing existing GhostVoice (second call)")
        }

        do {
            // CRITICAL: Send call-request BEFORE adding audio track!
            // Adding audio track triggers onnegotiationneeded → renegotiation offer.
            // If renegotiation offer arrives at callee before call-request,
            // callee processes it in idle state → one-way audio.

            // Only set calling state + CallKit if not already set (offline call branch sets it earlier)
            if callState != .calling {
                callState = .calling
                let uuid = UUID()
                activeCallUUID = uuid
                let callerName = currentPeerContact?.label ?? "Ghost Chat"
                if let appDelegate = AppDelegate.shared ?? (UIApplication.shared.delegate as? AppDelegate) {
                    appDelegate.reportOutgoingCall(uuid: uuid, handle: callerName)
                }
            }

            await sendEncryptedControl(.callRequest)
            addSystemMessage(String(localized: "system.calling"))
            let didReuseSender = try voice?.startCall() ?? false

            // CRITICAL: When sender was reused (second call), onnegotiationneeded does NOT fire
            // because WebRTC sees the same transceiver. Peer needs renegotiation to know audio changed.
            if didReuseSender {
                ghostLog("[ChatViewModel] startCall: sender reused — forcing manual renegotiation")
                if let offer = await rtc.createOffer() {
                    await sendRenegotiationOffer(offer)
                }
            }

            // ВСЕГДА включаем аудио вручную — CallKit didActivate ненадёжен
            ghostLog("[ChatViewModel] startCall: enabling audio immediately")
            RTCAudioSession.sharedInstance().isAudioEnabled = true
            voice?.enableAudioManually()

            // Aggressive audio enable fallback — retry at 0.5s, 1.5s, 3s
            for delay in [500_000_000, 1_500_000_000, 3_000_000_000] as [UInt64] {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: delay)
                    guard let self, self.callState == .calling || self.callState == .active else { return }
                    let rtcAudio = RTCAudioSession.sharedInstance()
                    if !rtcAudio.isAudioEnabled {
                        ghostLog("[ChatViewModel] startCall: fallback audio enable at \(delay/1_000_000)ms")
                        rtcAudio.isAudioEnabled = true
                        self.voice?.enableAudioManually()
                    }
                }
            }

            // Caller-side timeout — cancel call after 45s of no answer
            callingTimeout = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.callState == .calling else { return }
                    self.addSystemMessage(String(localized: "system.noAnswer"))
                    // Send missed call push notification to peer
                    await self.sendMissedCallPush()
                    await self.endCall()
                }
            }
        } catch {
            addSystemMessage(String(format: String(localized: "system.callError"), error.localizedDescription))
            callState = .idle
        }
    }

    private func handleIncomingCall() {
        ghostLog("[ChatViewModel] handleIncomingCall called, callState=\(callState)")
        guard callState == .idle else {
            Task {
                await sendEncryptedControl(.callResponse(accepted: false))
            }
            return
        }

        callState = .ringing
        addSystemMessage(String(localized: "system.incomingCall"))

        // Ringing timeout — auto-decline after 30 seconds
        ringingTimeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.callState == .ringing else { return }
                await self.declineCall()
            }
        }

        // CallKit — системный UI входящего звонка (играет рингтон на полной громкости,
        // игнорирует silent switch — гарантирует звук 100%)
        reportIncomingCallToSystem()
    }

    private var ringtoneTimer: Timer?

    private func startIncomingCallVibration() {
        ghostLog("[ChatViewModel] startIncomingCallVibration called")
        let ringtone = SoundLibrary.ringtone(forId: ringtoneId)
        let shouldVibrate = vibrationEnabled

        // Первое воспроизведение сразу
        if shouldVibrate {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
        SoundLibrary.playRingtoneSound(ringtone)

        // Повтор каждые 2.5 секунды (рингтон + вибрация)
        ringtoneTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in
            if shouldVibrate {
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }
            SoundLibrary.playRingtoneSound(ringtone)
        }
    }

    private func stopIncomingCallVibration() {
        ghostLog("[ChatViewModel] stopIncomingCallVibration called")
        vibrationTimer?.invalidate()
        vibrationTimer = nil
        ringtoneTimer?.invalidate()
        ringtoneTimer = nil
    }

    private func reportIncomingCallToSystem() {
        ghostLog("[ChatViewModel] reportIncomingCallToSystem called")
        guard let appDelegate = AppDelegate.shared ?? (AppDelegate.shared ?? (UIApplication.shared.delegate as? AppDelegate)) else {
            ghostLog("[ChatViewModel] reportIncomingCallToSystem: appDelegate is nil!")
            voice?.enableAudioManually()
            startIncomingCallVibration()
            return
        }

        let uuid = UUID()
        activeCallUUID = uuid
        let callerName = currentPeerContact?.label ?? "Ghost Chat"
        ghostLog("[ChatViewModel] reportIncomingCallToSystem: calling reportIncomingCall, name=\(callerName)")

        startIncomingCallVibration()

        // CRITICAL: Register callbacks BEFORE reportIncomingCall —
        // CallKit may invoke onCallAnswer synchronously on the main thread
        // before reportIncomingCall returns (e.g. when phone is locked).
        appDelegate.onCallAnswer = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.acceptCall()
            }
        }
        appDelegate.onCallEnd = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.declineCall()
            }
        }
        appDelegate.onCallMute = { [weak self] in
            Task { @MainActor [weak self] in
                self?.toggleMute()
            }
        }

        appDelegate.reportIncomingCall(uuid: uuid, handle: callerName) { [weak self] error in
            if let error {
                ghostLog("[ChatViewModel] CallKit reportIncomingCall FAILED: \(error)")
                #if DEBUG
                print("[CallKit] Failed to report call: \(error)")
                #endif
                self?.activeCallUUID = nil
                // Fallback при ошибке CallKit — вручную включаем аудио
                self?.voice?.enableAudioManually()
            }
        }
    }

    /// Buffered "user tapped Accept in CallKit" intent when P2P isn't ready yet
    /// (e.g. cold-start VoIP push: CallKit UI shows instantly, user taps immediately,
    /// but DataChannel/keyExchange hasn't finished). Flushed by completeKeyExchange.
    private var pendingAcceptCall = false

    func acceptCall() async {
        ghostLog("[ChatViewModel] acceptCall called, callState=\(String(describing: self.callState)), isFromPush=\(isFromPush), isConnected=\(isConnected), keyExchangeCompleted=\(keyExchangeCompleted)")

        // If this is a push-triggered accept and P2P isn't ready yet, buffer the intent
        // and flush it from completeKeyExchange. User sees "connecting" in CallKit UI.
        if callState != .ringing || rtc?.peerConnection == nil || !isConnected || !keyExchangeCompleted {
            if isFromPush {
                ghostLog("[ChatViewModel] acceptCall: P2P not ready — buffering accept intent until completeKeyExchange")
                pendingAcceptCall = true
                addSystemMessage(String(localized: "system.connecting"))
                return
            }
            logger.warning("[ChatViewModel] acceptCall: not ringing or no PC — dropping")
            return
        }

        guard callState == .ringing, let rtc, let pc = rtc.peerConnection else {
            logger.warning("[ChatViewModel] acceptCall: guard fell through")
            return
        }

        // Reset timer display so old value doesn't flash briefly
        callTimer = "00:00"

        ringingTimeout?.invalidate()
        ringingTimeout = nil
        stopIncomingCallVibration()

        // Reuse voice if exists (same P2P session)
        if voice == nil {
            voice = GhostVoice(peerConnection: pc, factory: rtc.factory)
            setupVoiceCallbacks()
            ghostLog("[ChatViewModel] acceptCall: new GhostVoice created")
        } else {
            ghostLog("[ChatViewModel] acceptCall: reusing existing GhostVoice")
        }

        do {
            // Only initialize audio (create track), don't add to PC yet
            try voice?.initializeAudio()

            // ВСЕГДА включаем аудио вручную сразу
            ghostLog("[ChatViewModel] acceptCall: enabling audio immediately")
            RTCAudioSession.sharedInstance().isAudioEnabled = true
            voice?.enableAudioManually()

            // Process pending renegotiation offer with correct ordering:
            // setRemoteDescription → addTrack → createAnswer
            if let pendingOffer = pendingRenegotiationOffer {
                let sdpDict = GhostRTC.sdpToDict(pendingOffer)
                await processRenegotiationOffer(sdpDict)
                pendingRenegotiationOffer = nil
            } else {
                // No pending offer — add track and renegotiate to inform peer
                voice?.addAudioTrack()

                // Renegotiate to inform peer about new audio track
                // (onRenegotiationNeeded may not fire reliably on second call)
                if let offer = await rtc.createOffer() {
                    await sendRenegotiationOffer(offer)
                }
            }

            // Mark call as active
            voice?.markCallActive()

            await sendEncryptedControl(.callResponse(accepted: true))

            callState = .active
            addSystemMessage(String(localized: "system.callConnected"))

            // Report to CallKit that incoming call was answered in-app
            // This dismisses Dynamic Island / system incoming call UI
            if let uuid = activeCallUUID,
               let appDelegate = AppDelegate.shared ?? (UIApplication.shared.delegate as? AppDelegate) {
                ghostLog("[ChatViewModel] acceptCall: reporting incoming call connected to CallKit, uuid=\(uuid)")
                appDelegate.reportIncomingCallConnected(uuid: uuid)
            }
        } catch {
            addSystemMessage(String(format: String(localized: "system.error"), error.localizedDescription))
            await sendEncryptedControl(.callResponse(accepted: false))
            callState = .idle
        }
    }

    func declineCall() async {
        ghostLog("[ChatViewModel] declineCall called, callState=\(callState)")
        guard callState == .ringing else { return }
        ringingTimeout?.invalidate()
        ringingTimeout = nil
        stopIncomingCallVibration()
        endSystemCall()

        await sendEncryptedControl(.callResponse(accepted: false))

        voice?.destroy()
        voice = nil
        callState = .idle
        pendingRenegotiationOffer = nil
        addSystemMessage(String(localized: "system.callDeclined"))
    }

    private func handleCallResponse(_ accepted: Bool) {
        ghostLog("[ChatViewModel] handleCallResponse called, accepted=\(accepted), callState=\(callState)")
        guard callState == .calling else { return }

        // Clear caller-side timeout
        callingTimeout?.invalidate()
        callingTimeout = nil

        if accepted {
            voice?.callAccepted()
            callState = .active
            addSystemMessage(String(localized: "system.callStarted"))
            // Report outgoing call connected to system (Dynamic Island timer starts)
            if let uuid = activeCallUUID,
               let appDelegate = AppDelegate.shared ?? (UIApplication.shared.delegate as? AppDelegate) {
                appDelegate.reportOutgoingCallConnected(uuid: uuid)
            }
        } else {
            voice?.endCall()
            voice?.destroy()
            voice = nil
            callState = .idle
            endSystemCall()
            addSystemMessage(String(localized: "system.callDeclined"))
        }
    }

    func endCall() async {
        ghostLog("[ChatViewModel] endCall called, callState=\(String(describing: self.callState))")
        guard callState != .idle else { return }
        callingTimeout?.invalidate()
        callingTimeout = nil
        stopIncomingCallVibration()
        endSystemCall()

        voice?.endCall()
        // DON'T destroy voice — keep for second call in same P2P session
        // voice will be destroyed in performLeave/destroy when P2P ends

        await sendEncryptedControl(.callEnd)

        callState = .idle
        isMuted = false
        isSpeakerOn = false
        pendingRenegotiationOffer = nil
        addSystemMessage(String(localized: "system.callEnded"))
    }

    private func handleCallEnded() {
        ghostLog("[ChatViewModel] handleCallEnded called")
        callingTimeout?.invalidate()
        callingTimeout = nil
        stopIncomingCallVibration()
        endSystemCall()

        voice?.endCall()
        // Keep voice for second call

        callState = .idle
        isMuted = false
        isSpeakerOn = false
        pendingRenegotiationOffer = nil
        addSystemMessage(String(localized: "system.peerEndedCall"))
    }

    private func endSystemCall() {
        ghostLog("[ChatViewModel] endSystemCall called, uuid=\(activeCallUUID?.uuidString ?? "nil")")
        guard let uuid = activeCallUUID,
              let appDelegate = AppDelegate.shared ?? (UIApplication.shared.delegate as? AppDelegate) else { return }
        appDelegate.endSystemCall(uuid: uuid)
        activeCallUUID = nil
    }

    func toggleMute() {
        ghostLog("[ChatViewModel] toggleMute called")
        guard let voice else { return }
        isMuted = voice.toggleMute()
    }

    func toggleSpeaker() {
        ghostLog("[ChatViewModel] toggleSpeaker called")
        guard let voice else { return }
        isSpeakerOn = voice.toggleSpeaker()
    }

    private func setupVoiceCallbacks() {
        ghostLog("[ChatViewModel] setupVoiceCallbacks called")
        voice?.onCallTimer = { [weak self] time in
            self?.callTimer = time
        }

        voice?.onCallStateChange = { [weak self] state in
            switch state {
            case .active:
                self?.callState = .active
            case .ended:
                self?.callState = .idle
            case .calling:
                self?.callState = .calling
            }
        }

        // Replay buffered remote track
        if let pendingStream = pendingRemoteStream,
           let audioTrack = pendingStream.audioTracks.first {
            voice?.onRemoteAudioTrack?(audioTrack)
            pendingRemoteStream = nil
        }
    }

    // MARK: - Security

    private func handleSecurityAlert(_ alert: String) {
        ghostLog("[ChatViewModel] handleSecurityAlert called, alert=\(alert)")
        if alert == "screenshot-attempt" {
            addSystemMessage(String(localized: "system.peerScreenshot"))
        }
    }

    private func handleMessageAck(_ counter: Int) {
        ghostLog("[ChatViewModel] handleMessageAck called, counter=\(counter)")
        if let record = sentMessages[counter],
           let index = messages.firstIndex(where: { $0.id == record.id }) {
            let msgId = record.id
            messages[index].isDelivered = true
            // Don't remove from sentMessages — keep for read receipt tracking
            if saveMessageHistory {
                do {
                    try messageStore.markDelivered(msgId)
                } catch {
                    ghostLog("[ChatViewModel] ERROR: failed to mark message delivered: \(error)")
                }
            }
        }
    }

    private func handleMessageRead(_ counter: Int) {
        ghostLog("[ChatViewModel] handleMessageRead called, counter=\(counter)")
        if let record = sentMessages[counter],
           let index = messages.firstIndex(where: { $0.id == record.id }) {
            messages[index].isDelivered = true // in case READ arrived before ACK
            messages[index].isRead = true
            sentMessages.removeValue(forKey: counter)
            if saveMessageHistory {
                do {
                    try messageStore.markDelivered(record.id)
                } catch {
                    ghostLog("[ChatViewModel] ERROR: failed to mark message read: \(error)")
                }
            }
        }
    }

    /// Convert stored token Data to string for server API
    /// Handles both old format (32 raw APNs bytes) and new format (UTF-8 encoded string)
    private func tokenString(_ data: Data) -> String {
        // Old format: raw 32-byte APNs token (pre-fix contacts)
        if data.count == 32 {
            return data.hexString
        }
        // New format: UTF-8 encoded token string (hex for APNs, plain for FCM)
        return String(data: data, encoding: .utf8) ?? data.hexString
    }

    /// Сохранить push token peer'а в контакте
    /// Tokens stored as UTF-8 Data: hex string for APNs, plain string for FCM
    private func handlePeerPushToken(_ tokenStr: String) {
        ghostLog("[ChatViewModel] handlePeerPushToken called, len=\(tokenStr.count)")
        guard !tokenStr.isEmpty else { return }
        let tokenData = Data(tokenStr.utf8)
        peerPushToken = tokenData

        // Обновить контакт если есть
        if var contact = currentPeerContact {
            contact.pushToken = tokenData
            let store = ContactStore()
            do {
                try? DatabaseService.shared.setup()
                try store.save(contact)
                ghostLog("[ChatViewModel] handlePeerPushToken: saved to contact \(contact.label)")
            } catch {
                ghostLog("[ChatViewModel] ERROR: failed to save peer push token: \(error)")
            }
            currentPeerContact = contact
        } else {
            ghostLog("[ChatViewModel] handlePeerPushToken: no currentPeerContact yet — kept in memory, will be persisted on contact creation")
        }

        // MUTUAL EXCHANGE: if we haven't yet sent OUR tokens this session
        // (e.g. they were nil at completeKeyExchange time), send them now.
        // Guarded so we don't ping-pong ACKs forever.
        if !tokensSentToPeerThisSession, let myToken = localVoIPToken {
            tokensSentToPeerThisSession = true
            ghostLog("[Push] handlePeerPushToken: mutual ACK — sending OUR tokens now")
            Task { await sendEncryptedControl(.pushToken(token: myToken.hexString)) }
            if let myNotify = localRegularPushToken {
                Task { await sendEncryptedControl(.notifyToken(token: myNotify.hexString)) }
            }
        }
    }

    private func handlePeerNotifyToken(_ tokenStr: String) {
        ghostLog("[ChatViewModel] handlePeerNotifyToken called, len=\(tokenStr.count)")
        guard !tokenStr.isEmpty else { return }
        let tokenData = Data(tokenStr.utf8)
        peerNotifyToken = tokenData

        // Обновить контакт если есть
        if var contact = currentPeerContact {
            contact.notifyToken = tokenData
            let store = ContactStore()
            do {
                try? DatabaseService.shared.setup()
                try store.save(contact)
                ghostLog("[ChatViewModel] handlePeerNotifyToken: saved to contact \(contact.label)")
            } catch {
                ghostLog("[ChatViewModel] ERROR: failed to save peer notify token: \(error)")
            }
            currentPeerContact = contact
        } else {
            ghostLog("[ChatViewModel] handlePeerNotifyToken: no currentPeerContact yet — kept in memory, will be persisted on contact creation")
        }

        // MUTUAL EXCHANGE: same dedup flag as pushToken branch (handled there)
        if !tokensSentToPeerThisSession, let myToken = localRegularPushToken {
            tokensSentToPeerThisSession = true
            ghostLog("[Push] handlePeerNotifyToken: mutual ACK — sending OUR tokens now")
            Task { await sendEncryptedControl(.notifyToken(token: myToken.hexString)) }
            if let myPush = localVoIPToken {
                Task { await sendEncryptedControl(.pushToken(token: myPush.hexString)) }
            }
        }
    }

    // MARK: - Saved Messages (Избранное)

    /// Open local "Saved Messages" chat — like Telegram favorites
    func openSavedMessages() {
        ghostLog("[ChatViewModel] openSavedMessages called")
        currentContactId = Self.savedMessagesContactId
        messages.removeAll()
        loadMessageHistory()
        screen = .chat
    }

    /// Leave saved messages mode
    func leaveSavedMessages() {
        ghostLog("[ChatViewModel] leaveSavedMessages called")
        currentContactId = nil
        messages.removeAll()
        screen = .welcome
    }

    // MARK: - Chat Invite Push

    /// Пригласить контакт в чат через push-уведомление
    /// Ghost Threads: open chat with contact → load history → new room → P2P
    func openContactChat(_ contact: Contact) async {
        ghostLog("[ChatViewModel] openContactChat called, contact=\(contact.label)")
        currentContactId = contact.id.uuidString
        currentPeerContact = contact
        expectedPeerIdentityKey = contact.identityKey
        updateActiveChat(contactId: contact.id.uuidString, contactName: contact.label)

        // Clear pending message highlight if opening this contact
        if pendingMessageContactId == contact.id.uuidString {
            pendingMessageContactId = nil
            pendingMessageType = nil
        }

        // Clear previous messages to avoid duplicates on re-open
        messages.removeAll()

        // Load history if enabled
        loadMessageHistory()

        // Create new room (new keys, new fingerprint every time)
        await inviteContactToChat(contact)
    }

    func inviteContactToChat(_ contact: Contact) async {
        ghostLog("[ChatViewModel] inviteContactToChat called, contact=\(contact.label)")
        // Use notifyToken (chat invite token) or fallback to pushToken
        guard let tokenData = contact.notifyToken ?? contact.pushToken else { return }

        expectedPeerIdentityKey = contact.identityKey
        currentPeerContact = contact

        // Создаём комнату и ЖДЁМ roomId от сервера
        guard let roomId = await createRoomAndWait() else { return }

        // Detect platform: APNs hex tokens are ≤80 chars, FCM tokens are 100+ chars
        let token = tokenString(tokenData)
        let platform = token.count <= 80 ? "ios" : "android"

        // Отправить push с приглашением (APNs для iOS, FCM для Android)
        // Используем имя отправителя (наше), а не получателя
        let myName = Self.loadStringSetting(forKey: "settings_display_name", default: String(localized: "notification.yourContact"))
        await sendInvitePush(
            token: token,
            roomId: roomId,
            inviterName: myName,
            platform: platform
        )
    }

    private func sendInvitePush(token: String, roomId: String, inviterName: String, platform: String) async {
        ghostLog("[ChatViewModel] sendInvitePush called, platform=\(platform)")
        await ensureFreshPushAuth()
        ghostLog("[InvitePush] Sending invite, platform=\(platform), token=\(token.prefix(8))..., roomId=\(roomId.prefix(8))..., auth=\(pushAuthToken != nil ? "present" : "missing")")
        var request = URLRequest(url: Self.serverURL.appendingPathComponent("api/send-invite"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "token": token,
            "platform": platform,
            "payload": ["roomId": roomId, "inviterName": inviterName]
        ]
        if let auth = pushAuthToken { body["auth"] = auth }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    ghostLog("[InvitePush] Success")
                } else {
                    let respBody = String(data: data, encoding: .utf8) ?? ""
                    ghostLog("[InvitePush] Server returned \(httpResponse.statusCode): \(respBody)")
                }
            }
        } catch {
            ghostLog("[InvitePush] Failed to send: \(error.localizedDescription)")
        }
    }

    // MARK: - Offline Message Push

    /// Отправить push-уведомление о новом сообщении (peer офлайн)
    /// Не отправляет если пользователь уже в чате с этим контактом (проверяется на стороне отправителя)
    private func sendOfflineMessagePush() async {
        guard let contact = currentPeerContact else {
            ghostLog("[NotifyPush] sendOfflineMessagePush: no currentPeerContact, skipping")
            return
        }
        // Используем notifyToken (regular APNs) для сообщений, fallback на pushToken
        guard let tokenData = contact.notifyToken ?? contact.pushToken else {
            ghostLog("[NotifyPush] sendOfflineMessagePush: no notify/push token for contact \(contact.label), skipping")
            return
        }

        let token = tokenString(tokenData)
        let platform = token.count <= 80 ? "ios" : "android"

        // Имя отправителя — НАШЕ имя (не имя получателя)
        // Получатель увидит "Новое сообщение от X" где X = наше display name
        let senderName = Self.loadStringSetting(forKey: "settings_display_name", default: contact.label)

        ghostLog("[NotifyPush] sendOfflineMessagePush: sending to \(contact.label), token=\(token.prefix(8))..., platform=\(platform), senderName=\(senderName)")
        await sendNotifyPush(token: token, platform: platform, type: "new-message", senderName: senderName)
    }

    /// Отправить push о пропущенном звонке (таймаут 45с)
    private func sendMissedCallPush() async {
        guard let contact = currentPeerContact else {
            ghostLog("[NotifyPush] sendMissedCallPush: no currentPeerContact, skipping")
            return
        }
        guard let tokenData = contact.notifyToken ?? contact.pushToken else {
            ghostLog("[NotifyPush] sendMissedCallPush: no notify/push token for contact \(contact.label), skipping")
            return
        }

        let token = tokenString(tokenData)
        let platform = token.count <= 80 ? "ios" : "android"

        // Имя отправителя — НАШЕ имя
        let senderName = Self.loadStringSetting(forKey: "settings_display_name", default: contact.label)

        ghostLog("[NotifyPush] sendMissedCallPush: sending to \(contact.label), token=\(token.prefix(8))..., platform=\(platform)")
        await sendNotifyPush(token: token, platform: platform, type: "missed-call", senderName: senderName)
    }

    /// Универсальный метод отправки уведомления через сервер
    /// Сервер — тупой прокси: получает токен → отправляет push → затирает данные нулями
    private func sendNotifyPush(token: String, platform: String, type: String, senderName: String) async {
        ghostLog("[ChatViewModel] sendNotifyPush called, platform=\(platform), type=\(type)")
        await ensureFreshPushAuth()
        ghostLog("[NotifyPush] Sending type=\(type), platform=\(platform), token=\(token.prefix(8))..., auth=\(pushAuthToken != nil ? "present" : "missing")")
        var request = URLRequest(url: Self.serverURL.appendingPathComponent("api/push/notify"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "token": token,
            "platform": platform,
            "type": type,
            "senderName": senderName
        ]
        if let auth = pushAuthToken { body["auth"] = auth }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    ghostLog("[NotifyPush] Success for type=\(type)")
                } else if httpResponse.statusCode == 410 {
                    // APNs said this token is dead — drop it from peer contact so next
                    // key exchange issues a fresh one.
                    ghostLog("[NotifyPush] 410 stale token — clearing notifyToken for contact")
                    dropStalePeerTokens()
                } else if httpResponse.statusCode == 403 {
                    // pushAuth expired — refresh for next call
                    ghostLog("[NotifyPush] 403 auth — refreshing pushAuthToken")
                    pushAuthToken = nil
                    pushAuthIssuedAt = nil
                } else {
                    let respBody = String(data: data, encoding: .utf8) ?? ""
                    ghostLog("[NotifyPush] Server returned \(httpResponse.statusCode): \(respBody)")
                }
            }
        } catch {
            ghostLog("[NotifyPush] Failed: \(error.localizedDescription)")
        }
    }

    /// Remove stale peer push tokens from current contact after APNs 410
    private func dropStalePeerTokens() {
        guard var contact = currentPeerContact else { return }
        contact.pushToken = nil
        contact.notifyToken = nil
        let store = ContactStore()
        do {
            try? DatabaseService.shared.setup()
            try store.save(contact)
            currentPeerContact = contact
            ghostLog("[ChatViewModel] dropStalePeerTokens: cleared tokens for \(contact.label)")
        } catch {
            ghostLog("[ChatViewModel] dropStalePeerTokens: save failed: \(error)")
        }
    }

    /// Обработка входящего приглашения в чат (из push или foreground)
    private func handleIncomingInvite(roomId: String, inviterName: String) {
        ghostLog("[ChatViewModel] handleIncomingInvite called, inviter=\(inviterName), roomId=\(roomId.prefix(8))")
        // Если уже в чате — игнорируем
        guard screen != .chat else { return }

        // Если на другом экране (waiting/connecting) — сначала выйти
        if screen != .welcome {
            leave()
        }

        pendingInviteRoom = roomId
        pendingInviterName = inviterName
    }

    /// Обработка push о новом сообщении / пропущенном звонке
    /// Если на WelcomeScreen — открываем чат, иначе подсвечиваем контакт
    private func handleMessagePush(type: String, senderName: String) {
        ghostLog("[ChatViewModel] handleMessagePush called, type=\(type), sender=\(senderName)")
        let store = ContactStore()
        guard let allContacts = try? store.fetchAll() else { return }
        let matches = allContacts.filter { $0.label == senderName }

        // Ambiguous match — multiple contacts with same name, skip auto-open
        guard matches.count == 1, let contact = matches.first else { return }

        if screen == .welcome {
            // Открываем чат напрямую — пользователь тапнул на уведомление
            Task { await openContactChat(contact) }
        } else {
            // Пользователь в другом чате — подсвечиваем контакт для WelcomeScreen
            pendingMessageContactId = contact.id.uuidString
            pendingMessageType = type
        }
    }

    /// Обновить activeContactChatId в AppDelegate (для подавления push если пользователь в чате)
    func updateActiveChat(contactId: String?, contactName: String? = nil) {
        ghostLog("[ChatViewModel] updateActiveChat called, contactId=\(contactId ?? "nil")")
        let delegate = AppDelegate.shared ?? (UIApplication.shared.delegate as? AppDelegate)
        delegate?.activeContactChatId = contactId
        delegate?.activeContactName = contactName
    }

    /// Обработка typing indicator от peer'а
    private func handlePeerTyping(_ isTyping: Bool) {
        ghostLog("[ChatViewModel] handlePeerTyping called, isTyping=\(isTyping)")
        peerIsTyping = isTyping

        // Автоотмена через 6 секунд если нет обновления
        peerTypingTimer?.invalidate()
        if isTyping {
            peerTypingTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.peerIsTyping = false
                }
            }
        }
    }

    // MARK: - Verification

    func markAsVerified(_ verified: Bool) {
        ghostLog("[ChatViewModel] markAsVerified called, verified=\(verified)")
        isVerified = verified
        if verified {
            addSystemMessage(String(localized: "system.verified"))
        } else {
            addSystemMessage(String(localized: "system.codesDoNotMatch"))
            addSystemMessage(String(localized: "system.endSession"))
        }
    }

    // MARK: - Messages

    @discardableResult
    func addMessage(_ text: String, type: ChatMessage.MessageType,
                    replyToId: String? = nil, replyToText: String? = nil,
                    senderMessageId: String? = nil) -> ChatMessage {
        ghostLog("[ChatViewModel] addMessage called, type=\(type), len=\(text.count)")
        let msg: ChatMessage
        if isSavedMessagesMode {
            msg = ChatMessage(
                id: UUID(),
                contactId: Self.savedMessagesContactId,
                text: text,
                type: type,
                timestamp: Date(),
                isDelivered: true,
                replyToId: replyToId,
                replyToText: replyToText,
                senderMessageId: senderMessageId
            )
            messages.append(msg)
            do {
                try messageStore.save(msg)
            } catch {
                ghostLog("[ChatViewModel] ERROR: failed to save message (saved messages): \(error)")
            }
            return msg
        }

        msg = ChatMessage(text: text, type: type, autoDeleteInterval: messageAutoDeleteTime)
        // Set reply/sender fields on the ephemeral message
        var enriched = msg
        enriched.replyToId = replyToId
        enriched.replyToText = replyToText
        enriched.senderMessageId = senderMessageId
        messages.append(enriched)

        // Ghost Threads: persist to DB if history enabled
        if saveMessageHistory, let contactId = currentContactId, type != .system {
            // Received messages viewed in open chat are immediately "delivered" (read)
            let isDeliveredForDB = enriched.isDelivered || (type == .received && screen == .chat)
            let persistMsg = ChatMessage(
                id: enriched.id,
                contactId: contactId,
                text: text,
                type: type,
                timestamp: enriched.timestamp,
                isDelivered: isDeliveredForDB,
                replyToId: replyToId,
                replyToText: replyToText,
                senderMessageId: senderMessageId
            )
            do {
                try messageStore.save(persistMsg)
            } catch {
                ghostLog("[ChatViewModel] ERROR: failed to persist message to DB: \(error)")
            }
        }

        return enriched
    }

    func addSystemMessage(_ text: String) {
        ghostLog("[ChatViewModel] addSystemMessage called, text='\(text.prefix(40))'")
        // M4: System messages get 10 min TTL (not indefinite)
        messages.append(ChatMessage(text: text, type: .system, autoDeleteInterval: 10 * 60))
    }

    /// Load message history from DB for current contact
    /// Guard: verify contactId hasn't changed during fetch (fast switch protection)
    func loadMessageHistory() {
        ghostLog("[ChatViewModel] loadMessageHistory called, contactId=\(currentContactId ?? "nil")")
        guard let contactId = currentContactId else { return }
        // Always load for saved messages; otherwise only if history is enabled
        guard isSavedMessagesMode || saveMessageHistory else { return }
        if let history = try? messageStore.fetchForContact(contactId) {
            // Verify contact hasn't changed during fetch
            guard currentContactId == contactId else { return }
            // Prepend history (no auto-delete timer — persisted messages)
            messages.insert(contentsOf: history, at: 0)
        }
    }

    /// Save a pending message (queued for sending when P2P connects)
    func queuePendingMessage(_ text: String) {
        ghostLog("[ChatViewModel] queuePendingMessage called, len=\(text.count)")
        guard let contactId = currentContactId else { return }
        let msgId = UUID()
        let msg = ChatMessage(
            id: msgId,
            contactId: contactId,
            text: text,
            type: .sent,
            isPending: true,
            expiresAt: saveMessageHistory ? nil : Date().addingTimeInterval(messageAutoDeleteTime)
        )
        // Сохраняем в БД только если история включена — иначе только in-memory
        // При saveMessageHistory=false лучше потерять сообщение при крахе,
        // чем нарушить гарантию zero-trace
        if saveMessageHistory || isSavedMessagesMode {
            do {
                try messageStore.save(msg)
            } catch {
                ghostLog("[ChatViewModel] ERROR: failed to queue pending message: \(error)")
            }
        }
        messages.append(msg)
    }

    /// Create room lazily (on first message) and send invite push to peer.
    /// Operates silently — no UI changes, no leave() on timeout.
    private func ensureRoomAndInvitePeer() async {
        ghostLog("[ChatViewModel] ensureRoomAndInvitePeer called")
        // Don't create a second room if one is already being set up
        guard roomId == nil, signaling == nil else { return }
        guard !isCreatingRoom else { return }

        guard let contact = currentPeerContact else { return }

        isCreatingRoom = true
        // Create room silently — don't change screen
        guard let newRoomId = await createRoomAndWait() else {
            isCreatingRoom = false
            return
        }

        // Disable connection timeout — we don't want leave() for offline messages
        connectionTimeout?.invalidate()
        connectionTimeout = nil

        ghostLog("[ChatViewModel] ensureRoomAndInvitePeer: room \(newRoomId.prefix(8)), registering pending room")

        // Register pending room on server so peer can find it
        let myHash = identityKeyHash()
        let peerHash = identityKeyHash(for: contact)
        if let myHash, let peerHash {
            await registerPendingRoom(peerHash: peerHash, roomId: newRoomId, creatorHash: myHash)
        }

        isCreatingRoom = false

        // Send invite push if we have a token
        if let tokenData = contact.notifyToken ?? contact.pushToken {
            let token = tokenString(tokenData)
            let platform = token.count <= 80 ? "ios" : "android"
            let myName = Self.loadStringSetting(forKey: "settings_display_name", default: String(localized: "notification.yourContact"))
            await sendInvitePush(token: token, roomId: newRoomId, inviterName: myName, platform: platform)
        }
    }

    // MARK: - Pending Room (offline contact reconnection)

    /// SHA256 hash of our identity key (anonymous ID for server)
    private func identityKeyHash() -> String? {
        let keyData = IdentityKeyService.shared.publicKeyData
        return SHA256.hash(data: keyData).compactMap { String(format: "%02x", $0) }.joined()
    }

    /// SHA256 hash of contact's identity key
    private func identityKeyHash(for contact: Contact) -> String? {
        let data = contact.identityKey
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Register pending room on server
    private func registerPendingRoom(peerHash: String, roomId: String, creatorHash: String) async {
        ghostLog("[ChatViewModel] registerPendingRoom called, roomId=\(roomId.prefix(8))")
        var request = URLRequest(url: Self.serverURL.appendingPathComponent("api/pending-room"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["peerHash": peerHash, "roomId": roomId, "creatorHash": creatorHash]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                ghostLog("[ChatViewModel] registerPendingRoom: status=\(http.statusCode)")
            }
        } catch {
            ghostLog("[ChatViewModel] registerPendingRoom error: \(error)")
        }
    }

    /// Short-timeout URL session for pending-room polls (fails fast instead of 60s default)
    private static let pendingRoomSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8     // fail fast — polls retry every 5s anyway
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Check if there's a pending room from this contact
    private func checkPendingRoom(for contact: Contact) async -> String? {
        ghostLog("[ChatViewModel] checkPendingRoom called, contact=\(contact.label)")
        guard let myHash = identityKeyHash() else { return nil }
        var components = URLComponents(url: Self.serverURL.appendingPathComponent("api/pending-room"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "myHash", value: myHash)]
        guard let url = components.url else { return nil }
        do {
            let (data, response) = try await Self.pendingRoomSession.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let roomId = json["roomId"] as? String {
                ghostLog("[ChatViewModel] checkPendingRoom: found room \(roomId.prefix(8))")
                return roomId
            }
        } catch {
            ghostLog("[ChatViewModel] checkPendingRoom error: \(error.localizedDescription)")
        }
        return nil
    }

    /// Flush pending messages after P2P connection + key exchange established
    private func flushPendingMessages() async {
        ghostLog("[ChatViewModel] flushPendingMessages called")
        guard let contactId = currentContactId, let crypto else { return }

        // Verify we have a known contact for this session
        guard currentPeerContact != nil else { return }

        let pending: [ChatMessage]
        if saveMessageHistory || isSavedMessagesMode {
            // Pending messages stored in DB
            do { pending = try messageStore.fetchPending(for: contactId) }
            catch { return }
        } else {
            // No DB storage — read pending from in-memory list
            pending = messages.filter { $0.isPending && $0.type == .sent }
        }

        guard !pending.isEmpty else { return }

        for msg in pending {
            do {
                var opts: [String: Any] = [:]
                if let sid = msg.senderMessageId { opts["id"] = sid }
                let encrypted = try crypto.encrypt(msg.text, options: opts.isEmpty ? nil : opts)
                let payload: [String: Any] = ["type": "encrypted-message", "data": encrypted]
                if let data = try? JSONSerialization.data(withJSONObject: payload),
                   let jsonStr = String(data: data, encoding: .utf8) {
                    _ = rtc?.send(jsonStr)
                }
                sentMessages[crypto.messageCounter] = (id: msg.id, sentAt: Date())
                do {
                    try messageStore.markSent(msg.id)
                } catch {
                    ghostLog("[ChatViewModel] ERROR: failed to mark pending message as sent: \(error)")
                }

                // Update in-memory list if message is still there
                if let idx = messages.firstIndex(where: { $0.id == msg.id }) {
                    messages[idx].isPending = false
                }
            } catch {
                break // Stop flushing on first error (crypto state compromised)
            }
        }
    }

    /// Delete all message history for a contact
    func deleteHistory(for contactId: String) {
        ghostLog("[ChatViewModel] deleteHistory called, contactId=\(contactId)")
        do {
            try messageStore.deleteForContact(contactId)
        } catch {
            ghostLog("[ChatViewModel] ERROR: failed to delete history for contact \(contactId): \(error)")
        }
    }

    /// Таймер автоудаления — порт startMessageTimerLoop()
    private var lastTTLCleanupAt: Date = .distantPast

    private func startMessageCleanup() {
        ghostLog("[ChatViewModel] startMessageCleanup called")
        messageCleanupTimer?.invalidate()
        messageCleanupTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // M4: All messages (including system) now have TTL
                self.messages.removeAll { $0.isExpired }

                // L2: Clean up sentMessages — remove for expired messages + stale entries (>5 min)
                let validIds = Set(self.messages.map(\.id))
                let cutoff = Date().addingTimeInterval(-300) // 5 minutes
                self.sentMessages = self.sentMessages.filter {
                    validIds.contains($0.value.id) && $0.value.sentAt > cutoff
                }

                // Per-contact TTL cleanup from DB (every 60 seconds)
                if self.saveMessageHistory, Date().timeIntervalSince(self.lastTTLCleanupAt) >= 60 {
                    self.lastTTLCleanupAt = Date()
                    self.cleanupExpiredMessages()
                }
            }
        }
    }

    /// Clean up expired messages from DB based on per-contact TTL
    private func cleanupExpiredMessages() {
        ghostLog("[ChatViewModel] cleanupExpiredMessages called")
        let contactStore = ContactStore()
        guard let allContacts = try? contactStore.fetchAll() else { return }

        for contact in allContacts {
            guard let ttl = contact.messageTTL, ttl > 0 else { continue }
            try? messageStore.deleteExpired(contactId: contact.id.uuidString, ttlSeconds: ttl)
        }

        // Also remove from in-memory messages if current contact has TTL
        if let cId = currentContactId,
           let contact = allContacts.first(where: { $0.id.uuidString == cId }),
           let ttl = contact.messageTTL, ttl > 0 {
            let cutoff = Date().addingTimeInterval(-Double(ttl))
            messages.removeAll { $0.contactId == cId && $0.timestamp < cutoff }
        }
    }

    // MARK: - Room Rotation (Forward Secrecy at signaling level)

    /// Start periodic room rotation (host only). Random 10-25 min interval.
    /// Creates new room, notifies peer, both switch — old room ID becomes useless.
    private func startRoomRotationTimer() {
        ghostLog("[ChatViewModel] startRoomRotationTimer called")
        roomRotationTimer?.invalidate()
        let interval = Double.random(in: 600...1500) // 10-25 minutes
        roomRotationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.rotateRoom()
            }
        }
    }

    /// Perform room rotation: create new room, notify peer, update local state
    private func rotateRoom() async {
        ghostLog("[ChatViewModel] rotateRoom called, isHost=\(isHost), isConnected=\(isConnected)")
        guard isHost, isConnected, callState == .idle else { return }
        guard let signaling else { return }

        isRotatingRoom = true

        // Create new room using EXISTING signaling connection —
        // do NOT call createRoomAndWait() as it replaces signaling/rtc/crypto
        // and destroys the active P2P connection
        let newRoomId = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            self.roomCreatedContinuation = continuation
            signaling.createRoom()

            // Timeout after 10 seconds
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if let pending = self.roomCreatedContinuation {
                    self.roomCreatedContinuation = nil
                    pending.resume(returning: nil)
                }
            }
        }

        guard let newRoomId else {
            isRotatingRoom = false
            return
        }

        // Notify peer via encrypted P2P channel
        await sendEncryptedControl(.roomRotate(roomId: newRoomId))

        // Update local room ID — if WebRTC reconnects, use new room
        roomId = newRoomId
        saveSession()
        isRotatingRoom = false

        // Schedule next rotation
        startRoomRotationTimer()
    }

    /// Peer received room-rotate from host — switch to new room for re-signaling
    private func handleRoomRotate(_ newRoomId: String) {
        ghostLog("[ChatViewModel] handleRoomRotate called, newRoomId=\(newRoomId.prefix(8))")
        guard !newRoomId.isEmpty else { return }

        isRotatingRoom = true
        roomId = newRoomId

        // Rejoin signaling server with new room (for re-signaling if WebRTC drops)
        signaling?.rejoinRoom(newRoomId, role: "guest")

        // Clear flag after short delay (ignore peer-joined from rejoin)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.isRotatingRoom = false
        }
    }

    // MARK: - Connection Timeout

    private func startConnectionTimeout() {
        ghostLog("[ChatViewModel] startConnectionTimeout called")
        connectionTimeout?.invalidate()
        connectionTimeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isConnected else { return }
                // Если мы в чате с контактом — НЕ leave(), просто показать что peer оффлайн
                if self.currentPeerContact != nil || self.screen == .chat {
                    ghostLog("[ChatViewModel] connectionTimeout: peer offline, staying in chat")
                    self.showPeerDisconnectedBanner = true
                    return
                }
                self.addSystemMessage(String(localized: "system.connectionTimeout"))
                self.leave()
            }
        }
    }

    // MARK: - Session Persistence (Keychain — C3 fix)

    private static let sessionKey = "ghost-room"

    private func saveSession() {
        ghostLog("[ChatViewModel] saveSession called")
        guard let roomId else { return }
        var dict: [String: Any] = [
            "roomId": roomId,
            "isHost": isHost,
            "ts": Date().timeIntervalSince1970
        ]
        if let contactId = currentContactId {
            dict["contactId"] = contactId
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        KeychainService.save(data, forKey: Self.sessionKey)
    }

    func restoreSession() async {
        ghostLog("[ChatViewModel] restoreSession called")
        guard let data = KeychainService.load(forKey: Self.sessionKey),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roomId = saved["roomId"] as? String,
              let savedIsHost = saved["isHost"] as? Bool,
              let ts = saved["ts"] as? TimeInterval else { return }

        // Session TTL: 10 minutes
        if Date().timeIntervalSince1970 - ts > 10 * 60 {
            clearSession()
            return
        }

        self.roomId = roomId
        self.isHost = savedIsHost

        // Restore contactId if saved
        if let savedContactId = saved["contactId"] as? String {
            self.currentContactId = savedContactId
            // Restore contact from DB
            let store = ContactStore()
            if let allContacts = try? store.fetchAll(),
               let contact = allContacts.first(where: { $0.id.uuidString == savedContactId }) {
                self.currentPeerContact = contact
                self.expectedPeerIdentityKey = contact.identityKey
            }
        }

        // DON'T pre-create crypto keys here — they will be generated when
        // peer reconnects and onPeerJoined fires (which triggers startWebRTCConnection
        // for host, or handleSignal for guest). Premature key generation during
        // restore is wasteful since a fresh key exchange happens on each reconnect.

        rtc = GhostRTC()
        rtc?.setPrivacyMode(privacyMode)
        setupRTCCallbacks()

        signaling = SignalingClient(serverURL: Self.serverURL)
        turnService = TURNService(baseURL: Self.serverURL)
        rtc?.setTurnService(turnService)
        setupSignalingCallbacks()

        signaling?.connect()
        signaling?.rejoinRoom(roomId, role: isHost ? "host" : "guest")

        screen = isHost ? .waiting : .connecting
    }

    private func clearSession() {
        ghostLog("[ChatViewModel] clearSession called")
        KeychainService.delete(forKey: Self.sessionKey)
    }

    // MARK: - Invite Link

    func getInviteLink() -> String? {
        ghostLog("[ChatViewModel] getInviteLink called")
        guard let roomId else { return nil }
        return "\(Self.serverURL.absoluteString)/?room=\(roomId)"
    }

    // MARK: - Leave & Cleanup

    func leave() {
        let caller = Thread.callStackSymbols.prefix(5).joined(separator: "\n")
        ghostLog("[ChatViewModel] leave called from:\n\(caller)")
        if isSavedMessagesMode {
            leaveSavedMessages()
            return
        }
        guard !isLeaving else {
            ghostLog("[ChatViewModel] leave: already leaving, skipping")
            return
        }
        isLeaving = true
        // Если новый native peer (не web, не из контактов) — спросить имя перед выходом
        if currentPeerContact == nil && keyExchangeCompleted && peerIdentityKeyData != nil && peerIsNativeApp {
            showSaveContactPrompt = true
            pendingLeave = true
            isLeaving = false  // Reset — actual leave happens in performLeave after save prompt
            return
        }
        performLeave()
    }

    /// Hard reset — удаляет всё и возвращает на Welcome как в первый раз
    func performHardReset() {
        ghostLog("[ChatViewModel] performHardReset called")
        clearSession()
        destroy()
        currentContactId = nil
        currentPeerContact = nil
        updateActiveChat(contactId: nil)
        screen = .welcome
        messages.removeAll()

        // Full DB reset: close → delete file → recreate fresh
        DatabaseService.shared.close()
        DatabaseService.destroy()
        do {
            try DatabaseService.shared.setup()
            ghostLog("[ChatViewModel] Hard reset: DB recreated OK")
        } catch {
            ghostLog("[ChatViewModel] Hard reset: DB recreate FAILED: \(error)")
        }
    }

    /// Выполняет фактический выход из чата
    private func performLeave() {
        ghostLog("[ChatViewModel] performLeave called")
        pendingCallAfterConnect = false
        isAutoConnecting = false
        pendingRoomPollTimer?.invalidate()
        pendingRoomPollTimer = nil
        peerStatus = .offline
        peerLastSeenDate = nil
        peerStatusTransitionTimer?.invalidate()
        peerStatusTransitionTimer = nil
        clearSession()
        destroy()
        currentContactId = nil
        isCreatingRoom = false
        isLeaving = false
        updateActiveChat(contactId: nil)
        screen = .welcome
        messages.removeAll()
    }

    private func destroy() {
        ghostLog("[ChatViewModel] destroy called")
        // Persist DR state for known contacts before cleanup
        persistRatchetStateIfNeeded()

        // Invalidate ALL timers in one place
        invalidateAllTimers()

        voice?.destroy()
        voice = nil
        callState = .idle

        signaling?.leaveRoom()
        signaling?.disconnect()
        signaling = nil

        rtc?.destroy()
        rtc = nil

        crypto?.destroy()
        crypto = nil

        securityMonitor.destroy()

        if let observer = screenshotObserver {
            NotificationCenter.default.removeObserver(observer)
            screenshotObserver = nil
        }

        if activeCallUUID != nil {
            endSystemCall()
        }

        // Cancel pending room creation continuation
        if let continuation = roomCreatedContinuation {
            roomCreatedContinuation = nil
            continuation.resume(returning: nil)
        }

        isHost = false
        isConnected = false
        isMuted = false
        isSpeakerOn = false
        isFromPush = false
        peerIsTyping = false
        pendingIceCandidates.removeAll()
        pendingSignals.removeAll()
        pendingRenegotiationOffer = nil
        pendingIceRestartOffer = nil
        sentMessages.removeAll()
        keyExchangeCompleted = false
        isRotatingRoom = false
        pendingPQDerivation = false
        roomId = nil
        fingerprint = ""
        currentPeerContact = nil
        peerIdentityKeyData = nil
        expectedPeerIdentityKey = nil
        peerPushToken = nil
        peerNotifyToken = nil
        peerIsNativeApp = false
        tokensSentToPeerThisSession = false
        peerSupportsFiles = false
        fileTransfer.cancelAll()
        showSaveContactPrompt = false
        pendingContactName = ""
        lastTypingSentAt = nil
    }

    // MARK: - DR State Persistence

    private func persistRatchetStateIfNeeded() {
        guard let contact = currentPeerContact,
              let crypto = crypto,
              let state = crypto.exportRatchetState() else { return }

        let store = ContactStore()
        do {
            let stateData = try JSONEncoder().encode(state)
            try store.updateRatchetState(contactId: contact.id, ratchetState: stateData)
            let skippedKeys = crypto.exportSkippedKeys()
            try store.saveSkippedKeys(contactId: contact.id, keys: skippedKeys)
        } catch {
            #if DEBUG
            print("[ChatViewModel] Failed to persist DR state: \(error)")
            #endif
        }
    }

    // MARK: - Settings Persistence (Keychain)

    private static func saveSetting(_ value: Bool, forKey key: String) {
        let str = value ? "1" : "0"
        if let data = str.data(using: .utf8) {
            KeychainService.save(data, forKey: key)
        }
    }

    private static func saveSetting(_ value: Int, forKey key: String) {
        if let data = String(value).data(using: .utf8) {
            KeychainService.save(data, forKey: key)
        }
    }

    private static func loadBoolSetting(forKey key: String, default defaultValue: Bool) -> Bool {
        guard let data = KeychainService.load(forKey: key),
              let str = String(data: data, encoding: .utf8) else { return defaultValue }
        return str == "1"
    }

    private static func loadIntSetting(forKey key: String, default defaultValue: Int) -> Int {
        guard let data = KeychainService.load(forKey: key),
              let str = String(data: data, encoding: .utf8),
              let value = Int(str) else { return defaultValue }
        return value
    }

    private static func saveStringSetting(_ value: String, forKey key: String) {
        if let data = value.data(using: .utf8) {
            KeychainService.save(data, forKey: key)
        }
    }

    private static func loadStringSetting(forKey key: String, default defaultValue: String) -> String {
        guard let data = KeychainService.load(forKey: key),
              let str = String(data: data, encoding: .utf8), !str.isEmpty else { return defaultValue }
        return str
    }
}
