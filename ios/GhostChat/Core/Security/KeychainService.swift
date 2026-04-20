import Foundation
import Security

protocol KeychainServicing: AnyObject {
    func set(_ data: Data, for key: String) throws
    func get(_ key: String) throws -> Data?
    func delete(_ key: String) throws
    func deleteAll() throws
}

final class KeychainService: KeychainServicing {

    enum Error: Swift.Error, Equatable {
        case unhandled(OSStatus)
    }

    private let service: String

    init(service: String = "com.kordar.ghostchat") {
        self.service = service
    }

    // MARK: - Set

    func set(_ data: Data, for key: String) throws {
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        key,
            kSecAttrAccessible as String:     kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrIsInvisible as String:    true,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String:          data
        ]
        let deleteStatus = SecItemDelete([
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ] as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            throw Error.unhandled(deleteStatus)
        }

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Error.unhandled(status) }
    }

    // MARK: - Get

    func get(_ key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw Error.unhandled(status)
        }
    }

    // MARK: - Delete

    func delete(_ key: String) throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Error.unhandled(status)
        }
    }

    func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Error.unhandled(status)
        }
    }
}

/// In-memory keychain for tests.
final class InMemoryKeychain: KeychainServicing {
    private var storage: [String: Data] = [:]
    private let queue = DispatchQueue(label: "InMemoryKeychain")

    func set(_ data: Data, for key: String) throws {
        queue.sync { storage[key] = data }
    }
    func get(_ key: String) throws -> Data? {
        queue.sync { storage[key] }
    }
    func delete(_ key: String) throws {
        queue.sync { _ = storage.removeValue(forKey: key) }
    }
    func deleteAll() throws {
        queue.sync { storage.removeAll() }
    }
}
