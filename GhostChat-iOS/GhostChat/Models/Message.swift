import Foundation

/// Сообщение в чате
struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let type: MessageType
    let timestamp: Date
    var isDelivered: Bool = false

    /// Время до автоудаления
    var expiresAt: Date

    enum MessageType {
        case sent
        case received
        case system
    }

    init(text: String, type: MessageType, autoDeleteInterval: TimeInterval = 5 * 60) {
        self.text = text
        self.type = type
        self.timestamp = Date()
        self.expiresAt = Date().addingTimeInterval(autoDeleteInterval)
    }

    /// Оставшееся время до удаления
    var remainingTime: TimeInterval {
        max(0, expiresAt.timeIntervalSinceNow)
    }

    var remainingTimeFormatted: String {
        let remaining = Int(remainingTime)
        let minutes = remaining / 60
        let seconds = remaining % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var isExpired: Bool {
        remainingTime <= 0
    }
}
