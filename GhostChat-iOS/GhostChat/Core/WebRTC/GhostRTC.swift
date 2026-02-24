import Foundation
import WebRTC

/// WebRTC P2P модуль — порт webrtc.js
/// RTCPeerConnection + DataChannel + Trickle ICE
final class GhostRTC: NSObject {

    // MARK: - Properties

    private(set) var peerConnection: RTCPeerConnection?
    private(set) var dataChannel: RTCDataChannel?
    private var factory: RTCPeerConnectionFactory!
    private var isConnectedFlag = false
    private var isNegotiating = false
    private var disconnectTimer: Timer?

    /// TURN credentials
    private var turnCredentials: TURNCredentials?

    /// Режим приватности: relay-only скрывает реальный IP
    var privacyMode = false

    // MARK: - Callbacks

    var onMessage: ((String) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onError: ((String) -> Void)?
    var onIceCandidate: ((RTCIceCandidate) -> Void)?
    var onTrack: ((RTCMediaStream) -> Void)?
    var onRenegotiationNeeded: ((RTCSessionDescription) -> Void)?

    // MARK: - Init

    override init() {
        super.init()
        RTCInitializeSSL()

        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory
        )
    }

    // MARK: - ICE Configuration

    private func buildConfig() -> RTCConfiguration {
        let config = RTCConfiguration()

        var iceServers: [RTCIceServer] = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun.cloudflare.com:3478"])
        ]

        // Добавляем TURN серверы если есть credentials
        if let creds = turnCredentials {
            for url in creds.urls {
                let turnServer = RTCIceServer(
                    urlStrings: [url],
                    username: creds.username,
                    credential: creds.credential
                )
                iceServers.append(turnServer)
            }
        }

        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.iceTransportPolicy = privacyMode ? .relay : .all

