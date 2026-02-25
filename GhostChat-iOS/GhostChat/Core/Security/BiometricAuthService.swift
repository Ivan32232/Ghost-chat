import Foundation
import LocalAuthentication

/// Face ID / Touch ID authentication service
/// Setting stored in Keychain (not UserDefaults) for security
@MainActor
final class BiometricAuthService: ObservableObject {

    // MARK: - Published State

    @Published var isUnlocked = false
    @Published private(set) var isEnabled: Bool

    // MARK: - Constants

    private static let keychainKey = "biometric_enabled"

    // MARK: - Init

    init() {
        // Load setting from Keychain
        if let data = KeychainService.load(forKey: Self.keychainKey),
           let value = String(data: data, encoding: .utf8) {
            self.isEnabled = value == "1"
        } else {
            self.isEnabled = false
        }

        // If biometric is not enabled, start unlocked
        if !isEnabled {
            isUnlocked = true
        }
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

    /// Enable or disable biometric lock
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        let value = enabled ? "1" : "0"
        if let data = value.data(using: .utf8) {
            KeychainService.save(data, forKey: Self.keychainKey)
        }

        // If disabling, unlock immediately
        if !enabled {
            isUnlocked = true
        }
    }

    /// Lock the app (called when going to background)
    func lock() {
        guard isEnabled else { return }
        isUnlocked = false
    }
}
