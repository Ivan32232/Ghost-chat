import Foundation

/// Orchestrates SignalingClient + GhostRTC + GhostChatCrypto through a single state machine.
/// Owns the per-session `rtc` and `crypto` instances; recreates them on every fresh connect.
///
/// Events fan in via two AsyncStream sources (signaling.events, rtc.events) into one internal
/// task per client-facing flow.
@MainActor
final class ConnectionManager: ObservableObject {

    enum Error: Swift.Error, Equatable {
        case notConnected
        case unexpectedState
    }

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var roomId: String?
    @Published private(set) var safetyNumber: String?
    @Published private(set) var peerIdentity: Data?

    let incomingText: AsyncStream<String>

    private let signalingURL: URL
    private let apiBaseURL: URL
    private let identity: IdentityKeyService
    private let push: PushManager
    private let pinning: CertificatePinning

    private var signaling: SignalingClient?
    private var turn: TURNService
    private var rtc: GhostRTC?
    private var crypto: GhostChatCrypto?
    private var role: Role?

    private var incomingContinuation: AsyncStream<String>.Continuation?
    private var tasks: [Task<Void, Never>] = []

    init(
        signalingURL: URL,
        apiBaseURL: URL,
        identity: IdentityKeyService,
        push: PushManager,
        pinning: CertificatePinning = CertificatePinning()
    ) {
        self.signalingURL = signalingURL
        self.apiBaseURL = apiBaseURL
        self.identity = identity
        self.push = push
        self.pinning = pinning
        self.turn = TURNService(baseURL: apiBaseURL, pinning: pinning)
        var cont: AsyncStream<String>.Continuation!
        self.incomingText = AsyncStream { cont = $0 }
        self.incomingContinuation = cont
    }

    // MARK: - Connect flows

    func createRoom() async throws {
        reset()
        state = .connecting
        role = .host

        let creds = try await turn.fetchCredentials()
        push.pushAuth = creds.pushAuth

        rtc = GhostRTC(role: .host, turnCredentials: creds)
        crypto = GhostChatCrypto(identity: identity)
        try rtc?.start()
        startRTCEventLoop()

        let sig = SignalingClient(url: signalingURL, pinning: pinning)
        signaling = sig
        startSignalingLoop(sig)
        sig.connect()
        try sig.createRoom()
        state = .signaling
    }

    func joinRoom(_ id: String) async throws {
        reset()
        state = .connecting
        role = .guest

        let creds = try await turn.fetchCredentials()
        push.pushAuth = creds.pushAuth

        rtc = GhostRTC(role: .guest, turnCredentials: creds)
        crypto = GhostChatCrypto(identity: identity)
        try rtc?.start()
        startRTCEventLoop()

        let sig = SignalingClient(url: signalingURL, pinning: pinning)
        signaling = sig
        startSignalingLoop(sig)
        sig.connect()
        try sig.joinRoom(id)
        state = .signaling
    }

    func sendText(_ text: String) async throws {
        guard let crypto, let rtc else { throw Error.unexpectedState }
        guard state == .encrypted else { throw Error.notConnected }
        let wire = try await crypto.encrypt(text)
        try rtc.send(Data(wire.utf8))
    }

    func leave() {
        try? signaling?.leaveRoom()
        reset()
    }

    private func reset() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        signaling?.disconnect()
        rtc?.close()
        signaling = nil
        rtc = nil
        crypto = nil
        roomId = nil
        safetyNumber = nil
        peerIdentity = nil
        role = nil
        state = .disconnected
    }

    // MARK: - Loops

    private func startSignalingLoop(_ client: SignalingClient) {
        let task = Task { [weak self] in
            for await event in client.events {
                await self?.handleSignaling(event)
            }
        }
        tasks.append(task)
    }

    private func startRTCEventLoop() {
        guard let rtc else { return }
        let task = Task { [weak self] in
            for await event in rtc.events {
                await self?.handleRTC(event)
            }
        }
        tasks.append(task)
    }

    private func handleSignaling(_ event: SignalingEvent) async {
        switch event {
        case .roomCreated(let id):
            roomId = id
        case .roomJoined(let id):
            roomId = id
        case .peerJoined:
            if role == .host {
                try? await rtc?.createOffer()
            }
        case .signal(let raw):
            await handleSignalPayload(raw)
        case .peerLeft, .disconnected:
            state = .disconnected
        case .error:
            state = .disconnected
        case .connected, .rejoinOk:
            break
        }
    }

    private func handleSignalPayload(_ raw: Data) async {
        guard let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return }
        if let type = json["type"] as? String {
            if type == "offer", let sdp = json["sdp"] as? String {
                try? await rtc?.receiveOffer(sdp)
                return
            }
            if type == "answer", let sdp = json["sdp"] as? String {
                try? await rtc?.receiveAnswer(sdp)
                return
            }
            if type == "key-exchange",
               let pkt = try? JSONDecoder().decode(KeyExchangePacket.self, from: raw) {
                try? await completeHandshake(with: pkt)
                return
            }
        }
        if let candidate = json["candidate"] as? String {
            let mid = json["sdpMid"] as? String
            let idx = (json["sdpMLineIndex"] as? Int).map(Int32.init) ?? 0
            try? await rtc?.addIceCandidate(sdp: candidate, sdpMid: mid, sdpMLineIndex: idx)
        }
    }

    private func handleRTC(_ event: GhostRTCEvent) async {
        switch event {
        case .iceCandidate(let sdp, let mid, let idx):
            let payload: [String: Any] = [
                "candidate": sdp,
                "sdpMid": mid ?? "",
                "sdpMLineIndex": Int(idx)
            ]
            emitSignal(payload)
        case .offerReady(let sdp):
            emitSignal(["type": "offer", "sdp": sdp])
        case .answerReady(let sdp):
            emitSignal(["type": "answer", "sdp": sdp])
            state = .webRTC
        case .dataChannelOpen:
            state = .webRTC
            await startKeyExchangeOverDataChannel()
        case .dataChannelMessage(let data):
            await handleDataChannelMessage(data)
        case .dataChannelClosed:
            state = .disconnected
        case .iceStateChanged, .peerConnectionStateChanged:
            break
        }
    }

    private func startKeyExchangeOverDataChannel() async {
        guard let crypto, let rtc else { return }
        do {
            let pkt = try await crypto.beginHandshake()
            let data = try JSONEncoder().encode(pkt)
            try rtc.send(data)
        } catch {
            state = .disconnected
        }
    }

    private func completeHandshake(with peerPkt: KeyExchangePacket) async throws {
        guard let crypto, let role else { return }
        if role == .host {
            try await crypto.completeAsHost(peer: peerPkt)
        } else {
            try await crypto.completeAsGuest(peer: peerPkt)
        }
        state = .encrypted
        peerIdentity = peerPkt.identityKey
        safetyNumber = try? await crypto.safetyNumber()
    }

    private func handleDataChannelMessage(_ data: Data) async {
        // Try key exchange packet first
        if let pkt = try? JSONDecoder().decode(KeyExchangePacket.self, from: data),
           pkt.type == "key-exchange" {
            try? await completeHandshake(with: pkt)
            return
        }
        // Otherwise expect encrypted wire
        guard let wire = String(data: data, encoding: .utf8) else { return }
        if let text = try? await crypto?.decrypt(wire) {
            incomingContinuation?.yield(text)
        }
    }

    private func emitSignal(_ payload: [String: Any]) {
        guard let raw = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? signaling?.sendSignal(rawJSON: raw)
    }
}
