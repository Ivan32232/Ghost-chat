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
}

/// Helper required because `hexString` on `Data` is declared in an internal extension
/// within the GhostCrypto package; duplicating for convenience inside the app target.
private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