        return config
    }

    // MARK: - Host

    /// Инициализация как хост (создатель комнаты) — порт initAsHost()
    func initAsHost(turnCredentials: TURNCredentials?) -> RTCSessionDescription? {
        self.turnCredentials = turnCredentials
        createPeerConnection()

        guard let pc = peerConnection else { return nil }

        // Хост создаёт DataChannel
        let dcConfig = RTCDataChannelConfiguration()
        dcConfig.isOrdered = true

        dataChannel = pc.dataChannel(forLabel: "ghost-chat", configuration: dcConfig)
        setupDataChannel()

        // Создаём offer
        var offer: RTCSessionDescription?
        let semaphore = DispatchSemaphore(value: 0)

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )

        pc.offer(for: constraints) { sdp, error in
            if let sdp {
                pc.setLocalDescription(sdp) { _ in
                    offer = sdp
                    semaphore.signal()
                }
            } else {
                semaphore.signal()
            }
        }

        semaphore.wait()
        return offer
    }

    /// Асинхронная версия initAsHost
    func initAsHost(turnCredentials: TURNCredentials?) async -> RTCSessionDescription? {
        self.turnCredentials = turnCredentials
        createPeerConnection()

        guard let pc = peerConnection else { return nil }

        // Хост создаёт DataChannel
        let dcConfig = RTCDataChannelConfiguration()
        dcConfig.isOrdered = true

        dataChannel = pc.dataChannel(forLabel: "ghost-chat", configuration: dcConfig)
        setupDataChannel()

        // Создаём offer
        return await withCheckedContinuation { continuation in
            let constraints = RTCMediaConstraints(
                mandatoryConstraints: nil,
                optionalConstraints: nil
            )

            pc.offer(for: constraints) { sdp, error in
                if let sdp {
                    pc.setLocalDescription(sdp) { _ in
                        continuation.resume(returning: sdp)
                    }
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Guest

    /// Инициализация как гость — порт initAsGuest()
    func initAsGuest(turnCredentials: TURNCredentials?) {
        self.turnCredentials = turnCredentials
        createPeerConnection()

        // Гость ждёт DataChannel от хоста (обрабатывается в delegate)
    }

    // MARK: - PeerConnection

    private func createPeerConnection() {
        // Закрываем старое соединение
        cleanupConnection()

        let config = buildConfig()
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )

        peerConnection = factory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: self
        )
    }

    private func cleanupConnection() {
        disconnectTimer?.invalidate()
        disconnectTimer = nil

        dataChannel?.close()
        dataChannel = nil

        peerConnection?.close()
        peerConnection = nil

        isConnectedFlag = false
    }

    // MARK: - DataChannel

    private func setupDataChannel() {
        dataChannel?.delegate = self
    }

    private func fireConnected() {
        guard !isConnectedFlag else { return }
        guard dataChannel?.readyState == .open else { return }
        isConnectedFlag = true
        DispatchQueue.main.async { [weak self] in
            self?.onConnected?()
        }
    }

    // MARK: - Signaling

    /// Обработка offer (для гостя) — порт handleOffer()
    func handleOffer(_ sdp: RTCSessionDescription) async -> RTCSessionDescription? {
        guard let pc = peerConnection else { return nil }

        return await withCheckedContinuation { continuation in
            pc.setRemoteDescription(sdp) { error in
                if error != nil {
                    continuation.resume(returning: nil)
                    return
                }

                let constraints = RTCMediaConstraints(
                    mandatoryConstraints: nil,
                    optionalConstraints: nil
                )

                pc.answer(for: constraints) { answer, error in
                    if let answer {
                        pc.setLocalDescription(answer) { _ in
                            continuation.resume(returning: answer)
                        }
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }

    /// Обработка answer (для хоста) — порт handleAnswer()
    func handleAnswer(_ sdp: RTCSessionDescription) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            peerConnection?.setRemoteDescription(sdp) { _ in
                continuation.resume()
            }
        }
    }

    /// Добавление ICE кандидата
    func addIceCandidate(_ candidate: RTCIceCandidate) {
        peerConnection?.add(candidate) { error in
            if let error {
                print("[GhostRTC] Error adding ICE candidate: \(error)")
            }
        }
    }

    // MARK: - Data

    /// Отправка через DataChannel
    func send(_ data: String) -> Bool {
        guard let dc = dataChannel, dc.readyState == .open else { return false }
        let buffer = RTCDataBuffer(data: Data(data.utf8), isBinary: false)
        return dc.sendData(buffer)
    }

    var isConnected: Bool {
        dataChannel?.readyState == .open
    }

    // MARK: - Privacy

    func setPrivacyMode(_ enabled: Bool) {
        privacyMode = enabled
    }

    // MARK: - ICE Candidate Filtering

    /// Фильтрация кандидатов для приватности — порт shouldFilterCandidate()
    private func shouldFilter(_ candidate: RTCIceCandidate) -> Bool {
        guard privacyMode else { return false }
        return !candidate.sdp.contains("typ relay")
    }

    // MARK: - Audio Track Management

    /// Добавить аудио трек к PeerConnection (для звонков)
    func addAudioTrack(_ track: RTCAudioTrack, stream: RTCMediaStream) -> RTCRtpSender? {
        return peerConnection?.add(track, streamIds: [stream.streamId])
    }

    /// Удалить sender (при завершении звонка)
    func removeTrack(_ sender: RTCRtpSender) {
        peerConnection?.removeTrack(sender)
    }

    // MARK: - Renegotiation

    /// Создать offer для renegotiation
    func createOffer() async -> RTCSessionDescription? {
        guard let pc = peerConnection else { return nil }

        return await withCheckedContinuation { continuation in
            let constraints = RTCMediaConstraints(
                mandatoryConstraints: nil,
                optionalConstraints: nil
            )

            pc.offer(for: constraints) { sdp, error in
                if let sdp {
                    pc.setLocalDescription(sdp) { _ in
                        continuation.resume(returning: sdp)
                    }
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Cleanup

    func destroy() {
        disconnectTimer?.invalidate()
        disconnectTimer = nil

        dataChannel?.close()
        dataChannel = nil

        peerConnection?.close()
        peerConnection = nil

        onMessage = nil
        onConnected = nil
        onDisconnected = nil
        onError = nil
        onIceCandidate = nil
        onTrack = nil
        onRenegotiationNeeded = nil
        isConnectedFlag = false
        isNegotiating = false
        turnCredentials = nil
    }
}

// MARK: - RTCPeerConnectionDelegate

extension GhostRTC: RTCPeerConnectionDelegate {

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        // Signaling state changed
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        DispatchQueue.main.async { [weak self] in
            self?.onTrack?(stream)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        // Stream removed
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        guard !isNegotiating, isConnectedFlag else { return }
        isNegotiating = true

        Task {
            if let offer = await createOffer() {
                DispatchQueue.main.async { [weak self] in
                    self?.isNegotiating = false
                    self?.onRenegotiationNeeded?(offer)
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.isNegotiating = false
                }
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard !shouldFilter(candidate) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onIceCandidate?(candidate)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        // Candidates removed
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        // Гость получает DataChannel от хоста
        DispatchQueue.main.async { [weak self] in
            self?.dataChannel = dataChannel
            self?.setupDataChannel()
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            self.disconnectTimer?.invalidate()
            self.disconnectTimer = nil

            switch newState {
            case .connected, .completed:
                self.fireConnected()

            case .failed:
                self.onError?("ICE connection failed")
                if self.isConnectedFlag {
                    self.isConnectedFlag = false
                    self.onDisconnected?()
                }

            case .disconnected where self.isConnectedFlag:
                // Delayed disconnect — ICE may reconnect during renegotiation (5s)
                self.disconnectTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    if self.peerConnection?.iceConnectionState == .disconnected {
                        self.isConnectedFlag = false
                        self.onDisconnected?()
                    }
                }

            case .closed where self.isConnectedFlag:
                self.isConnectedFlag = false
                self.onDisconnected?()

            default:
                break
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        // ICE gathering state changed
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            switch newState {
            case .connected where !self.isConnectedFlag:
                self.fireConnected()

            case .failed, .closed:
                if self.isConnectedFlag {
                    self.isConnectedFlag = false
                    self.onDisconnected?()
                }

            default:
                break
            }
        }
    }
}

// MARK: - RTCDataChannelDelegate

extension GhostRTC: RTCDataChannelDelegate {

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            switch dataChannel.readyState {
            case .open:
                self.fireConnected()
            case .closed:
                if self.isConnectedFlag {
                    self.isConnectedFlag = false
                    self.onDisconnected?()
                }
            default:
                break
            }
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let text = String(data: buffer.data, encoding: .utf8) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onMessage?(text)
        }
    }
}

// MARK: - SDP Helpers

extension GhostRTC {

    /// Конвертация RTCSessionDescription → словарь для отправки по WS
    static func sdpToDict(_ sdp: RTCSessionDescription) -> [String: Any] {
        let typeStr: String
        switch sdp.type {
        case .offer: typeStr = "offer"
        case .answer: typeStr = "answer"
        case .prAnswer: typeStr = "pranswer"
        case .rollback: typeStr = "rollback"
        @unknown default: typeStr = "unknown"
        }
        return ["type": typeStr, "sdp": sdp.sdp]
    }

    /// Конвертация словаря → RTCSessionDescription
    static func dictToSdp(_ dict: [String: Any]) -> RTCSessionDescription? {
        guard let typeStr = dict["type"] as? String,
              let sdpStr = dict["sdp"] as? String else { return nil }

        let type: RTCSdpType
        switch typeStr {
        case "offer": type = .offer
        case "answer": type = .answer
        case "pranswer": type = .prAnswer
        default: return nil
        }

        return RTCSessionDescription(type: type, sdp: sdpStr)
    }

    /// Конвертация RTCIceCandidate → словарь
    static func candidateToDict(_ candidate: RTCIceCandidate) -> [String: Any] {
        return [
            "candidate": candidate.sdp,
            "sdpMLineIndex": candidate.sdpMLineIndex,
            "sdpMid": candidate.sdpMid ?? ""
        ]
    }

    /// Конвертация словаря → RTCIceCandidate
    static func dictToCandidate(_ dict: [String: Any]) -> RTCIceCandidate? {
        guard let sdp = dict["candidate"] as? String else { return nil }
        let sdpMLineIndex = dict["sdpMLineIndex"] as? Int32 ?? 0
        let sdpMid = dict["sdpMid"] as? String

        return RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
    }
}
