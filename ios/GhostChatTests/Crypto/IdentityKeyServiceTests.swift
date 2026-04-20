import CryptoKit
import XCTest
@testable import GhostChat

final class IdentityKeyServiceTests: XCTestCase {

    private func makeService() -> IdentityKeyService {
        IdentityKeyService(keychain: InMemoryKeychain())
    }

    func test_getOrCreate_firstCall_generatesAndPersists() throws {
        let keychain = InMemoryKeychain()
        let service = IdentityKeyService(keychain: keychain)
        let key = try service.getOrCreateIdentity()
        XCTAssertEqual(key.rawRepresentation.count, 32, "P-256 private key raw is 32 bytes")
        XCTAssertNotNil(try keychain.get(IdentityKeyService.Keys.privateRaw))
    }

    func test_getOrCreate_isStableAcrossInstances() throws {
        let keychain = InMemoryKeychain()
        let first = try IdentityKeyService(keychain: keychain).getOrCreateIdentity()
        let second = try IdentityKeyService(keychain: keychain).getOrCreateIdentity()
        XCTAssertEqual(first.rawRepresentation, second.rawRepresentation)
    }

    func test_publicKeyX963_is65Bytes() throws {
        let service = makeService()
        let pub = try service.publicKeyX963
        XCTAssertEqual(pub.count, 65)
        XCTAssertEqual(pub[0], 0x04, "x963 prefix")
    }

    func test_publicKeyRaw_is64Bytes_withoutPrefix() throws {
        let service = makeService()
        let raw = try service.publicKeyRaw
        XCTAssertEqual(raw.count, 64)
    }

    func test_resetIdentity_generatesNewKeyNextCall() throws {
        let keychain = InMemoryKeychain()
        let service = IdentityKeyService(keychain: keychain)
        let first = try service.getOrCreateIdentity().rawRepresentation
        try service.resetIdentity()
        let second = try service.getOrCreateIdentity().rawRepresentation
        XCTAssertNotEqual(first, second)
    }

    func test_corruptKeychainEntry_throws() throws {
        let keychain = InMemoryKeychain()
        try keychain.set(Data([0xFF, 0xFF]), for: IdentityKeyService.Keys.privateRaw)
        let service = IdentityKeyService(keychain: keychain)
        XCTAssertThrowsError(try service.getOrCreateIdentity()) { err in
            XCTAssertEqual(err as? IdentityKeyService.Error, .decodingFailed)
        }
    }
}
