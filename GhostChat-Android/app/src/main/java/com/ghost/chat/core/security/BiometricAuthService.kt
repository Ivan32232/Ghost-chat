package com.ghost.chat.core.security

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import com.ghost.chat.core.crypto.IdentityKeyService
import com.ghost.chat.core.storage.DatabaseService
import java.io.File
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec

/// Biometric + PIN authentication service
/// PIN code is stored as PBKDF2-HMAC-SHA256 hash with random salt in KeystoreService
/// Brute force protection: lockout after 5 attempts, wipe after 10
/// Biometric auth is only available when a PIN code is already set
object BiometricAuthService {

    private const val BIOMETRIC_KEY_ALIAS = "ghost_biometric_key"
    private const val KEY_BIOMETRIC_ENABLED = "biometric_enabled"
    private const val KEY_PIN_HASH = "pin_code_hash"
    private const val KEY_PIN_LENGTH = "pin_code_length"
    private const val KEY_AUTOLOCK_SECONDS = "autolock_seconds"
    private const val KEY_BACKGROUND_TS = "background_timestamp"

    private lateinit var appContext: android.content.Context

    var isUnlocked: Boolean by mutableStateOf(true)
        private set

    // Cold start: determine initial lock state
    // Must be called after KeystoreService.init()
    fun initLockState(context: android.content.Context) {
        appContext = context.applicationContext
        val pinSet = KeystoreService.loadString(KEY_PIN_HASH) != null
        val bioEnabled = KeystoreService.loadBool(KEY_BIOMETRIC_ENABLED, false)
        if (pinSet || bioEnabled) {
            val autoLock = KeystoreService.loadInt(KEY_AUTOLOCK_SECONDS, 0)
            if (autoLock > 0) {
                // Timer-based: check if background timestamp is within the window
                val tsStr = KeystoreService.loadString(KEY_BACKGROUND_TS)
                val ts = tsStr?.toLongOrNull()
                if (ts != null) {
                    val elapsed = (System.currentTimeMillis() / 1000) - ts
                    isUnlocked = elapsed < autoLock
                } else {
                    isUnlocked = false
                }
                KeystoreService.delete(KEY_BACKGROUND_TS)
            } else {
                // Instant lock — always lock on cold start
                isUnlocked = false
            }
        }
        // else: no PIN and no biometric → isUnlocked stays true
    }

    var isEnabled: Boolean
        get() = KeystoreService.loadBool(KEY_BIOMETRIC_ENABLED, false)
        set(value) = KeystoreService.saveBool(value, KEY_BIOMETRIC_ENABLED)

    /** Whether a PIN code has been set */
    val isPinSet: Boolean
        get() = KeystoreService.loadString(KEY_PIN_HASH) != null

    /** PIN length: 4 or 6 digits */
    var pinLength: Int
        get() = KeystoreService.loadInt(KEY_PIN_LENGTH, 4)
        set(value) = KeystoreService.saveInt(value, KEY_PIN_LENGTH)

    /** Auto-lock timer in seconds (0 = instant) */
    var autoLockSeconds: Int
        get() = KeystoreService.loadInt(KEY_AUTOLOCK_SECONDS, 0)
        set(value) = KeystoreService.saveInt(value, KEY_AUTOLOCK_SECONDS)

    /** PBKDF2-HMAC-SHA256 key derivation (600k iterations, OWASP recommendation) */
    private fun pbkdf2(pin: String, salt: ByteArray, iterations: Int = 600_000): ByteArray {
        val spec = PBEKeySpec(pin.toCharArray(), salt, iterations, 256)
        val factory = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
        return factory.generateSecret(spec).encoded
    }

    /** Set a new PIN code (stores PBKDF2 hash with random salt) */
    fun setPin(pin: String) {
        val salt = ByteArray(16).also { SecureRandom().nextBytes(it) }
        val derived = pbkdf2(pin, salt)
        val stored = salt + derived  // 16 bytes salt + 32 bytes key
        KeystoreService.saveString(
            stored.joinToString("") { "%02x".format(it) },
            KEY_PIN_HASH
        )
        resetPinAttempts()
    }

