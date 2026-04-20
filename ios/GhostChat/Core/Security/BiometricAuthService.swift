import CryptoKit
import Foundation
import LocalAuthentication

/// Salted SHA-256 hash of a user PIN.
struct PINHash: Codable, Equatable {
    let salt: Data
    let hash: Data

    static func make(pin: String) -> PINHash {
        let salt = randomSalt()
        return PINHash(salt: salt, hash: Self.compute(pin: pin, salt: salt))
    }

    func verify(pin: String) -> Bool {
        Self.compute(pin: pin, salt: salt) == hash
    }

    static func compute(pin: String, salt: Data) -> Data {
        var input = Data()
        input.append(salt)
        input.append(contentsOf: pin.utf8)
        return Data(SHA256.hash(data: input))
    }

    static func randomSalt(length: Int = 32) -> Data {
        var bytes = Data(count: length)
        let status = bytes.withUnsafeMutableBytes { buf in
            SecRandomCopyBytes(kSecRandomDefault, length, buf.baseAddress!)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return bytes
    }
}

final class BiometricAuthService {

    enum AuthResult: Equatable {
        case authenticated
        case authenticatedAsDecoy
        case invalid
        case wiped
    }

    struct Keys {
        static let mainPIN       = "auth.pin.main"
        static let decoyPIN      = "auth.pin.decoy"
        static let failureCount  = "auth.fail.count"
        static let biometric     = "auth.biometric.enabled"
        static let autoLockSec   = "auth.autolock.seconds"
    }

    struct Config {
        var failureLimit: Int = 10
        var onWipe: () -> Void = {}
    }

    private let keychain: KeychainServicing
    private var config: Config

    init(keychain: KeychainServicing, config: Config = .init()) {
        self.keychain = keychain
        self.config = config
    }

    // MARK: - PIN management

    func setMainPIN(_ pin: String) throws {
        try validate(pin: pin)
        let hash = PINHash.make(pin: pin)
        try keychain.set(try JSONEncoder().encode(hash), for: Keys.mainPIN)
    }

    func setDecoyPIN(_ pin: String) throws {
        try validate(pin: pin)
        let hash = PINHash.make(pin: pin)
        try keychain.set(try JSONEncoder().encode(hash), for: Keys.decoyPIN)
    }

    func clearPINs() throws {
        try keychain.delete(Keys.mainPIN)
        try keychain.delete(Keys.decoyPIN)
        try resetFailureCount()
    }

    var hasMainPIN: Bool {
        (try? keychain.get(Keys.mainPIN)) != nil
    }

    // MARK: - Authenticate

    func authenticate(pin: String) throws -> AuthResult {
        if let mainData = try keychain.get(Keys.mainPIN),
           let main = try? JSONDecoder().decode(PINHash.self, from: mainData),
           main.verify(pin: pin) {
            try resetFailureCount()
            return .authenticated
        }
        if let decoyData = try keychain.get(Keys.decoyPIN),
           let decoy = try? JSONDecoder().decode(PINHash.self, from: decoyData),
           decoy.verify(pin: pin) {
            try resetFailureCount()
            return .authenticatedAsDecoy
        }
        let count = try incrementFailureCount()
        if count >= config.failureLimit {
            try clearPINs()
            config.onWipe()
            return .wiped
        }
        return .invalid
    }

    func authenticateBiometric(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }
        return await withCheckedContinuation { cont in
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
                cont.resume(returning: success)
            }
        }
    }

    // MARK: - Failure counter

    func failureCount() throws -> Int {
        let data = try keychain.get(Keys.failureCount)
        guard let bytes = data,
              let str = String(data: bytes, encoding: .utf8),
              let n = Int(str) else { return 0 }
        return n
    }

    private func incrementFailureCount() throws -> Int {
        let n = (try failureCount()) + 1
        try keychain.set(Data("\(n)".utf8), for: Keys.failureCount)
        return n
    }

    private func resetFailureCount() throws {
        try keychain.set(Data("0".utf8), for: Keys.failureCount)
    }

    // MARK: - Biometric toggle

    var biometricEnabled: Bool {
        get {
            guard let data = try? keychain.get(Keys.biometric) else { return false }
            return data == Data([0x01])
        }
        set {
            try? keychain.set(Data([newValue ? 0x01 : 0x00]), for: Keys.biometric)
        }
    }

    // MARK: - Auto-lock

    var autoLockTimeout: AutoLockTimeout {
        get {
            guard let data = try? keychain.get(Keys.autoLockSec),
                  let str = String(data: data, encoding: .utf8),
                  let seconds = Int(str),
                  let value = AutoLockTimeout(rawValue: seconds) else {
                return .oneMinute
            }
            return value
        }
        set {
            try? keychain.set(Data("\(newValue.rawValue)".utf8), for: Keys.autoLockSec)
        }
    }

    // MARK: - Validation

    private func validate(pin: String) throws {
        guard pin.count >= 4, pin.count <= 6, pin.allSatisfy({ $0.isNumber }) else {
            throw PINError.invalidFormat
        }
    }

    enum PINError: Swift.Error, Equatable {
        case invalidFormat
    }
}
