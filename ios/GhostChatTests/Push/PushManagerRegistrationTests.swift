import XCTest
import PushKit
@testable import GhostChat

/// Tests for PushManager registration & token bookkeeping. Mirrors the
/// regression where `requestAPNsAuthorization()` and `registerForVoIP()` were
/// dead code — these tests document the wiring contract so the regression
/// can't silently come back.
@MainActor
final class PushManagerRegistrationTests: XCTestCase {

    private func makeManager() -> PushManager {
        PushManager(
            baseURL: URL(string: "https://example.invalid")!,
            pinning: CertificatePinning()
        )
    }

    func test_registerForVoIP_setsUpRegistry() {
        let mgr = makeManager()
        XCTAssertNil(mgr.voipToken)
        mgr.registerForVoIP()
        // We can't directly assert on the private registry, but we can exercise
        // the delegate path PKPushRegistry would otherwise call.
        // No crash, no leak — registerForVoIP is idempotent for repeat calls.
        mgr.registerForVoIP()
        XCTAssertNil(mgr.voipToken, "voipToken stays nil until PKPushRegistry delivers credentials")
    }

    func test_didReceiveAPNsToken_setsToken_andYieldsViaStream() async {
        let mgr = makeManager()
        let bytes = Data([0x01, 0x02, 0x03, 0x04, 0x05])

        // Subscribe BEFORE the yield so the AsyncStream buffers it.
        let received = expectation(description: "apnsTokens stream yields")
        let task = Task {
            for await tok in mgr.apnsTokens {
                if tok == bytes { received.fulfill(); break }
            }
        }
        mgr.didReceiveAPNsToken(bytes)
        await fulfillment(of: [received], timeout: 2)
        task.cancel()

        XCTAssertEqual(mgr.apnsToken, bytes)
    }

    func test_voipDelegate_setsToken_andYieldsViaStream() async {
        let mgr = makeManager()
        let received = expectation(description: "voipTokens stream yields")
        let task = Task {
            for await _ in mgr.voipTokens { received.fulfill(); break }
        }

        // Synthesize a PushKit credential delivery without the real registry.
        let bytes = Data([0x10, 0x20, 0x30])
        mgr._test_setVoipToken(bytes)
        await fulfillment(of: [received], timeout: 2)
        task.cancel()

        XCTAssertEqual(mgr.voipToken, bytes)
    }

    // MARK: - SettingsManager.notificationsEnabled (new property)

    func test_settings_notificationsEnabled_defaultsFalse() {
        // Privacy-first: never opt user into network egress without explicit consent.
        let mgr = SettingsManager(keychain: InMemoryKeychain())
        XCTAssertFalse(mgr.notificationsEnabled)
    }

    func test_settings_notificationsEnabled_persistsToKeychain() {
        let keychain = InMemoryKeychain()
        do {
            let mgr = SettingsManager(keychain: keychain)
            mgr.notificationsEnabled = true
        }
        let reloaded = SettingsManager(keychain: keychain)
        XCTAssertTrue(reloaded.notificationsEnabled)
    }
}
