import Foundation
import LocalAuthentication
import CryptoKit
import CommonCrypto

/// Face ID / Touch ID + PIN code authentication service
/// Settings stored in Keychain (not UserDefaults) for security
@MainActor
final class BiometricAuthService: ObservableObject {

    // MARK: - Published State

    @Published var isUnlocked = false
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isPinSet: Bool
    @Published var pinLength: Int {
        didSet {
            if let data = "\(pinLength)".data(using: .utf8) {
                KeychainService.save(data, forKey: Self.pinLengthKey)
            }
        }
    }
    @Published var autoLockSeconds: Int {
        didSet {
            if let data = "\(autoLockSeconds)".data(using: .utf8) {
                KeychainService.save(data, forKey: Self.autoLockKey)
            }
        }
    }

    // MARK: - Constants

    private static let keychainKey = "biometric_enabled"
    private static let pinHashKey = "app_pin_hash"
    private static let pinLengthKey = "app_pin_length"
    private static let autoLockKey = "app_autolock_seconds"
    private static let backgroundTimestampKey = "app_background_ts"
    private static let failedAttemptsKey = "pin_failed_attempts"
    private static let lockedUntilKey = "pin_locked_until"

    // MARK: - Brute Force Protection

    private var failedPinAttempts: Int {
        get {
            guard let data = KeychainService.load(forKey: Self.failedAttemptsKey),
                  let str = String(data: data, encoding: .utf8),
                  let count = Int(str) else { return 0 }
            return count
        }
        set {
            if let data = "\(newValue)".data(using: .utf8) {
                KeychainService.save(data, forKey: Self.failedAttemptsKey)
            }
        }
    }

    private var pinLockedUntil: Date? {
        get {
            guard let data = KeychainService.load(forKey: Self.lockedUntilKey),
                  let str = String(data: data, encoding: .utf8),
                  let ts = Double(str) else { return nil }
            return Date(timeIntervalSince1970: ts)
        }
        set {
            if let date = newValue {
                let ts = "\(date.timeIntervalSince1970)"
                if let data = ts.data(using: .utf8) {
                    KeychainService.save(data, forKey: Self.lockedUntilKey)
                }
            } else {
                KeychainService.delete(forKey: Self.lockedUntilKey)
            }
        }
    }

    // MARK: - Init

    init() {
        // Load biometric setting from Keychain
        if let data = KeychainService.load(forKey: Self.keychainKey),
           let value = String(data: data, encoding: .utf8) {
            self.isEnabled = value == "1"
        } else {
            self.isEnabled = false
        }

        // Check if PIN is set
        self.isPinSet = KeychainService.load(forKey: Self.pinHashKey) != nil

        // Load PIN length (default 4)
        if let data = KeychainService.load(forKey: Self.pinLengthKey),
           let str = String(data: data, encoding: .utf8),
           let len = Int(str) {
            self.pinLength = len
        } else {
            self.pinLength = 4
        }

        // Load auto-lock timer (default 0 = instant)
        if let data = KeychainService.load(forKey: Self.autoLockKey),
           let str = String(data: data, encoding: .utf8),
           let secs = Int(str) {
            self.autoLockSeconds = secs
        } else {
            self.autoLockSeconds = 0
        }

        // Determine initial lock state
        if !isPinSet && !isEnabled {
            // No security configured — start unlocked
            isUnlocked = true
        } else if autoLockSeconds > 0 {
            // Timer-based lock: check if background timestamp is within the window
            // This enables "stay unlocked on cold start if timer hasn't expired"
            if let data = KeychainService.load(forKey: Self.backgroundTimestampKey),
               let str = String(data: data, encoding: .utf8),
               let ts = Int(str) {
                let elapsed = Int(Date().timeIntervalSince1970) - ts
                if elapsed < autoLockSeconds {
                    isUnlocked = true
                }
                // else: timer expired → isUnlocked stays false
            }
            // Clean up timestamp
            KeychainService.delete(forKey: Self.backgroundTimestampKey)
        }
        // else: instant lock (autoLockSeconds == 0) → isUnlocked stays false
    }

    // MARK: - Biometric Type Detection

    enum BiometricType {
        case faceID
        case touchID
        case none
    }

    static var biometricType: BiometricType {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }

