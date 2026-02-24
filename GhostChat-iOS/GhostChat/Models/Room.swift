import Foundation

/// Состояние комнаты
struct Room {
    let id: String
    let isHost: Bool
    let createdAt: Date

    var isExpired: Bool {
        Date().timeIntervalSince(createdAt) > 10 * 60 // 10 минут TTL
    }
}
