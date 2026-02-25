package com.ghost.chat.core.crypto

import android.util.Base64
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.nio.ByteBuffer
import java.security.KeyPair
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey

/// Ghost Chat E2E Encryption — Double Ratchet Protocol (v2)
///
/// Signal Protocol style:
/// - Initial ECDH P-256 key exchange
/// - Double Ratchet: DH ratchet per sender change, symmetric ratchet per message
/// - Every message encrypted with a unique key (per-message forward secrecy)
///
/// Wire format v2:
/// { type: "encrypted-message", data: "base64(4B headerLen + encryptedHeader + encryptedBody)", v: 2 }
class GhostCrypto {

    companion object {
        const val PROTOCOL_VERSION = 3
        private const val PADDING_BLOCK_SIZE = 256
        private const val NONCE_EXPIRY_MS = 5 * 60 * 1000L       // 5 min
        private const val COUNTER_WINDOW = 100
        private const val TIMESTAMP_MAX_AGE_MS = 5 * 60 * 1000L  // 5 min
        private const val SEND_CHAIN_TIMEOUT_MS = 10_000L         // 10 sec

        private val ECDH_SALT = "ghost-chat-v2".toByteArray(Charsets.UTF_8)
        private val ECDH_INFO = "ghost-dr-init-secret".toByteArray(Charsets.UTF_8)
    }

    // Keys
    private var keyPair: KeyPair? = null
    val publicKey: ECPublicKey? get() = keyPair?.public as? ECPublicKey
    private var peerPublicKey: ECPublicKey? = null

    // Double Ratchet
    private var ratchet: DoubleRatchet? = null

    // Counters & Replay Protection
    var messageCounter: Int = 0
        private set
    private var peerMessageCounter: Int = 0
    private val receivedNonces = mutableMapOf<String, Long>()

    // Initialization tracking
    var isHost: Boolean = false
        private set

    // Serialization queue (prevents concurrent encrypt/decrypt race conditions)
    private val cryptoMutex = Mutex()

    // Send chain wait for guest (waits for first message from host to init DH ratchet)
    private var sendChainReady: CompletableDeferred<Unit>? = null

    // MARK: - Key Generation

    fun generateKeyPair() {
        val kp = DoubleRatchet.generateKeyPair()
        keyPair = kp
    }

    // MARK: - Key Export/Import

    fun exportPublicKey(): String? {
        val pub = publicKey ?: return null
        val x963 = DoubleRatchet.exportPublicKeyX963(pub)
        return Base64.encodeToString(x963, Base64.NO_WRAP)
    }

    fun importPeerPublicKey(base64Key: String) {
        val data = Base64.decode(base64Key, Base64.DEFAULT)
        peerPublicKey = DoubleRatchet.importPublicKeyX963(data)
    }

    // MARK: - Key Derivation (Double Ratchet Initialization)

    fun deriveSharedKey(asHost: Boolean) {
        val priv = keyPair?.private ?: throw GhostCryptoError.KeysNotReady()
        val peer = peerPublicKey ?: throw GhostCryptoError.KeysNotReady()

        this.isHost = asHost

        // ECDH shared secret
        val sharedSecret = DoubleRatchet.ecdh(priv, peer)

        // Derive root symmetric key from ECDH shared secret
        val rootSecret = DoubleRatchet.hkdf(sharedSecret, ECDH_SALT, ECDH_INFO, 32)

        // Initialize Double Ratchet
        ratchet = if (asHost) {
            DoubleRatchet.initAsInitiator(rootSecret, peer)
        } else {
            // Guest: set up send chain wait
            sendChainReady = CompletableDeferred()
            DoubleRatchet.initAsResponder(rootSecret)
        }
    }

    /** Export the DH ratchet public key for the key-exchange message */
    fun exportDHRatchetKey(): String? {
        val data = ratchet?.dhPublicKeyData ?: return null
        return Base64.encodeToString(data, Base64.NO_WRAP)
    }

    // MARK: - Encryption (Double Ratchet v2 — with serialization queue)

    /** Encrypt a message using Double Ratchet — serialized via mutex */
    suspend fun encrypt(plaintext: String): String {
        // Wait for send chain to be ready (guest only)
        sendChainReady?.let { deferred ->
            withTimeoutOrNull(SEND_CHAIN_TIMEOUT_MS) { deferred.await() }
                ?: throw GhostCryptoError.SendChainTimeout()
        }

        return cryptoMutex.withLock { encryptImpl(plaintext) }
    }

