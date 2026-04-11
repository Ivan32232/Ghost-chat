import Foundation

/// Сообщение в чате (Ghost Threads — persistent + ephemeral)
struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let contactId: String?       // nil = legacy/anonymous session
    let text: String
    let type: MessageType
    let timestamp: Date
    var isDelivered: Bool
    var isRead: Bool
    var isPending: Bool

    /// Время до автоудаления (nil = persistent, no auto-delete)
    var expiresAt: Date?

    // Reply (Telegram-style inline quote)
    var replyToId: String?          // sender's message UUID that this replies to
    var replyToText: String?        // quoted text preview (truncated)

    // Edit
    var isEdited: Bool

    // Sender's message ID (for cross-device delete/edit correlation)
    var senderMessageId: String?

    // File attachment (nil = text-only message)
    var fileName: String?
    var fileSize: Int64?
    var fileMimeType: String?
    var fileLocalPath: String?      // relative path inside app's Documents/files/
    var fileTransferProgress: Double?  // 0.0–1.0 during transfer, nil when done
    var fileId: String?             // unique ID for chunked transfer correlation

    var isFileMessage: Bool { fileName != nil }

    enum MessageType: Int {
        case sent = 0
        case received = 1
        case system = 2
    }

    /// Legacy init (without contactId — current session behavior)
    init(text: String, type: MessageType, autoDeleteInterval: TimeInterval = 5 * 60) {
        self.id = UUID()
        self.contactId = nil
        self.text = text
        self.type = type
        self.timestamp = Date()
        self.isDelivered = false
        self.isRead = false
        self.isPending = false
        self.expiresAt = autoDeleteInterval > 0 ? Date().addingTimeInterval(autoDeleteInterval) : nil
        self.replyToId = nil
        self.replyToText = nil
        self.isEdited = false
        self.senderMessageId = nil
    }

    /// Full init for DB persistence
    init(
        id: UUID = UUID(),
        contactId: String?,
        text: String,
        type: MessageType,
        timestamp: Date = Date(),
        isDelivered: Bool = false,
        isRead: Bool = false,
        isPending: Bool = false,
        expiresAt: Date? = nil,
        replyToId: String? = nil,
        replyToText: String? = nil,
        isEdited: Bool = false,
        senderMessageId: String? = nil,
        fileName: String? = nil,
        fileSize: Int64? = nil,
        fileMimeType: String? = nil,
        fileLocalPath: String? = nil,
        fileTransferProgress: Double? = nil,
        fileId: String? = nil
    ) {
        self.id = id
        self.contactId = contactId
        self.text = text
        self.type = type
        self.timestamp = timestamp
        self.isDelivered = isDelivered
        self.isRead = isRead
        self.isPending = isPending
        self.expiresAt = expiresAt
        self.replyToId = replyToId
        self.replyToText = replyToText
        self.isEdited = isEdited
        self.senderMessageId = senderMessageId
        self.fileName = fileName
        self.fileSize = fileSize
        self.fileMimeType = fileMimeType
        self.fileLocalPath = fileLocalPath
        self.fileTransferProgress = fileTransferProgress
        self.fileId = fileId
    }

    /// Оставшееся время до удаления
    var remainingTime: TimeInterval {
        guard let expiresAt else { return .infinity }
        return max(0, expiresAt.timeIntervalSinceNow)
    }

    var remainingTimeFormatted: String {
        guard expiresAt != nil else { return "" }
        let remaining = Int(remainingTime)
        let minutes = remaining / 60
        let seconds = remaining % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow <= 0
    }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        // Compare all mutable fields so SwiftUI re-renders when properties change
        // (fileLocalPath, fileTransferProgress, isDelivered, isRead, etc.)
        lhs.id == rhs.id
        && lhs.text == rhs.text
        && lhs.isDelivered == rhs.isDelivered
        && lhs.isRead == rhs.isRead
        && lhs.isPending == rhs.isPending
        && lhs.fileLocalPath == rhs.fileLocalPath
        && lhs.fileTransferProgress == rhs.fileTransferProgress
        && lhs.isEdited == rhs.isEdited
        && lhs.expiresAt == rhs.expiresAt
    }
}
