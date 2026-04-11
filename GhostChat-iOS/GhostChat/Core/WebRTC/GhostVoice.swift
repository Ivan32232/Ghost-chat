import Foundation
import AVFoundation
import UIKit
import WebRTC

/// Голосовые звонки — порт voice.js
/// AVAudioSession для earpiece/speaker routing (главная причина нативного приложения)
final class GhostVoice {

    // MARK: - Properties

    private weak var peerConnection: RTCPeerConnection?
    private var audioTrack: RTCAudioTrack?
    private var audioSender: RTCRtpSender?
    private var factory: RTCPeerConnectionFactory

    private(set) var isMuted = false
    private(set) var isInCall = false
    private(set) var isSpeakerOn = false
    private var callStartTime: Date?
    private var callTimer: Timer?

    /// Observers для AVAudioSession notifications
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var mediaResetObserver: NSObjectProtocol?

    // MARK: - Callbacks

    var onCallStateChange: ((CallState) -> Void)?
    var onCallTimer: ((String) -> Void)?
    var onRemoteAudioTrack: ((RTCAudioTrack) -> Void)?

    enum CallState {
        case calling, active, ended
    }

    // MARK: - Init

    init(peerConnection: RTCPeerConnection, factory: RTCPeerConnectionFactory) {
        self.peerConnection = peerConnection
        self.factory = factory
    }

    // MARK: - Audio Session

