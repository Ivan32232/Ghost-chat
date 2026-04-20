import XCTest
@testable import GhostChat

@MainActor
final class LocalizationManagerTests: XCTestCase {

    func test_supported_includesEnAndRu() {
        let codes = LocalizationManager.supported.map(\.identifier)
        XCTAssertTrue(codes.contains("en"))
        XCTAssertTrue(codes.contains("ru"))
    }

    func test_setOverride_persists() throws {
        let keychain = InMemoryKeychain()
        let mgr1 = LocalizationManager(keychain: keychain)
        try mgr1.setOverride(Locale(identifier: "ru"))
        XCTAssertEqual(mgr1.locale.identifier, "ru")

        let mgr2 = LocalizationManager(keychain: keychain)
        XCTAssertEqual(mgr2.locale.identifier, "ru")
    }

    func test_setOverride_ignoresUnsupportedLocale() throws {
        let keychain = InMemoryKeychain()
        let mgr = LocalizationManager(keychain: keychain)
        let before = mgr.locale
        try mgr.setOverride(Locale(identifier: "ja"))
        XCTAssertEqual(mgr.locale, before)
    }

    func test_clearOverride_restoresSystem() throws {
        let keychain = InMemoryKeychain()
        let mgr = LocalizationManager(keychain: keychain)
        try mgr.setOverride(Locale(identifier: "ru"))
        try mgr.clearOverride()
        XCTAssertNil(try keychain.get(LocalizationManager.keychainKey))
    }

    func test_localized_returnsTranslation() throws {
        let mgr = LocalizationManager(keychain: InMemoryKeychain())
        try mgr.setOverride(Locale(identifier: "en"))
        XCTAssertEqual(mgr.localized("chat.send"), "Send")
        try mgr.setOverride(Locale(identifier: "ru"))
        XCTAssertEqual(mgr.localized("chat.send"), "Отправить")
    }

    func test_localized_missingKey_returnsFallback() throws {
        let mgr = LocalizationManager(keychain: InMemoryKeychain())
        XCTAssertEqual(mgr.localized("nope.nonexistent", default: "(missing)"), "(missing)")
    }
}
