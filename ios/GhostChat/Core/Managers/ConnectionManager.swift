import Foundation
import GhostCrypto

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
        case fileTooLarge(Int)
    }

    /// Backpressure threshold — pause file sends when the SCTP send buffer
    /// exceeds 16 KiB. Matches the spec and the Android mirror.
    static let backpressureThresholdBytes: UInt64 = 16 * 1024

    /// Hard cap on attachment size (100 MiB). Above this we refuse to send rather
    /// than spend tens of seconds chunking + encrypting on the main actor.
    static let maxFileBytes = 100 * 1024 * 1024

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var roomId: String?
    @Published private(set) var safetyNumber: String?
    @Published private(set) var peerIdentity: Data?

    /// Authoritative "a remote peer is in the room" signal, sourced ONLY from
    /// signaling-server events (`peer-joined` for host, `room-joined` for guest).
    /// Local RTC events like `dataChannelOpen` or `answerReady` MUST NOT flip this —
    /// stasel/WebRTC fires them once the local SCTP association is up, even when
    /// no peer has connected. Keeping this flag separate from `state` is what
    /// gates ChatView, fixing the regression where host bypassed WaitingView.
    @Published private(set) var hasRemotePeer: Bool = false

    // Extension access hooks (see ConnectionHandshake.swift, ConnectionFileTransferRouter.swift).
    func _set(state: ConnectionState) { self.state = state }
    func _set(safetyNumber: String?) { self.safetyNumber = safetyNumber }
    func _set(peerIdentity: Data?) { self.peerIdentity = peerIdentity }
    func _set(hasRemotePeer: Bool) { self.hasRemotePeer = hasRemotePeer }
    var cryptoRef: GhostChatCrypto? { crypto }
    var rtcRef: GhostRTC? { rtc }
    var roleRef: Role? { role }

    /// Set when this session is bound to a saved contact. On `leave()`, a deterministic
    /// key rotation is triggered against `contactManager` using the session's shared secret.
    var currentContactId: String?

    /// Strong reference into the app-wide `ContactManager`. Nil if rotations are disabled
    /// (e.g. unit tests that don't care about saved contacts).
    weak var contactManager: ContactManager?

    let incomingText: AsyncStream<String>
    let incomingFile: AsyncStream<FileTransferService.IncomingFile>
    let fileTransferAborted: AsyncStream<String>

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
    var fileTransfer: FileTransferService = FileTransferService()
    let chunkTimeout = ChunkTimeoutTracker()

    private var incomingContinuation: AsyncStream<String>.Continuation?
    var fileContinuation: AsyncStream<FileTransferService.IncomingFile>.Continuation?
    var abortContinuation: AsyncStream<String>.Continuation?
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
        var textCont: AsyncStream<String>.Continuation!
        self.incomingText = AsyncStream { textCont = $0 }
        self.incomingContinuation = textCont
        var fileCont: AsyncStream<FileTransferService.IncomingFile>.Continuation!
        self.incomingFile = AsyncStream { fileCont = $0 }
        self.fileContinuation = fileCont
        var abortCont: AsyncStream<String>.Continuation!
        self.fileTransferAborted = AsyncStream { abortCont = $0 }
        self.abortContinuation = abortCont
        wireChunkTimeoutHandlers()
    }

    private func wireChunkTimeoutHandlers() {
        // onTimeout: 30 s with no chunk → ask peer to retransmit the ones we're missing.
        chunkTimeout.onTimeout = { [weak self] fileId in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let missing = self.fileTransfer.missingChunks(fileId: fileId) ?? []
                if !missing.isEmpty {
                    try? await self.sendControl(.fileRetransmit(fileId: fileId, indices: missing))
                }
            }
        }
        // onAbort: 3 retries exhausted → drop the incomplete inbound, surface to UI.
        chunkTimeout.onAbort = { [weak self] fileId in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.fileTransfer.cancelInbound(fileId: fileId)
                self.abortContinuation?.yield(fileId)
            }
        }
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

    /// Send a raw control message (encoded as JSON, encrypted, sent over the
    /// DataChannel). Callers must only invoke once the session is `.encrypted`.
    func sendControl(_ ctrl: ControlMessage) async throws {
        guard let crypto, let rtc else { throw Error.unexpectedState }
        guard state == .encrypted else { throw Error.notConnected }
        let json = try JSONEncoder().encode(ctrl)
        guard let text = String(data: json, encoding: .utf8) else { throw Error.unexpectedState }
        let wire = try await crypto.encrypt(text)
        try rtc.send(Data(wire.utf8))
    }

    /// Chunk `data`, stream each chunk as an encrypted `file-chunk` control
    /// message with backpressure, then send `file-complete`. Returns the
    /// locally-minted `fileId` so the caller can track progress / show a bubble.
    @discardableResult
    func sendFile(data: Data, name: String, mimeType: String) async throws -> String {
        guard state == .encrypted else { throw Error.notConnected }
        guard data.count <= Self.maxFileBytes else { throw Error.fileTooLarge(data.count) }

        let out = try fileTransfer.prepareOutbound(data: data, name: name, mimeType: mimeType)
        try await sendControl(out.startMessage)
        for chunk in out.chunkMessages {
            try await awaitSendSlot()
            try await sendControl(chunk)
        }
        try await sendControl(out.completeMessage)
        return out.fileId
    }

    func leave() {
        // Capture before reset() nukes `crypto` and `currentContactId`.
        let cid = currentContactId
        let cryptoRef = crypto
        let mgrRef = contactManager

        try? signaling?.leaveRoom()
        reset()

        // Fire-and-forget rotation. Rotation is best-effort: if the crypto actor has
        // already been torn down or the contact was deleted, silently drop.
        if let cid, let cryptoRef, let mgrRef {
            Task { @MainActor in
                if let secret = try? await cryptoRef.sessionSecret() {
                    try? mgrRef.rotateKeys(contactId: cid, sessionSecret: secret)
                }
            }
        }
    }

    /// Test hook: synchronous variant of `leave()` that awaits the rotation step so
    /// assertions can observe the rotated contact state.
    func leaveAndAwaitRotation() async {
        let cid = currentContactId
        let cryptoRef = crypto
        let mgrRef = contactManager
        try? signaling?.leaveRoom()
        reset()
        if let cid, let cryptoRef, let mgrRef,
           let secret = try? await cryptoRef.sessionSecret() {
            try? mgrRef.rotateKeys(contactId: cid, sessionSecret: secret)
        }
    }

    /// Test hook: inject a pre-built crypto actor so tests can exercise `leaveAndAwaitRotation()`
    /// without running the full signaling + WebRTC + handshake pipeline.
    func _test_injectReadyCrypto(_ crypto: GhostChatCrypto) {
        self.crypto = crypto
    }

    private func reset() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        signaling?.disconnect()
        rtc?.close()
        signaling = nil
        rtc = nil
        crypto = nil
        fileTransfer = FileTransferService()
        // Drop any armed chunk timers — new session gets a fresh set.
        chunkTimeout.cancelAll()
        roomId = nil
        safetyNumber = nil
        peerIdentity = nil
        hasRemotePeer = false
        role = nil
        state = .disconnected
    }

    /// Sleep briefly while the DataChannel's outgoing SCTP buffer is over the
    /// backpressure threshold. Resolves as soon as the buffer drains — or if
    /// the session tears down.
    private func awaitSendSlot() async throws {
        while let rtc, rtc.bufferedAmount > Self.backpressureThresholdBytes {
            if Task.isCancelled { throw CancellationError() }
            try await Task.sleep(nanoseconds: 10_000_000)  // 10 ms
        }
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
            // Server only lets a guest into a non-empty room (`server/src/signaling.ts`
            // rejects with "Room not found" / "Room is full"), so receiving roomJoined
            // implicitly means the host is present.
            roomId = id
            hasRemotePeer = true
        case .peerJoined:
            hasRemotePeer = true
            if role == .host {
                try? await rtc?.createOffer()
            }
        case .signal(let raw):
            await handleSignalPayload(raw)
        case .peerLeft:
            hasRemotePeer = false
            state = .disconnected
        case .disconnected:
            state = .disconnected
        case .error:
            state = .disconnected
        case .connected, .rejoinOk:
            break
        }
    }

    // MARK: - Test hooks

    /// Test-only re-entry into the signaling event handler. Lets unit tests inject
    /// `SignalingEvent`s directly without standing up a live WebSocket. Production
    /// code uses the loop in `startSignalingLoop`.
    func _test_dispatchSignaling(_ event: SignalingEvent) async {
        await handleSignaling(event)
    }

    /// Test-only re-entry into the RTC event handler. Same reasoning as above —
    /// exists so we can verify that `dataChannelOpen` / `answerReady` do NOT flip
    /// `hasRemotePeer` (the regression test).
    func _test_dispatchRTC(_ event: GhostRTCEvent) async {
        await handleRTC(event)
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
            if type == "pq-exchange",
               let pkt = try? JSONDecoder().decode(PqExchangePacket.self, from: raw) {
                try? await completePqHandshake(with: pkt)
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

    private func handleDataChannelMessage(_ data: Data) async {
        // Try key exchange packet first (plaintext JSON, sent right after DC open).
        if let pkt = try? JSONDecoder().decode(KeyExchangePacket.self, from: data),
           pkt.type == "key-exchange" {
            try? await completeHandshake(with: pkt)
            return
        }
        // Phase 7: HOST may receive a PqExchangePacket right after GUEST processes our key-exchange.
        if let pqPkt = try? JSONDecoder().decode(PqExchangePacket.self, from: data),
           pqPkt.type == "pq-exchange" {
            try? await completePqHandshake(with: pqPkt)
            return
        }
        // Otherwise expect encrypted wire — decrypt via Double Ratchet.
        guard let wire = String(data: data, encoding: .utf8) else { return }
        guard let plaintext = try? await crypto?.decrypt(wire) else { return }
        let plainData = Data(plaintext.utf8)

        // Control messages (`_ctrl: true`) get routed to the control handler.
        if let ctrl = try? JSONDecoder().decode(ControlMessage.self, from: plainData) {
            await handleControl(ctrl)
            return
        }

        // Fallback: deliver as a plain text chat message.
        incomingContinuation?.yield(plaintext)
    }

    private func handleControl(_ ctrl: ControlMessage) async { await routeFileControl(ctrl) }
    func awaitSendSlotForRoute() async throws { try await awaitSendSlot() }

    private func emitSignal(_ payload: [String: Any]) {
        guard let raw = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? signaling?.sendSignal(rawJSON: raw)
    }
}
