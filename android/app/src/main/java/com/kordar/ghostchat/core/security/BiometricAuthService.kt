package com.kordar.ghostchat.core.security

import com.kordar.ghostchat.models.AutoLockTimeout
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * PIN + biometric authentication service. Mirrors iOS `BiometricAuthService`:
 *
 * - SHA-256(salt || pin) hash (identical to iOS)
 * - main PIN + optional decoy PIN
 * - 10 failed attempts → panic wipe (invokes `Config.onWipe`)
 * - biometric gate (BiometricPrompt launcher is injected so the service itself
 *   stays free of Android UI APIs and testable)
 */
class BiometricAuthService(
    private val keystore: KeystoreServicing,
    private val biometricLauncher: BiometricLauncher = BiometricLauncher.Unavailable,
    private var config: Config = Config()
) {

    sealed class AuthResult {
        data object Authenticated      : AuthResult()
        data object AuthenticatedDecoy : AuthResult()
        data object Invalid            : AuthResult()
        data object Wiped              : AuthResult()
    }

    data class Config(
        val failureLimit: Int = 10,
        val onWipe: () -> Unit = {}
    )

    object Keys {
        const val MAIN_PIN      = "auth.pin.main"
        const val DECOY_PIN     = "auth.pin.decoy"
        const val FAILURE_COUNT = "auth.fail.count"
        const val BIOMETRIC     = "auth.biometric.enabled"
        const val AUTO_LOCK_SEC = "auth.autolock.seconds"
    }

    /** PIN entry validation — same shape as iOS. */
    enum class PINError { INVALID_FORMAT }

    // MARK: - PIN management

    fun setMainPIN(pin: String) {
        validate(pin)
        val hash = PINHash.create(pin)
        keystore.set(Keys.MAIN_PIN, hash.encoded())
    }

    fun setDecoyPIN(pin: String) {
        validate(pin)
        val hash = PINHash.create(pin)
        keystore.set(Keys.DECOY_PIN, hash.encoded())
    }

    fun clearPINs() {
        keystore.delete(Keys.MAIN_PIN)
        keystore.delete(Keys.DECOY_PIN)
        resetFailureCount()
    }

    fun hasMainPIN(): Boolean = keystore.get(Keys.MAIN_PIN) != null

    // MARK: - Authenticate

    fun authenticate(pin: String): AuthResult {
        keystore.get(Keys.MAIN_PIN)?.let { raw ->
            val hash = PINHash.fromEncoded(raw)
            if (hash != null && hash.verify(pin)) {
                resetFailureCount()
                return AuthResult.Authenticated
            }
        }
        keystore.get(Keys.DECOY_PIN)?.let { raw ->
            val hash = PINHash.fromEncoded(raw)
            if (hash != null && hash.verify(pin)) {
                resetFailureCount()
                return AuthResult.AuthenticatedDecoy
            }
        }
        val count = incrementFailureCount()
        if (count >= config.failureLimit) {
            clearPINs()
            config.onWipe()
            return AuthResult.Wiped
        }
        return AuthResult.Invalid
    }

    /** Suspends until biometric check completes — delegates to the injected launcher. */
    suspend fun authenticateBiometric(reason: String): Boolean =
        biometricLauncher.prompt(reason)

    // MARK: - Failure counter

    fun failureCount(): Int =
        keystore.get(Keys.FAILURE_COUNT)?.let { String(it, StandardCharsets.UTF_8).toIntOrNull() } ?: 0

    private fun incrementFailureCount(): Int {
        val next = failureCount() + 1
        keystore.set(Keys.FAILURE_COUNT, next.toString().toByteArray(StandardCharsets.UTF_8))
        return next
    }

    private fun resetFailureCount() {
        keystore.set(Keys.FAILURE_COUNT, "0".toByteArray(StandardCharsets.UTF_8))
    }

    // MARK: - Biometric toggle

    var biometricEnabled: Boolean
        get() = (keystore.get(Keys.BIOMETRIC)?.firstOrNull() == 0x01.toByte())
        set(value) = keystore.set(Keys.BIOMETRIC, byteArrayOf(if (value) 0x01 else 0x00))

    // MARK: - Auto-lock

    var autoLockTimeout: AutoLockTimeout
        get() {
            val raw = keystore.get(Keys.AUTO_LOCK_SEC) ?: return AutoLockTimeout.ONE_MINUTE
            val sec = String(raw, StandardCharsets.UTF_8).toIntOrNull() ?: return AutoLockTimeout.ONE_MINUTE
            return AutoLockTimeout.fromSeconds(sec)
        }
        set(value) = keystore.set(Keys.AUTO_LOCK_SEC, value.seconds.toString().toByteArray(StandardCharsets.UTF_8))

    // MARK: - Private

    private fun validate(pin: String) {
        if (pin.length !in 4..6 || !pin.all { it.isDigit() }) {
            throw IllegalArgumentException(PINError.INVALID_FORMAT.name)
        }
    }
}

/** Salted SHA-256 digest of a PIN. Encoded form is `JSON { salt: base16, hash: base16 }`. */
internal data class PINHash(val salt: ByteArray, val hash: ByteArray) {

    fun verify(pin: String): Boolean = compute(pin, salt).contentEquals(hash)

    fun encoded(): ByteArray = Json.encodeToString(Encoded.serializer(),
        Encoded(salt = salt.toHex(), hash = hash.toHex())
    ).toByteArray(StandardCharsets.UTF_8)

    @Serializable
    private data class Encoded(val salt: String, val hash: String)

    companion object {
        fun create(pin: String): PINHash {
            val salt = randomSalt()
            return PINHash(salt, compute(pin, salt))
        }

        fun fromEncoded(data: ByteArray): PINHash? = runCatching {
            val raw = String(data, StandardCharsets.UTF_8)
            val encoded = Json.decodeFromString(Encoded.serializer(), raw)
            PINHash(salt = encoded.salt.fromHex(), hash = encoded.hash.fromHex())
        }.getOrNull()

        fun compute(pin: String, salt: ByteArray): ByteArray {
            val digest = MessageDigest.getInstance("SHA-256")
            digest.update(salt)
            digest.update(pin.toByteArray(StandardCharsets.UTF_8))
            return digest.digest()
        }

        fun randomSalt(length: Int = 32): ByteArray =
            ByteArray(length).also { SecureRandom().nextBytes(it) }

        private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

        private fun String.fromHex(): ByteArray {
            check(length % 2 == 0) { "odd hex length" }
            return chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        }
    }
}

/** Abstraction over BiometricPrompt so the service is testable without an Activity. */
fun interface BiometricLauncher {
    suspend fun prompt(reason: String): Boolean

    object Unavailable : BiometricLauncher {
        override suspend fun prompt(reason: String): Boolean = false
    }
}
