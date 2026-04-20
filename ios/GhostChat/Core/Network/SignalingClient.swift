import Foundation

/// High-level event emitted by the signaling server over WebSocket.
enum SignalingEvent: Equatable {
    case connected
    case roomCreated(roomId: String)
    case roomJoined(roomId: String)
    case rejoinOk
    case peerJoined
    case peerLeft
    case signal(rawJSON: Data)
    case error(message: String)
    case disconnected
}

/// Thin wrapper around `URLSessionWebSocketTask` targeting the Ghost Chat signaling endpoint.
///
/// Owns one WebSocket connection, performs framing + JSON parse, surfaces `SignalingEvent`s
/// via an `AsyncStream`. No reconnect policy here — that belongs in `ConnectionManager`.
final class SignalingClient: NSObject {

    enum Error: Swift.Error, Equatable {
        case notConnected
        case encodingFailed
    }

    private let url: URL
    private let pinning: CertificatePinning
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var continuation: AsyncStream<SignalingEvent>.Continuation?

    let events: AsyncStream<SignalingEvent>

    init(url: URL, pinning: CertificatePinning = CertificatePinning()) {
        self.url = url
        self.pinning = pinning
        var cont: AsyncStream<SignalingEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        super.init()
        self.continuation = cont
    }

    // MARK: - Lifecycle

    func connect() {
        guard task == nil else { return }
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        let sess = URLSession(configuration: config, delegate: pinning, delegateQueue: nil)
        let newTask = sess.webSocketTask(with: url)
        newTask.resume()
        self.session = sess
        self.task = newTask
        continuation?.yield(.connected)
        receiveLoop()
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        continuation?.yield(.disconnected)
    }

    // MARK: - Outgoing

    func createRoom() throws {
        try send(["type": "create-room"])
    }

    func joinRoom(_ roomId: String) throws {
        try send(["type": "join-room", "roomId": roomId])
    }

    func rejoinRoom(_ roomId: String, role: Role) throws {
        try send(["type": "rejoin-room", "roomId": roomId, "role": role.rawValue])
    }

    func leaveRoom() throws {
        try send(["type": "leave-room"])
    }

    /// Sends a raw signal payload. Caller supplies already-serialized JSON.
    func sendSignal(rawJSON: Data) throws {
        guard let parsed = try? JSONSerialization.jsonObject(with: rawJSON, options: []) else {
            throw Error.encodingFailed
        }
        try send(["type": "signal", "data": parsed])
    }

    private func send(_ object: [String: Any]) throws {
        guard let task else { throw Error.notConnected }
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let string = String(data: data, encoding: .utf8) else {
            throw Error.encodingFailed
        }
        task.send(.string(string)) { [weak self] error in
            if error != nil {
                self?.continuation?.yield(.disconnected)
            }
        }
    }

    // MARK: - Incoming

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handle(message)
                self.receiveLoop()
            case .failure:
                self.continuation?.yield(.disconnected)
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let d):   data = d
        case .string(let s): data = s.data(using: .utf8) ?? Data()
        @unknown default:    return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "room-created":
            if let id = json["roomId"] as? String {
                continuation?.yield(.roomCreated(roomId: id))
            }
        case "room-joined":
            if let id = json["roomId"] as? String {
                continuation?.yield(.roomJoined(roomId: id))
            }
        case "rejoin-ok":
            continuation?.yield(.rejoinOk)
        case "peer-joined":
            continuation?.yield(.peerJoined)
        case "peer-left":
            continuation?.yield(.peerLeft)
        case "signal":
            if let payload = json["data"],
               let raw = try? JSONSerialization.data(withJSONObject: payload, options: []) {
                continuation?.yield(.signal(rawJSON: raw))
            }
        case "error":
            continuation?.yield(.error(message: json["message"] as? String ?? "unknown"))
        default:
            break
        }
    }
}
