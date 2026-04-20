import XCTest
@testable import GhostChat

final class PINHashTests: XCTestCase {
    func test_differentPINs_produceDifferentHashes_sameSalt() {
        let salt = Data(repeating: 0xAA, count: 32)
        let a = PINHash.compute(pin: "1234", salt: salt)
        let b = PINHash.compute(pin: "4321", salt: salt)
        XCTAssertNotEqual(a, b)
    }

    func test_samePIN_differentSalts_produceDifferentHashes() {
        let a = PINHash.compute(pin: "1234", salt: Data(repeating: 0xAA, count: 32))
        let b = PINHash.compute(pin: "1234", salt: Data(repeating: 0xBB, count: 32))
        XCTAssertNotEqual(a, b)
    }

    func test_verify_correctPIN_true() {
        let hash = PINHash.make(pin: "1234")
        XCTAssertTrue(hash.verify(pin: "1234"))
    }

    func test_verify_wrongPIN_false() {
        let hash = PINHash.make(pin: "1234")
        XCTAssertFalse(hash.verify(pin: "4321"))
    }

    func test_make_usesRandomSalt() {
        let a = PINHash.make(pin: "1234")
        let b = PINHash.make(pin: "1234")
        XCTAssertNotEqual(a.salt, b.salt)
        XCTAssertNotEqual(a.hash, b.hash)
    }
}

final class BiometricAuthServiceTests: XCTestCase {

    private var keychain: InMemoryKeychain!
    private var wipeCount = 0

    override func setUp() {
        super.setUp()
        keychain = InMemoryKeychain()
        wipeCount = 0
    }

    private func makeService(failureLimit: Int = 10) -> BiometricAuthService {
        BiometricAuthService(
            keychain: keychain,
            config: .init(failureLimit: failureLimit, onWipe: { [weak self] in
                self?.wipeCount += 1
            })
        )
    }

    // MARK: - setPIN / authenticate

    func test_setMainPIN_authenticateWithSame_authenticated() throws {
        let service = makeService()
        try service.setMainPIN("1234")
        XCTAssertEqual(try service.authenticate(pin: "1234"), .authenticated)
    }

    func test_setMainPIN_authenticateWithWrong_invalid_thenCounterIncrements() throws {
        let service = makeService()
        try service.setMainPIN("1234")
        XCTAssertEqual(try service.authenticate(pin: "0000"), .invalid)
        XCTAssertEqual(try service.failureCount(), 1)
    }

    func test_correctPIN_resetsFailureCount() throws {
        let service = makeService()
        try service.setMainPIN("1234")
        _ = try service.authenticate(pin: "wrong")
        _ = try service.authenticate(pin: "wrong")
        XCTAssertEqual(try service.failureCount(), 2)
        _ = try service.authenticate(pin: "1234")
        XCTAssertEqual(try service.failureCount(), 0)
    }

    // MARK: - decoy

    func test_decoyPIN_authenticatesWithDecoyCase() throws {
        let service = makeService()
        try service.setMainPIN("1234")
        try service.setDecoyPIN("0000")
        XCTAssertEqual(try service.authenticate(pin: "0000"), .authenticatedAsDecoy)
    }

    // MARK: - wipe

    func test_failureLimitReached_triggersWipeAndReturnsWiped() throws {
        let service = makeService(failureLimit: 3)
        try service.setMainPIN("1234")
        try service.setDecoyPIN("0000")

        XCTAssertEqual(try service.authenticate(pin: "bad"), .invalid)
        XCTAssertEqual(try service.authenticate(pin: "bad"), .invalid)
        XCTAssertEqual(try service.authenticate(pin: "bad"), .wiped)

        XCTAssertEqual(wipeCount, 1)
        XCTAssertFalse(service.hasMainPIN)
    }

    // MARK: - validation

    func test_setPIN_tooShort_throws() {
        let service = makeService()
        XCTAssertThrowsError(try service.setMainPIN("12"))
    }

    func test_setPIN_tooLong_throws() {
        let service = makeService()
        XCTAssertThrowsError(try service.setMainPIN("1234567"))
    }

    func test_setPIN_nonDigits_throws() {
        let service = makeService()
        XCTAssertThrowsError(try service.setMainPIN("abcd"))
    }

    // MARK: - auto-lock

    func test_autoLockTimeout_defaultIsOneMinute() {
        let service = makeService()
        XCTAssertEqual(service.autoLockTimeout, .oneMinute)
    }

    func test_autoLockTimeout_persistsAcrossInstances() {
        let service = makeService()
        service.autoLockTimeout = .fiveMinutes
        let reloaded = makeService()
        XCTAssertEqual(reloaded.autoLockTimeout, .fiveMinutes)
    }

    func test_biometricEnabled_toggle() {
        let service = makeService()
        XCTAssertFalse(service.biometricEnabled)
        service.biometricEnabled = true
        XCTAssertTrue(service.biometricEnabled)
        service.biometricEnabled = false
        XCTAssertFalse(service.biometricEnabled)
    }

    // MARK: - clear

    func test_clearPINs_removesBothPINs_andResetsCounter() throws {
        let service = makeService()
        try service.setMainPIN("1234")
        try service.setDecoyPIN("0000")
        _ = try service.authenticate(pin: "bad")
        try service.clearPINs()
        XCTAssertFalse(service.hasMainPIN)
        XCTAssertEqual(try service.failureCount(), 0)
        XCTAssertEqual(try service.authenticate(pin: "1234"), .invalid)
    }
}
