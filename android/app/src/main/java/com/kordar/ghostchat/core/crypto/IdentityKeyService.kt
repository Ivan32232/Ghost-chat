package com.kordar.ghostchat.core.crypto

import com.kordar.ghostchat.core.crypto.CryptoUtils as Bc
import com.kordar.ghostchat.core.security.KeystoreServicing

/**
 * Persistent P-256 identity keypair. Generated once on first call, then retained in the
 * [KeystoreServicing]-backed secure store. Mirrors iOS `IdentityKeyService`: the public
 * key represents "who am I" for safety-number comparison and for the pending-room
 * HOST/GUEST determination.
 */
class IdentityKeyService(
    private val keystore: KeystoreServicing
) {

    object Keys {
        const val PRIVATE_RAW = "identity.private.raw"
    }

    @Volatile private var cached: Bc.ECKeyPair? = null

    /** Get or lazily create the identity keypair. Thread-safe. */
    @Synchronized
    fun getOrCreateIdentity(): Bc.ECKeyPair {
        cached?.let { return it }
        val stored = keystore.get(Keys.PRIVATE_RAW)
        val keypair = if (stored != null) {
            Bc.keyPairFromPrivateBytes(stored)
        } else {
            Bc.generateKeyPair().also { fresh ->
                keystore.set(Keys.PRIVATE_RAW, fresh.privateKeyBytes)
            }
        }
        cached = keypair
        return keypair
    }

    /** 65-byte uncompressed public (0x04 || X || Y). */
    val publicKeyX963: ByteArray
        get() = getOrCreateIdentity().publicKeyBytes

    /** 64-byte raw public (X || Y) for safety-number input. */
    val publicKeyRaw: ByteArray
        get() = getOrCreateIdentity().publicKeyRaw

    /** Irrevocably deletes the identity. Called during panic wipe. */
    @Synchronized
    fun resetIdentity() {
        cached = null
        keystore.delete(Keys.PRIVATE_RAW)
    }
}
