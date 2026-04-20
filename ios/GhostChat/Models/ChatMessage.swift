import Foundation

struct ChatMessage: Codable, Equatable, Identifiable, Hashable {
    let id: String
    var contactId: String
    var sender: Sender
    var text: String
    var type: MessageType
    var isDelivered: Bool
    var isPending: Bool
    let createdAt: Date
    var fileName: String?
    var fileSize: Int?
    var fileMimeType: String?
    var fileLocalPath: String?
    var fileId: String?
    var replyToId: String?
    var replyToText: String?
    var isEdited: Bool
    var senderMessageId: String?
    var isPinned: Bool

    init(
        id: String = UUID().uuidString,
        contactId: String = "",
        sender: Sender,
        text: String,
        type: MessageType = .text,
        isDelivered: Bool = false,
        isPending: Bool = true,
        createdAt: Date = Date(),
        fileName: String? = nil,
        fileSize: Int? = nil,
        fileMimeType: String? = nil,
        fileLocalPath: String? = nil,
        fileId: String? = nil,
        replyToId: String? = nil,
        replyToText: String? = nil,
        isEdited: Bool = false,
        senderMessageId: String? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.contactId = contactId
        self.sender = sender
        self.text = text
        self.type = type
        self.isDelivered = isDelivered
        self.isPending = isPending
        self.createdAt = createdAt
        self.fileName = fileName
        self.fileSize = fileSize
        self.fileMimeType = fileMimeType
        self.fileLocalPath = fileLocalPath
        self.fileId = fileId
        self.replyToId = replyToId
        self.replyToText = replyToText
        self.isEdited = isEdited
        self.senderMessageId = senderMessageId
        self.isPinned = isPinned
    }

    /// Wire payload used over encrypted DataChannel: matches SPEC
    /// `{ "m": string, "t": unix_ms, "c": counter, "id": uuid, "r"?: {"id","t"} }`
    struct WirePayload: Codable, Equatable {
        var m: String
        var t: Int64
        var c: UInt64
        var id: String
        var r: Reply?

        struct Reply: Codable, Equatable {
            var id: String
            var t: String
        }
    }
}
