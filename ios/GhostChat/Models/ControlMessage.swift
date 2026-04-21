import Foundation

/// Application-level control messages sent over the encrypted DataChannel.
/// Wire format: `{ "_ctrl": true, "type": "<type>", <payload-fields...> }`.
/// Must remain byte-for-byte compatible with Android counterpart.
enum ControlMessage: Equatable {
    case renegotiate(sdp: String)
    case callRequest
    case callResponse(accepted: Bool)
    case callEnd
    case securityAlert(alert: String)
    case messageAck(counter: UInt64)
    case messageRead(counter: UInt64)
    case ready
    case pushToken(token: String)
    case notifyToken(token: String)
    case typing(isTyping: Bool)
    case capabilities(features: [String])
    case fileStart(fileId: String, name: String, size: Int, mimeType: String, totalChunks: Int)
    case fileChunk(fileId: String, index: Int, data: String)
    case fileComplete(fileId: String, sha256: String)
    case fileRetransmit(fileId: String, indices: [Int])
    case messageDelete(messageId: String)
    case messageEdit(messageId: String, newText: String)
    case messagePin(messageId: String, pinned: Bool)
}

extension ControlMessage {
    enum DecodingError: Error, Equatable {
        case missingCtrlMarker
        case unknownType(String)
    }

    /// Wire tag for each case. Keep in sync with Android `ControlMessageType`.
    var wireType: String {
        switch self {
        case .renegotiate:      return "renegotiate"
        case .callRequest:      return "call-request"
        case .callResponse:     return "call-response"
        case .callEnd:          return "call-end"
        case .securityAlert:    return "security-alert"
        case .messageAck:       return "message-ack"
        case .messageRead:      return "message-read"
        case .ready:            return "ready"
        case .pushToken:        return "push-token"
        case .notifyToken:      return "notify-token"
        case .typing:           return "typing"
        case .capabilities:     return "capabilities"
        case .fileStart:        return "file-start"
        case .fileChunk:        return "file-chunk"
        case .fileComplete:     return "file-complete"
        case .fileRetransmit:   return "file-retransmit"
        case .messageDelete:    return "message-delete"
        case .messageEdit:      return "message-edit"
        case .messagePin:       return "message-pin"
        }
    }
}

extension ControlMessage: Codable {
    private enum Keys: String, CodingKey {
        case ctrl = "_ctrl"
        case type
        case sdp, accepted, alert, c, token, isTyping, features
        case fileId, name, size, mimeType, totalChunks
        case index, data, indices, sha256
        case messageId, newText, pinned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let isCtrl = (try? c.decode(Bool.self, forKey: .ctrl)) ?? false
        guard isCtrl else { throw DecodingError.missingCtrlMarker }
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "renegotiate":
            self = .renegotiate(sdp: try c.decode(String.self, forKey: .sdp))
        case "call-request":
            self = .callRequest
        case "call-response":
            self = .callResponse(accepted: try c.decode(Bool.self, forKey: .accepted))
        case "call-end":
            self = .callEnd
        case "security-alert":
            self = .securityAlert(alert: try c.decode(String.self, forKey: .alert))
        case "message-ack":
            self = .messageAck(counter: try c.decode(UInt64.self, forKey: .c))
        case "message-read":
            self = .messageRead(counter: try c.decode(UInt64.self, forKey: .c))
        case "ready":
            self = .ready
        case "push-token":
            self = .pushToken(token: try c.decode(String.self, forKey: .token))
        case "notify-token":
            self = .notifyToken(token: try c.decode(String.self, forKey: .token))
        case "typing":
            self = .typing(isTyping: try c.decode(Bool.self, forKey: .isTyping))
        case "capabilities":
            self = .capabilities(features: try c.decode([String].self, forKey: .features))
        case "file-start":
            self = .fileStart(
                fileId:      try c.decode(String.self, forKey: .fileId),
                name:        try c.decode(String.self, forKey: .name),
                size:        try c.decode(Int.self,    forKey: .size),
                mimeType:    try c.decode(String.self, forKey: .mimeType),
                totalChunks: try c.decode(Int.self,    forKey: .totalChunks)
            )
        case "file-chunk":
            self = .fileChunk(
                fileId: try c.decode(String.self, forKey: .fileId),
                index:  try c.decode(Int.self,    forKey: .index),
                data:   try c.decode(String.self, forKey: .data)
            )
        case "file-complete":
            self = .fileComplete(
                fileId: try c.decode(String.self, forKey: .fileId),
                sha256: try c.decode(String.self, forKey: .sha256)
            )
        case "file-retransmit":
            self = .fileRetransmit(
                fileId:  try c.decode(String.self, forKey: .fileId),
                indices: try c.decode([Int].self,  forKey: .indices)
            )
        case "message-delete":
            self = .messageDelete(messageId: try c.decode(String.self, forKey: .messageId))
        case "message-edit":
            self = .messageEdit(
                messageId: try c.decode(String.self, forKey: .messageId),
                newText:   try c.decode(String.self, forKey: .newText)
            )
        case "message-pin":
            self = .messagePin(
                messageId: try c.decode(String.self, forKey: .messageId),
                pinned:    try c.decode(Bool.self,   forKey: .pinned)
            )
        default:
            throw DecodingError.unknownType(type)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(true, forKey: .ctrl)
        try c.encode(wireType, forKey: .type)
        switch self {
        case .renegotiate(let sdp):
            try c.encode(sdp, forKey: .sdp)
        case .callRequest, .callEnd, .ready:
            break
        case .callResponse(let accepted):
            try c.encode(accepted, forKey: .accepted)
        case .securityAlert(let alert):
            try c.encode(alert, forKey: .alert)
        case .messageAck(let counter), .messageRead(let counter):
            try c.encode(counter, forKey: .c)
        case .pushToken(let token), .notifyToken(let token):
            try c.encode(token, forKey: .token)
        case .typing(let isTyping):
            try c.encode(isTyping, forKey: .isTyping)
        case .capabilities(let features):
            try c.encode(features, forKey: .features)
        case .fileStart(let fileId, let name, let size, let mimeType, let totalChunks):
            try c.encode(fileId,      forKey: .fileId)
            try c.encode(name,        forKey: .name)
            try c.encode(size,        forKey: .size)
            try c.encode(mimeType,    forKey: .mimeType)
            try c.encode(totalChunks, forKey: .totalChunks)
        case .fileChunk(let fileId, let index, let data):
            try c.encode(fileId, forKey: .fileId)
            try c.encode(index,  forKey: .index)
            try c.encode(data,   forKey: .data)
        case .fileComplete(let fileId, let sha256):
            try c.encode(fileId, forKey: .fileId)
            try c.encode(sha256, forKey: .sha256)
        case .fileRetransmit(let fileId, let indices):
            try c.encode(fileId,  forKey: .fileId)
            try c.encode(indices, forKey: .indices)
        case .messageDelete(let messageId):
            try c.encode(messageId, forKey: .messageId)
        case .messageEdit(let messageId, let newText):
            try c.encode(messageId, forKey: .messageId)
            try c.encode(newText,   forKey: .newText)
        case .messagePin(let messageId, let pinned):
            try c.encode(messageId, forKey: .messageId)
            try c.encode(pinned,    forKey: .pinned)
        }
    }
}
