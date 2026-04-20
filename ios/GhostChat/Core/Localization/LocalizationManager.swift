import Foundation

/// Observable manager for app locale.
/// Default: system locale if supported (`en`, `ru`); otherwise `en`.
/// Override: persisted in Keychain under `settings.locale.override`.
@MainActor
final class LocalizationManager: ObservableObject {

    static let supported: [Locale] = [
        Locale(identifier: "en"),
        Locale(identifier: "ru")
    ]

    static let keychainKey = "settings.locale.override"

    @Published private(set) var locale: Locale

    private let keychain: KeychainServicing

    init(keychain: KeychainServicing) {
        self.keychain = keychain
        self.locale = LocalizationManager.resolve(keychain: keychain)
    }

    convenience init() {
        self.init(keychain: KeychainService())
    }

    private static func resolve(keychain: KeychainServicing) -> Locale {
        if let data = try? keychain.get(keychainKey),
           let code = String(data: data, encoding: .utf8),
           let match = supported.first(where: { $0.identifier == code }) {
            return match
        }
        let systemCode = Locale.current.language.languageCode?.identifier ?? "en"
        return supported.first(where: { $0.language.languageCode?.identifier == systemCode })
            ?? Locale(identifier: "en")
    }

    func setOverride(_ newLocale: Locale) throws {
        guard LocalizationManager.supported.contains(where: { $0.identifier == newLocale.identifier }) else { return }
        self.locale = newLocale
        try keychain.set(Data(newLocale.identifier.utf8), for: Self.keychainKey)
    }

    func clearOverride() throws {
        try keychain.delete(Self.keychainKey)
        self.locale = Self.resolve(keychain: keychain)
    }

    /// Localise `key` (from Localizable.xcstrings) in the current locale.
    /// Navigates to the per-locale `.lproj` bundle to force a specific translation —
    /// `String(localized:locale:)` uses `locale` for formatting only.
    func localized(_ key: String, default fallback: String? = nil) -> String {
        if let path = Bundle.main.path(forResource: locale.identifier, ofType: "lproj"),
           let localeBundle = Bundle(path: path) {
            let value = localeBundle.localizedString(forKey: key, value: "__MISSING__", table: nil)
            if value != "__MISSING__" { return value }
        }
        let fallbackValue = Bundle.main.localizedString(forKey: key, value: "__MISSING__", table: nil)
        if fallbackValue != "__MISSING__" { return fallbackValue }
        return fallback ?? key
    }
}
