import XCTest
@testable import GhostChat

/// Integration tests against the real system Keychain.
///
/// The iOS simulator returns errSecMissingEntitlement (-34018) unless the running
/// bundle has a keychain-access-group; host-based test bundles without explicit
/// signing frequently don't. Tests self-skip in that case so CI stays green.
/// Keychain behaviour on real devices is covered by end-to-end QA.
final class KeychainServiceTests: XCTestCase {

    private var keychain: KeychainService!
    private let testService = "com.kordar.ghostchat.tests.\(UUID().uuidString)"

    override func setUpWithError() throws {
        try super.setUpWithError()
        keychain = KeychainService(service: testService)
        do {
            try keychain.set(Data([0xAA]), for: "__preflight__")
            try keychain.delete("__preflight__")
        } catch KeychainService.Error.unhandled(let status) where status == -34018 {
            throw XCTSkip("Keychain unavailable in this environment (errSecMissingEntitlement)")
        }
    }

    override func tearDown() {
        try? keychain.deleteAll()
        super.tearDown()
    }

    func test_setAndGet_returnsStoredData() throws {
        let value = Data("hello".utf8)
        try keychain.set(value, for: "alpha")
        XCTAssertEqual(try keychain.get("alpha"), value)
    }

    func test_get_missingKey_returnsNil() throws {
        XCTAssertNil(try keychain.get("ghost"))
    }

    func test_set_overwritesExisting() throws {
        try keychain.set(Data("one".utf8), for: "k")
        try keychain.set(Data("two".utf8), for: "k")
        XCTAssertEqual(try keychain.get("k"), Data("two".utf8))
    }

    func test_delete_removesEntry() throws {
        try keychain.set(Data("x".utf8), for: "k")
        try keychain.delete("k")
        XCTAssertNil(try keychain.get("k"))
    }

    func test_delete_missingKey_doesNotThrow() throws {
        XCTAssertNoThrow(try keychain.delete("never-set"))
    }

    func test_deleteAll_removesOnlyThisService() throws {
        let other = KeychainService(service: "com.kordar.ghostchat.tests.other.\(UUID().uuidString)")
        try other.set(Data("other".utf8), for: "shared-key")
        try keychain.set(Data("mine".utf8), for: "shared-key")

        try keychain.deleteAll()

        XCTAssertNil(try keychain.get("shared-key"))
        XCTAssertEqual(try other.get("shared-key"), Data("other".utf8))
        try other.deleteAll()
    }

    func test_largePayload_roundtrip() throws {
        let data = Data(repeating: 0xAB, count: 4096)
        try keychain.set(data, for: "big")
        XCTAssertEqual(try keychain.get("big"), data)
    }
}

final class InMemoryKeychainTests: XCTestCase {
    func test_inMemoryMatchesKeychainAPI() throws {
        let k: KeychainServicing = InMemoryKeychain()
        try k.set(Data("x".utf8), for: "a")
        XCTAssertEqual(try k.get("a"), Data("x".utf8))
        try k.delete("a")
        XCTAssertNil(try k.get("a"))
        try k.set(Data("1".utf8), for: "b")
        try k.set(Data("2".utf8), for: "c")
        try k.deleteAll()
        XCTAssertNil(try k.get("b"))
        XCTAssertNil(try k.get("c"))
    }
}
