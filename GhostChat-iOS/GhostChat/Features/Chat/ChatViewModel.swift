import Foundation
import Combine
import WebRTC
import AudioToolbox
import UIKit

/// Главный orchestrator — порт app.js (GhostChat class)
/// Связывает SignalingClient + GhostRTC + GhostCrypto + GhostVoice
@MainActor
final class ChatViewModel: ObservableObject {

    // MARK: - Configuration

    static let serverURL = URL(string: "https://gbskgs.xyz")!

    /// Auto-delete time derived from user setting
    private var messageAutoDeleteTime: TimeInterval {
        TimeInterval(autoDeleteMinutes) * 60
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

    // Call state
    @Published var callState: CallUIState = .idle
    @Published var callTimer: String = "00:00"
    @Published var isMuted = false
    @Published var isSpeakerOn = false

    // Security alerts
    @Published var securityAlert: SecurityMonitor.SecurityAlert?

    // H3: Deep link confirmation
    @Published var pendingDeepLinkRoom: String?

    // Contacts
    @Published var currentPeerContact: Contact?
    @Published var showSaveContactPrompt = false
    @Published var pendingContactName: String = ""

    enum Screen {
        case welcome, waiting, connecting, chat
    }

    enum CallUIState {
        case idle, calling, ringing, active
    }

    // MARK: - Private Properties

    private var signaling: SignalingClient?
    private var rtc: GhostRTC?
    private var crypto: GhostCrypto?
    private var voice: GhostVoice?
    private var securityMonitor = SecurityMonitor()
    private var turnService: TURNService?

    private var isHost = false
    private var pendingIceCandidates: [RTCIceCandidate] = []
    private var pendingRenegotiationOffer: RTCSessionDescription?
    private var sentMessages: [Int: UUID] = [:] // counter → message ID
    private var keyExchangeCompleted = false    // C2: prevent re-exchange
    private var pendingPQDerivation = false     // C1: host waits for PQ exchange
    private var messageCleanupTimer: Timer?
    private var connectionTimeout: Timer?
    private var vibrationTimer: Timer?
    private var peerIdentityKeyData: Data?
    private var expectedPeerIdentityKey: Data?
    private var screenshotObserver: NSObjectProtocol?
    private var activeCallUUID: UUID?

    // MARK: - Lifecycle

    init() {
        // Load persisted settings from Keychain
        self.privacyMode = Self.loadBoolSetting(forKey: "settings_privacy_mode", default: false)
        self.autoDeleteMinutes = Self.loadIntSetting(forKey: "settings_auto_delete", default: 5)
        self.screenshotNotifications = Self.loadBoolSetting(forKey: "settings_screenshot_notify", default: true)
        self.messageSoundEnabled = Self.loadBoolSetting(forKey: "settings_sound", default: true)
        self.vibrationEnabled = Self.loadBoolSetting(forKey: "settings_vibration", default: true)
        self.ringtoneId = Self.loadStringSetting(forKey: "settings_ringtone", default: SoundLibrary.defaultRingtoneId)
        self.messageSoundId = Self.loadStringSetting(forKey: "settings_msg_sound", default: SoundLibrary.defaultMessageSoundId)

        startMessageCleanup()
    }

    deinit {
        messageCleanupTimer?.invalidate()
        connectionTimeout?.invalidate()
    }

    // MARK: - Create Room

    func createRoom() async {
        isHost = true
        crypto = GhostCrypto()
        crypto?.generateKeyPair()

        rtc = GhostRTC()
        rtc?.setPrivacyMode(privacyMode)

        signaling = SignalingClient(serverURL: Self.serverURL)
        turnService = TURNService(baseURL: Self.serverURL)

        setupSignalingCallbacks()
        setupRTCCallbacks()

        signaling?.connect()
        signaling?.createRoom()
    }

    // MARK: - Join Room

    func joinRoom(_ inputRoomId: String) async {
        let trimmed = inputRoomId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // M3: Validate room ID format (base64url, 64 chars)
        let roomIdPattern = "^[A-Za-z0-9_-]{64}$"
        guard trimmed.range(of: roomIdPattern, options: .regularExpression) != nil else { return }

        isHost = false
        crypto = GhostCrypto()
        crypto?.generateKeyPair()

        rtc = GhostRTC()
        rtc?.setPrivacyMode(privacyMode)

        signaling = SignalingClient(serverURL: Self.serverURL)
        turnService = TURNService(baseURL: Self.serverURL)

        setupSignalingCallbacks()
        setupRTCCallbacks()

        signaling?.connect()
        signaling?.joinRoom(trimmed)
    }

    // MARK: - Signaling Callbacks

    private func setupSignalingCallbacks() {
        signaling?.onRoomCreated = { [weak self] roomId in
            guard let self else { return }
            self.roomId = roomId
            self.saveSession()
            self.screen = .waiting
        }

        signaling?.onRoomJoined = { [weak self] roomId in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.roomId = roomId
                self.saveSession()
                self.screen = .connecting
                await self.initAsGuest()
            }
        }

        signaling?.onRejoinOk = { [weak self] in
            // Reconnected to room
            _ = self
        }

        signaling?.onPeerJoined = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isConnected = false
                self.screen = .connecting
                self.startConnectionTimeout()

                if self.isHost {
                    await self.startWebRTCConnection()
                }
            }
        }

        signaling?.onPeerLeft = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.addSystemMessage(String(localized: "system.peerDisconnected"))
                self.leave()
            }
        }

        signaling?.onSignal = { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.handleSignal(data)
            }
        }

        signaling?.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self else { return }
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
        rtc?.onIceCandidate = { [weak self] candidate in
            self?.signaling?.sendSignal([
                "type": "ice-candidate",
                "candidate": GhostRTC.candidateToDict(candidate)
            ])
        }

        rtc?.onConnected = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }

                self.connectionTimeout?.invalidate()
                self.connectionTimeout = nil

                let wasConnected = self.isConnected
                self.isConnected = true

                if !wasConnected {
                    // First connection — exchange keys (v3 Double Ratchet + Identity Key)
                    guard let pubKey = self.crypto?.exportPublicKey() else { return }
                    var msg: [String: Any] = [
                        "type": "key-exchange",
                        "publicKey": pubKey,
                        "identityKey": IdentityKeyService.shared.exportPublicKey(),
                        "v": GhostCrypto.protocolVersion
                    ]

                    // Guest: include PQ capability so host knows whether to wait
                    if !self.isHost {
                        msg["pqSupported"] = GhostCrypto.isPQAvailable
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
                } else {
                    self.addSystemMessage(String(localized: "system.connectionRestored"))
                }
            }
        }

        rtc?.onDisconnected = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.addSystemMessage(String(localized: "system.connectionLost"))
                self.isConnected = false

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
            // Handle remote audio stream
            if let audioTrack = stream.audioTracks.first {
                self?.voice?.onRemoteAudioTrack?(audioTrack)
            }
        }

        rtc?.onRenegotiationNeeded = { [weak self] offer in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.sendRenegotiationOffer(offer)
            }
        }
    }

    // MARK: - WebRTC Connection

    private func startWebRTCConnection() async {
        var turnCreds: TURNCredentials?
        do {
            turnCreds = try await turnService?.fetchCredentials()
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
        var turnCreds: TURNCredentials?
        do {
            turnCreds = try await turnService?.fetchCredentials()
        } catch {
            #if DEBUG
            print("[ChatViewModel] TURN fetch failed: \(error)")
            #endif
        }

        rtc?.initAsGuest(turnCredentials: turnCreds)
    }

    // MARK: - Signal Handling

    private func handleSignal(_ signal: [String: Any]) async {
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
        // C2: reject re-exchange after initial key exchange
        guard !keyExchangeCompleted else { return }

        guard let peerPublicKey = json["publicKey"] as? String else { return }

        // Accept v2+ (backward compatible with v2 web client)
        let peerVersion = json["v"] as? Int ?? 1
        guard peerVersion >= 2 else {
            addSystemMessage(String(localized: "system.incompatibleVersion"))
            return
        }

        // v3: Extract and lookup identity key
        if let idKeyBase64 = json["identityKey"] as? String,
           let idKeyData = Data(base64Encoded: idKeyBase64) {
            self.peerIdentityKeyData = idKeyData

            let store = ContactStore()
            if let knownContact = try? store.fetchByIdentityKey(idKeyData) {
                self.currentPeerContact = knownContact
                addSystemMessage(String(format: String(localized: "system.knownPeer"), knownContact.label))
            }

            // Verify expected peer if starting chat with specific contact
            if let expected = expectedPeerIdentityKey, expected != idKeyData {
                addSystemMessage(String(localized: "system.unexpectedPeer"))
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
        keyExchangeCompleted = true
        fingerprint = (try? crypto?.generateFingerprint()) ?? ""
        screen = .chat
        isConnected = true

        let pqStatus = (crypto?.isPQEnabled == true) ? " (PQ)" : ""
        addSystemMessage(String(localized: "system.secureConnection") + pqStatus)
        addSystemMessage(String(localized: "system.tapShield"))

        startSecurityMonitoring()
        handleContactAutoSave()

        // Host sends bootstrap message to initialize guest's send chain
        // (guest's Double Ratchet needs to receive at least one message
        // to trigger DH ratchet and initialize the send chain)
        if isHost {
            Task { await sendEncryptedControl(.ready) }
        }
    }

    /// Auto-save or update contact after successful key exchange
    private func handleContactAutoSave() {
        guard peerIdentityKeyData != nil else { return } // v2 peer — no identity key

        if let existingContact = currentPeerContact {
            // Known contact — increment session count
            let store = ContactStore()
            try? store.incrementSessionCount(contactId: existingContact.id)
        } else {
            // New peer — show save prompt
            showSaveContactPrompt = true
        }
    }

    /// Save new contact from the save prompt
    func saveNewContact(name: String) {
        guard let peerIdKey = peerIdentityKeyData, !name.isEmpty else { return }
        let contact = Contact(
            label: name,
            publicKey: peerIdKey,
            identityKey: peerIdKey,
            sessionCount: 1,
            lastSessionAt: Date()
        )
        let store = ContactStore()
        try? store.save(contact)
        currentPeerContact = contact
        showSaveContactPrompt = false
        pendingContactName = ""
    }

    func skipSaveContact() {
        showSaveContactPrompt = false
        pendingContactName = ""
    }

    /// Start a room expecting a specific contact to join
    func startChatWithContact(_ contact: Contact) async {
        expectedPeerIdentityKey = contact.identityKey
        currentPeerContact = contact
        screen = .waiting
        await createRoom()
    }

    private func startSecurityMonitoring() {
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
        do {
            let plaintext = try crypto?.decrypt(encryptedData) ?? ""

            // Пробуем как управляющее сообщение
            if let data = plaintext.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let controlMsg = ControlMessage.from(json) {
                await handleControlMessage(controlMsg)
                return
            }

            // Обычное текстовое сообщение
            addMessage(plaintext, type: .received)

            // Звук и вибрация при получении
            if messageSoundEnabled {
                let sound = SoundLibrary.messageSound(forId: messageSoundId)
                SoundLibrary.playMessageSound(sound, withVibration: vibrationEnabled)
            } else if vibrationEnabled {
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }

            // Подтверждение доставки
            if let counter = crypto?.messageCounter {
                let ack = ControlMessage.messageAck(counter: counter)
                await sendEncryptedControl(ack)
            }
        } catch {
            addSystemMessage(String(localized: "system.decryptionError"))
        }
    }

    // MARK: - Control Messages

    private func handleControlMessage(_ msg: ControlMessage) async {
        switch msg {
        case .renegotiate(let sdp):
            await handleRenegotiation(sdp)

        case .callRequest:
            handleIncomingCall()

        case .callResponse(let accepted):
            handleCallResponse(accepted)

        case .callEnd:
            handleCallEnded()

        case .callSecurityAlert(let alert):
            if let message = alert["message"] as? String {
                addSystemMessage(String(format: String(localized: "system.securityWarning"), message))
            }

        case .securityAlert(let alert):
            handleSecurityAlert(alert)

        case .messageAck(let counter):
            handleMessageAck(counter)

        case .ready:
            // Bootstrap from host — decryption already triggered DH ratchet
            break
        }
    }

    // MARK: - Send Messages

    func sendMessage(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isConnected, let crypto else { return }

        do {
            let encrypted = try crypto.encrypt(trimmed)
            let msg: [String: Any] = ["type": "encrypted-message", "data": encrypted]

            if let data = try? JSONSerialization.data(withJSONObject: msg),
               let jsonStr = String(data: data, encoding: .utf8) {
                _ = rtc?.send(jsonStr)
            }

            let chatMsg = addMessage(trimmed, type: .sent)
            sentMessages[crypto.messageCounter] = chatMsg.id
        } catch {
            addSystemMessage(String(localized: "system.sendError"))
        }
    }

    func sendEncryptedControl(_ message: ControlMessage) async {
        guard let crypto, crypto.isReady, rtc?.isConnected == true else { return }

        do {
            let json = message.toJSON()
            let jsonData = try JSONSerialization.data(withJSONObject: json)
            guard let jsonStr = String(data: jsonData, encoding: .utf8) else { return }

            let encrypted = try crypto.encrypt(jsonStr)
            let msg: [String: Any] = ["type": "encrypted-message", "data": encrypted]

            if let data = try? JSONSerialization.data(withJSONObject: msg),
               let text = String(data: data, encoding: .utf8) {
                _ = rtc?.send(text)
            }
        } catch {
            #if DEBUG
            print("[ChatViewModel] Failed to send encrypted control: \(error)")
            #endif
        }
    }

    // MARK: - Renegotiation

    private func sendRenegotiationOffer(_ offer: RTCSessionDescription) async {
        let sdpDict = GhostRTC.sdpToDict(offer)
        await sendEncryptedControl(.renegotiate(sdp: sdpDict))
    }

    private func handleRenegotiation(_ sdp: [String: Any]) async {
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
        }
    }

    private func processRenegotiationOffer(_ sdp: [String: Any]) async {
        guard let rtcSdp = GhostRTC.dictToSdp(sdp) else { return }

        guard let answer = await rtc?.handleOffer(rtcSdp) else { return }

        let answerDict = GhostRTC.sdpToDict(answer)
        await sendEncryptedControl(.renegotiate(sdp: answerDict))
    }

    // MARK: - Voice Calls

    func startCall() async {
        guard isConnected, callState == .idle, let rtc, let pc = rtc.peerConnection else { return }

        if voice == nil {
            voice = GhostVoice(peerConnection: pc, factory: createRTCFactory())
            setupVoiceCallbacks()
        }

        do {
            try voice?.startCall()
            callState = .calling
            await sendEncryptedControl(.callRequest)
            addSystemMessage(String(localized: "system.calling"))
        } catch {
            addSystemMessage(String(format: String(localized: "system.callError"), error.localizedDescription))
            callState = .idle
        }
    }

    private func handleIncomingCall() {
        guard callState == .idle else {
            Task {
                await sendEncryptedControl(.callResponse(accepted: false))
            }
            return
        }

        callState = .ringing
        addSystemMessage(String(localized: "system.incomingCall"))

        // Вибрация при входящем звонке (повторяется каждые 2 сек)
        startIncomingCallVibration()

        // CallKit — системный UI входящего звонка
        reportIncomingCallToSystem()
    }

    private var ringtoneTimer: Timer?

    private func startIncomingCallVibration() {
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
        vibrationTimer?.invalidate()
        vibrationTimer = nil
        ringtoneTimer?.invalidate()
        ringtoneTimer = nil
    }

    private func reportIncomingCallToSystem() {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        let uuid = UUID()
        activeCallUUID = uuid

        appDelegate.reportIncomingCall(uuid: uuid, handle: "Ghost Chat") { [weak self] error in
            if let error {
                #if DEBUG
                print("[CallKit] Failed to report call: \(error)")
                #endif
                self?.activeCallUUID = nil
            }
        }

        // Сохраняем ссылку на viewModel в AppDelegate для callback
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
    }

    func acceptCall() async {
        guard callState == .ringing, let rtc, let pc = rtc.peerConnection else { return }
        stopIncomingCallVibration()

        if voice == nil {
            voice = GhostVoice(peerConnection: pc, factory: createRTCFactory())
            setupVoiceCallbacks()
        }

        do {
            try voice?.acceptCall()

            // Process pending renegotiation offer
            if let pendingOffer = pendingRenegotiationOffer {
                let sdpDict = GhostRTC.sdpToDict(pendingOffer)
                await processRenegotiationOffer(sdpDict)
                pendingRenegotiationOffer = nil
            }

            await sendEncryptedControl(.callResponse(accepted: true))

            callState = .active
            addSystemMessage(String(localized: "system.callConnected"))
        } catch {
            addSystemMessage(String(format: String(localized: "system.error"), error.localizedDescription))
            await sendEncryptedControl(.callResponse(accepted: false))
            callState = .idle
        }
    }

    func declineCall() async {
        guard callState == .ringing else { return }
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
        guard callState == .calling else { return }

        if accepted {
            voice?.callAccepted()
            callState = .active
            addSystemMessage(String(localized: "system.callStarted"))
        } else {
            voice?.endCall()
            voice?.destroy()
            voice = nil
            callState = .idle
            addSystemMessage(String(localized: "system.callDeclined"))
        }
    }

    func endCall() async {
        guard callState != .idle else { return }
        stopIncomingCallVibration()
        endSystemCall()

        voice?.endCall()
        voice?.destroy()
        voice = nil

        await sendEncryptedControl(.callEnd)

        callState = .idle
        isMuted = false
        isSpeakerOn = false
        pendingRenegotiationOffer = nil
        addSystemMessage(String(localized: "system.callEnded"))
    }

    private func handleCallEnded() {
        stopIncomingCallVibration()
        endSystemCall()

        voice?.endCall()
        voice?.destroy()
        voice = nil

        callState = .idle
        isMuted = false
        isSpeakerOn = false
        pendingRenegotiationOffer = nil
        addSystemMessage(String(localized: "system.peerEndedCall"))
    }

    private func endSystemCall() {
        guard let uuid = activeCallUUID,
              let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        appDelegate.endSystemCall(uuid: uuid)
        activeCallUUID = nil
    }

    func toggleMute() {
        guard let voice else { return }
        isMuted = voice.toggleMute()
    }

    func toggleSpeaker() {
        guard let voice else { return }
        isSpeakerOn = voice.toggleSpeaker()
    }

    private func setupVoiceCallbacks() {
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
    }

    private func createRTCFactory() -> RTCPeerConnectionFactory {
        RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }

    // MARK: - Security

    private func handleSecurityAlert(_ alert: String) {
        if alert == "screenshot-attempt" {
            addSystemMessage(String(localized: "system.peerScreenshot"))
        }
    }

    private func handleMessageAck(_ counter: Int) {
        if let msgId = sentMessages[counter],
           let index = messages.firstIndex(where: { $0.id == msgId }) {
            messages[index].isDelivered = true
            sentMessages.removeValue(forKey: counter)
        }
    }

    // MARK: - Verification

    func markAsVerified(_ verified: Bool) {
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
    func addMessage(_ text: String, type: ChatMessage.MessageType) -> ChatMessage {
        let msg = ChatMessage(text: text, type: type, autoDeleteInterval: messageAutoDeleteTime)
        messages.append(msg)
        return msg
    }

    func addSystemMessage(_ text: String) {
        // M4: System messages get 10 min TTL (not indefinite)
        messages.append(ChatMessage(text: text, type: .system, autoDeleteInterval: 10 * 60))
    }

    /// Таймер автоудаления — порт startMessageTimerLoop()
    private func startMessageCleanup() {
        messageCleanupTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // M4: All messages (including system) now have TTL
                self.messages.removeAll { $0.isExpired }

                // L2: Clean up unacknowledged sentMessages for expired messages
                let validIds = Set(self.messages.map(\.id))
                self.sentMessages = self.sentMessages.filter { validIds.contains($0.value) }
            }
        }
    }

    // MARK: - Connection Timeout

    private func startConnectionTimeout() {
        connectionTimeout?.invalidate()
        connectionTimeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isConnected else { return }
                self.addSystemMessage(String(localized: "system.connectionTimeout"))
                self.leave()
            }
        }
    }

    // MARK: - Session Persistence (Keychain — C3 fix)

    private static let sessionKey = "ghost-room"

    private func saveSession() {
        guard let roomId else { return }
        let dict: [String: Any] = [
            "roomId": roomId,
            "isHost": isHost,
            "ts": Date().timeIntervalSince1970
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        KeychainService.save(data, forKey: Self.sessionKey)
    }

    func restoreSession() async {
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

        crypto = GhostCrypto()
        crypto?.generateKeyPair()

        rtc = GhostRTC()
        rtc?.setPrivacyMode(privacyMode)
        setupRTCCallbacks()

        signaling = SignalingClient(serverURL: Self.serverURL)
        turnService = TURNService(baseURL: Self.serverURL)
        setupSignalingCallbacks()

        signaling?.connect()
        signaling?.rejoinRoom(roomId, role: isHost ? "host" : "guest")

        screen = isHost ? .waiting : .connecting
    }

    private func clearSession() {
        KeychainService.delete(forKey: Self.sessionKey)
    }

    // MARK: - Invite Link

    func getInviteLink() -> String? {
        guard let roomId else { return nil }
        return "\(Self.serverURL.absoluteString)/?room=\(roomId)"
    }

    // MARK: - Leave & Cleanup

    func leave() {
        clearSession()
        destroy()
        screen = .welcome
        messages.removeAll()
    }

    private func destroy() {
        // Persist DR state for known contacts before cleanup
        persistRatchetStateIfNeeded()

        connectionTimeout?.invalidate()
        connectionTimeout = nil

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
        stopIncomingCallVibration()

        if let observer = screenshotObserver {
            NotificationCenter.default.removeObserver(observer)
            screenshotObserver = nil
        }

        if activeCallUUID != nil {
            endSystemCall()
        }

        isHost = false
        isConnected = false
        isMuted = false
        isSpeakerOn = false
        pendingIceCandidates.removeAll()
        pendingRenegotiationOffer = nil
        sentMessages.removeAll()
        keyExchangeCompleted = false
        pendingPQDerivation = false
        roomId = nil
        fingerprint = ""
        currentPeerContact = nil
        peerIdentityKeyData = nil
        expectedPeerIdentityKey = nil
        showSaveContactPrompt = false
        pendingContactName = ""
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
