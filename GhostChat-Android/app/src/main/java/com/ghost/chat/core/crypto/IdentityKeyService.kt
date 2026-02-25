package com.ghost.chat.core.crypto

import android.util.Base64
import com.ghost.chat.core.security.KeystoreService
import java.security.KeyFactory
import java.security.KeyPair
import java.security.interfaces.ECPublicKey
import java.security.spec.PKCS8EncodedKeySpec

/// Manages the persistent P-256 Identity Key.
/// Generated once on first launch, stored in EncryptedSharedPreferences.
/// This key identifies the user between sessions.
object IdentityKeyService {

    private const val KEYSTORE_KEY_PRIVATE = "ghost_identity_key_private"
    private const val KEYSTORE_KEY_PUBLIC = "ghost_identity_key_public"

    private var _keyPair: KeyPair? = null

    /** Private identity key pair (lazy-loaded from Keystore or generated) */
    val keyPair: KeyPair
        get() {
            _keyPair?.let { return it }
            val kp = loadOrGenerate()
            _keyPair = kp
            return kp
        }

    /** Public identity key */
    val publicKey: ECPublicKey
        get() = keyPair.public as ECPublicKey

    /** x963 representation (65 bytes) for storage in Contact.identityKey */
    val publicKeyData: ByteArray
        get() = DoubleRatchet.exportPublicKeyX963(publicKey)

    /** Base64-encoded x963 public key for key-exchange wire protocol */
    fun exportPublicKey(): String {
        return Base64.encodeToString(publicKeyData, Base64.NO_WRAP)
    }

    /** Destroy identity key — panic button (wipes from Keystore + memory) */
    fun destroy() {
        _keyPair = null
        KeystoreService.delete(KEYSTORE_KEY_PRIVATE)
        KeystoreService.delete(KEYSTORE_KEY_PUBLIC)
    }

    // MARK: - Internal

    private fun loadOrGenerate(): KeyPair {
        // Try loading from Keystore
        val privateKeyData = KeystoreService.load(KEYSTORE_KEY_PRIVATE)
        val publicKeyData = KeystoreService.load(KEYSTORE_KEY_PUBLIC)

        if (privateKeyData != null && publicKeyData != null) {
            try {
                val kf = KeyFactory.getInstance("EC")
                val privateKey = kf.generatePrivate(PKCS8EncodedKeySpec(privateKeyData))
                val publicKey = DoubleRatchet.importPublicKeyX963(publicKeyData)
                return KeyPair(publicKey, privateKey)
            } catch (e: Exception) {
                // Corrupted — regenerate
            }
        }

        // Generate new key
        val kp = DoubleRatchet.generateKeyPair()
        KeystoreService.save(kp.private.encoded, KEYSTORE_KEY_PRIVATE)
        KeystoreService.save(DoubleRatchet.exportPublicKeyX963(kp.public as ECPublicKey), KEYSTORE_KEY_PUBLIC)
        return kp
    }
}
