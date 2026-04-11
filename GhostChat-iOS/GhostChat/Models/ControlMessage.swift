import Foundation

/// Управляющие сообщения через E2E DataChannel
/// Все типы из app.js handleControlMessage()
enum ControlMessage {
    case renegotiate(sdp: [String: Any])
    case callRequest
    case callResponse(accepted: Bool)
    case callEnd
    case callSecurityAlert(alert: [String: Any])
    case securityAlert(alert: String)
    case messageAck(counter: Int)
    case messageRead(counter: Int)
    case ready
    case pushToken(token: String)
    case notifyToken(token: String)
    case typing(isTyping: Bool)
    case capabilities(features: [String])
    case fileStart(fileId: String, name: String, size: Int64, mimeType: String, totalChunks: Int)
    case fileChunk(fileId: String, index: Int, data: String)
    case fileComplete(fileId: String)
    case roomRotate(roomId: String)
    case messageDelete(messageId: String)
    case messageEdit(messageId: String, newText: String)
    case fileRetransmit(fileId: String, indices: [Int])

    /// Создание из JSON (парсинг входящих)
    static func from(_ json: [String: Any]) -> ControlMessage? {
        guard let type = json["type"] as? String else { return nil }

        switch type {
        case "renegotiate":
            guard let sdp = json["sdp"] as? [String: Any] else { return nil }
            return .renegotiate(sdp: sdp)
        case "call-request":
            return .callRequest
        case "call-response":
            guard let accepted = json["accepted"] as? Bool else { return nil }
            return .callResponse(accepted: accepted)
        case "call-end":
            return .callEnd
        case "call-security-alert":
            guard let alert = json["alert"] as? [String: Any] else { return nil }
            return .callSecurityAlert(alert: alert)
        case "security-alert":
            guard let alert = json["alert"] as? String else { return nil }
            return .securityAlert(alert: alert)
        case "message-ack":
            guard let counter = json["c"] as? Int else { return nil }
            return .messageAck(counter: counter)
        case "message-read":
            guard let counter = json["c"] as? Int else { return nil }
            return .messageRead(counter: counter)
        case "ready":
            return .ready
        case "push-token":
            guard let token = json["token"] as? String else { return nil }
            return .pushToken(token: token)
        case "notify-token":
            guard let token = json["token"] as? String else { return nil }
            return .notifyToken(token: token)
        case "typing":
            guard let isTyping = json["isTyping"] as? Bool else { return nil }
            return .typing(isTyping: isTyping)
        case "capabilities":
            guard let features = json["features"] as? [String] else { return nil }
            return .capabilities(features: features)
        case "file-start":
            guard let fileId = json["fileId"] as? String,
                  let name = json["name"] as? String,
                  let size = json["size"] as? Int64,
                  let mimeType = json["mimeType"] as? String,
                  let totalChunks = json["totalChunks"] as? Int else { return nil }
            return .fileStart(fileId: fileId, name: name, size: size, mimeType: mimeType, totalChunks: totalChunks)
        case "file-chunk":
            guard let fileId = json["fileId"] as? String,
                  let index = json["index"] as? Int,
                  let data = json["data"] as? String else { return nil }
            return .fileChunk(fileId: fileId, index: index, data: data)
        case "file-complete":
            guard let fileId = json["fileId"] as? String else { return nil }
            return .fileComplete(fileId: fileId)
        case "room-rotate":
            guard let roomId = json["roomId"] as? String, !roomId.isEmpty else { return nil }
            return .roomRotate(roomId: roomId)
        case "message-delete":
            guard let messageId = json["messageId"] as? String, !messageId.isEmpty else { return nil }
            return .messageDelete(messageId: messageId)
        case "message-edit":
            guard let messageId = json["messageId"] as? String, !messageId.isEmpty,
                  let newText = json["newText"] as? String else { return nil }
            return .messageEdit(messageId: messageId, newText: newText)
        case "file-retransmit":
            guard let fileId = json["fileId"] as? String,
                  let indices = json["indices"] as? [Int] else { return nil }
            return .fileRetransmit(fileId: fileId, indices: indices)
        default:
            return nil
        }
    }

    /// Сериализация для отправки
    func toJSON() -> [String: Any] {
        var json: [String: Any]
        switch self {
        case .renegotiate(let sdp):
            json = ["type": "renegotiate", "sdp": sdp]
        case .callRequest:
            json = ["type": "call-request"]
        case .callResponse(let accepted):
            json = ["type": "call-response", "accepted": accepted]
        case .callEnd:
            json = ["type": "call-end"]
        case .callSecurityAlert(let alert):
            json = ["type": "call-security-alert", "alert": alert]
        case .securityAlert(let alert):
            json = ["type": "security-alert", "alert": alert]
        case .messageAck(let counter):
            json = ["type": "message-ack", "c": counter]
        case .messageRead(let counter):
            json = ["type": "message-read", "c": counter]
        case .ready:
            json = ["type": "ready"]
        case .pushToken(let token):
            json = ["type": "push-token", "token": token]
        case .notifyToken(let token):
            json = ["type": "notify-token", "token": token]
        case .typing(let isTyping):
            json = ["type": "typing", "isTyping": isTyping]
        case .capabilities(let features):
            json = ["type": "capabilities", "features": features]
        case .fileStart(let fileId, let name, let size, let mimeType, let totalChunks):
            json = ["type": "file-start", "fileId": fileId, "name": name, "size": size, "mimeType": mimeType, "totalChunks": totalChunks]
        case .fileChunk(let fileId, let index, let data):
            json = ["type": "file-chunk", "fileId": fileId, "index": index, "data": data]
        case .fileComplete(let fileId):
            json = ["type": "file-complete", "fileId": fileId]
        case .roomRotate(let roomId):
            json = ["type": "room-rotate", "roomId": roomId]
        case .messageDelete(let messageId):
            json = ["type": "message-delete", "messageId": messageId]
        case .messageEdit(let messageId, let newText):
            json = ["type": "message-edit", "messageId": messageId, "newText": newText]
        case .fileRetransmit(let fileId, let indices):
            json = ["type": "file-retransmit", "fileId": fileId, "indices": indices]
        }
        // Web клиент проверяет _ctrl чтобы отличить control от текста
        json["_ctrl"] = true
        return json
    }
}

// MARK: - Data Hex Utilities

extension Data {
    /// Инициализация из hex-строки (для push token)
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var index = hexString.startIndex
        for _ in 0..<len {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }

    /// Преобразование в hex-строку
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
