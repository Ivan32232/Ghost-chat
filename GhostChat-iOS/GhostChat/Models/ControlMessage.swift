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
        default:
            return nil
        }
    }

    /// Сериализация для отправки
    func toJSON() -> [String: Any] {
        switch self {
        case .renegotiate(let sdp):
            return ["type": "renegotiate", "sdp": sdp]
        case .callRequest:
            return ["type": "call-request"]
        case .callResponse(let accepted):
            return ["type": "call-response", "accepted": accepted]
        case .callEnd:
            return ["type": "call-end"]
        case .callSecurityAlert(let alert):
            return ["type": "call-security-alert", "alert": alert]
        case .securityAlert(let alert):
            return ["type": "security-alert", "alert": alert]
        case .messageAck(let counter):
            return ["type": "message-ack", "c": counter]
        }
    }
}
