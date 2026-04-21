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

    // MARK: - Key rotation (Phase 6)

    func test_rotateKeys_firstRotation_slidesPublicIntoPrevious_noFallback() throws {
        let (mgr, contactStore, _, _, keychain) = try makeSubject()
        let peer = P256.KeyAgreement.PrivateKey()
        let firstPublic = peer.publicKey.x963Representation
        let c = Contact(
            id: "c1", label: "Alice",
            identityKey: Data([0x04]) + Data(repeating: 0x01, count: 64),
            publicKey: firstPublic,
            rotationCounter: 0,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        try mgr.save(c)
        let didRun = try mgr.rotateKeys(contactId: "c1",
                                         sessionSecret: Data(repeating: 0x42, count: 32))
        XCTAssertTrue(didRun)
        let updated = try XCTUnwrap(contactStore.fetch(id: "c1"))
        XCTAssertEqual(updated.rotationCounter, 1)
        XCTAssertEqual(updated.previousKey, firstPublic)
        XCTAssertNil(updated.fallbackKey)
        XCTAssertNotEqual(updated.publicKey, firstPublic)
        // Private scalar stored in the keychain
        let stored = try XCTUnwrap(try keychain.get("contact.priv.c1"))
        XCTAssertEqual(stored.count, 32)
    }

    func test_rotateKeys_secondRotation_slidesPreviousIntoFallback() throws {
        let (mgr, contactStore, _, _, _) = try makeSubject()
        let firstPeer = P256.KeyAgreement.PrivateKey()
        let c = Contact(
            id: "c1", label: "Bob",
            identityKey: Data([0x04]) + Data(repeating: 0x02, count: 64),
            publicKey: firstPeer.publicKey.x963Representation,
            rotationCounter: 0,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        try mgr.save(c)
        try mgr.rotateKeys(contactId: "c1", sessionSecret: Data(repeating: 0x42, count: 32))
        let g1 = try XCTUnwrap(contactStore.fetch(id: "c1"))
        try mgr.rotateKeys(contactId: "c1", sessionSecret: Data(repeating: 0x43, count: 32))
        let g2 = try XCTUnwrap(contactStore.fetch(id: "c1"))
        XCTAssertEqual(g2.rotationCounter, 2)
        XCTAssertEqual(g2.fallbackKey, firstPeer.publicKey.x963Representation)
        XCTAssertEqual(g2.previousKey, g1.publicKey)
        XCTAssertNotEqual(g2.publicKey, g1.publicKey)
    }

    func test_rotateKeys_noSuchContact_returnsFalse() throws {
        let (mgr, _, _, _, _) = try makeSubject()
        XCTAssertFalse(try mgr.rotateKeys(contactId: "does-not-exist",
                                          sessionSecret: Data(count: 32)))
    }

    func test_rotateKeys_deterministicAcrossPeers() throws {
        // Both peers running with the same session secret must produce the same new
        // public key — that's what enables zero-exchange rotation.
        let (mgrA, storeA, _, _, _) = try makeSubject()
        let (mgrB, storeB, _, _, _) = try makeSubject()
        let init0 = P256.KeyAgreement.PrivateKey()
        let idKey = Data([0x04]) + Data(repeating: 0x05, count: 64)
        try mgrA.save(Contact(id: "x", label: "", identityKey: idKey,
                              publicKey: init0.publicKey.x963Representation,
                              createdAt: Date(timeIntervalSince1970: 1)))
        try mgrB.save(Contact(id: "x", label: "", identityKey: idKey,
                              publicKey: init0.publicKey.x963Representation,
                              createdAt: Date(timeIntervalSince1970: 1)))
        let secret = Data(repeating: 0xAA, count: 32)
        try mgrA.rotateKeys(contactId: "x", sessionSecret: secret)
        try mgrB.rotateKeys(contactId: "x", sessionSecret: secret)
        let a = try XCTUnwrap(storeA.fetch(id: "x"))
        let b = try XCTUnwrap(storeB.fetch(id: "x"))
        XCTAssertEqual(a.publicKey, b.publicKey)
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