    private fun encryptImpl(plaintext: String): String {
        val dr = ratchet ?: throw GhostCryptoError.SendKeyNotDerived()

        messageCounter++

        // Build message with metadata {m, t, c}
        val meta = JSONObject().apply {
            put("m", plaintext)
            put("t", System.currentTimeMillis())
            put("c", messageCounter)
        }
        val metaString = meta.toString()

        // Padding to 256-byte blocks
        val padded = padMessage(metaString)
        val paddedData = padded.toByteArray(Charsets.UTF_8)

        // Double Ratchet encrypt -> (encryptedHeader, ciphertext)
        val (encryptedHeader, ciphertext) = dr.encrypt(paddedData)

        // Combine: 4-byte header length (big-endian) + encryptedHeader + ciphertext
        val headerLen = encryptedHeader.size
        val buffer = ByteBuffer.allocate(4 + headerLen + ciphertext.size)
        buffer.putInt(headerLen)
        buffer.put(encryptedHeader)
        buffer.put(ciphertext)

        return Base64.encodeToString(buffer.array(), Base64.NO_WRAP)
    }

    // MARK: - Decryption (Double Ratchet v2 — with serialization queue)

    /** Decrypt a Double Ratchet message — serialized via mutex */
    suspend fun decrypt(encryptedBase64: String): String {
        return cryptoMutex.withLock { decryptImpl(encryptedBase64) }
    }

    private fun decryptImpl(encryptedBase64: String): String {
        val dr = ratchet ?: throw GhostCryptoError.ReceiveKeyNotDerived()

        val combined = Base64.decode(encryptedBase64, Base64.DEFAULT)
        require(combined.size > 4) { "Invalid ciphertext" }

        // Parse: 4-byte header length + encrypted header + ciphertext
        val buffer = ByteBuffer.wrap(combined)
        val headerLen = buffer.int
        require(combined.size > 4 + headerLen) { "Invalid ciphertext" }

        val encryptedHeader = ByteArray(headerLen)
        buffer.get(encryptedHeader)
        val ciphertext = ByteArray(combined.size - 4 - headerLen)
        buffer.get(ciphertext)

        // Replay protection: extract nonce from ciphertext
        require(ciphertext.size > 12) { "Invalid ciphertext" }
        val nonceData = ciphertext.copyOfRange(0, 12)
        val nonceString = Base64.encodeToString(nonceData, Base64.NO_WRAP)

        cleanupExpiredNonces()

        if (receivedNonces.containsKey(nonceString)) {
            throw GhostCryptoError.ReplayAttack()
        }

        // Try skipped keys first (out-of-order messages)
        val skippedResult = try {
            dr.tryDecryptWithSkippedKey(encryptedHeader, ciphertext)
        } catch (e: Exception) { null }

        if (skippedResult != null) {
            val result = processDecryptedData(skippedResult, nonceString)
            resolveSendChainReady()
            return result
        }

        // Normal Double Ratchet decrypt
        val plainData = dr.decrypt(encryptedHeader, ciphertext)
        val result = processDecryptedData(plainData, nonceString)
        resolveSendChainReady()
        return result
    }

    /** Resolve send chain ready after successful decrypt (guest DH ratchet triggers) */
    private fun resolveSendChainReady() {
        val deferred = sendChainReady ?: return
        if (ratchet != null) {
            deferred.complete(Unit)
            sendChainReady = null
        }
    }

    /** Process decrypted data: unpad, validate metadata, return message */
    private fun processDecryptedData(data: ByteArray, nonceString: String): String {
        val paddedText = String(data, Charsets.UTF_8)
        val unpaddedText = unpadMessage(paddedText)

        try {
            val parsed = JSONObject(unpaddedText)

            // Timestamp validation (5 min max age)
            val timestamp = parsed.optLong("t", 0)
            if (timestamp > 0) {
                val messageAge = System.currentTimeMillis() - timestamp
                if (messageAge > TIMESTAMP_MAX_AGE_MS) {
                    throw GhostCryptoError.MessageTooOld()
                }
            }

            // Counter validation
            val counter = parsed.optInt("c", -1)
            if (counter >= 0) {
                if (counter <= peerMessageCounter - COUNTER_WINDOW) {
                    throw GhostCryptoError.CounterTooOld()
                }
                if (counter > peerMessageCounter) {
                    peerMessageCounter = counter
                }
            }

            // Save nonce
            receivedNonces[nonceString] = System.currentTimeMillis()

            val message = parsed.optString("m", "")
            if (message.isNotEmpty()) return message
        } catch (e: GhostCryptoError) {
            throw e
        } catch (_: Exception) {
            // Not JSON — return raw
        }

        return unpaddedText
    }

    // MARK: - Message Padding