    /// Настройка AVAudioSession через RTCAudioSession для координации с CallKit
    /// CRITICAL: Все вызовы ЧЕРЕЗ RTCAudioSession, не напрямую AVAudioSession —
    /// иначе WebRTC теряет синхронизацию и не маршрутизирует аудио
    /// .voiceChat mode → earpiece по умолчанию
    private func configureAudioSession(speaker: Bool = false) {
        ghostLog("[GhostVoice] configureAudioSession ENTER, speaker=\(speaker)")
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.lockForConfiguration()
        do {
            // Конфигурируем через RTCAudioSession — он синхронизирует с WebRTC audio module
            try rtcSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: speaker ? [.defaultToSpeaker, .allowBluetoothA2DP] : [.allowBluetoothA2DP]
            )
            try rtcSession.setActive(true)

            // Earpiece/Speaker routing (через AVAudioSession — overrideOutputAudioPort нет в RTCAudioSession)
            let session = AVAudioSession.sharedInstance()
            try session.setPreferredSampleRate(48000)
            try session.setPreferredIOBufferDuration(0.01)
            if speaker {
                try session.overrideOutputAudioPort(.speaker)
            } else {
                try session.overrideOutputAudioPort(.none) // → earpiece
            }
            ghostLog("[GhostVoice] configureAudioSession EXIT: category=playAndRecord, mode=voiceChat, route=\(speaker ? "speaker" : "earpiece")")
        } catch {
            ghostLog("[GhostVoice] configureAudioSession FAILED: \(error.localizedDescription)")
        }
        rtcSession.unlockForConfiguration()
    }

    /// Включить аудио в WebRTC (fallback когда CallKit не управляет сессией)
    func enableAudioManually() {
        ghostLog("[GhostVoice] enableAudioManually: isAudioEnabled=true")
        RTCAudioSession.sharedInstance().isAudioEnabled = true
    }

    // MARK: - Audio Session Notifications

    /// Подписка на системные уведомления об аудио сессии
    private func observeAudioSession() {
        let nc = NotificationCenter.default

        // Обработка прерываний (звонок, Siri, системные алерты)
        interruptionObserver = nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }

        // Обработка смены маршрута аудио (наушники, bluetooth)
        routeChangeObserver = nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification)
        }

        // Обработка сброса медиа сервера (крайне редко, но критично)
        mediaResetObserver = nc.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            self?.handleMediaReset()
        }
    }

    private func removeAudioObservers() {
        let nc = NotificationCenter.default
        if let obs = interruptionObserver { nc.removeObserver(obs) }
        if let obs = routeChangeObserver { nc.removeObserver(obs) }
        if let obs = mediaResetObserver { nc.removeObserver(obs) }
        interruptionObserver = nil
        routeChangeObserver = nil
        mediaResetObserver = nil
    }

    /// Прерывание аудио сессии (входящий системный звонок, Siri, etc.)
    /// Это ГЛАВНАЯ причина пропадания звука через ~7 минут
    private func handleInterruption(_ notification: Notification) {
        guard isInCall,
              let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            ghostLog("[GhostVoice] audioInterruption BEGAN")
            // iOS прервал аудио — трек остаётся, но сессия деактивирована

        case .ended:
            ghostLog("[GhostVoice] audioInterruption ENDED, reactivating")
            // Восстанавливаем аудио сессию после прерывания
            let shouldResume = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) }
                ?? true
            ghostLog("[GhostVoice] audioInterruption: shouldResume=\(shouldResume)")

            if shouldResume {
                configureAudioSession(speaker: isSpeakerOn)
                // Убеждаемся что WebRTC audio и трек активны
                RTCAudioSession.sharedInstance().isAudioEnabled = true
                audioTrack?.isEnabled = !isMuted
                ghostLog("[GhostVoice] audioInterruption: resumed, isAudioEnabled=true, trackEnabled=\(!isMuted)")
            }

        @unknown default:
            break
        }
    }

    /// Смена маршрута аудио (подключили/отключили наушники, bluetooth)
    private func handleRouteChange(_ notification: Notification) {
        guard isInCall,
              let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        ghostLog("[GhostVoice] routeChange: reason=\(reason.rawValue)")

        switch reason {
        case .oldDeviceUnavailable:
            // Наушники/bluetooth отключены — переключаемся на earpiece
            if !isSpeakerOn {
                switchSpeakerOutput(false)
            }
        case .newDeviceAvailable:
            // Новое устройство — пересоздаём конфигурацию только если критично
            break
        case .override, .categoryChange:
            // Переопределение — восстанавливаем speaker state
            switchSpeakerOutput(isSpeakerOn)
        default:
            break
        }
    }

    /// Сброс медиа сервера — полная переинициализация
    private func handleMediaReset() {
        guard isInCall else { return }
        ghostLog("[GhostVoice] mediaServicesReset — reconfiguring audio")
        configureAudioSession(speaker: isSpeakerOn)
        RTCAudioSession.sharedInstance().isAudioEnabled = true
        audioTrack?.isEnabled = !isMuted
        ghostLog("[GhostVoice] mediaServicesReset EXIT: isAudioEnabled=true, trackEnabled=\(!isMuted)")
    }

    // MARK: - Proximity Sensor

    /// Включить proximity sensor — экран гаснет когда подносишь к уху
    private func enableProximitySensor() {
        DispatchQueue.main.async {
            UIDevice.current.isProximityMonitoringEnabled = true
        }
    }

    /// Выключить proximity sensor
    private func disableProximitySensor() {
        DispatchQueue.main.async {
            UIDevice.current.isProximityMonitoringEnabled = false
        }
    }

    // MARK: - Start Call

    /// Начать исходящий звонок — порт startCall()
    /// Reuses existing sender/transceiver if available (fixes second call audio bug).
    /// Only creates new sender on first call when audioSender is nil.
    /// Returns `true` if sender was reused (renegotiation needed manually).
    @discardableResult
    func startCall() throws -> Bool {
        ghostLog("[GhostVoice] startCall: isInCall=\(isInCall), audioTrack=\(audioTrack != nil), audioSender=\(audioSender != nil)")

        // Reset state from previous call if needed
        if isInCall {
            ghostLog("[GhostVoice] startCall: ending previous call first")
            endCall()
        }

        // Configure audio session FIRST — then tell WebRTC about it
        configureAudioSession(speaker: false) // Earpiece по умолчанию

        // Enable WebRTC audio — CallKit's didActivate will handle AVAudioSession activation
        // Don't call setActive(true) here — it conflicts with CallKit's audio session management
        let rtcAudio = RTCAudioSession.sharedInstance()
        rtcAudio.lockForConfiguration()
        rtcAudio.isAudioEnabled = true
        rtcAudio.unlockForConfiguration()
        ghostLog("[GhostVoice] startCall: isAudioEnabled=true (CallKit manages session)")
        observeAudioSession()
        enableProximitySensor()

        // ALWAYS create brand new audio track
        let audioSource = factory.audioSource(with: Self.audioConstraints)
        audioTrack = factory.audioTrack(with: audioSource, trackId: "ghost-audio-\(UUID().uuidString)")

        guard let track = audioTrack, let pc = peerConnection else {
            removeAudioObservers()
            disableProximitySensor()
            throw VoiceError.audioInitFailed
        }

        // Reuse existing sender (preserves transceiver) or create new one
        var didReuseSender = false
        if let existingSender = audioSender {
            existingSender.track = track
            didReuseSender = true
            ghostLog("[GhostVoice] startCall: reused existing sender (transceiver preserved — MANUAL renegotiation needed)")
        } else {
            audioSender = pc.add(track, streamIds: ["ghost-audio-stream"])
            ghostLog("[GhostVoice] startCall: created new audioSender (first call)")
        }

        // CRITICAL: Гарантируем что WebRTC audio module включён
        RTCAudioSession.sharedInstance().isAudioEnabled = true

        isInCall = true
        onCallStateChange?(.calling)
        return didReuseSender
    }

    /// Инициализировать аудио без добавления в PeerConnection
    /// Для callee: initializeAudio → setRemoteDescription → addAudioTrack → createAnswer
    /// Creates fresh track, keeps existing sender if available for reuse
    func initializeAudio() throws {
        // Detach old track from sender (don't remove sender — preserves transceiver)
        audioTrack?.isEnabled = false
        audioSender?.track = nil
        audioTrack = nil

        configureAudioSession(speaker: false)
        observeAudioSession()
        enableProximitySensor()

        let audioSource = factory.audioSource(with: Self.audioConstraints)
        audioTrack = factory.audioTrack(with: audioSource, trackId: "ghost-audio-\(UUID().uuidString)")

        guard audioTrack != nil, peerConnection != nil else {
            removeAudioObservers()
            disableProximitySensor()
            throw VoiceError.audioInitFailed
        }

        // Enable WebRTC audio — CallKit's didActivate handles AVAudioSession
        let rtcAudio = RTCAudioSession.sharedInstance()
        rtcAudio.lockForConfiguration()
        rtcAudio.isAudioEnabled = true
        rtcAudio.unlockForConfiguration()
        ghostLog("[GhostVoice] initializeAudio: isAudioEnabled=true (CallKit manages session)")
    }

    /// Добавить аудио трек в PeerConnection (после setRemoteDescription)
    /// Reuses existing sender if available (preserves transceiver, avoids SDP conflicts)
    func addAudioTrack() {
        guard let track = audioTrack, let pc = peerConnection else { return }
        if let existingSender = audioSender {
            existingSender.track = track
            ghostLog("[GhostVoice] addAudioTrack: reused existing sender (transceiver preserved)")
        } else {
            audioSender = pc.add(track, streamIds: ["ghost-audio-stream"])
            ghostLog("[GhostVoice] addAudioTrack: created new sender (first call)")
        }
    }

    /// Пометить звонок активным (callee после принятия)
    func markCallActive() {
        ghostLog("[GhostVoice] markCallActive ENTER, wasInCall=\(isInCall)")
        isInCall = true
        callStartTime = Date()
        startCallTimer()
        onCallStateChange?(.active)
        ghostLog("[GhostVoice] markCallActive EXIT: state=.active")
    }

    /// Принять входящий звонок — legacy метод (если нет pending offer)
    func acceptCall() throws {
        ghostLog("[GhostVoice] acceptCall ENTER, isInCall=\(isInCall)")
        guard !isInCall else {
            ghostLog("[GhostVoice] acceptCall: already in call, skipping")
            return
        }

        try initializeAudio()
        addAudioTrack()

        isInCall = true
        callStartTime = Date()
        startCallTimer()
        onCallStateChange?(.active)
        ghostLog("[GhostVoice] acceptCall EXIT: state=.active")
    }

    // MARK: - Call Active

    /// Вызывается когда собеседник принял звонок
    func callAccepted() {
        ghostLog("[GhostVoice] callAccepted ENTER")
        callStartTime = Date()
        startCallTimer()
        onCallStateChange?(.active)
        ghostLog("[GhostVoice] callAccepted EXIT: state=.active")
    }

    // MARK: - Mute

    func toggleMute() -> Bool {
        isMuted.toggle()
        audioTrack?.isEnabled = !isMuted
        ghostLog("[GhostVoice] toggleMute: isMuted=\(isMuted), trackEnabled=\(!isMuted)")
        return isMuted
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        audioTrack?.isEnabled = !muted
        ghostLog("[GhostVoice] setMuted: isMuted=\(isMuted), trackEnabled=\(!muted)")
    }

    // MARK: - Speaker / Earpiece

    /// Переключение earpiece ↔ speaker
    /// Только меняем output port — НЕ пересоздаём всю сессию (это вызывает лаги)
    func toggleSpeaker() -> Bool {
        isSpeakerOn.toggle()
        ghostLog("[GhostVoice] toggleSpeaker: isSpeakerOn=\(isSpeakerOn)")
        switchSpeakerOutput(isSpeakerOn)
        return isSpeakerOn
    }

    func setSpeaker(_ enabled: Bool) {
        isSpeakerOn = enabled
        ghostLog("[GhostVoice] setSpeaker: isSpeakerOn=\(enabled)")
        switchSpeakerOutput(enabled)
    }

    /// Лёгкое переключение output — без пересоздания категории/режима/sample rate
    private func switchSpeakerOutput(_ speaker: Bool) {
        guard isInCall else { return }
        do {
            let rtcSession = RTCAudioSession.sharedInstance()
            let session = AVAudioSession.sharedInstance()
            // Убеждаемся что категория правильная перед override
            if session.category != .playAndRecord {
                rtcSession.lockForConfiguration()
                try rtcSession.setCategory(.playAndRecord, mode: .voiceChat, options: speaker ? [.defaultToSpeaker, .allowBluetoothA2DP] : [.allowBluetoothA2DP])
                rtcSession.unlockForConfiguration()
            }
            try session.overrideOutputAudioPort(speaker ? .speaker : .none)
        } catch {
            #if DEBUG
            print("[GhostVoice] Speaker switch error: \(error)")
            #endif
        }
    }

    // MARK: - Timer

    private func startCallTimer() {
        callTimer?.invalidate()
        callTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let start = self.callStartTime else { return }
            let elapsed = Int(Date().timeIntervalSince(start))
            let minutes = elapsed / 60
            let seconds = elapsed % 60
            let formatted = String(format: "%02d:%02d", minutes, seconds)
            self.onCallTimer?(formatted)
        }
    }

    // MARK: - End Call

    /// Завершить звонок — порт endCall()
    /// DON'T removeTrack — that puts transceiver in "stopped" state permanently.
    /// Instead: disable track + set sender.track = nil. Sender stays alive for reuse.
    /// Next call: create new track → sender.track = newTrack (no new transceiver).
    func endCall() {
        callTimer?.invalidate()
        callTimer = nil

        removeAudioObservers()
        disableProximitySensor()

        // Disable track but DON'T remove sender — preserves transceiver for second call
        audioTrack?.isEnabled = false
        if let sender = audioSender {
            sender.track = nil  // Detach track without removing transceiver
            ghostLog("[GhostVoice] endCall: detached track from sender (transceiver preserved)")
        }
        audioTrack = nil
        // Keep audioSender reference — reuse on next startCall

        // Keep audio session active — DON'T call setActive(false)
        // WebRTC ADM won't restart properly after deactivation
        // Only disable isAudioEnabled (mutes without killing the module)
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.lockForConfiguration()
        rtcSession.isAudioEnabled = false
        rtcSession.unlockForConfiguration()
        ghostLog("[GhostVoice] endCall: audio disabled, session kept active")

        isInCall = false
        isMuted = false
        isSpeakerOn = false
        callStartTime = nil

        onCallStateChange?(.ended)
    }

    // MARK: - Status

    var callDuration: Int {
        guard let start = callStartTime else { return 0 }
        return Int(Date().timeIntervalSince(start))
    }

    // MARK: - Cleanup

    func destroy() {
        callTimer?.invalidate()
        callTimer = nil
        removeAudioObservers()
        disableProximitySensor()

        // On destroy, actually remove track+sender (voice object is being discarded)
        if let sender = audioSender {
            peerConnection?.removeTrack(sender)
            ghostLog("[GhostVoice] destroy: removed sender from PeerConnection")
        }
        audioSender = nil
        audioTrack = nil

        isInCall = false
        isMuted = false
        isSpeakerOn = false
        callStartTime = nil

        onCallStateChange = nil
        onCallTimer = nil
        onRemoteAudioTrack = nil
    }

    // MARK: - Audio Constraints

    /// Безопасные аудио constraints — порт getSecureAudioConstraints()
    private static var audioConstraints: RTCMediaConstraints {
        RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: [
                "echoCancellation": "true",
                "noiseSuppression": "true",
                "autoGainControl": "false"
            ]
        )
    }
}

enum VoiceError: LocalizedError {
    case audioInitFailed
    case microphoneDenied
    case microphoneNotFound

    var errorDescription: String? {
        switch self {
        case .audioInitFailed: return "Failed to initialize audio"
        case .microphoneDenied: return "Microphone access denied"
        case .microphoneNotFound: return "Microphone not found"
        }
    }
}
