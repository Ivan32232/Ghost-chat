import Foundation
import SQLCipher

/// CRUD для сообщений (Ghost Threads) — SQLCipher
final class MessageStore {

    private let db: DatabaseService

    init(db: DatabaseService = .shared) {
        self.db = db
    }

    // MARK: - Save

    func save(_ message: ChatMessage) throws {
        try db.executeSync {
            let stmt = try self.db.prepare("""
                INSERT OR REPLACE INTO messages
                (id, contactId, text, type, isDelivered, isPending, createdAt,
                 fileName, fileSize, fileMimeType, fileLocalPath, fileId,
                 replyToId, replyToText, isEdited, senderMessageId)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(stmt) }

            let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

            let idStr = message.id.uuidString
            sqlite3_bind_text(stmt, 1, idStr, -1, TRANSIENT)
            guard let contactId = message.contactId else { throw DatabaseError.executeFailed(0, "No contactId") }
            sqlite3_bind_text(stmt, 2, contactId, -1, TRANSIENT)
            sqlite3_bind_text(stmt, 3, message.text, -1, TRANSIENT)
            sqlite3_bind_int(stmt, 4, Int32(message.type.rawValue))
            sqlite3_bind_int(stmt, 5, message.isDelivered ? 1 : 0)
            sqlite3_bind_int(stmt, 6, message.isPending ? 1 : 0)
            sqlite3_bind_double(stmt, 7, message.timestamp.timeIntervalSince1970)

            // File attachment columns (8-12)
            Self.bindOptionalText(stmt, 8, message.fileName)
            if let val = message.fileSize { sqlite3_bind_int64(stmt, 9, val) } else { sqlite3_bind_null(stmt, 9) }
            Self.bindOptionalText(stmt, 10, message.fileMimeType)
            Self.bindOptionalText(stmt, 11, message.fileLocalPath)
            Self.bindOptionalText(stmt, 12, message.fileId)

            // Reply + edit columns (13-16)
            Self.bindOptionalText(stmt, 13, message.replyToId)
            Self.bindOptionalText(stmt, 14, message.replyToText)
            sqlite3_bind_int(stmt, 15, message.isEdited ? 1 : 0)
            Self.bindOptionalText(stmt, 16, message.senderMessageId)

            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else {
                throw DatabaseError.executeFailed(rc, "Failed to save message")
            }
        }
    }

    private static func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let val = value {
            sqlite3_bind_text(stmt, index, val, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    // MARK: - Fetch

    func fetchForContact(_ contactId: String, limit: Int = 100, offset: Int = 0) throws -> [ChatMessage] {
        try db.executeSync {
            let stmt = try self.db.prepare("""
                SELECT id, contactId, text, type, isDelivered, isPending, createdAt,
                       fileName, fileSize, fileMimeType, fileLocalPath, fileId,
                       replyToId, replyToText, isEdited, senderMessageId
                FROM messages
                WHERE contactId = ?
                ORDER BY createdAt ASC
                LIMIT ? OFFSET ?;
            """)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, contactId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int(stmt, 2, Int32(limit))
            sqlite3_bind_int(stmt, 3, Int32(offset))

            var messages: [ChatMessage] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let msg = self.rowToMessage(stmt) {
                    messages.append(msg)
                }
            }
            return messages
        }
    }

    /// Последнее сообщение для контакта (для превью в списке)
    func fetchLastMessage(for contactId: String) throws -> ChatMessage? {
        try db.executeSync {
            let stmt = try self.db.prepare("""
                SELECT id, contactId, text, type, isDelivered, isPending, createdAt,
                       fileName, fileSize, fileMimeType, fileLocalPath, fileId,
                       replyToId, replyToText, isEdited, senderMessageId
                FROM messages
                WHERE contactId = ?
                ORDER BY createdAt DESC
                LIMIT 1;
            """)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, contactId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            if sqlite3_step(stmt) == SQLITE_ROW {
                return self.rowToMessage(stmt)
            }
            return nil
        }
    }

    /// Количество непрочитанных (received + not delivered)
    func countUnread(for contactId: String) throws -> Int {
        try db.executeSync {
            let stmt = try self.db.prepare("""
                SELECT COUNT(*) FROM messages
                WHERE contactId = ? AND type = 1 AND isDelivered = 0;
            """)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, contactId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            if sqlite3_step(stmt) == SQLITE_ROW {
                return Int(sqlite3_column_int(stmt, 0))
            }
            return 0
        }
    }

    /// Pending сообщения для отправки при подключении
    func fetchPending(for contactId: String) throws -> [ChatMessage] {
        try db.executeSync {
            let stmt = try self.db.prepare("""
                SELECT id, contactId, text, type, isDelivered, isPending, createdAt,
                       fileName, fileSize, fileMimeType, fileLocalPath, fileId,
                       replyToId, replyToText, isEdited, senderMessageId
                FROM messages
                WHERE contactId = ? AND isPending = 1
                ORDER BY createdAt ASC;
            """)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, contactId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            var messages: [ChatMessage] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let msg = self.rowToMessage(stmt) {
                    messages.append(msg)
                }
            }
            return messages
        }
    }

    // MARK: - Update

    func markDelivered(_ messageId: UUID) throws {
        let idStr = messageId.uuidString
        try db.executeSync {
            let stmt = try self.db.prepare("UPDATE messages SET isDelivered = 1 WHERE id = ?;")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, idStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_step(stmt)
        }
    }

    func markSent(_ messageId: UUID) throws {
        let idStr = messageId.uuidString
        try db.executeSync {
            let stmt = try self.db.prepare("UPDATE messages SET isPending = 0 WHERE id = ?;")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, idStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_step(stmt)
        }
    }

    /// Mark all received messages for a contact as delivered (clears unread count)
    func markAllDelivered(for contactId: String) throws {
        try db.executeSync {
            let stmt = try self.db.prepare("UPDATE messages SET isDelivered = 1 WHERE contactId = ? AND type = 1 AND isDelivered = 0;")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, contactId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_step(stmt)
        }
    }

    // MARK: - Delete

    func deleteForContact(_ contactId: String) throws {
        try db.executeSync {
            let stmt = try db.prepare("DELETE FROM messages WHERE contactId = ?;")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, contactId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_step(stmt)
        }
    }

    func deleteOlderThan(_ date: Date) throws {
        try db.executeSync {
            let stmt = try db.prepare("DELETE FROM messages WHERE createdAt < ?;")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    /// Delete expired messages for a specific contact based on TTL (seconds)
    func deleteExpired(contactId: String, ttlSeconds: Int) throws {
        try db.executeSync {
            let cutoff = Date().timeIntervalSince1970 - Double(ttlSeconds)
            let stmt = try db.prepare("DELETE FROM messages WHERE contactId = ? AND createdAt < ?;")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, contactId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_double(stmt, 2, cutoff)
            sqlite3_step(stmt)
        }
    }

    func deleteAll() throws {
        try db.execute("DELETE FROM messages;")
    }

    // MARK: - Private

    private func rowToMessage(_ stmt: OpaquePointer) -> ChatMessage? {
        guard let idCStr = sqlite3_column_text(stmt, 0),
              let contactIdCStr = sqlite3_column_text(stmt, 1),
              let textCStr = sqlite3_column_text(stmt, 2) else {
            return nil
        }

        let idStr = String(cString: idCStr)
        let contactId = String(cString: contactIdCStr)
        let text = String(cString: textCStr)
        let typeRaw = Int(sqlite3_column_int(stmt, 3))
        let isDelivered = sqlite3_column_int(stmt, 4) != 0
        let isPending = sqlite3_column_int(stmt, 5) != 0
        let createdAt = sqlite3_column_double(stmt, 6)

        // File attachment columns (7-11)
        let fileName: String? = sqlite3_column_type(stmt, 7) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 7))
            : nil
        let fileSize: Int64? = sqlite3_column_type(stmt, 8) != SQLITE_NULL
            ? sqlite3_column_int64(stmt, 8)
            : nil
        let fileMimeType: String? = sqlite3_column_type(stmt, 9) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 9))
            : nil
        let fileLocalPath: String? = sqlite3_column_type(stmt, 10) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 10))
            : nil
        let fileId: String? = sqlite3_column_type(stmt, 11) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 11))
            : nil

        // Reply + edit columns (12-15)
        let replyToId: String? = sqlite3_column_type(stmt, 12) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 12))
            : nil
        let replyToText: String? = sqlite3_column_type(stmt, 13) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 13))
            : nil
        let isEdited = sqlite3_column_int(stmt, 14) != 0
        let senderMessageId: String? = sqlite3_column_type(stmt, 15) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 15))
            : nil

        guard let id = UUID(uuidString: idStr) else { return nil }
        let type = ChatMessage.MessageType(rawValue: typeRaw) ?? .system

        return ChatMessage(
            id: id,
            contactId: contactId,
            text: text,
            type: type,
            timestamp: Date(timeIntervalSince1970: createdAt),
            isDelivered: isDelivered,
            isPending: isPending,
            replyToId: replyToId,
            replyToText: replyToText,
            isEdited: isEdited,
            senderMessageId: senderMessageId,
            fileName: fileName,
            fileSize: fileSize,
            fileMimeType: fileMimeType,
            fileLocalPath: fileLocalPath,
            fileId: fileId
        )
    }

    // MARK: - Delete by sender message ID (for "delete for everyone")

    func deleteBySenderMessageId(_ senderMessageId: String) throws {
        try db.executeSync {
            let stmt = try db.prepare("DELETE FROM messages WHERE senderMessageId = ?;")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, senderMessageId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_step(stmt)
        }
    }

    // MARK: - Update text (for "edit message")

    func updateText(senderMessageId: String, newText: String) throws {
        try db.executeSync {
            let stmt = try db.prepare("UPDATE messages SET text = ?, isEdited = 1 WHERE senderMessageId = ?;")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, newText, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, senderMessageId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_step(stmt)
        }
    }
}
