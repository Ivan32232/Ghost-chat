import Foundation

/// WebSocket клиент для signaling сервера — порт connectWebSocket() + handleSignalingMessage()
/// Протокол полностью совместим с server/index.js
final class SignalingClient: NSObject {

    // MARK: - Properties

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let serverURL: URL

    private var isReconnecting = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 10

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
        webSocket = session.webSocketTask(with: wsURL)
        webSocket?.resume()

        listenForMessages()
        onConnected?()
    }

    func disconnect() {
        isReconnecting = false
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    // MARK: - Send Messages

    func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }

        webSocket?.send(.string(text)) { error in
            if let error {
                print("[SignalingClient] Send error: \(error)")
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
                print("[SignalingClient] Receive error: \(error)")
                self.onDisconnected?()
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

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
        guard !isReconnecting else { return }
        isReconnecting = true
        reconnectAttempts = 0

        attemptReconnect(roomId: roomId, isHost: isHost)
    }

    private func attemptReconnect(roomId: String, isHost: Bool) {
        guard isReconnecting else { return }

        reconnectAttempts += 1
        if reconnectAttempts > maxReconnectAttempts {
            isReconnecting = false
            onError?("Не удалось переподключиться")
            return
        }

        // Exponential backoff: 1s, 2s, 4s, 8s... max 30s
        let delay = min(pow(2.0, Double(reconnectAttempts - 1)), 30.0)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isReconnecting else { return }

            self.disconnect()

            let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
            self.urlSession = session

            var components = URLComponents(url: self.serverURL, resolvingAgainstBaseURL: false)!
            components.scheme = self.serverURL.scheme == "https" ? "wss" : "ws"
            components.path = "/ws"

            let ws = session.webSocketTask(with: components.url!)
            self.webSocket = ws
            ws.resume()

            // Слушаем сообщения
            self.listenForMessages()

            // Отправляем rejoin
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                if ws.state == .running {
                    self.reconnectAttempts = 0
                    self.isReconnecting = false
                    self.rejoinRoom(roomId, role: isHost ? "host" : "guest")
                } else {
                    self.attemptReconnect(roomId: roomId, isHost: isHost)
                }
            }
        }
    }

    var isConnected: Bool {
        webSocket?.state == .running
    }
}

// MARK: - URLSessionWebSocketDelegate

extension SignalingClient: URLSessionWebSocketDelegate {

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        // WebSocket connected
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        onDisconnected?()
    }
}
