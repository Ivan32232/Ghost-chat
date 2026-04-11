import Foundation

/// Contact model for persistent storage (SQLCipher)
/// Хранит identity key собеседника и опционально состояние Double Ratchet
struct Contact: Identifiable, Codable, Equatable {
    let id: UUID
    var label: String
    var publicKey: Data             // Ephemeral DH key from last session
    var identityKey: Data           // Peer's static P-256 identity key (65 bytes x963)
    var ratchetState: Data?         // JSON-encoded DoubleRatchetState blob
    var previousKey: Data?
    var fallbackKey: Data?
    var pushToken: Data?
    var notifyToken: Data?          // Regular APNs token for chat invites
    var rotationCounter: Int
    var notes: String?              // User-added notes about this contact
    var messageTTL: Int?            // Per-contact message TTL in seconds (nil = global setting)
    var sessionCount: Int           // Number of sessions with this contact
    let createdAt: Date
    var lastSessionAt: Date?

    static func == (lhs: Contact, rhs: Contact) -> Bool {
        lhs.id == rhs.id
    }

    init(
        id: UUID = UUID(),
        label: String,
        publicKey: Data,
        identityKey: Data? = nil,
        ratchetState: Data? = nil,
        previousKey: Data? = nil,
        fallbackKey: Data? = nil,
        pushToken: Data? = nil,
        notifyToken: Data? = nil,
        notes: String? = nil,
        messageTTL: Int? = nil,
        rotationCounter: Int = 0,
        sessionCount: Int = 0,
        createdAt: Date = Date(),
        lastSessionAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.publicKey = publicKey
        self.identityKey = identityKey ?? publicKey
        self.ratchetState = ratchetState
        self.previousKey = previousKey
        self.fallbackKey = fallbackKey
        self.pushToken = pushToken
        self.notifyToken = notifyToken
        self.notes = notes
        self.messageTTL = messageTTL
        self.rotationCounter = rotationCounter
        self.sessionCount = sessionCount
        self.createdAt = createdAt
        self.lastSessionAt = lastSessionAt
    }
}