        switch context.biometryType {
        case .faceID:
            return .faceID
        case .touchID:
            return .touchID
        case .opticID:
            return .faceID // Vision Pro — treat as Face ID
        case .none:
            return .none
        @unknown default:
            return .none
        }
    }

    static var isAvailable: Bool {
        biometricType != .none
    }

    var biometricName: String {
        switch Self.biometricType {
        case .faceID:
            return String(localized: "biometric.faceid")
        case .touchID:
            return String(localized: "biometric.touchid")
        case .none:
            return ""
        }
    }

    // MARK: - PIN Management

    /// Set or change PIN code (stored as PBKDF2-HMAC-SHA256 hash + salt in Keychain)
    func setPin(_ pin: String) {
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        guard let derivedKey = pbkdf2(pin: pin, salt: salt) else { return }
        let stored = salt + derivedKey  // 16 bytes salt + 32 bytes derived key
        KeychainService.save(stored, forKey: Self.pinHashKey)
        isPinSet = true
        // Reset brute force counters on PIN change
        failedPinAttempts = 0
        pinLockedUntil = nil
    }

    /// PBKDF2-HMAC-SHA256 key derivation (600k rounds)
    private func pbkdf2(pin: String, salt: Data, rounds: Int = 600_000) -> Data? {
        let pinData = Data(pin.utf8)
        var derivedKey = Data(count: 32)
        let result = derivedKey.withUnsafeMutableBytes { derivedKeyBytes in
            salt.withUnsafeBytes { saltBytes in
                pinData.withUnsafeBytes { pinBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pinBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        pinData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(rounds),
                        derivedKeyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        return result == kCCSuccess ? derivedKey : nil
    }

    /// Verify entered PIN against stored PBKDF2 hash with brute force protection
    func verifyPin(_ pin: String) -> Bool {
        // Check brute force lockout
        if let lockedUntil = pinLockedUntil, Date() < lockedUntil {
            return false
        }

        guard let stored = KeychainService.load(forKey: Self.pinHashKey) else { return false }

        // Support both old (32-byte SHA256) and new (48-byte PBKDF2) format
        let match: Bool
        if stored.count == 48 {
            // New format: 16 bytes salt + 32 bytes PBKDF2 hash
            let salt = Data(stored.prefix(16))
            let storedHash = Data(stored.suffix(32))
            guard let derivedKey = pbkdf2(pin: pin, salt: salt) else { return false }
            // Constant-time comparison
            var result: UInt8 = 0
            for (a, b) in zip(derivedKey, storedHash) { result |= a ^ b }
            match = result == 0
        } else {
            // Legacy format: 32-byte SHA256 — migrate on success
            let hash = Data(SHA256.hash(data: Data(pin.utf8)))
            match = hash == stored
            if match {
                // Auto-migrate to PBKDF2 format
                setPin(pin)
            }
        }

        if match {
            isUnlocked = true
            failedPinAttempts = 0
            pinLockedUntil = nil
        } else {
            let attempts = failedPinAttempts + 1
            failedPinAttempts = attempts
            if attempts >= 10 {
                // PANIC: 10 failed attempts — wipe all data
                panicWipe()
            } else if attempts >= 8 {
                // Lock for 5 minutes
                pinLockedUntil = Date().addingTimeInterval(300)
            } else if attempts >= 5 {
                // Lock for 30 seconds
                pinLockedUntil = Date().addingTimeInterval(30)
            }
        }
        return match
    }

    /// Remaining lockout seconds (for UI display)
    var pinLockoutRemaining: TimeInterval {
        guard let lockedUntil = pinLockedUntil else { return 0 }
        return max(0, lockedUntil.timeIntervalSinceNow)
    }

    /// Emergency wipe — 10 failed PIN attempts
    private func panicWipe() {
        // Destroy database + encryption key + identity key
        DatabaseService.destroy()
        // Clear all Keychain data
        KeychainService.delete(forKey: Self.pinHashKey)
        KeychainService.delete(forKey: Self.keychainKey)
        KeychainService.delete(forKey: Self.pinLengthKey)
        KeychainService.delete(forKey: Self.autoLockKey)
        KeychainService.delete(forKey: Self.failedAttemptsKey)
        KeychainService.delete(forKey: Self.lockedUntilKey)
        KeychainService.delete(forKey: Self.backgroundTimestampKey)
        // Reset state
        isPinSet = false
        isEnabled = false
        isUnlocked = true
        failedPinAttempts = 0
        pinLockedUntil = nil
    }

    /// Remove PIN code and disable biometric (biometric requires PIN)
    func removePin() {
        KeychainService.delete(forKey: Self.pinHashKey)
        isPinSet = false
        // Biometric requires PIN — disable it too
        setEnabled(false)
        isUnlocked = true
    }

    // MARK: - Authentication

    /// Authenticate with biometrics (or device passcode as fallback)
    func authenticate() async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "" // Hide "Enter Password" to force biometric
        context.localizedCancelTitle = nil

        var error: NSError?

        // Try biometrics first
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            // Biometrics unavailable — try device passcode as fallback
            return await authenticateWithPasscode()
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: String(localized: "biometric.reason")
            )
            if success {
                isUnlocked = true
            }
            return success
        } catch {
            // Biometric failed (e.g. face not recognized) — try passcode
            if let laError = error as? LAError,
               laError.code == .biometryLockout || laError.code == .biometryNotAvailable {
                return await authenticateWithPasscode()
            }
            return false
        }
    }

    /// Fallback: device passcode authentication
    private func authenticateWithPasscode() async -> Bool {
        let context = LAContext()

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: String(localized: "biometric.reason")
            )
            if success {
                isUnlocked = true
            }
            return success
        } catch {
            return false
        }
    }

    // MARK: - Toggle

    /// Enable or disable biometric lock (requires PIN to be set first)
    func setEnabled(_ enabled: Bool) {
        // Biometric requires PIN to be set first
        if enabled && !isPinSet { return }

        isEnabled = enabled
        let value = enabled ? "1" : "0"
        if let data = value.data(using: .utf8) {
            KeychainService.save(data, forKey: Self.keychainKey)
        }

        // If disabling and no PIN, unlock immediately
        if !enabled && !isPinSet {
            isUnlocked = true
        }
    }

    /// Save background timestamp (for auto-lock timer).
    /// Called on .inactive — harmless if .background also fires (it will overwrite).
    func saveBackgroundTimestamp() {
        guard isPinSet || isEnabled else { return }
        guard autoLockSeconds > 0 else { return }

        let ts = "\(Int(Date().timeIntervalSince1970))"
        if let data = ts.data(using: .utf8) {
            KeychainService.save(data, forKey: Self.backgroundTimestampKey)
        }
    }

    /// Record background timestamp (for auto-lock timer)
    func didEnterBackground() {
        guard isPinSet || isEnabled else { return }

        if autoLockSeconds == 0 {
            // Instant lock
            isUnlocked = false
        } else {
            // Record timestamp for delayed lock
            saveBackgroundTimestamp()
        }
    }

    /// Check auto-lock timer on foreground return
    func didEnterForeground() {
        guard isPinSet || isEnabled else { return }
        guard autoLockSeconds > 0 else { return } // instant lock already handled

        if let data = KeychainService.load(forKey: Self.backgroundTimestampKey),
           let str = String(data: data, encoding: .utf8),
           let ts = Int(str) {
            let elapsed = Int(Date().timeIntervalSince1970) - ts
            if elapsed >= autoLockSeconds {
                isUnlocked = false
            }
        }
        // Clean up timestamp
        KeychainService.delete(forKey: Self.backgroundTimestampKey)
    }

    /// Lock the app immediately
    func lock() {
        guard isPinSet || isEnabled else { return }
        isUnlocked = false
    }

    /// Re-read Keychain state (used after first-launch cleanup)
    func refreshState() {
        if let data = KeychainService.load(forKey: Self.keychainKey),
           let value = String(data: data, encoding: .utf8) {
            isEnabled = value == "1"
        } else {
            isEnabled = false
        }
        isPinSet = KeychainService.load(forKey: Self.pinHashKey) != nil

        if let data = KeychainService.load(forKey: Self.pinLengthKey),
           let str = String(data: data, encoding: .utf8),
           let len = Int(str) {
            pinLength = len
        } else {
            pinLength = 4
        }

        if let data = KeychainService.load(forKey: Self.autoLockKey),
           let str = String(data: data, encoding: .utf8),
           let secs = Int(str) {
            autoLockSeconds = secs
        } else {
            autoLockSeconds = 0
        }

        if !isPinSet && !isEnabled {
            isUnlocked = true
        }
    }
}
