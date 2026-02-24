import Foundation
import AVFoundation
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

    /// Настройка AVAudioSession — ГЛАВНОЕ преимущество нативного приложения
    /// .voiceChat mode → earpiece по умолчанию
    private func configureAudioSession(speaker: Bool = false) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: speaker ? [.defaultToSpeaker] : []
            )
            try session.setPreferredSampleRate(48000)
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)

            // Earpiece/Speaker routing
            if speaker {
                try session.overrideOutputAudioPort(.speaker)
            } else {
                try session.overrideOutputAudioPort(.none) // → earpiece
            }
        } catch {
            print("[GhostVoice] Audio session error: \(error)")
        }
    }

    // MARK: - Start Call

    /// Начать исходящий звонок — порт startCall()
    func startCall() throws {
        guard !isInCall else { return }

        configureAudioSession(speaker: false) // Earpiece по умолчанию

        // Создаём аудио трек
        let audioSource = factory.audioSource(with: Self.audioConstraints)
        audioTrack = factory.audioTrack(with: audioSource, trackId: "ghost-audio-0")

        guard let track = audioTrack, let pc = peerConnection else {
            throw VoiceError.audioInitFailed
        }

        // Добавляем к PeerConnection
        audioSender = pc.add(track, streamIds: ["ghost-audio-stream"])

        isInCall = true
        onCallStateChange?(.calling)
    }

    /// Принять входящий звонок — порт acceptCall()
    func acceptCall() throws {
        guard !isInCall else { return }

        configureAudioSession(speaker: false)

        let audioSource = factory.audioSource(with: Self.audioConstraints)
        audioTrack = factory.audioTrack(with: audioSource, trackId: "ghost-audio-0")

        guard let track = audioTrack, let pc = peerConnection else {
            throw VoiceError.audioInitFailed
        }

        audioSender = pc.add(track, streamIds: ["ghost-audio-stream"])

        isInCall = true
        callStartTime = Date()
        startCallTimer()
        onCallStateChange?(.active)
    }

    // MARK: - Call Active

    /// Вызывается когда собеседник принял звонок
    func callAccepted() {
        callStartTime = Date()
        startCallTimer()
        onCallStateChange?(.active)
    }

    // MARK: - Mute

    func toggleMute() -> Bool {
        isMuted.toggle()
        audioTrack?.isEnabled = !isMuted
        return isMuted
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        audioTrack?.isEnabled = !muted
    }

    // MARK: - Speaker / Earpiece

    /// Переключение earpiece ↔ speaker
    /// Нативный AVAudioSession — работает корректно (в отличие от WebView)
    func toggleSpeaker() -> Bool {
        isSpeakerOn.toggle()
        configureAudioSession(speaker: isSpeakerOn)
        return isSpeakerOn
    }

    func setSpeaker(_ enabled: Bool) {
        isSpeakerOn = enabled
        configureAudioSession(speaker: enabled)
    }

    // MARK: - Timer

    private func startCallTimer() {
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
    func endCall() {
        callTimer?.invalidate()
        callTimer = nil

        // Удаляем track из PeerConnection
        if let sender = audioSender, let pc = peerConnection {
            pc.removeTrack(sender)
        }
        audioSender = nil

        // Останавливаем audio track
        audioTrack?.isEnabled = false
        audioTrack = nil

        // Деактивируем audio session
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

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
        endCall()
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
