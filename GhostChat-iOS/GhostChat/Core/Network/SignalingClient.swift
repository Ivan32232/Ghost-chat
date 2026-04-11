import Foundation
import os.log

/// WebSocket клиент для signaling сервера — порт connectWebSocket() + handleSignalingMessage()
/// Протокол полностью совместим с server/index.js
final class SignalingClient: NSObject {

    private let logger = Logger(subsystem: "com.ivanpokhvalitov.ghostchat", category: "SignalingClient")

    // MARK: - Properties

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let serverURL: URL

    private var isReconnecting = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 10
    private var pendingRejoin: (roomId: String, isHost: Bool)?
    private var reconnectTimeoutWork: DispatchWorkItem?

    /// Message queue — messages sent before WS opens get queued and flushed on open
    private var pendingMessages: [[String: Any]] = []
    private var isOpen = false

    // MARK: - Callbacks

    var onRoomCreated: ((String) -> Void)?
    var onRoomJoined: ((String) -> Void)?
    var onRejoinOk: (() -> Void)?
    var onPeerJoined: (() -> Void)?
    var onPeerLeft: (() -> Void)?
    var onSignal: (([String: Any]) -> Void)?
    var onError: ((String) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?

    // MARK: - Init

    init(serverURL: URL) {
        self.serverURL = serverURL
        super.init()
    }

    // MARK: - Connection

    func connect() {
        ghostLog("[SignalingClient] connect called, server=\(self.serverURL.absoluteString)")
        let session = URLSession(
            configuration: .default,
            delegate: self,
            delegateQueue: .main
        )
        urlSession = session

        // Строим WS URL: https → wss, http → ws
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        components.scheme = serverURL.scheme == "https" ? "wss" : "ws"
        components.path = "/ws"

        let wsURL = components.url!
        ghostLog("[SignalingClient] connecting to \(wsURL.absoluteString)")
        webSocket = session.webSocketTask(with: wsURL)
        webSocket?.resume()

        listenForMessages()
        // onConnected вызывается в didOpenWithProtocol delegate
    }

    func disconnect() {
        ghostLog("[SignalingClient] disconnect called")
        isReconnecting = false
        isOpen = false
        reconnectTimeoutWork?.cancel()
        reconnectTimeoutWork = nil
        pendingMessages.removeAll()
        pendingRejoin = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    // MARK: - Send Messages

    func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }

        let msgType = message["type"] as? String ?? "unknown"
        guard isOpen else {
            // Queue messages until WebSocket is open
            ghostLog("[SignalingClient] WS not open, queuing message type=\(msgType)")
            pendingMessages.append(message)
            return
        }

        ghostLog("[SignalingClient] sending message type=\(msgType)")
        webSocket?.send(.string(text)) { error in
            if let error {
                ghostLog("[SignalingClient] send error: \(error.localizedDescription)")
            }
        }
    }

    func createRoom() {
        send(["type": "create-room"])
    }

    func joinRoom(_ roomId: String) {
        send(["type": "join-room", "roomId": roomId])
    }

    func rejoinRoom(_ roomId: String, role: String) {
        send(["type": "rejoin-room", "roomId": roomId, "role": role])
    }

    func sendSignal(_ data: [String: Any]) {
        let signalType = data["type"] as? String ?? "unknown"
        ghostLog("[SignalingClient] sendSignal signalType=\(signalType)")
        send(["type": "signal", "data": data])
    }

    func leaveRoom() {
        send(["type": "leave-room"])
    }

    // MARK: - Receive Messages

