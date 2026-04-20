package com.kordar.ghostchat.core.crypto

import org.bouncycastle.jcajce.provider.asymmetric.ec.BCECPrivateKey
import org.bouncycastle.jcajce.provider.asymmetric.ec.BCECPublicKey
import org.bouncycastle.jce.ECNamedCurveTable
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.bouncycastle.jce.spec.ECPrivateKeySpec
import org.bouncycastle.jce.spec.ECPublicKeySpec
import java.math.BigInteger
import java.security.*
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

object CryptoUtils {

    init {
        if (Security.getProvider("BC") == null) {
            Security.addProvider(BouncyCastleProvider())
        }
    }

    private val ecSpec = ECNamedCurveTable.getParameterSpec("P-256")

    // MARK: - ECDH

    data class ECKeyPair(val privateKey: PrivateKey, val publicKey: PublicKey) {
        /** 65-byte uncompressed public key (04 + x + y) */
        val publicKeyBytes: ByteArray
            get() = (publicKey as BCECPublicKey).q.getEncoded(false)

        /** 64-byte raw public key (x + y, no 04 prefix) */
        val publicKeyRaw: ByteArray
            get() = publicKeyBytes.copyOfRange(1, 65)

        /** 32-byte private key scalar */
        val privateKeyBytes: ByteArray
            get() {
                val d = (privateKey as BCECPrivateKey).d.toByteArray()
                // BigInteger may have leading zero or be shorter than 32 bytes
                return when {
                    d.size == 32 -> d
                    d.size > 32 -> d.copyOfRange(d.size - 32, d.size)
                    else -> ByteArray(32 - d.size) + d
                }
            }
    }

    fun generateKeyPair(): ECKeyPair {
        val kpg = java.security.KeyPairGenerator.getInstance("EC", "BC")
        kpg.initialize(ecSpec, SecureRandom())
        val kp = kpg.generateKeyPair()
        return ECKeyPair(kp.private, kp.public)
    }

    fun keyPairFromPrivateBytes(privateBytes: ByteArray): ECKeyPair {
        val d = BigInteger(1, privateBytes)
        val privSpec = ECPrivateKeySpec(d, ecSpec)
        val kf = KeyFactory.getInstance("EC", "BC")
        val privateKey = kf.generatePrivate(privSpec)
        val q = ecSpec.g.multiply(d).normalize()
        val pubSpec = ECPublicKeySpec(q, ecSpec)
        val publicKey = kf.generatePublic(pubSpec)
        return ECKeyPair(privateKey, publicKey)
    }

    fun publicKeyFromBytes(bytes: ByteArray): PublicKey {
        // Accept 65-byte (with 04) or 64-byte (raw)
        val uncompressed = if (bytes.size == 64) byteArrayOf(0x04) + bytes else bytes
        val point = ecSpec.curve.decodePoint(uncompressed)
        val pubSpec = ECPublicKeySpec(point, ecSpec)
        val kf = KeyFactory.getInstance("EC", "BC")
        return kf.generatePublic(pubSpec)
    }

    fun ecdhSharedSecret(privateKey: PrivateKey, publicKey: PublicKey): ByteArray {
        val ka = javax.crypto.KeyAgreement.getInstance("ECDH", "BC")
        ka.init(privateKey)
        ka.doPhase(publicKey, true)
        val secret = ka.generateSecret()
        // Ensure exactly 32 bytes
        return when {
            secret.size == 32 -> secret
            secret.size > 32 -> secret.copyOfRange(secret.size - 32, secret.size)
            else -> ByteArray(32 - secret.size) + secret
        }
    }

    // MARK: - HKDF-SHA256

    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        // HKDF-Extract
        val prk = hmacSha256(salt, ikm)
        // HKDF-Expand
        val n = (length + 31) / 32
        var t = byteArrayOf()
        val okm = ByteArray(length)
        var offset = 0
        for (i in 1..n) {
            t = hmacSha256(prk, t + info + byteArrayOf(i.toByte()))
            val copyLen = minOf(32, length - offset)
            System.arraycopy(t, 0, okm, offset, copyLen)
            offset += copyLen
        }
        return okm
    }

    // MARK: - Initial Root Key

    fun deriveInitialRootKey(sharedSecret: ByteArray): ByteArray {
        return hkdf(sharedSecret, "ghost-dr-root".toByteArray(), "ghost-dr-rk".toByteArray(), 32)
    }

    // MARK: - Root KDF

    data class RootKDFResult(val newRootKey: ByteArray, val chainKey: ByteArray)

    fun rootKDF(rootKey: ByteArray, dhOutput: ByteArray): RootKDFResult {
        val derived = hkdf(dhOutput, rootKey, "ghost-dr-rk".toByteArray(), 64)
        return RootKDFResult(
            newRootKey = derived.copyOfRange(0, 32),
            chainKey = derived.copyOfRange(32, 64)
        )
    }

    // MARK: - Chain KDF

    data class ChainKDFResult(val messageKey: ByteArray, val nextChainKey: ByteArray)

    fun chainKDF(chainKey: ByteArray): ChainKDFResult {
        return ChainKDFResult(
            messageKey = hmacSha256(chainKey, byteArrayOf(0x01)),
            nextChainKey = hmacSha256(chainKey, byteArrayOf(0x02))
        )
    }

    // MARK: - HMAC-SHA256

    fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    // MARK: - AES-256-GCM

    fun aesGcmEncrypt(key: ByteArray, nonce: ByteArray, plaintext: ByteArray, aad: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD(aad)
        return cipher.doFinal(plaintext) // ciphertext + tag (appended)
    }

    fun aesGcmDecrypt(key: ByteArray, nonce: ByteArray, ciphertextWithTag: ByteArray, aad: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD(aad)
        return cipher.doFinal(ciphertextWithTag)
    }

    // MARK: - Safety Number

    fun safetyNumber(identityKeyA: ByteArray, identityKeyB: ByteArray): String {
        val sorted = if (identityKeyA.compareLexicographically(identityKeyB) <= 0) {
            identityKeyA + identityKeyB
        } else {
            identityKeyB + identityKeyA
        }
        val hash = MessageDigest.getInstance("SHA-256").digest(sorted)
        val first16 = hash.copyOfRange(0, 16)
        val hexStr = first16.toHexString().uppercase()
        return hexStr.chunked(4).joinToString(" ")
    }
}

// MARK: - Extensions

fun ByteArray.toHexString(): String = joinToString("") { "%02x".format(it) }

fun String.hexToByteArray(): ByteArray {
    check(length % 2 == 0) { "Hex string must have even length" }
    return chunked(2).map { it.toInt(16).toByte() }.toByteArray()
}

private fun ByteArray.compareLexicographically(other: ByteArray): Int {
    val len = minOf(size, other.size)
    for (i in 0 until len) {
        val cmp = (this[i].toInt() and 0xFF) - (other[i].toInt() and 0xFF)
        if (cmp != 0) return cmp
    }
    return size - other.size
}
