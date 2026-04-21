import CryptoKit
import Foundation

/// Coordinates contact CRUD, panic wipe, and HOST/GUEST role determination for
/// pending-room auto-connect.
@MainActor
final class ContactManager: ObservableObject {

    @Published private(set) var contacts: [Contact] = []

    private let store: ContactStore
    private let messages: MessageStore
    private let identity: IdentityKeyService
    private let keychain: KeychainServicing

    init(store: ContactStore, messages: MessageStore, identity: IdentityKeyService, keychain: KeychainServicing) {
        self.store = store
        self.messages = messages
        self.identity = identity
        self.keychain = keychain
    }

    func refresh() {
        contacts = (try? store.all()) ?? []
    }

    func save(_ contact: Contact) throws {
        try store.save(contact)
        refresh()
    }

    func delete(id: String) throws {
        try store.delete(id: id)
        refresh()
    }

    /// Deterministic HOST/GUEST selection used for auto-connect:
    /// SHA-256(myIdentity) lexicographically less than SHA-256(peerIdentity) → HOST.
    func determineRole(peerIdentity: Data) throws -> Role {
        let me = try identity.publicKeyRaw
        let myHash   = SHA256.hash(data: me)
        let peerHash = SHA256.hash(data: peerIdentity.dropFirst()) // peer is x963; drop 0x04 prefix
        let myHex   = Data(myHash).hexString
        let peerHex = Data(peerHash).hexString
        return myHex < peerHex ? .host : .guest
    }

    /// Irrecoverably deletes all contacts, messages, skipped keys, identity, DB file, and every
    /// keychain entry under our prefix.
    func panicWipe() throws {
        try? store.deleteAll()
        try? identity.resetIdentity()
        try? keychain.deleteAll()
        DatabaseService.deleteFile()
        refresh()
    }

    /// Rotate a saved contact's keys using the just-ended session's shared secret.
    ///
    /// Both peers derive the same new keypair from the same `sessionSecret` via
    /// `ContactKeyRotation.deriveNextSeed` — no wire exchange needed. The prior
    /// `publicKey` slides into `previousKey`, and `previousKey` slides into
    /// `fallbackKey`, giving us 3 generations of continuity across occasional
    /// state desync.
    ///
    /// The new private scalar is stored in Keychain under a per-contact label so
    /// the next connect can use it for the ECDH handshake. Returns `true` when
    /// the rotation actually ran (contact existed); `false` otherwise.
    @discardableResult
    func rotateKeys(contactId: String, sessionSecret: Data) throws -> Bool {
        guard var contact = try store.fetch(id: contactId) else { return false }
        let privateKeyKeychainId = "contact.priv.\(contactId)"
        let currentPrivate = (try keychain.get(privateKeyKeychainId)) ?? Data()
        let rotated = ContactKeyRotation.rotate(
            sessionSecret: sessionSecret,
            currentPrivate: currentPrivate,
            previousPublic: contact.publicKey,
            fallbackPublic: contact.previousKey,
            counter: contact.rotationCounter
        )
        try keychain.set(rotated.newPrivate, for: privateKeyKeychainId)
        contact.publicKey = rotated.newPublicX963
        contact.previousKey = rotated.previousPublicX963
        contact.fallbackKey = rotated.fallbackPublicX963
        contact.rotationCounter = rotated.counter
        try store.save(contact)
        refresh()
        return true
    }
}

/// Helper required because `hexString` on `Data` is declared in an internal extension
/// within the GhostCrypto package; duplicating for convenience inside the app target.
private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
