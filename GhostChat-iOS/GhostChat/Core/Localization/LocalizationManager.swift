import Foundation
import SwiftUI

/// Менеджер локализации — переключение языка без перезапуска приложения
/// Использует подмену Bundle.main через Objective-C runtime
@MainActor
final class LocalizationManager: ObservableObject {

    static let shared = LocalizationManager()

    // MARK: - Language Definition

    struct Language: Identifiable {
        let code: String      // ISO 639-1
        let flag: String      // Emoji flag
        let nameNative: String  // Name in its own language
        let nameEn: String    // Name in English

        var id: String { code }
    }

    /// Доступные языки — расширяется добавлением .lproj + записи сюда
    static let availableLanguages: [Language] = [
        Language(code: "en", flag: "🇺🇸", nameNative: "English", nameEn: "English"),
        Language(code: "ru", flag: "🇷🇺", nameNative: "Русский", nameEn: "Russian"),
    ]

    // MARK: - Published State

    /// Текущий код языка (en, ru, ...)
    /// При изменении — мгновенная перезагрузка строк через Bundle swizzling
    @Published var currentLanguage: String {
        didSet {
            guard currentLanguage != oldValue else { return }
            applyLanguage(currentLanguage)
        }
    }

    /// Инкрементный счётчик для принудительного обновления SwiftUI
    @Published var refreshToken: UUID = UUID()

    // MARK: - Init

    private init() {
        // Загружаем сохранённый язык или определяем из системных настроек
        let saved = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first
        let systemLang = Locale.current.language.languageCode?.identifier ?? "en"
        let lang = saved ?? systemLang

        // Проверяем что язык доступен
        let validLang = Self.availableLanguages.contains(where: { $0.code == lang }) ? lang : "en"
        self.currentLanguage = validLang
        applyLanguage(validLang)
    }

    // MARK: - Apply

    private func applyLanguage(_ code: String) {
        UserDefaults.standard.set([code], forKey: "AppleLanguages")
        UserDefaults.standard.synchronize()
        Bundle.setLanguage(code)
        refreshToken = UUID()
    }

    /// Имя текущего языка для отображения в настройках
    var currentLanguageName: String {
        Self.availableLanguages.first { $0.code == currentLanguage }?.nameNative ?? currentLanguage
    }

    var currentFlag: String {
        Self.availableLanguages.first { $0.code == currentLanguage }?.flag ?? "🌐"
    }
}

// MARK: - Bundle Language Swizzling

/// Подменяет Bundle.main для загрузки строк из конкретного .lproj
/// Стандартный подход для runtime language switch в iOS
private var associatedBundleKey: UInt8 = 0

private final class LanguageBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        guard let path = objc_getAssociatedObject(self, &associatedBundleKey) as? String,
              let bundle = Bundle(path: path) else {
            return super.localizedString(forKey: key, value: value, table: tableName)
        }
        return bundle.localizedString(forKey: key, value: value, table: tableName)
    }
}

extension Bundle {
    static func setLanguage(_ language: String) {
        defer {
            object_setClass(Bundle.main, LanguageBundle.self)
        }
        objc_setAssociatedObject(
            Bundle.main,
            &associatedBundleKey,
            Bundle.main.path(forResource: language, ofType: "lproj"),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}
