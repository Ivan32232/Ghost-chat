import XCTest
@testable import GhostChat

@MainActor
final class SettingsManagerTests: XCTestCase {

    func test_defaults() {
        let keychain = InMemoryKeychain()
        let mgr = SettingsManager(keychain: keychain)
        XCTAssertFalse(mgr.privacyMode)
        XCTAssertFalse(mgr.biometricEnabled)
        XCTAssertTrue(mgr.soundEnabled)
        XCTAssertEqual(mgr.messageTTL, .fiveMinutes)
        XCTAssertEqual(mgr.autoLockTimeout, .oneMinute)
    }

    func test_allSettings_persistAcrossInstances() {
        let keychain = InMemoryKeychain()
        do {
            let mgr = SettingsManager(keychain: keychain)
            mgr.privacyMode = true
            mgr.biometricEnabled = true
            mgr.soundEnabled = false
            mgr.messageTTL = .fifteenMinutes
            mgr.autoLockTimeout = .fiveMinutes
        }
        let reloaded = SettingsManager(keychain: keychain)
        XCTAssertTrue(reloaded.privacyMode)
        XCTAssertTrue(reloaded.biometricEnabled)
        XCTAssertFalse(reloaded.soundEnabled)
        XCTAssertEqual(reloaded.messageTTL, .fifteenMinutes)
        XCTAssertEqual(reloaded.autoLockTimeout, .fiveMinutes)
    }
}
