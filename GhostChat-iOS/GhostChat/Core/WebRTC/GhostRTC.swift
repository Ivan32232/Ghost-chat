import Foundation
@preconcurrency import WebRTC
import os.log

/// WebRTC P2P модуль — порт webrtc.js
/// RTCPeerConnection + DataChannel + Trickle ICE
final class GhostRTC: NSObject, @unchecked Sendable {

    private let logger = Logger(subsystem: "com.ivanpokhvalitov.ghostchat", category: "GhostRTC")

    // MARK: - Properties

    private(set) var peerConnection: RTCPeerConnection?
    private(set) var dataChannel: RTCDataChannel?
    private(set) var factory: RTCPeerConnectionFactory!
    private var isConnectedFlag = false
    private var isNegotiating = false
    private var disconnectTimer: Timer?

    /// TURN credentials
    private var turnCredentials: TURNCredentials?

    /// TURN credential refresh — обновление за 5 мин до истечения TTL
    private var turnRefreshTimer: Timer?
    private var turnService: TURNService?

    /// Режим приватности: relay-only скрывает реальный IP (ON by default — max security)
    var privacyMode = true

    private var iceRestartAttempted = false

    // MARK: - Callbacks

    var onMessage: ((String) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onError: ((String) -> Void)?
    var onIceCandidate: ((RTCIceCandidate) -> Void)?
    var onTrack: ((RTCMediaStream) -> Void)?
    var onRenegotiationNeeded: ((RTCSessionDescription) -> Void)?
    var onIceRestartNeeded: ((RTCSessionDescription) -> Void)?

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
    /// M6: Removed synchronous semaphore version — use async only
    func initAsHost(turnCredentials: TURNCredentials?) async -> RTCSessionDescription? {
        let iceServerCount = (turnCredentials?.urls.count ?? 0) + 2 // + 2 STUN
        ghostLog("[GhostRTC] initAsHost ENTER, hasTURN=\(turnCredentials != nil), iceServerCount=\(iceServerCount), privacyMode=\(privacyMode)")
        self.turnCredentials = turnCredentials
        createPeerConnection()
        scheduleTurnRefresh()

        guard let pc = peerConnection else {
            ghostLog("[GhostRTC] initAsHost FAILED: no PeerConnection")
            return nil
        }

        // Хост создаёт DataChannel
        let dcConfig = RTCDataChannelConfiguration()
        dcConfig.isOrdered = true

        dataChannel = pc.dataChannel(forLabel: "ghost-chat", configuration: dcConfig)
        ghostLog("[GhostRTC] initAsHost: DataChannel created, label=ghost-chat, state=\(String(describing: dataChannel?.readyState.rawValue))")
        setupDataChannel()

        // Создаём offer
        return await withCheckedContinuation { continuation in
            let constraints = RTCMediaConstraints(
                mandatoryConstraints: nil,
                optionalConstraints: nil
            )

            pc.offer(for: constraints) { sdp, error in
                if let sdp {
                    ghostLog("[GhostRTC] initAsHost: offer created, sdpSize=\(sdp.sdp.count), hasAudio=\(sdp.sdp.contains("m=audio")), transceivers=\(pc.transceivers.count)")
                    pc.setLocalDescription(sdp) { err in
                        if let err {
                            ghostLog("[GhostRTC] initAsHost: setLocalDescription FAILED: \(err.localizedDescription)")
                        } else {
                            ghostLog("[GhostRTC] initAsHost: setLocalDescription OK")
                        }
                        continuation.resume(returning: sdp)
                    }
                } else {
                    ghostLog("[GhostRTC] initAsHost: createOffer FAILED: \(error?.localizedDescription ?? "unknown")")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Guest

    /// Инициализация как гость — порт initAsGuest()
    func initAsGuest(turnCredentials: TURNCredentials?) {
        let iceServerCount = (turnCredentials?.urls.count ?? 0) + 2
        ghostLog("[GhostRTC] initAsGuest ENTER, hasTURN=\(turnCredentials != nil), iceServerCount=\(iceServerCount), privacyMode=\(privacyMode)")
        self.turnCredentials = turnCredentials
        createPeerConnection()
        scheduleTurnRefresh()

        // Гость ждёт DataChannel от хоста (обрабатывается в delegate)
        ghostLog("[GhostRTC] initAsGuest EXIT: waiting for DataChannel from host")
    }

    // MARK: - PeerConnection

    private func createPeerConnection() {
        ghostLog("[GhostRTC] createPeerConnection ENTER")
        // Закрываем старое соединение
        cleanupConnection()

        let config = buildConfig()
        ghostLog("[GhostRTC] createPeerConnection: config built, iceServers=\(config.iceServers.count), iceTransportPolicy=\(config.iceTransportPolicy.rawValue)")
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )

        peerConnection = factory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: self
        )
        ghostLog("[GhostRTC] createPeerConnection EXIT, pcCreated=\(peerConnection != nil)")
    }

    private func cleanupConnection() {
        ghostLog("[GhostRTC] cleanupConnection ENTER, hasDC=\(dataChannel != nil), hasPC=\(peerConnection != nil), isConnected=\(isConnectedFlag)")
        disconnectTimer?.invalidate()
        disconnectTimer = nil

        dataChannel?.close()
        dataChannel = nil

        peerConnection?.close()
        peerConnection = nil

        isConnectedFlag = false
        ghostLog("[GhostRTC] cleanupConnection EXIT")
    }

    // MARK: - DataChannel

    private func setupDataChannel() {
        ghostLog("[GhostRTC] setupDataChannel ENTER, hasDC=\(dataChannel != nil), state=\(String(describing: dataChannel?.readyState.rawValue))")
        dataChannel?.delegate = self
        // If DataChannel is already OPEN when delegate is set (guest race),
        // dataChannelDidChangeState won't fire — trigger manually
        if dataChannel?.readyState == .open {
            ghostLog("[GhostRTC] setupDataChannel: DC already OPEN, firing connected")
            fireConnected()
        }
    }

    private func fireConnected() {
        guard !isConnectedFlag else { return }
        guard dataChannel?.readyState == .open else { return }
        ghostLog("[GhostRTC] fireConnected: P2P connection established")
        isConnectedFlag = true
        DispatchQueue.main.async { [weak self] in
            self?.onConnected?()
        }
    }

    // MARK: - Signaling

    /// Обработка offer (для гостя) — порт handleOffer()
    func handleOffer(_ sdp: RTCSessionDescription) async -> RTCSessionDescription? {
        ghostLog("[GhostRTC] handleOffer ENTER, sdpSize=\(sdp.sdp.count), hasAudio=\(sdp.sdp.contains("m=audio"))")
        guard let pc = peerConnection else {
            ghostLog("[GhostRTC] handleOffer FAILED: no PeerConnection")
            return nil
        }

        return await withCheckedContinuation { continuation in
            pc.setRemoteDescription(sdp) { error in
                if let error {
                    ghostLog("[GhostRTC] handleOffer setRemoteDescription FAILED: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }
                ghostLog("[GhostRTC] handleOffer: setRemoteDescription OK, transceivers=\(pc.transceivers.count)")

                let constraints = RTCMediaConstraints(
                    mandatoryConstraints: nil,
                    optionalConstraints: nil
                )

                pc.answer(for: constraints) { answer, error in
                    if let answer {
                        ghostLog("[GhostRTC] handleOffer: answer created, sdpSize=\(answer.sdp.count), hasAudio=\(answer.sdp.contains("m=audio"))")
                        pc.setLocalDescription(answer) { err in
                            if let err {
                                ghostLog("[GhostRTC] handleOffer setLocalDescription FAILED: \(err.localizedDescription)")
                            } else {
                                ghostLog("[GhostRTC] handleOffer EXIT: setLocalDescription OK")
                            }
                            continuation.resume(returning: answer)
                        }
                    } else {
                        ghostLog("[GhostRTC] handleOffer createAnswer FAILED: \(error?.localizedDescription ?? "unknown")")
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }

    /// Только setRemoteDescription (для renegotiation — между шагами нужно добавить track)
    func setRemoteOffer(_ sdp: RTCSessionDescription) async -> Bool {
        ghostLog("[GhostRTC] setRemoteOffer ENTER, sdpSize=\(sdp.sdp.count), hasAudio=\(sdp.sdp.contains("m=audio"))")
        guard let pc = peerConnection else {
            ghostLog("[GhostRTC] setRemoteOffer FAILED: no PeerConnection")
            return false
        }

        return await withCheckedContinuation { continuation in
            pc.setRemoteDescription(sdp) { error in
                if let error {
                    ghostLog("[GhostRTC] setRemoteOffer EXIT: FAILED \(error.localizedDescription)")
                } else {
                    ghostLog("[GhostRTC] setRemoteOffer EXIT: OK, transceivers=\(pc.transceivers.count)")
                }
                continuation.resume(returning: error == nil)
            }
        }
    }

    /// Только createAnswer + setLocalDescription (после setRemoteOffer + addTrack)
    func createAndSetAnswer() async -> RTCSessionDescription? {
        ghostLog("[GhostRTC] createAndSetAnswer ENTER")
        guard let pc = peerConnection else {
            ghostLog("[GhostRTC] createAndSetAnswer FAILED: no PeerConnection")
            return nil
        }

        return await withCheckedContinuation { continuation in
            let constraints = RTCMediaConstraints(
                mandatoryConstraints: nil,
                optionalConstraints: nil
            )

            pc.answer(for: constraints) { answer, error in
                if let answer {
                    ghostLog("[GhostRTC] createAndSetAnswer: answer created, sdpSize=\(answer.sdp.count), hasAudio=\(answer.sdp.contains("m=audio")), transceivers=\(pc.transceivers.count)")
                    pc.setLocalDescription(answer) { err in
                        if let err {
                            ghostLog("[GhostRTC] createAndSetAnswer setLocalDescription FAILED: \(err.localizedDescription)")
                        } else {
                            ghostLog("[GhostRTC] createAndSetAnswer EXIT: OK")
                        }
                        continuation.resume(returning: answer)
                    }
                } else {
                    ghostLog("[GhostRTC] createAndSetAnswer createAnswer FAILED: \(error?.localizedDescription ?? "unknown")")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Обработка answer (для хоста) — порт handleAnswer()
    func handleAnswer(_ sdp: RTCSessionDescription) async {
        ghostLog("[GhostRTC] handleAnswer ENTER, sdpSize=\(sdp.sdp.count), hasAudio=\(sdp.sdp.contains("m=audio"))")
        guard let pc = peerConnection else {
            ghostLog("[GhostRTC] handleAnswer FAILED: no PeerConnection")
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pc.setRemoteDescription(sdp) { error in
                if let error {
                    ghostLog("[GhostRTC] handleAnswer setRemoteDescription FAILED: \(error.localizedDescription)")
                } else {
                    ghostLog("[GhostRTC] handleAnswer EXIT: setRemoteDescription OK, transceivers=\(pc.transceivers.count)")
                }
                continuation.resume()
            }
        }
    }

    /// Добавление ICE кандидата
    func addIceCandidate(_ candidate: RTCIceCandidate) {
        // Parse type (host/srflx/relay/prflx) and IP type (IPv4/IPv6) from SDP
        let typeStr: String
        if candidate.sdp.contains("typ host") { typeStr = "host" }
        else if candidate.sdp.contains("typ srflx") { typeStr = "srflx" }
        else if candidate.sdp.contains("typ relay") { typeStr = "relay" }
        else if candidate.sdp.contains("typ prflx") { typeStr = "prflx" }
        else { typeStr = "unknown" }
        let ipType = candidate.sdp.contains(":") && candidate.sdp.components(separatedBy: " ").count > 4 ? "?" : "?"
        ghostLog("[GhostRTC] addIceCandidate ENTER, candType=\(typeStr), sdpMid=\(candidate.sdpMid ?? "nil"), ipType=\(ipType)")
        peerConnection?.add(candidate) { error in
            if let error {
                ghostLog("[GhostRTC] addIceCandidate FAILED: \(error.localizedDescription)")
            } else {
                ghostLog("[GhostRTC] addIceCandidate EXIT: OK (\(typeStr))")
            }
        }
    }

    // MARK: - Data

    /// Отправка через DataChannel
    func send(_ data: String) -> Bool {
        guard let dc = dataChannel, dc.readyState == .open else {
            ghostLog("[GhostRTC] send FAILED: DataChannel not open, state=\(String(describing: dataChannel?.readyState.rawValue))")
            return false
        }

        let bufferedBefore = dc.bufferedAmount
        // Backpressure: wait if buffer is too full (prevents DataChannel overflow)
        let maxBuffered: UInt64 = 1024 * 1024 // 1MB
        var waitCount = 0
        while dc.bufferedAmount > maxBuffered && waitCount < 100 {
            Thread.sleep(forTimeInterval: 0.05)
            waitCount += 1
        }
        if waitCount > 0 {
            ghostLog("[GhostRTC] send: backpressure waited \(waitCount * 50)ms, buffered=\(dc.bufferedAmount)")
        }

        let buffer = RTCDataBuffer(data: Data(data.utf8), isBinary: false)
        let result = dc.sendData(buffer)
        let bufferedAfter = dc.bufferedAmount
        if !result {
            ghostLog("[GhostRTC] send FAILED: sendData returned false, size=\(data.count), buffered=\(bufferedAfter)")
        } else {
            // Only log occasional sends to avoid spam (every 10th or large)
            if data.count > 4096 || bufferedAfter > 65536 {
                ghostLog("[GhostRTC] send OK, size=\(data.count), bufferedBefore=\(bufferedBefore), bufferedAfter=\(bufferedAfter)")
            }
        }
        return result
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
        ghostLog("[GhostRTC] addAudioTrack ENTER, trackId=\(track.trackId), streamId=\(stream.streamId)")
        let sender = peerConnection?.add(track, streamIds: [stream.streamId])
        ghostLog("[GhostRTC] addAudioTrack EXIT, senderCreated=\(sender != nil), totalSenders=\(peerConnection?.senders.count ?? 0)")
        return sender
    }

    /// Удалить sender (при завершении звонка)
    func removeTrack(_ sender: RTCRtpSender) {
        ghostLog("[GhostRTC] removeTrack ENTER")
        peerConnection?.removeTrack(sender)
        ghostLog("[GhostRTC] removeTrack EXIT, remainingSenders=\(peerConnection?.senders.count ?? 0)")
    }

    // MARK: - Renegotiation

    /// Создать offer для renegotiation
    func createOffer() async -> RTCSessionDescription? {
        ghostLog("[GhostRTC] createOffer called")
        guard let pc = peerConnection else {
            ghostLog("[GhostRTC] createOffer failed: no PeerConnection")
            return nil
        }

        return await withCheckedContinuation { continuation in
            let constraints = RTCMediaConstraints(
                mandatoryConstraints: nil,
                optionalConstraints: nil
            )

            pc.offer(for: constraints) { sdp, error in
                if let sdp {
                    let hasAudio = sdp.sdp.contains("m=audio")
                    let hasSendrecv = sdp.sdp.contains("a=sendrecv")
                    ghostLog("[GhostRTC] createOffer: hasAudio=\(hasAudio), hasSendrecv=\(hasSendrecv), senders=\(pc.senders.count), transceivers=\(pc.transceivers.count)")
                    pc.setLocalDescription(sdp) { _ in
                        continuation.resume(returning: sdp)
                    }
                } else {
                    ghostLog("[GhostRTC] createOffer FAILED: \(error?.localizedDescription ?? "unknown")")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - ICE Restart

    /// ICE restart — пересогласование ICE при деградации соединения
    func restartIce() async -> RTCSessionDescription? {
        ghostLog("[GhostRTC] restartIce ENTER")
        guard let pc = peerConnection else {
            ghostLog("[GhostRTC] restartIce FAILED: no PeerConnection")
            return nil
        }

        return await withCheckedContinuation { continuation in
            let constraints = RTCMediaConstraints(
                mandatoryConstraints: ["IceRestart": "true"],
                optionalConstraints: nil
            )

            pc.offer(for: constraints) { sdp, error in
                if let sdp {
                    ghostLog("[GhostRTC] restartIce: offer created, sdpSize=\(sdp.sdp.count)")
                    pc.setLocalDescription(sdp) { err in
                        if let err {
                            ghostLog("[GhostRTC] restartIce setLocalDescription FAILED: \(err.localizedDescription)")
                        } else {
                            ghostLog("[GhostRTC] restartIce EXIT: OK")
                        }
                        continuation.resume(returning: sdp)
                    }
                } else {
                    ghostLog("[GhostRTC] restartIce createOffer FAILED: \(error?.localizedDescription ?? "unknown")")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - TURN Credential Refresh

    /// Установить TURNService для автоматического обновления credentials
    func setTurnService(_ service: TURNService?) {
        self.turnService = service
    }

    /// Запланировать обновление TURN credentials за 5 мин до истечения TTL
    private func scheduleTurnRefresh() {
        turnRefreshTimer?.invalidate()
        turnRefreshTimer = nil

        guard let creds = turnCredentials, turnService != nil else { return }

        // Обновляем за 300 секунд (5 мин) до истечения, минимум 60 секунд
        let refreshInterval = max(TimeInterval(creds.ttl - 300), 60)
        #if DEBUG
        print("[GhostRTC] TURN refresh scheduled in \(Int(refreshInterval))s (TTL=\(creds.ttl)s)")
        #endif

        turnRefreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: false) { [weak self] _ in
            Task { [weak self] in
                await self?.refreshTurnCredentials()
            }
        }
    }

    /// Обновить TURN credentials и применить к PeerConnection
    private func refreshTurnCredentials() async {
        guard let turnService else { return }

        do {
            let newCreds = try await turnService.fetchCredentials()
            self.turnCredentials = newCreds

            // Обновляем ICE серверы на живом PeerConnection
            if let pc = peerConnection {
                let config = buildConfig()
                pc.setConfiguration(config)
                #if DEBUG
                print("[GhostRTC] TURN credentials refreshed, new TTL=\(newCreds.ttl)s")
                #endif
            }

            // Планируем следующее обновление
            scheduleTurnRefresh()
        } catch {
            #if DEBUG
            print("[GhostRTC] TURN refresh failed: \(error) — retry in 300s")
            #endif
            // Retry через 5 минут
            DispatchQueue.main.async { [weak self] in
                self?.turnRefreshTimer?.invalidate()
                self?.turnRefreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
                    Task { [weak self] in
                        await self?.refreshTurnCredentials()
                    }
                }
            }
        }
    }

    // MARK: - Cleanup

    func destroy() {
        turnRefreshTimer?.invalidate()
        turnRefreshTimer = nil

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
        onIceRestartNeeded = nil
        isConnectedFlag = false
        isNegotiating = false
        iceRestartAttempted = false
        turnCredentials = nil
        turnService = nil
    }
}

// MARK: - RTCPeerConnectionDelegate

extension GhostRTC: RTCPeerConnectionDelegate {

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        ghostLog("[GhostRTC] signalingState changed: \(stateChanged.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        ghostLog("[GhostRTC] didAddStream: audioTracks=\(stream.audioTracks.count), videoTracks=\(stream.videoTracks.count)")
        DispatchQueue.main.async { [weak self] in
            self?.onTrack?(stream)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        ghostLog("[GhostRTC] didRemoveStream")
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        ghostLog("[GhostRTC] shouldNegotiate, isNegotiating=\(isNegotiating), isConnected=\(isConnectedFlag)")
        guard !isNegotiating, isConnectedFlag else {
            ghostLog("[GhostRTC] shouldNegotiate: skipping (busy or not connected)")
            return
        }
        isNegotiating = true

        Task {
            if let offer = await createOffer() {
                ghostLog("[GhostRTC] shouldNegotiate: offer ready, invoking onRenegotiationNeeded")
                DispatchQueue.main.async { [weak self] in
                    self?.isNegotiating = false
                    self?.onRenegotiationNeeded?(offer)
                }
            } else {
                ghostLog("[GhostRTC] shouldNegotiate: createOffer returned nil")
                DispatchQueue.main.async { [weak self] in
                    self?.isNegotiating = false
                }
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let typeStr: String
        if candidate.sdp.contains("typ host") { typeStr = "host" }
        else if candidate.sdp.contains("typ srflx") { typeStr = "srflx" }
        else if candidate.sdp.contains("typ relay") { typeStr = "relay" }
        else if candidate.sdp.contains("typ prflx") { typeStr = "prflx" }
        else { typeStr = "unknown" }
        let filtered = shouldFilter(candidate)
        ghostLog("[GhostRTC] didGenerateCandidate type=\(typeStr), filtered=\(filtered), privacyMode=\(privacyMode)")
        guard !filtered else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onIceCandidate?(candidate)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        ghostLog("[GhostRTC] didRemoveCandidates count=\(candidates.count)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        ghostLog("[GhostRTC] DataChannel opened, label=\(dataChannel.label)")
        // M8: Validate DataChannel label
        guard dataChannel.label == "ghost-chat" else {
            logger.warning("[GhostRTC] rejecting DataChannel with unexpected label: \(dataChannel.label)")
            return
        }
        // Register delegate IMMEDIATELY on WebRTC thread to avoid missing messages
        // (same approach as Android — prevents key-exchange race on fast networks)
        self.dataChannel = dataChannel
        dataChannel.delegate = self
        ghostLog("[GhostRTC] DataChannel delegate set on WebRTC thread, state=\(String(describing: dataChannel.readyState.rawValue))")
        // Fire connected on main thread
        DispatchQueue.main.async { [weak self] in
            self?.fireConnected()
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        ghostLog("[GhostRTC] ICE connection state changed: \(String(describing: newState.rawValue))")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            self.disconnectTimer?.invalidate()
            self.disconnectTimer = nil

            switch newState {
            case .connected, .completed:
                self.iceRestartAttempted = false
                self.fireConnected()

            case .failed:
                // Попытка ICE restart перед отключением
                if self.isConnectedFlag && !self.iceRestartAttempted {
                    self.iceRestartAttempted = true
                    #if DEBUG
                    print("[GhostRTC] ICE failed — attempting restart")
                    #endif
                    Task {
                        if let offer = await self.restartIce() {
                            // ICE restart offer MUST go through signaling (not DataChannel!)
                            DispatchQueue.main.async { [weak self] in
                                self?.onIceRestartNeeded?(offer)
                            }
                        } else {
                            DispatchQueue.main.async { [weak self] in
                                guard let self else { return }
                                self.onError?("ICE connection failed")
                                self.isConnectedFlag = false
                                self.onDisconnected?()
                            }
                        }
                    }
                } else if !self.iceRestartAttempted {
                    self.onError?("ICE connection failed")
                } else {
                    // ICE restart уже был — сдаёмся
                    self.onError?("ICE connection failed after restart")
                    if self.isConnectedFlag {
                        self.isConnectedFlag = false
                        self.onDisconnected?()
                    }
                }

            case .disconnected where self.isConnectedFlag:
                // Delayed disconnect — ICE may reconnect during renegotiation (5s)
                self.disconnectTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    if self.peerConnection?.iceConnectionState == .disconnected {
                        // Попробовать ICE restart
                        if !self.iceRestartAttempted {
                            self.iceRestartAttempted = true
                            #if DEBUG
                            print("[GhostRTC] ICE disconnected — attempting restart")
                            #endif
                            Task {
                                if let offer = await self.restartIce() {
                                    // ICE restart offer MUST go through signaling (not DataChannel!)
                                    DispatchQueue.main.async { [weak self] in
                                        self?.onIceRestartNeeded?(offer)
                                    }
                                } else {
                                    DispatchQueue.main.async { [weak self] in
                                        guard let self else { return }
                                        self.isConnectedFlag = false
                                        self.onDisconnected?()
                                    }
                                }
                            }
                        } else {
                            self.isConnectedFlag = false
                            self.onDisconnected?()
                        }
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
        ghostLog("[GhostRTC] iceGatheringState changed: \(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        ghostLog("[GhostRTC] peerConnectionState changed: \(newState.rawValue), isConnectedFlag=\(isConnectedFlag)")
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
        ghostLog("[GhostRTC] DataChannel state changed: \(String(describing: dataChannel.readyState.rawValue))")
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
        guard let text = String(data: buffer.data, encoding: .utf8) else {
            ghostLog("[GhostRTC] didReceiveMessage: non-UTF8 binary, size=\(buffer.data.count)")
            return
        }
        // Don't log message content (crypto privacy), only length
        if text.count > 10000 {
            ghostLog("[GhostRTC] didReceiveMessage: size=\(text.count)")
        }
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
