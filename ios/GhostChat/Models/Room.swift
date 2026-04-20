import Foundation

struct Room: Codable, Equatable, Identifiable {
    let id: String
    let createdAt: Date
    let myRole: Role

    init(id: String, createdAt: Date = Date(), myRole: Role) {
        self.id = id
        self.createdAt = createdAt
        self.myRole = myRole
    }

    /// base64url, 64 chars → 48 raw bytes → 384 bits of entropy
    static func isValidID(_ candidate: String) -> Bool {
        guard candidate.count == 64 else { return false }
        return candidate.allSatisfy { ch in
            ch.isLetter || ch.isNumber || ch == "-" || ch == "_"
        }
    }
}
