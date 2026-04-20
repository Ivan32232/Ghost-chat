import Foundation
import GRDB

extension ChatMessage: FetchableRecord, PersistableRecord {
    static let databaseTableName = "messages"

    enum Columns {
        static let id = Column("id")
        static let contactId = Column("contactId")
        static let sender = Column("sender")
        static let createdAt = Column("createdAt")
        static let isPinned = Column("isPinned")
    }
}

struct SkippedKey: Codable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "skippedKeys"

    let contactId: String
    let dhPublicKey: Data
    let messageNumber: Int
    let messageKey: Data
    let createdAt: Date
}

final class MessageStore {

    private let dbQueue: DatabaseQueue

    init(database: DatabaseService) {
        self.dbQueue = database.dbQueue
    }

    // MARK: - Messages

    func append(_ message: ChatMessage) throws {
        try dbQueue.write { db in try message.save(db) }
    }

    func fetch(contactId: String, limit: Int = 500) throws -> [ChatMessage] {
        try dbQueue.read { db in
            try ChatMessage
                .filter(ChatMessage.Columns.contactId == contactId)
                .order(ChatMessage.Columns.createdAt.asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func deleteMessage(id: String) throws {
        _ = try dbQueue.write { db in try ChatMessage.deleteOne(db, key: id) }
    }

    func deleteAll(forContact contactId: String) throws {
        _ = try dbQueue.write { db in
            try ChatMessage
                .filter(ChatMessage.Columns.contactId == contactId)
                .deleteAll(db)
        }
    }

    func pinnedMessages(forContact contactId: String) throws -> [ChatMessage] {
        try dbQueue.read { db in
            try ChatMessage
                .filter(ChatMessage.Columns.contactId == contactId &&
                        ChatMessage.Columns.isPinned == true)
                .order(ChatMessage.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    // MARK: - Skipped keys

    func storeSkipped(_ key: SkippedKey) throws {
        try dbQueue.write { db in try key.save(db) }
    }

    func takeSkipped(contactId: String, dhPublicKey: Data, messageNumber: Int) throws -> SkippedKey? {
        try dbQueue.write { db in
            let row = try SkippedKey
                .filter(Column("contactId") == contactId)
                .filter(Column("dhPublicKey") == dhPublicKey)
                .filter(Column("messageNumber") == messageNumber)
                .fetchOne(db)
            if row != nil {
                try db.execute(
                    sql: "DELETE FROM skippedKeys WHERE contactId = ? AND dhPublicKey = ? AND messageNumber = ?",
                    arguments: [contactId, dhPublicKey, messageNumber]
                )
            }
            return row
        }
    }

    /// Delete skippedKeys older than 24 hours (run opportunistically at app launch).
    func pruneSkipped(olderThan: TimeInterval = 86_400, now: Date = Date()) throws {
        let cutoff = now.addingTimeInterval(-olderThan)
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM skippedKeys WHERE createdAt < ?",
                arguments: [cutoff]
            )
        }
    }
}
