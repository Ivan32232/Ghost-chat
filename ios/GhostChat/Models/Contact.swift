import Foundation

struct Contact: Codable, Equatable, Identifiable {
    let id: String
    var label: String
    var identityKey: Data
    var publicKey: Data
    var previousKey: Data?
    var fallbackKey: Data?
    var pushToken: Data?
    var notifyToken: Data?
    var ratchetState: Data?
    var rotationCounter: Int
    var sessionCount: Int
    var messageTTL: Int
    var notes: String?
    var isMuted: Bool
    let createdAt: Date
    var lastSessionAt: Date?

    init(
        id: String = UUID().uuidString,
        label: String,
        identityKey: Data,
        publicKey: Data,
        previousKey: Data? = nil,
        fallbackKey: Data? = nil,
        pushToken: Data? = nil,
        notifyToken: Data? = nil,
        ratchetState: Data? = nil,
        rotationCounter: Int = 0,
        sessionCount: Int = 0,
        messageTTL: Int = MessageTTL.fiveMinutes.rawValue,
        notes: String? = nil,
        isMuted: Bool = false,
        createdAt: Date = Date(),
        lastSessionAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.identityKey = identityKey
        self.publicKey = publicKey
        self.previousKey = previousKey
        self.fallbackKey = fallbackKey
        self.pushToken = pushToken
        self.notifyToken = notifyToken
        self.ratchetState = ratchetState
        self.rotationCounter = rotationCounter
        self.sessionCount = sessionCount
        self.messageTTL = messageTTL
        self.notes = notes
        self.isMuted = isMuted
        self.createdAt = createdAt
        self.lastSessionAt = lastSessionAt
    }
}
