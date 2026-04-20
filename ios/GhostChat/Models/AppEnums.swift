import Foundation

enum ConnectionState: String, Codable, Equatable {
    case disconnected
    case connecting
    case signaling
    case webRTC
    case connected
    case encrypted
}

enum CallState: String, Codable, Equatable {
    case idle
    case outgoingPending
    case outgoingRinging
    case incoming
    case active
    case ended
}

enum Role: String, Codable, Equatable {
    case host
    case guest
}

enum Sender: Int, Codable, Equatable {
    case me = 0
    case peer = 1
    case system = 2
}

enum MessageType: Int, Codable, Equatable {
    case text = 0
    case file = 1
    case voice = 2
    case system = 3
}

enum MessageTTL: Int, Codable, CaseIterable, Identifiable {
    case thirtySeconds = 30
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case oneHour = 3600

    var id: Int { rawValue }

    var localizedKey: String {
        switch self {
        case .thirtySeconds:   return "ttl.thirty_seconds"
        case .oneMinute:       return "ttl.one_minute"
        case .fiveMinutes:     return "ttl.five_minutes"
        case .fifteenMinutes:  return "ttl.fifteen_minutes"
        case .oneHour:         return "ttl.one_hour"
        }
    }
}

enum AutoLockTimeout: Int, Codable, CaseIterable, Identifiable {
    case immediate = 0
    case thirtySeconds = 30
    case oneMinute = 60
    case fiveMinutes = 300
    case thirtyMinutes = 1800

    var id: Int { rawValue }
}
