import Foundation

/// Assembles every Manager + service once and holds references. The caller (`GhostChatApp`)
/// surfaces them as `@EnvironmentObject`s so views pick them up.
@MainActor
final class AppServices {

    let keychain: KeychainService
    let identity: IdentityKeyService
    let database: DatabaseService
    let contactStore: ContactStore
    let messageStore: MessageStore
    let pinning: CertificatePinning
    let push: PushManager
    let connection: ConnectionManager
    let contacts: ContactManager
    let messages: MessageManager
    let calls: CallManager
    let settings: SettingsManager
    let localization: LocalizationManager
    let auth: BiometricAuthService
    let sounds: SoundLibrary

    static let serverHTTPS = URL(string: "https://ghostchat.one")!
    static let serverWSS   = URL(string: "wss://ghostchat.one/ws")!

    init() {
        let keychain = KeychainService()
        self.keychain = keychain

        self.pinning = CertificatePinning()
        self.identity = IdentityKeyService(keychain: keychain)

        let database: DatabaseService
        do {
            database = try DatabaseService.onDisk(keychain: keychain)
        } catch {
            database = try! DatabaseService.inMemory(keychain: keychain)
        }
        self.database = database

        self.contactStore = ContactStore(database: database)
        self.messageStore = MessageStore(database: database)
        self.push = PushManager(baseURL: Self.serverHTTPS, pinning: pinning)

        self.connection = ConnectionManager(
            signalingURL: Self.serverWSS,
            apiBaseURL: Self.serverHTTPS,
            identity: identity,
            push: push,
            pinning: pinning
        )
        self.contacts = ContactManager(
            store: contactStore,
            messages: messageStore,
            identity: identity,
            keychain: keychain
        )

        // Wire ContactManager into ConnectionManager so `leave()` can trigger a
        // deterministic contact-key rotation using the just-ended session's secret.
        self.connection.contactManager = self.contacts
        self.messages = MessageManager(store: messageStore)
        self.calls = CallManager()
        self.settings = SettingsManager(keychain: keychain)
        self.localization = LocalizationManager(keychain: keychain)
        self.auth = BiometricAuthService(keychain: keychain, config: .init(failureLimit: 10, onWipe: {
            // Panic wipe dispatched via ContactManager — stored weak via reference cycle avoidance.
        }))
        self.sounds = SoundLibrary(muted: !settings.soundEnabled)

        // Best-effort identity bootstrap (cached after first access).
        _ = try? identity.getOrCreateIdentity()

        // Prune old skipped keys opportunistically on launch.
        try? messageStore.pruneSkipped()

        // Initial contact list.
        contacts.refresh()
    }
}
