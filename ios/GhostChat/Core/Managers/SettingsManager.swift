import Foundation

/// Keychain-backed user preferences. No UserDefaults anywhere.
@MainActor
final class SettingsManager: ObservableObject {

    private struct Keys {
        static let privacyMode      = "settings.privacy_mode"
        static let biometricEnabled = "settings.biometric_enabled"
        static let soundEnabled     = "settings.sound_enabled"
        static let messageTTL       = "settings.message_ttl"
        static let autoLock         = "settings.auto_lock"
    }

    private let keychain: KeychainServicing

    @Published var privacyMode: Bool {
        didSet { writeBool(privacyMode, for: Keys.privacyMode) }
    }

    @Published var biometricEnabled: Bool {
        didSet { writeBool(biometricEnabled, for: Keys.biometricEnabled) }
    }

    @Published var soundEnabled: Bool {
        didSet { writeBool(soundEnabled, for: Keys.soundEnabled) }
    }

    @Published var messageTTL: MessageTTL {
        didSet { writeInt(messageTTL.rawValue, for: Keys.messageTTL) }
    }

    @Published var autoLockTimeout: AutoLockTimeout {
        didSet { writeInt(autoLockTimeout.rawValue, for: Keys.autoLock) }
    }

    init(keychain: KeychainServicing) {
        self.keychain = keychain
        self.privacyMode      = Self.readBool(keychain: keychain, key: Keys.privacyMode, default: false)
        self.biometricEnabled = Self.readBool(keychain: keychain, key: Keys.biometricEnabled, default: false)
        self.soundEnabled     = Self.readBool(keychain: keychain, key: Keys.soundEnabled, default: true)
        let ttlRaw = Self.readInt(keychain: keychain, key: Keys.messageTTL, default: MessageTTL.fiveMinutes.rawValue)
        self.messageTTL = MessageTTL(rawValue: ttlRaw) ?? .fiveMinutes
        let alRaw = Self.readInt(keychain: keychain, key: Keys.autoLock, default: AutoLockTimeout.oneMinute.rawValue)
        self.autoLockTimeout = AutoLockTimeout(rawValue: alRaw) ?? .oneMinute
    }

    // MARK: - Private

    private func writeBool(_ value: Bool, for key: String) {
        try? keychain.set(Data([value ? 0x01 : 0x00]), for: key)
    }

    private func writeInt(_ value: Int, for key: String) {
        try? keychain.set(Data("\(value)".utf8), for: key)
    }

    private static func readBool(keychain: KeychainServicing, key: String, `default`: Bool) -> Bool {
        guard let data = try? keychain.get(key), data.count == 1 else { return `default` }
        return data[0] == 0x01
    }

    private static func readInt(keychain: KeychainServicing, key: String, `default`: Int) -> Int {
        guard let data = try? keychain.get(key),
              let str = String(data: data, encoding: .utf8),
              let n = Int(str) else { return `default` }
        return n
    }
}