    private func listenForMessages() {
        webSocket?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                // Продолжаем слушать
                self.listenForMessages()

            case .failure(let error):
                ghostLog("[SignalingClient] receive FAILED: \(error.localizedDescription)")
                self.isOpen = false
                self.onDisconnected?()
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        ghostLog("[SignalingClient] received message type=\(type)")

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            switch type {
            case "room-created":
                if let roomId = json["roomId"] as? String {
                    self.onRoomCreated?(roomId)
                }

            case "room-joined":
                if let roomId = json["roomId"] as? String {
                    self.onRoomJoined?(roomId)
                }

            case "rejoin-ok":
                self.onRejoinOk?()

            case "peer-joined":
                self.onPeerJoined?()

            case "peer-left":
                self.onPeerLeft?()

            case "signal":
                if let signalData = json["data"] as? [String: Any] {
                    self.onSignal?(signalData)
                }

            case "error":
                let message = json["message"] as? String ?? "Unknown error"
                self.onError?(message)

            default:
                break
            }
        }
    }

    // MARK: - Reconnection

    /// Автопереподключение с exponential backoff — порт scheduleReconnect()
    func scheduleReconnect(roomId: String, isHost: Bool) {
        ghostLog("[SignalingClient] scheduleReconnect isHost=\(isHost), alreadyReconnecting=\(isReconnecting)")
        guard !isReconnecting else { return }
        isReconnecting = true
        reconnectAttempts = 0

        attemptReconnect(roomId: roomId, isHost: isHost)
    }

    private func attemptReconnect(roomId: String, isHost: Bool) {
        guard isReconnecting else { return }

        reconnectAttempts += 1
        ghostLog("[SignalingClient] attemptReconnect #\(reconnectAttempts)/\(maxReconnectAttempts), isHost=\(isHost)")
        if reconnectAttempts > maxReconnectAttempts {
            ghostLog("[SignalingClient] reconnect giving up after \(maxReconnectAttempts) attempts")
            isReconnecting = false
            pendingRejoin = nil
            onError?(String(localized: "signaling.reconnectFailed"))
            return
        }

        // Exponential backoff: 1s, 2s, 4s, 8s... max 30s
        let delay = min(pow(2.0, Double(reconnectAttempts - 1)), 30.0)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isReconnecting else { return }

            let wasReconnecting = self.isReconnecting
            self.disconnect()
            self.isReconnecting = wasReconnecting

            let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
            self.urlSession = session

            var components = URLComponents(url: self.serverURL, resolvingAgainstBaseURL: false)!
            components.scheme = self.serverURL.scheme == "https" ? "wss" : "ws"
            components.path = "/ws"

            let ws = session.webSocketTask(with: components.url!)
            self.webSocket = ws

            // Store pending rejoin — will fire in didOpenWithProtocol delegate
            self.pendingRejoin = (roomId: roomId, isHost: isHost)

            ws.resume()
            self.listenForMessages()

            // Timeout: if not connected in 10s, retry (cancellable on success)
            self.reconnectTimeoutWork?.cancel()
            let timeoutWork = DispatchWorkItem { [weak self] in
                guard let self, self.isReconnecting, self.pendingRejoin != nil else { return }
                // Connection didn't open in time — retry
                self.pendingRejoin = nil
                self.attemptReconnect(roomId: roomId, isHost: isHost)
            }
            self.reconnectTimeoutWork = timeoutWork
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeoutWork)
        }
    }

    var isConnected: Bool {
        isOpen
    }
}

// MARK: - URLSessionWebSocketDelegate + Certificate Pinning (M1)

extension SignalingClient: URLSessionWebSocketDelegate {

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        ghostLog("[SignalingClient] WebSocket opened")
        isOpen = true

        // Cancel pending reconnect timeout — connection succeeded
        reconnectTimeoutWork?.cancel()
        reconnectTimeoutWork = nil

        // Flush queued messages
        let queued = pendingMessages
        pendingMessages.removeAll()
        if !queued.isEmpty {
            ghostLog("[SignalingClient] flushing \(queued.count) queued messages")
        }
        for msg in queued {
            send(msg)
        }

        // Handle reconnection: send rejoin on successful open
        if let rejoin = pendingRejoin {
            ghostLog("[SignalingClient] reconnected, rejoining room")
            pendingRejoin = nil
            reconnectAttempts = 0
            isReconnecting = false
            rejoinRoom(rejoin.roomId, role: rejoin.isHost ? "host" : "guest")
        }

        onConnected?()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        ghostLog("[SignalingClient] WebSocket closed, code=\(closeCode.rawValue)")
        isOpen = false
        onDisconnected?()
    }

    /// M1: Certificate pinning — validate server certificate's public key
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        CertificatePinning.handleChallenge(challenge, completionHandler: completionHandler)
    }
}
