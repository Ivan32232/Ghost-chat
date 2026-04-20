import Foundation
import GRDB

extension Contact: FetchableRecord, PersistableRecord {
    static let databaseTableName = "contacts"
}

final class ContactStore {

    private let dbQueue: DatabaseQueue

    init(database: DatabaseService) {
        self.dbQueue = database.dbQueue
    }

    // MARK: - Read

    func all() throws -> [Contact] {
        try dbQueue.read { db in
            try Contact
                .order(Column("lastSessionAt").desc, Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    func fetch(id: String) throws -> Contact? {
        try dbQueue.read { db in try Contact.fetchOne(db, key: id) }
    }

    func fetch(identityKey: Data) throws -> Contact? {
        try dbQueue.read { db in
            try Contact.filter(Column("identityKey") == identityKey).fetchOne(db)
        }
    }

    // MARK: - Write

    func save(_ contact: Contact) throws {
        try dbQueue.write { db in try contact.save(db) }
    }

    func delete(id: String) throws {
        _ = try dbQueue.write { db in try Contact.deleteOne(db, key: id) }
    }

    func deleteAll() throws {
        _ = try dbQueue.write { db in try Contact.deleteAll(db) }
    }

    // MARK: - Convenience updates

    func updateRatchetState(id: String, state: Data) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE contacts SET ratchetState = ? WHERE id = ?",
                arguments: [state, id]
            )
        }
    }

    func bumpSessionCount(id: String, at now: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE contacts SET sessionCount = sessionCount + 1, lastSessionAt = ? WHERE id = ?",
                arguments: [now, id]
            )
        }
    }

    func setMuted(id: String, muted: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE contacts SET isMuted = ? WHERE id = ?",
                arguments: [muted ? 1 : 0, id]
            )
        }
    }
}
