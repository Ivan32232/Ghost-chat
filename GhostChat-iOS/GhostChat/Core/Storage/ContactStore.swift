import Foundation
import SQLCipher

/// CRUD operations for contacts using SQLCipher
final class ContactStore {

    private let db: DatabaseService

    init(db: DatabaseService = .shared) {
        self.db = db
    }

    // MARK: - Create / Update

    func save(_ contact: Contact) throws {
        try db.executeSync {
            let stmt = try self.db.prepare("""
                INSERT OR REPLACE INTO contacts
                (id, label, publicKey, identityKey, ratchetState, previousKey, fallbackKey, pushToken, rotationCounter, sessionCount, createdAt, lastSessionAt, notes, notifyToken, messageTTL)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(stmt) }

            let idStr = contact.id.uuidString
            sqlite3_bind_text(stmt, 1, idStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, contact.label, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            _ = contact.publicKey.withUnsafeBytes { buf in
                sqlite3_bind_blob(stmt, 3, buf.baseAddress, Int32(buf.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            _ = contact.identityKey.withUnsafeBytes { buf in
                sqlite3_bind_blob(stmt, 4, buf.baseAddress, Int32(buf.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }

            if let ratchetState = contact.ratchetState {
                _ = ratchetState.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, 5, buf.baseAddress, Int32(buf.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            } else {
                sqlite3_bind_null(stmt, 5)
            }

            if let prev = contact.previousKey {
                _ = prev.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, 6, buf.baseAddress, Int32(buf.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            } else {
                sqlite3_bind_null(stmt, 6)
            }

            if let fallback = contact.fallbackKey {
                _ = fallback.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, 7, buf.baseAddress, Int32(buf.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            } else {
                sqlite3_bind_null(stmt, 7)
            }

            if let token = contact.pushToken {
                _ = token.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, 8, buf.baseAddress, Int32(buf.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            } else {
                sqlite3_bind_null(stmt, 8)
            }

            sqlite3_bind_int(stmt, 9, Int32(contact.rotationCounter))
            sqlite3_bind_int(stmt, 10, Int32(contact.sessionCount))
            sqlite3_bind_double(stmt, 11, contact.createdAt.timeIntervalSince1970)

            if let lastSession = contact.lastSessionAt {
                sqlite3_bind_double(stmt, 12, lastSession.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 12)
            }

            if let notes = contact.notes {
                sqlite3_bind_text(stmt, 13, notes, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
                sqlite3_bind_null(stmt, 13)
            }

            if let notifyToken = contact.notifyToken {
                _ = notifyToken.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, 14, buf.baseAddress, Int32(buf.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            } else {
                sqlite3_bind_null(stmt, 14)
            }

            if let ttl = contact.messageTTL {
                sqlite3_bind_int(stmt, 15, Int32(ttl))
            } else {
                sqlite3_bind_null(stmt, 15)
            }

            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else {
                throw DatabaseError.executeFailed(rc, "Failed to save contact")
            }
        }
    }

    // MARK: - Read

    func fetchAll() throws -> [Contact] {
        try db.executeSync {
            let stmt = try self.db.prepare("SELECT * FROM contacts ORDER BY lastSessionAt DESC, createdAt DESC;")
            defer { sqlite3_finalize(stmt) }

            var contacts: [Contact] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let contact = self.parseContact(stmt) {
                    contacts.append(contact)
                }
            }
            return contacts
        }
    }

    func fetch(id: UUID) throws -> Contact? {
        try db.executeSync {
            let stmt = try self.db.prepare("SELECT * FROM contacts WHERE id = ?;")
            defer { sqlite3_finalize(stmt) }

            let idStr = id.uuidString
            sqlite3_bind_text(stmt, 1, idStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            if sqlite3_step(stmt) == SQLITE_ROW {
                return self.parseContact(stmt)
            }
            return nil
        }
    }

    /// Find contact by peer identity key (for recognizing returning peers)
    func fetchByIdentityKey(_ identityKey: Data) throws -> Contact? {
        try db.executeSync {
            let stmt = try self.db.prepare("SELECT * FROM contacts WHERE identityKey = ?;")
            defer { sqlite3_finalize(stmt) }

            _ = identityKey.withUnsafeBytes { buf in
                sqlite3_bind_blob(stmt, 1, buf.baseAddress, Int32(buf.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }

            if sqlite3_step(stmt) == SQLITE_ROW {
                return self.parseContact(stmt)
            }
            return nil
        }
    }

    // MARK: - Delete

    func delete(id: UUID) throws {
        try db.executeSync {
            let idStr = id.uuidString

            // Delete messages for this contact (explicit — не полагаемся только на CASCADE)
            let msgStmt = try self.db.prepare("DELETE FROM messages WHERE contactId = ?;")
            defer { sqlite3_finalize(msgStmt) }
            sqlite3_bind_text(msgStmt, 1, idStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_step(msgStmt)

            // Delete skipped keys for this contact
            let skStmt = try self.db.prepare("DELETE FROM skippedKeys WHERE contactId = ?;")
            defer { sqlite3_finalize(skStmt) }
            sqlite3_bind_text(skStmt, 1, idStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_step(skStmt)

            // Delete contact
            let stmt = try self.db.prepare("DELETE FROM contacts WHERE id = ?;")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, idStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else {
                throw DatabaseError.executeFailed(rc, "Failed to delete contact")
            }
        }
    }

    func deleteAll() throws {
        try db.executeSync {
            try self.db.executeSQL("DELETE FROM skippedKeys;")
            try self.db.executeSQL("DELETE FROM contacts;")
        }
    }

    // MARK: - Update Keys

    func updateKeys(id: UUID, publicKey: Data, previousKey: Data?, rotationCounter: Int) throws {
        try db.executeSync {
            let stmt = try self.db.prepare("""
                UPDATE contacts SET publicKey = ?, previousKey = ?, rotationCounter = ?, lastSessionAt = ? WHERE id = ?;
            """)
            defer { sqlite3_finalize(stmt) }

            _ = publicKey.withUnsafeBytes { buf in
                sqlite3_bind_blob(stmt, 1, buf.baseAddress, Int32(buf.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }

            if let prev = previousKey {
                _ = prev.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, 2, buf.baseAddress, Int32(buf.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            } else {
                sqlite3_bind_null(stmt, 2)
            }

            sqlite3_bind_int(stmt, 3, Int32(rotationCounter))
            sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)

            let idStr = id.uuidString
            sqlite3_bind_text(stmt, 5, idStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else {
                throw DatabaseError.executeFailed(rc, "Failed to update contact keys")
            }
        }
    }

    // MARK: - Update Ratchet State

    func updateRatchetState(contactId: UUID, ratchetState: Data) throws {
        try db.executeSync {
            let stmt = try self.db.prepare("""
                UPDATE contacts SET ratchetState = ?, lastSessionAt = ? WHERE id = ?;
            """)
            defer { sqlite3_finalize(stmt) }

            _ = ratchetState.withUnsafeBytes { buf in
                sqlite3_bind_blob(stmt, 1, buf.baseAddress, Int32(buf.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            let idStr = contactId.uuidString
            sqlite3_bind_text(stmt, 3, idStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else {
                throw DatabaseError.executeFailed(rc, "Failed to update ratchet state")
            }
        }
    }

    // MARK: - Update Label

    func updateLabel(contactId: UUID, label: String) throws {
        try db.executeSync {
            let stmt = try self.db.prepare("UPDATE contacts SET label = ? WHERE id = ?;")
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, label, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            let idStr = contactId.uuidString
            sqlite3_bind_text(stmt, 2, idStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else {
                throw DatabaseError.executeFailed(rc, "Failed to update contact label")
            }
        }
    }

    // MARK: - Update Notes

    func updateNotes(contactId: UUID, notes: String?) throws {
        try db.executeSync {
            let stmt = try self.db.prepare("UPDATE contacts SET notes = ? WHERE id = ?;")
            defer { sqlite3_finalize(stmt) }

            if let notes {
                sqlite3_bind_text(stmt, 1, notes, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            let idStr = contactId.uuidString
            sqlite3_bind_text(stmt, 2, idStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else {
                throw DatabaseError.executeFailed(rc, "Failed to update contact notes")
            }
        }
    }

    // MARK: - Update Message TTL

    func updateMessageTTL(contactId: UUID, ttl: Int?) throws {
        try db.executeSync {
            let stmt = try self.db.prepare("UPDATE contacts SET messageTTL = ? WHERE id = ?;")
            defer { sqlite3_finalize(stmt) }

            if let ttl {
                sqlite3_bind_int(stmt, 1, Int32(ttl))
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            let idStr = contactId.uuidString
            sqlite3_bind_text(stmt, 2, idStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else {
                throw DatabaseError.executeFailed(rc, "Failed to update message TTL")
            }
        }
    }

    // MARK: - Increment Session Count

    func incrementSessionCount(contactId: UUID) throws {
        try db.executeSync {
            let stmt = try self.db.prepare("""
                UPDATE contacts SET sessionCount = sessionCount + 1, lastSessionAt = ? WHERE id = ?;
            """)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            let idStr = contactId.uuidString
            sqlite3_bind_text(stmt, 2, idStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else {
                throw DatabaseError.executeFailed(rc, "Failed to increment session count")
            }
        }
    }

    // MARK: - Skipped Keys (per-contact)

    func saveSkippedKeys(contactId: UUID, keys: [(dhPublicKey: Data, messageNumber: Int, messageKey: Data)]) throws {
        try db.executeSync {
            let idStr = contactId.uuidString

            // Wrap in transaction — crash between DELETE and INSERT won't lose keys
            try self.db.executeSQL("BEGIN TRANSACTION;")

            do {
                // Delete existing
                let delStmt = try self.db.prepare("DELETE FROM skippedKeys WHERE contactId = ?;")
                defer { sqlite3_finalize(delStmt) }
                sqlite3_bind_text(delStmt, 1, idStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_step(delStmt)

                // Insert new
                for key in keys {
                    let insStmt = try self.db.prepare("""
                        INSERT OR REPLACE INTO skippedKeys (contactId, dhPublicKey, messageNumber, messageKey, createdAt)
                        VALUES (?, ?, ?, ?, ?);
                    """)
                    defer { sqlite3_finalize(insStmt) }

                    sqlite3_bind_text(insStmt, 1, idStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    _ = key.dhPublicKey.withUnsafeBytes { buf in
                        sqlite3_bind_blob(insStmt, 2, buf.baseAddress, Int32(buf.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    }
                    sqlite3_bind_int(insStmt, 3, Int32(key.messageNumber))
                    _ = key.messageKey.withUnsafeBytes { buf in
                        sqlite3_bind_blob(insStmt, 4, buf.baseAddress, Int32(buf.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    }
                    sqlite3_bind_double(insStmt, 5, Date().timeIntervalSince1970)
                    sqlite3_step(insStmt)
                }

                try self.db.executeSQL("COMMIT;")
            } catch {
                _ = try? self.db.executeSQL("ROLLBACK;")
                throw error
            }
        }
    }

    func fetchSkippedKeys(contactId: UUID) throws -> [(dhPublicKey: Data, messageNumber: Int, messageKey: Data)] {
        try db.executeSync {
            let stmt = try self.db.prepare("SELECT dhPublicKey, messageNumber, messageKey FROM skippedKeys WHERE contactId = ?;")
            defer { sqlite3_finalize(stmt) }

            let idStr = contactId.uuidString
            sqlite3_bind_text(stmt, 1, idStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            var results: [(Data, Int, Data)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let dhLen = sqlite3_column_bytes(stmt, 0)
                guard dhLen > 0, let dhPtr = sqlite3_column_blob(stmt, 0) else { continue }
                let dhKey = Data(bytes: dhPtr, count: Int(dhLen))

                let msgNum = Int(sqlite3_column_int(stmt, 1))

                let mkLen = sqlite3_column_bytes(stmt, 2)
                guard mkLen > 0, let mkPtr = sqlite3_column_blob(stmt, 2) else { continue }
                let msgKey = Data(bytes: mkPtr, count: Int(mkLen))

                results.append((dhKey, msgNum, msgKey))
            }
            return results
        }
    }

    // MARK: - Parse

    /// Column order: id(0), label(1), publicKey(2), previousKey(3), fallbackKey(4),
    ///               pushToken(5), rotationCounter(6), createdAt(7), lastSessionAt(8),
    ///               identityKey(9), ratchetState(10), sessionCount(11), notes(12), notifyToken(13),
    ///               messageTTL(14)
    private func parseContact(_ stmt: OpaquePointer) -> Contact? {
        guard let idCStr = sqlite3_column_text(stmt, 0),
              let id = UUID(uuidString: String(cString: idCStr)),
              let labelCStr = sqlite3_column_text(stmt, 1) else { return nil }

        let label = String(cString: labelCStr)

        let publicKeyLen = sqlite3_column_bytes(stmt, 2)
        guard publicKeyLen > 0, let publicKeyPtr = sqlite3_column_blob(stmt, 2) else { return nil }
        let publicKey = Data(bytes: publicKeyPtr, count: Int(publicKeyLen))

        let previousKey: Data? = {
            let len = sqlite3_column_bytes(stmt, 3)
            guard len > 0, let ptr = sqlite3_column_blob(stmt, 3) else { return nil }
            return Data(bytes: ptr, count: Int(len))
        }()

        let fallbackKey: Data? = {
            let len = sqlite3_column_bytes(stmt, 4)
            guard len > 0, let ptr = sqlite3_column_blob(stmt, 4) else { return nil }
            return Data(bytes: ptr, count: Int(len))
        }()

        let pushToken: Data? = {
            let len = sqlite3_column_bytes(stmt, 5)
            guard len > 0, let ptr = sqlite3_column_blob(stmt, 5) else { return nil }
            return Data(bytes: ptr, count: Int(len))
        }()

        let rotationCounter = Int(sqlite3_column_int(stmt, 6))
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))

        let lastSessionAt: Date? = {
            let val = sqlite3_column_double(stmt, 8)
            return val > 0 ? Date(timeIntervalSince1970: val) : nil
        }()

        // v2 columns (may be NULL for migrated v1 contacts)
        let identityKey: Data = {
            let len = sqlite3_column_bytes(stmt, 9)
            guard len > 0, let ptr = sqlite3_column_blob(stmt, 9) else { return publicKey }
            return Data(bytes: ptr, count: Int(len))
        }()

        let ratchetState: Data? = {
            let len = sqlite3_column_bytes(stmt, 10)
            guard len > 0, let ptr = sqlite3_column_blob(stmt, 10) else { return nil }
            return Data(bytes: ptr, count: Int(len))
        }()

        let sessionCount = Int(sqlite3_column_int(stmt, 11))

        // v3 column
        let notes: String? = {
            guard let ptr = sqlite3_column_text(stmt, 12) else { return nil }
            return String(cString: ptr)
        }()

        // v4 column
        let notifyToken: Data? = {
            let len = sqlite3_column_bytes(stmt, 13)
            guard len > 0, let ptr = sqlite3_column_blob(stmt, 13) else { return nil }
            return Data(bytes: ptr, count: Int(len))
        }()

        // v7 column
        let messageTTL: Int? = {
            guard sqlite3_column_type(stmt, 14) != SQLITE_NULL else { return nil }
            return Int(sqlite3_column_int(stmt, 14))
        }()

        return Contact(
            id: id,
            label: label,
            publicKey: publicKey,
            identityKey: identityKey,
            ratchetState: ratchetState,
            previousKey: previousKey,
            fallbackKey: fallbackKey,
            pushToken: pushToken,
            notifyToken: notifyToken,
            notes: notes,
            messageTTL: messageTTL,
            rotationCounter: rotationCounter,
            sessionCount: sessionCount,
            createdAt: createdAt,
            lastSessionAt: lastSessionAt
        )
    }
}