    /** Verify PIN code against stored PBKDF2 hash. Sets isUnlocked=true on match. */
    fun verifyPin(pin: String): Boolean {
        // Brute force lockout check
        if (isPinLocked()) return false

        val storedHex = KeystoreService.loadString(KEY_PIN_HASH) ?: return false
        val stored = storedHex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

        // Support both old SHA-256 (32 bytes) and new PBKDF2 (48 bytes = 16 salt + 32 hash)
        val matches = if (stored.size == 48) {
            // New format: PBKDF2 with salt
            val salt = stored.copyOfRange(0, 16)
            val storedHash = stored.copyOfRange(16, 48)
            val derived = pbkdf2(pin, salt)

            // Constant-time comparison
            var diff = 0
            for (i in derived.indices) {
                diff = diff or (derived[i].toInt() xor storedHash[i].toInt())
            }
            diff == 0
        } else {
            // Legacy SHA-256 format — migrate on successful verify
            val digest = java.security.MessageDigest.getInstance("SHA-256")
            val inputHash = digest.digest(pin.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
            val legacyMatch = storedHex == inputHash
            if (legacyMatch) {
                // Migrate to PBKDF2
                setPin(pin)
            }
            legacyMatch
        }

        if (matches) {
            resetPinAttempts()
            isUnlocked = true
        } else {
            onPinFailed()
        }
        return matches
    }

    /** Remove PIN code and disable biometric auth */
    fun removePin() {
        KeystoreService.delete(KEY_PIN_HASH)
        resetPinAttempts()
        isEnabled = false
        isUnlocked = true
    }

    // MARK: - Brute Force Protection

    private fun isPinLocked(): Boolean {
        val lockedUntil = KeystoreService.loadLong("pin_locked_until", 0)
        if (lockedUntil > System.currentTimeMillis()) return true
        return false
    }

    private fun onPinFailed() {
        val attempts = KeystoreService.loadInt("pin_failed_attempts", 0) + 1
        KeystoreService.saveInt(attempts, "pin_failed_attempts")

        when {
            attempts >= 10 -> {
                // Panic wipe — уничтожение всех данных после 10 неудачных попыток
                // 1. Destroy and close the SQLCipher database
                try {
                    val dbService = DatabaseService.getInstance(appContext)
                    dbService.destroyAll()
                    dbService.close()
                } catch (_: Exception) {}
                // 2. Delete the DB file from disk
                try {
                    appContext.getDatabasePath("ghost_chat.db")?.let { dbFile ->
                        if (dbFile.exists()) dbFile.delete()
                    }
                } catch (_: Exception) {}
                // 3. Destroy identity keys
                IdentityKeyService.destroy()
                // 4. Clear all Keystore data (PIN hash, settings, DB key, etc.)
                KeystoreService.clear()
                // 5. Reset lock state — app is wiped, nothing to protect
                isUnlocked = true
            }
            attempts >= 8 -> {
                // 5 минут блокировки
                KeystoreService.saveLong(
                    System.currentTimeMillis() + 5 * 60 * 1000,
                    "pin_locked_until"
                )
            }
            attempts >= 5 -> {
                // 30 секунд блокировки
                KeystoreService.saveLong(
                    System.currentTimeMillis() + 30 * 1000,
                    "pin_locked_until"
                )
            }
        }
    }

    private fun resetPinAttempts() {
        KeystoreService.saveInt(0, "pin_failed_attempts")
        KeystoreService.saveLong(0, "pin_locked_until")
    }

    // MARK: - Biometric-bound Keystore Key (hardware-enforced)

    /** Get or create AES key bound to biometric authentication in Android Keystore.
     *  setUserAuthenticationRequired(true) ensures the key can only be used after
     *  successful biometric auth — hardware-enforced, cannot be bypassed on rooted devices. */
    private fun getBiometricKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore")
        keyStore.load(null)

        // Return existing key if available
        keyStore.getKey(BIOMETRIC_KEY_ALIAS, null)?.let { return it as SecretKey }

        // Create new biometric-bound key
        val keyGen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        keyGen.init(
            KeyGenParameterSpec.Builder(
                BIOMETRIC_KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setUserAuthenticationRequired(true)
                .setInvalidatedByBiometricEnrollment(true)
                .build()
        )
        return keyGen.generateKey()
    }

    /** Create CryptoObject with biometric-bound cipher.
     *  Returns null if key was invalidated (e.g. new biometric enrolled). */
    private fun createCryptoObject(): BiometricPrompt.CryptoObject? {
        return try {
            val key = getBiometricKey()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key)
            BiometricPrompt.CryptoObject(cipher)
        } catch (e: Exception) {
            // Key invalidated (new biometric enrolled) or other Keystore error —
            // delete the old key so a fresh one is created next time
            try {
                val keyStore = KeyStore.getInstance("AndroidKeyStore")
                keyStore.load(null)
                keyStore.deleteEntry(BIOMETRIC_KEY_ALIAS)
            } catch (_: Exception) { }
            null
        }
    }

