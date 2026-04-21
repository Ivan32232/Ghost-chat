package com.kordar.ghostchat.core.crypto

import org.bouncycastle.pqc.crypto.mlkem.MLKEMExtractor
import org.bouncycastle.pqc.crypto.mlkem.MLKEMGenerator
import org.bouncycastle.pqc.crypto.mlkem.MLKEMKeyGenerationParameters
import org.bouncycastle.pqc.crypto.mlkem.MLKEMKeyPairGenerator
import org.bouncycastle.pqc.crypto.mlkem.MLKEMParameters
import org.bouncycastle.pqc.crypto.mlkem.MLKEMPrivateKeyParameters
import org.bouncycastle.pqc.crypto.mlkem.MLKEMPublicKeyParameters
import java.security.SecureRandom

/**
 * ML-KEM768 post-quantum key encapsulation (optional hybrid leg of the handshake).
 *
 * Uses BouncyCastle 1.82's native FIPS 203 (final) implementation. The ECDH
 * (P-256) leg of the handshake is always present; when both sides advertise
 * `pqSupported = true` via [KeyExchangePacket], the host encapsulates against
 * the guest's ML-KEM public key and both derive a combined root key through
 * [hybridDeriveSharedKey] — a Kyber break alone would still need to break
 * P-256 to recover the session root.
 *
 * Mirror of iOS `PostQuantum`. [hybridDeriveSharedKey] produces byte-identical
 * output for identical inputs (both platforms use the same HKDF salt/info).
 */
object PostQuantum {

    /** ML-KEM is always available on Android via BouncyCastle 1.82. */
    const val IS_SUPPORTED: Boolean = true

    data class KeyPair(val publicKey: ByteArray, val privateKey: ByteArray) {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is KeyPair) return false
            return publicKey.contentEquals(other.publicKey) &&
                   privateKey.contentEquals(other.privateKey)
        }
        override fun hashCode(): Int =
            31 * publicKey.contentHashCode() + privateKey.contentHashCode()
    }

    data class Encapsulation(val ciphertext: ByteArray, val sharedSecret: ByteArray) {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is Encapsulation) return false
            return ciphertext.contentEquals(other.ciphertext) &&
                   sharedSecret.contentEquals(other.sharedSecret)
        }
        override fun hashCode(): Int =
            31 * ciphertext.contentHashCode() + sharedSecret.contentHashCode()
    }

    /** Generate a fresh ML-KEM768 keypair. */
    fun generateKeyPair(random: SecureRandom = SecureRandom()): KeyPair {
        val kpg = MLKEMKeyPairGenerator()
        kpg.init(MLKEMKeyGenerationParameters(random, MLKEMParameters.ml_kem_768))
        val kp = kpg.generateKeyPair()
        val pub = (kp.public as MLKEMPublicKeyParameters).encoded
        val priv = (kp.private as MLKEMPrivateKeyParameters).encoded
        return KeyPair(pub, priv)
    }

    /**
     * Encapsulate against a peer's public key. Returns the ciphertext the peer
     * will decapsulate plus the shared secret we hold locally.
     */
    fun encapsulate(peerPublic: ByteArray, random: SecureRandom = SecureRandom()): Encapsulation {
        val pub = MLKEMPublicKeyParameters(MLKEMParameters.ml_kem_768, peerPublic)
        val generator = MLKEMGenerator(random)
        val secret = generator.generateEncapsulated(pub)
        return Encapsulation(
            ciphertext = secret.encapsulation,
            sharedSecret = secret.secret
        )
    }

    /** Decapsulate a peer's ciphertext using our private key. */
    fun decapsulate(ciphertext: ByteArray, privateKey: ByteArray): ByteArray {
        val priv = MLKEMPrivateKeyParameters(MLKEMParameters.ml_kem_768, privateKey)
        val extractor = MLKEMExtractor(priv)
        return extractor.extractSecret(ciphertext)
    }

    /**
     * Hybrid root-key derivation — always safe to call regardless of whether
     * a PQ leg was performed. If [pqSharedSecret] is `null`, we derive from
     * the ECDH secret alone through the PQ-salted HKDF so a hybrid session
     * is cryptographically distinct from plain ECDH (prevents silent PQ
     * downgrade).
     *
     * Byte-identical to iOS `PostQuantum.hybridDeriveSharedKey`.
     */
    fun hybridDeriveSharedKey(
        ecdhSharedSecret: ByteArray,
        pqSharedSecret: ByteArray?
    ): ByteArray {
        val ikm = if (pqSharedSecret != null) ecdhSharedSecret + pqSharedSecret
                  else                         ecdhSharedSecret
        return CryptoUtils.hkdf(
            ikm = ikm,
            salt = "ghost-chat-v1-pq".toByteArray(Charsets.UTF_8),
            info = "ghost-dr-root".toByteArray(Charsets.UTF_8),
            length = 32
        )
    }
}
