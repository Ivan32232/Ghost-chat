import XCTest
@testable import GhostChat
import GhostCrypto

@MainActor
final class ConnectionRotationTests: XCTestCase {

    /// Builds a fully-ready ConnectionManager + ContactManager pair, with a saved contact
    /// and the crypto actor driven through a full handshake so `sessionSecret()` returns
    /// real bytes. No signaling / RTC is live — we exercise just the rotation path.
    private func makeFixture() async throws -> (ConnectionManager, ContactManager, Contact) {
        let keychain = InMemoryKeychain()
        let identity = IdentityKeyService(keychain: keychain)
        _ = try identity.getOrCreateIdentity()
        let db = try DatabaseService.inMemory(keychain: keychain)
        let contactStore = ContactStore(database: db)
        let messageStore = MessageStore(database: db)
        let contacts = ContactManager(store: contactStore, messages: messageStore,
                                      identity: identity, keychain: keychain)

        // Save a contact so rotateKeys has something to rotate.
        let peerPub = Data(repeating: 0x04, count: 1) + Data(count: 64)
        let contact = Contact(
            id: "c-rotate-1", label: "Peer",
            identityKey: peerPub, publicKey: peerPub,
            previousKey: nil, fallbackKey: nil,
            pushToken: nil, notifyToken: nil,
            ratchetState: nil, rotationCounter: 0,
            sessionCount: 0, messageTTL: 300,
            notes: nil, isMuted: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSessionAt: nil
        )
        try contacts.save(contact)

        let conn = ConnectionManager(
            signalingURL: URL(string: "wss://example.invalid/ws")!,
            apiBaseURL: URL(string: "https://example.invalid")!,
            identity: identity,
            push: PushManager(baseURL: URL(string: "https://example.invalid")!,
                              pinning: CertificatePinning())
        )
        conn.contactManager = contacts

        // Drive the crypto actor into a ready state so `sessionSecret()` works.
        let host = GhostChatCrypto(identity: identity)
        let guest = GhostChatCrypto(identity: IdentityKeyService(keychain: InMemoryKeychain()))
        let hostPkt = try await host.beginHandshake(role: .host)
        let guestPkt = try await guest.beginHandshake(role: .guest)
        _ = try await guest.completeAsGuest(peer: hostPkt)
        _ = try await host.completeAsHost(peer: guestPkt)
        conn._test_injectReadyCrypto(host)

        return (conn, contacts, contact)
    }

    func test_leaveWithContactId_rotatesKeys() async throws {
        let (conn, contacts, contact) = try await makeFixture()
        conn.currentContactId = contact.id
        let priorPub = contact.publicKey
        let priorCounter = contact.rotationCounter

        await conn.leaveAndAwaitRotation()

        contacts.refresh()
        let rotated = contacts.contacts.first { $0.id == contact.id }
        XCTAssertNotNil(rotated)
        XCTAssertNotEqual(rotated?.publicKey, priorPub,
                          "publicKey must change after rotation")
        XCTAssertEqual(rotated?.previousKey, priorPub,
                       "previousKey column absorbs prior publicKey")
        XCTAssertEqual(rotated?.rotationCounter, priorCounter + 1)
    }

    func test_leaveWithoutContactId_noRotation() async throws {
        let (conn, contacts, contact) = try await makeFixture()
        // currentContactId intentionally not set — this session isn't a saved contact.
        let priorPub = contact.publicKey
        let priorCounter = contact.rotationCounter

        await conn.leaveAndAwaitRotation()

        contacts.refresh()
        let unchanged = contacts.contacts.first { $0.id == contact.id }
        XCTAssertEqual(unchanged?.publicKey, priorPub)
        XCTAssertEqual(unchanged?.rotationCounter, priorCounter)
    }
}
