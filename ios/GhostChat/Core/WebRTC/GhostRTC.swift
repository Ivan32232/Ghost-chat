import Foundation
import WebRTC

/// Static WebRTC assets — factory is expensive, created once.
enum GhostRTCFactory {
    static let shared: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let encoder = RTCDefaultVideoEncoderFactory()
        let decoder = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: decoder)
    }()
}

/// Events emitted by `GhostRTC` as the P2P session progresses.
enum GhostRTCEvent: Equatable {
    case iceCandidate(sdp: String, sdpMid: String?, sdpMLineIndex: Int32)
    case offerReady(sdp: String)
    case answerReady(sdp: String)
    case dataChannelOpen
    case dataChannelClosed
    case dataChannelMessage(Data)
    case iceStateChanged(String)
    case peerConnectionStateChanged(String)
}

/// Owns a single `RTCPeerConnection` + the `ghost-chat` data channel.
/// Used by HOST to create an offer, by GUEST to answer. Perfect-negotiation collision
/// handling: guest is polite, host is impolite.
final class GhostRTC: NSObject {

    enum Error: Swift.Error, Equatable {
        case notStarted
        case invalidDataChannelLabel(String)
        case operationFailed(String)
    }

    private static let dataChannelLabel = "ghost-chat"

    let role: Role
    private let privacyMode: Bool
    private let turnCredentials: TURNCredentials?
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var continuation: AsyncStream<GhostRTCEvent>.Continuation?

    let events: AsyncStream<GhostRTCEvent>

    // MARK: - Init

    init(role: Role, turnCredentials: TURNCredentials? = nil, privacyMode: Bool = false) {
        self.role = role
        self.turnCredentials = turnCredentials
        self.privacyMode = privacyMode
        var cont: AsyncStream<GhostRTCEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        super.init()
        self.continuation = cont
    }

    deinit { continuation?.finish() }

    // MARK: - Lifecycle

    func start() throws {
        guard peerConnection == nil else { return }

        let cfg = RTCConfiguration()
        cfg.iceServers = makeIceServers()
        cfg.sdpSemantics = .unifiedPlan
        cfg.bundlePolicy = .maxBundle
        cfg.rtcpMuxPolicy = .require
        cfg.iceTransportPolicy = privacyMode ? .relay : .all
        cfg.continualGatheringPolicy = .gatherContinually

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = GhostRTCFactory.shared.peerConnection(with: cfg, constraints: constraints, delegate: self) else {
            throw Error.operationFailed("failed to create peer connection")
        }
        self.peerConnection = pc

        if role == .host {
            let dcConfig = RTCDataChannelConfiguration()
            dcConfig.isOrdered = true
            dcConfig.isNegotiated = false
            guard let dc = pc.dataChannel(forLabel: Self.dataChannelLabel, configuration: dcConfig) else {
                throw Error.operationFailed("failed to create data channel")
            }
            dc.delegate = self
            self.dataChannel = dc
        }
    }

    func close() {
        dataChannel?.close()
        dataChannel = nil
        peerConnection?.close()
        peerConnection = nil
    }

    // MARK: - Signaling API

    /// HOST: build an offer and emit it via `events`.
    func createOffer() async throws {
        guard let pc = peerConnection else { throw Error.notStarted }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { cont in
            pc.offer(for: constraints) { sdp, error in
                if let sdp { cont.resume(returning: sdp) }
                else { cont.resume(throwing: error ?? Error.operationFailed("offer failed")) }
            }
        }
        try await setLocalDescription(offer)
        continuation?.yield(.offerReady(sdp: offer.sdp))
    }

    /// GUEST: accept an incoming offer, emit the answer.
    func receiveOffer(_ sdpString: String) async throws {
        guard let pc = peerConnection else { throw Error.notStarted }
        let offer = RTCSessionDescription(type: .offer, sdp: sdpString)
        try await setRemoteDescription(offer)

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let answer: RTCSessionDescription = try await withCheckedThrowingContinuation { cont in
            pc.answer(for: constraints) { sdp, error in
                if let sdp { cont.resume(returning: sdp) }
                else { cont.resume(throwing: error ?? Error.operationFailed("answer failed")) }
            }
        }
        try await setLocalDescription(answer)
        continuation?.yield(.answerReady(sdp: answer.sdp))
    }

    /// HOST: accept incoming answer.
    func receiveAnswer(_ sdpString: String) async throws {
        let answer = RTCSessionDescription(type: .answer, sdp: sdpString)
        try await setRemoteDescription(answer)
    }

    func addIceCandidate(sdp: String, sdpMid: String?, sdpMLineIndex: Int32) async throws {
        guard let pc = peerConnection else { throw Error.notStarted }
        let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Swift.Error>) in
            pc.add(candidate) { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            }
        }
    }

    /// Send arbitrary bytes over the data channel.
    func send(_ data: Data) throws {
        guard let dc = dataChannel, dc.readyState == .open else {
            throw Error.notStarted
        }
        let buffer = RTCDataBuffer(data: data, isBinary: true)
        guard dc.sendData(buffer) else {
            throw Error.operationFailed("dataChannel.sendData returned false")
        }
    }

    // MARK: - Private helpers

    private func makeIceServers() -> [RTCIceServer] {
        var servers: [RTCIceServer] = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun.cloudflare.com:3478"])
        ]
        if let turn = turnCredentials {
            servers.append(RTCIceServer(urlStrings: turn.urls, username: turn.username, credential: turn.credential))
        }
        return servers
    }

    private func setLocalDescription(_ sdp: RTCSessionDescription) async throws {
        guard let pc = peerConnection else { throw Error.notStarted }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Swift.Error>) in
            pc.setLocalDescription(sdp) { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            }
        }
    }

    private func setRemoteDescription(_ sdp: RTCSessionDescription) async throws {
        guard let pc = peerConnection else { throw Error.notStarted }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Swift.Error>) in
            pc.setRemoteDescription(sdp) { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            }
        }
    }

    /// Filters ICE candidates that leak real IP or duplicate IPv6 link-local info.
    static func shouldAcceptCandidate(_ sdp: String) -> Bool {
        if sdp.contains(" typ host ") { return false }
        if sdp.lowercased().contains(" fe80:") { return false }
        return true
    }
}

// MARK: - RTCPeerConnectionDelegate

extension GhostRTC: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        continuation?.yield(.iceStateChanged(String(describing: newState)))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard Self.shouldAcceptCandidate(candidate.sdp) else { return }
        continuation?.yield(.iceCandidate(
            sdp: candidate.sdp,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex
        ))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        guard dataChannel.label == Self.dataChannelLabel else {
            dataChannel.close()
            return
        }
        self.dataChannel = dataChannel
        dataChannel.delegate = self
    }
}

// MARK: - RTCDataChannelDelegate

extension GhostRTC: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        switch dataChannel.readyState {
        case .open:    continuation?.yield(.dataChannelOpen)
        case .closed:  continuation?.yield(.dataChannelClosed)
        default:       break
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        continuation?.yield(.dataChannelMessage(buffer.data))
    }
}