    fun padMessage(message: String, blockSize: Int = PADDING_BLOCK_SIZE): String {
        val base64Message = Base64.encodeToString(message.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
        val messageLength = base64Message.length

        require(messageLength <= 9999) { "Message too long" }

        val paddedLength = ((messageLength + 4 + blockSize - 1) / blockSize) * blockSize
        val paddingLength = paddedLength - messageLength - 4

        val paddingChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        val random = SecureRandom()
        val padding = StringBuilder(paddingLength)
        for (i in 0 until paddingLength) {
            padding.append(paddingChars[random.nextInt(paddingChars.length)])
        }

        return String.format("%04d", messageLength) + base64Message + padding.toString()
    }

    fun unpadMessage(paddedMessage: String): String {
        require(paddedMessage.length >= 4) { "Invalid padded message" }

        val prefixStr = paddedMessage.substring(0, 4)
        val originalLength = prefixStr.toIntOrNull()
            ?: throw GhostCryptoError.InvalidPaddedMessage()

        require(originalLength in 0..(paddedMessage.length - 4)) { "Invalid padded message" }

        val base64Message = paddedMessage.substring(4, 4 + originalLength)
        val data = Base64.decode(base64Message, Base64.DEFAULT)
        return String(data, Charsets.UTF_8)
    }

    // MARK: - Fingerprint

    fun generateFingerprint(): String {
        val pub = publicKey ?: throw GhostCryptoError.KeysNotReady()
        val peer = peerPublicKey ?: throw GhostCryptoError.KeysNotReady()

        val ourKeyRaw = DoubleRatchet.exportPublicKeyX963(pub)
        val peerKeyRaw = DoubleRatchet.exportPublicKeyX963(peer)

        // Sort keys lexicographically
        val sorted = listOf(ourKeyRaw, peerKeyRaw).sortedWith(Comparator { a, b ->
            for (i in 0 until minOf(a.size, b.size)) {
                val cmp = (a[i].toInt() and 0xFF).compareTo(b[i].toInt() and 0xFF)
                if (cmp != 0) return@Comparator cmp
            }
            a.size.compareTo(b.size)
        })

        val combined = sorted[0] + sorted[1]
        val hash = MessageDigest.getInstance("SHA-256").digest(combined)

        // First 16 bytes, hex, grouped by 4 chars
        val hexString = hash.take(16).joinToString("") { "%02x".format(it) }
        return hexString.chunked(4).joinToString(" ").uppercase()
    }

    // MARK: - Utility

    val isReady: Boolean
        get() = keyPair != null && ratchet != null && peerPublicKey != null

    private fun cleanupExpiredNonces() {
        val now = System.currentTimeMillis()
        receivedNonces.entries.removeAll { now - it.value > NONCE_EXPIRY_MS }
    }

    fun destroy() {
        keyPair = null
        peerPublicKey = null
        ratchet?.destroy()
        ratchet = null
        receivedNonces.clear()
        messageCounter = 0
        peerMessageCounter = 0
        sendChainReady = null
    }

    // MARK: - DR State Persistence

    /** Restore Double Ratchet from persisted state (known contacts) */
    fun restoreRatchet(state: DoubleRatchetState, skippedKeys: List<Triple<ByteArray, Int, ByteArray>>) {
        val dr = DoubleRatchet.fromState(state)
        dr.importSkippedKeys(skippedKeys)
        ratchet = dr
    }

    /** Export current DR state for persistent storage */
    fun exportRatchetState(): DoubleRatchetState? = ratchet?.exportState()

    /** Export skipped keys for persistent storage */
    fun exportSkippedKeys(): List<Triple<ByteArray, Int, ByteArray>> =
        ratchet?.exportSkippedKeys() ?: emptyList()

    /** Export message counters */
    val counters: Pair<Int, Int> get() = Pair(messageCounter, peerMessageCounter)
}

// MARK: - Errors

sealed class GhostCryptoError : Exception() {
    class InvalidKeyData : GhostCryptoError() { override val message = "Invalid key data" }
    class KeysNotReady : GhostCryptoError() { override val message = "Keys not ready" }
    class SendKeyNotDerived : GhostCryptoError() { override val message = "Send key not derived" }
    class ReceiveKeyNotDerived : GhostCryptoError() { override val message = "Receive key not derived" }
    class InvalidCiphertext : GhostCryptoError() { override val message = "Invalid ciphertext" }
    class ReplayAttack : GhostCryptoError() { override val message = "Replay attack detected" }
    class MessageTooOld : GhostCryptoError() { override val message = "Message too old" }
    class CounterTooOld : GhostCryptoError() { override val message = "Counter too old" }
    class InvalidPaddedMessage : GhostCryptoError() { override val message = "Invalid padded message" }
    class SendChainTimeout : GhostCryptoError() { override val message = "Send chain initialization timeout" }
}
