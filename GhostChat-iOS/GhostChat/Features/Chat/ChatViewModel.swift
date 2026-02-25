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
    private let messageAutoDeleteTime: TimeInterval = 5 * 60 // 5 минут

    // MARK: - Published State

    @Published var screen: Screen = .welcome
    @Published var messages: [ChatMessage] = []
    @Published var roomId: String?
    @Published var fingerprint: String = ""
    @Published var isConnected = false
    @Published var isVerified = false
    @Published var privacyMode = false

    // Call state
    @Published var callState: CallUIState = .idle
    @Published var callTimer: String = "00:00"
    @Published var isMuted = false
    @Published var isSpeakerOn = false

    // Security alerts
    @Published var securityAlert: SecurityMonitor.SecurityAlert?

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
    private var messageCleanupTimer: Timer?
    private var connectionTimeout: Timer?
    private var vibrationTimer: Timer?
    private var screenshotObserver: NSObjectProtocol?
    private var activeCallUUID: UUID?

    // MARK: - Lifecycle

    init() {
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
                self.addSystemMessage("Собеседник отключился")
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
                    // First connection — exchange keys
                    guard let pubKey = self.crypto?.exportPublicKey() else { return }
                    let msg: [String: Any] = ["type": "key-exchange", "publicKey": pubKey]
                    if let data = try? JSONSerialization.data(withJSONObject: msg),
                       let text = String(data: data, encoding: .utf8) {
                        _ = self.rtc?.send(text)
                    }
                } else {
                    self.addSystemMessage("Соединение восстановлено")
                }
            }
        }

        rtc?.onDisconnected = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.addSystemMessage("Соединение потеряно")
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
            print("[ChatViewModel] TURN fetch failed: \(error)")
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
            print("[ChatViewModel] TURN fetch failed: \(error)")
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
            if let publicKey = json["publicKey"] as? String {
                await handleKeyExchange(publicKey)
            }

        case "encrypted-message":
            if let encryptedData = json["data"] as? String {
                await handleEncryptedMessage(encryptedData)
            }

        default:
            break
        }
    }

    private func handleKeyExchange(_ peerPublicKey: String) async {
        do {
            try crypto?.importPeerPublicKey(peerPublicKey)
            try crypto?.deriveSharedKey()

            fingerprint = (try? crypto?.generateFingerprint()) ?? ""

            screen = .chat
            isConnected = true
            addSystemMessage("Защищённое соединение установлено")
            addSystemMessage("Нажмите на щит для сверки кодов безопасности")

            // Запускаем мониторинг безопасности
            startSecurityMonitoring()
        } catch {
            addSystemMessage("Ошибка обмена ключами")
        }
    }

    private func startSecurityMonitoring() {
        // SecurityMonitor — запись экрана, bluetooth устройства
        securityMonitor.onAlert = { [weak self] alert in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.addSystemMessage("⚠️ \(alert.message)")
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
                self.addSystemMessage("⚠️ Вы сделали скриншот")
                // Уведомляем собеседника
                await self.sendEncryptedControl(.securityAlert(alert: "screenshot-attempt"))
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

            // Подтверждение доставки
            if let counter = crypto?.messageCounter {
                let ack = ControlMessage.messageAck(counter: counter)
                await sendEncryptedControl(ack)
            }
        } catch {
            addSystemMessage("Ошибка расшифровки")
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
                addSystemMessage("⚠️ \(message)")
            }

        case .securityAlert(let alert):
            handleSecurityAlert(alert)

        case .messageAck(let counter):
            handleMessageAck(counter)
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
            addSystemMessage("Ошибка отправки")
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
            print("[ChatViewModel] Failed to send encrypted control: \(error)")
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
        guard isConnected, callState == .idle, let rtc else { return }

        if voice == nil {
            voice = GhostVoice(peerConnection: rtc.peerConnection!, factory: createRTCFactory())
            setupVoiceCallbacks()
        }

        do {
            try voice?.startCall()
            callState = .calling
            await sendEncryptedControl(.callRequest)
            addSystemMessage("Звоним...")
        } catch {
            addSystemMessage("Ошибка звонка: \(error.localizedDescription)")
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
        addSystemMessage("Входящий звонок...")

        // Вибрация при входящем звонке (повторяется каждые 2 сек)
        startIncomingCallVibration()

        // CallKit — системный UI входящего звонка
        reportIncomingCallToSystem()
    }

    private var ringtonePlayer: AVAudioPlayer?

    private func startIncomingCallVibration() {
        // Вибрация каждые 2 секунды
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        vibrationTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }

        // Рингтон — системный звук или кастомный
        playRingtone()
    }

    private func stopIncomingCallVibration() {
        vibrationTimer?.invalidate()
        vibrationTimer = nil
        ringtonePlayer?.stop()
        ringtonePlayer = nil
    }

    private func playRingtone() {
        // Пробуем кастомный звук из бандла
        if let url = Bundle.main.url(forResource: "ringtone", withExtension: "caf") ??
                     Bundle.main.url(forResource: "ringtone", withExtension: "mp3") {
            do {
                // Настраиваем аудио сессию для громкого звонка
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
                try AVAudioSession.sharedInstance().setActive(true)

                ringtonePlayer = try AVAudioPlayer(contentsOf: url)
                ringtonePlayer?.numberOfLoops = -1 // бесконечный повтор
                ringtonePlayer?.volume = 1.0
                ringtonePlayer?.play()
            } catch {
                print("[Ringtone] Custom sound failed: \(error)")
                fallbackSystemRingtone()
            }
        } else {
            fallbackSystemRingtone()
        }
    }

    private func fallbackSystemRingtone() {
        // Системный звук звонка (1007 = Tock, 1005 = alarm)
        // Используем триллинг как рингтон
        AudioServicesPlaySystemSound(1007)
        // Повторяем каждые 3 секунды через тот же vibrationTimer
    }

    private func reportIncomingCallToSystem() {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        let uuid = UUID()
        activeCallUUID = uuid

        appDelegate.reportIncomingCall(uuid: uuid, handle: "Ghost Chat") { [weak self] error in
            if let error {
                print("[CallKit] Failed to report call: \(error)")
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
        guard callState == .ringing, let rtc else { return }
        stopIncomingCallVibration()

        if voice == nil {
            voice = GhostVoice(peerConnection: rtc.peerConnection!, factory: createRTCFactory())
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
            addSystemMessage("Звонок подключён")
        } catch {
            addSystemMessage("Ошибка: \(error.localizedDescription)")
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
        addSystemMessage("Звонок отклонён")
    }

    private func handleCallResponse(_ accepted: Bool) {
        guard callState == .calling else { return }

        if accepted {
            voice?.callAccepted()
            callState = .active
            addSystemMessage("Звонок начат")
        } else {
            voice?.endCall()
            voice?.destroy()
            voice = nil
            callState = .idle
            addSystemMessage("Звонок отклонён")
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
        addSystemMessage("Звонок завершён")
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
        addSystemMessage("Собеседник завершил звонок")
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
            addSystemMessage("Собеседник сделал скриншот")
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
            addSystemMessage("Подтверждено! Соединение безопасно.")
        } else {
            addSystemMessage("ВНИМАНИЕ: Коды НЕ совпадают! Возможна атака!")
            addSystemMessage("Немедленно завершите сессию.")
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
        messages.append(ChatMessage(text: text, type: .system))
    }

    /// Таймер автоудаления — порт startMessageTimerLoop()
    private func startMessageCleanup() {
        messageCleanupTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.messages.removeAll { $0.isExpired && $0.type != .system }
            }
        }
    }

    // MARK: - Connection Timeout

    private func startConnectionTimeout() {
        connectionTimeout?.invalidate()
        connectionTimeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isConnected else { return }
                self.addSystemMessage("Не удалось подключиться (таймаут)")
                self.leave()
            }
        }
    }

    // MARK: - Session Persistence

    private func saveSession() {
        guard let roomId else { return }
        let data: [String: Any] = [
            "roomId": roomId,
            "isHost": isHost,
            "ts": Date().timeIntervalSince1970
        ]
        UserDefaults.standard.set(data, forKey: "ghost-room")
    }

    func restoreSession() async {
        guard let saved = UserDefaults.standard.dictionary(forKey: "ghost-room"),
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
        UserDefaults.standard.removeObject(forKey: "ghost-room")
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

        if let uuid = activeCallUUID {
            endSystemCall()
        }

        isHost = false
        isConnected = false
        isMuted = false
        isSpeakerOn = false
        pendingIceCandidates.removeAll()
        pendingRenegotiationOffer = nil
        sentMessages.removeAll()
        roomId = nil
        fingerprint = ""
    }
}