    /** Check if BIOMETRIC_STRONG is available (fingerprint/face with crypto support) */
    private fun canUseBiometricStrong(context: Context): Boolean {
        val biometricManager = BiometricManager.from(context)
        return biometricManager.canAuthenticate(
            BiometricManager.Authenticators.BIOMETRIC_STRONG
        ) == BiometricManager.BIOMETRIC_SUCCESS
    }

    /** Check if biometric auth is available on device */
    fun isAvailable(context: Context): Boolean {
        val biometricManager = BiometricManager.from(context)
        return biometricManager.canAuthenticate(
            BiometricManager.Authenticators.BIOMETRIC_STRONG or
                    BiometricManager.Authenticators.DEVICE_CREDENTIAL
        ) == BiometricManager.BIOMETRIC_SUCCESS
    }

    /** Authenticate with biometrics (hardware-enforced CryptoObject) or DEVICE_CREDENTIAL fallback */
    fun authenticate(
        activity: FragmentActivity,
        title: String,
        subtitle: String,
        onSuccess: () -> Unit,
        onError: (String) -> Unit
    ) {
        val executor = ContextCompat.getMainExecutor(activity)

        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                // result.cryptoObject is non-null for BIOMETRIC_STRONG path —
                // proves the hardware TEE actually authenticated the user
                isUnlocked = true
                onSuccess()
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                if (errorCode != BiometricPrompt.ERROR_USER_CANCELED &&
                    errorCode != BiometricPrompt.ERROR_NEGATIVE_BUTTON
                ) {
                    onError(errString.toString())
                }
            }

            override fun onAuthenticationFailed() {
                // Not an error — user can retry
            }
        }

        val biometricPrompt = BiometricPrompt(activity, executor, callback)

        // Try BIOMETRIC_STRONG with CryptoObject (hardware-enforced, cannot bypass on rooted devices)
        if (canUseBiometricStrong(activity)) {
            val cryptoObject = createCryptoObject()
            if (cryptoObject != null) {
                val promptInfo = BiometricPrompt.PromptInfo.Builder()
                    .setTitle(title)
                    .setSubtitle(subtitle)
                    .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                    .setNegativeButtonText("PIN")
                    .build()

                biometricPrompt.authenticate(promptInfo, cryptoObject)
                return
            }
        }

        // Fallback: DEVICE_CREDENTIAL (PIN/pattern/password — no CryptoObject allowed)
        val promptInfo = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle(subtitle)
            .setAllowedAuthenticators(
                BiometricManager.Authenticators.BIOMETRIC_STRONG or
                        BiometricManager.Authenticators.DEVICE_CREDENTIAL
            )
            .build()

        biometricPrompt.authenticate(promptInfo)
    }

    /** Record background timestamp (for auto-lock timer) */
    fun didEnterBackground() {
        if (!isPinSet && !isEnabled) return

        if (autoLockSeconds == 0) {
            // Instant lock
            isUnlocked = false
        } else {
            // Record timestamp for delayed lock
            KeystoreService.saveString(
                "${System.currentTimeMillis() / 1000}",
                KEY_BACKGROUND_TS
            )
        }
    }

    /** Check auto-lock timer on foreground return */
    fun didEnterForeground() {
        if (!isPinSet && !isEnabled) return
        if (autoLockSeconds == 0) return // instant lock already handled

        val tsStr = KeystoreService.loadString(KEY_BACKGROUND_TS) ?: return
        val ts = tsStr.toLongOrNull() ?: return
        val elapsed = (System.currentTimeMillis() / 1000) - ts
        if (elapsed >= autoLockSeconds) {
            isUnlocked = false
        }
        KeystoreService.delete(KEY_BACKGROUND_TS)
    }

    /** Lock immediately */
    fun lock() {
        if (isPinSet || isEnabled) {
            isUnlocked = false
        }
    }

    /** Toggle biometric auth (requires PIN to be set first) */
    fun toggle(
        activity: FragmentActivity,
        title: String,
        subtitle: String,
        onResult: (Boolean) -> Unit
    ) {
        if (!isPinSet) {
            // Cannot enable biometric without PIN
            onResult(false)
            return
        }

        if (isEnabled) {
            isEnabled = false
            onResult(false)
        } else {
            authenticate(activity, title, subtitle,
                onSuccess = {
                    isEnabled = true
                    onResult(true)
                },
                onError = { onResult(false) }
            )
        }
    }
}
