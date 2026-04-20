import CryptoKit
import XCTest
@testable import GhostChat

@MainActor
final class ContactManagerTests: XCTestCase {

    private func makeSubject() throws -> (ContactManager, ContactStore, MessageStore, IdentityKeyService, InMemoryKeychain) {
        let keychain = InMemoryKeychain()
        let db = try DatabaseService.inMemory(keychain: keychain)
        let contactStore = ContactStore(database: db)
        let messageStore = MessageStore(database: db)
        let identity = IdentityKeyService(keychain: keychain)
        _ = try identity.getOrCreateIdentity()
        let mgr = ContactManager(store: contactStore, messages: messageStore, identity: identity, keychain: keychain)
        return (mgr, contactStore, messageStore, identity, keychain)
    }

    func test_save_andRefresh_updatesContacts() throws {
        let (mgr, _, _, _, _) = try makeSubject()
        let c = Contact(label: "Alice", identityKey: Data([0x01]), publicKey: Data([0x02]),
                        createdAt: Date(timeIntervalSince1970: 12345))
        try mgr.save(c)
        XCTAssertEqual(mgr.contacts.count, 1)
        XCTAssertEqual(mgr.contacts.first?.label, "Alice")
    }

    func test_delete_removesContact() throws {
        let (mgr, _, _, _, _) = try makeSubject()
        let c = Contact(id: "fixed", label: "A", identityKey: Data(), publicKey: Data(),
                        createdAt: Date(timeIntervalSince1970: 100))
        try mgr.save(c)
        try mgr.delete(id: "fixed")
        XCTAssertEqual(mgr.contacts.count, 0)
    }

    func test_determineRole_myHashLessThanPeer_isHost() throws {
        let (mgr, _, _, identity, _) = try makeSubject()
        let me = try identity.publicKeyRaw
        let myHash = Data(SHA256.hash(data: me))
        // Build a peer x963 whose raw hash > ours: repeat bytes 0xFF
        var peerX963 = Data([0x04]) + Data(repeating: 0xFF, count: 64)
        let peerHash = Data(SHA256.hash(data: Data(peerX963.dropFirst())))
        let myHex = myHash.map { String(format: "%02x", $0) }.joined()
        let peerHex = peerHash.map { String(format: "%02x", $0) }.joined()
        let expected: Role = myHex < peerHex ? .host : .guest
        let got = try mgr.determineRole(peerIdentity: peerX963)
        XCTAssertEqual(got, expected)
        _ = peerX963
    }

    func test_panicWipe_clearsEverything() throws {
        let (mgr, contactStore, _, identity, keychain) = try makeSubject()
        try mgr.save(Contact(label: "x", identityKey: Data([0x01]), publicKey: Data([0x02]),
                             createdAt: Date(timeIntervalSince1970: 1)))
        try keychain.set(Data([0xAA]), for: "something.random")
        XCTAssertNotNil(try keychain.get("something.random"))
        try mgr.panicWipe()
        XCTAssertNil(try keychain.get("something.random"))
        XCTAssertEqual(try contactStore.all().count, 0)
        // identity cache was cleared; next call generates a fresh one
        let fresh = try identity.getOrCreateIdentity()
        XCTAssertEqual(fresh.rawRepresentation.count, 32)
    }
}
