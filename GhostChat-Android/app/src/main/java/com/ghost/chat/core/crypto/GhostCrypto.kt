package com.ghost.chat.core.crypto

import android.util.Base64
import android.util.Log
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
        private const val NONCE_EXPIRY_MS = 60 * 60 * 1000L      // 1 hour
        private const val COUNTER_WINDOW = 100L
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
    var messageCounter: Long = 0
        private set
    var lastDecryptedCounter: Long? = null
        private set
    private var peerMessageCounter: Long = 0
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
        Log.d("GhostChat", "[GhostCrypto] generateKeyPair called")
        try {
            val kp = DoubleRatchet.generateKeyPair()
            keyPair = kp
            Log.d("GhostChat", "[GhostCrypto] generateKeyPair success, hasPublicKey=${kp.public != null}")
        } catch (e: Exception) {
            Log.e("GhostChat", "[GhostCrypto] generateKeyPair FAILED: ${e.message}")
            throw e
        }
    }

    // MARK: - Key Export/Import

    fun exportPublicKey(): String? {
        Log.d("GhostChat", "[GhostCrypto] exportPublicKey called, hasPublicKey=${publicKey != null}")
        val pub = publicKey ?: run {
            Log.d("GhostChat", "[GhostCrypto] exportPublicKey — publicKey is null, returning null")
            return null
        }
        val x963 = DoubleRatchet.exportPublicKeyX963(pub)
        Log.d("GhostChat", "[GhostCrypto] exportPublicKey success, dataSize=${x963.size}")
        return Base64.encodeToString(x963, Base64.NO_WRAP)
    }

    fun importPeerPublicKey(base64Key: String) {
        Log.d("GhostChat", "[GhostCrypto] importPeerPublicKey called, keyLength=${base64Key.length}")
        try {
            val data = Base64.decode(base64Key, Base64.DEFAULT)
            peerPublicKey = DoubleRatchet.importPublicKeyX963(data)
            Log.d("GhostChat", "[GhostCrypto] importPeerPublicKey success, peerKey=${peerPublicKey != null}")
        } catch (e: Exception) {
            Log.e("GhostChat", "[GhostCrypto] importPeerPublicKey FAILED: ${e.message}")
            throw e
        }
    }

    // MARK: - Key Derivation (Double Ratchet Initialization)

    fun deriveSharedKey(asHost: Boolean) {
        Log.d("GhostChat", "[GhostCrypto] deriveSharedKey called, asHost=$asHost, hasPrivateKey=${keyPair?.private != null}, hasPeerKey=${peerPublicKey != null}")
        val priv = keyPair?.private ?: run {
            Log.e("GhostChat", "[GhostCrypto] deriveSharedKey FAILED — private key is null")
            throw GhostCryptoError.KeysNotReady()
        }
        val peer = peerPublicKey ?: run {
            Log.e("GhostChat", "[GhostCrypto] deriveSharedKey FAILED — peer public key is null")
            throw GhostCryptoError.KeysNotReady()
        }

        this.isHost = asHost

        // ECDH shared secret
        Log.d("GhostChat", "[GhostCrypto] deriveSharedKey — computing ECDH shared secret")
        val sharedSecret = DoubleRatchet.ecdh(priv, peer)
        Log.d("GhostChat", "[GhostCrypto] deriveSharedKey — ECDH complete, secretSize=${sharedSecret.size}")

        // Derive root symmetric key from ECDH shared secret
        Log.d("GhostChat", "[GhostCrypto] deriveSharedKey — deriving root key via HKDF")
        val rootSecret = DoubleRatchet.hkdf(sharedSecret, ECDH_SALT, ECDH_INFO, 32)
        Log.d("GhostChat", "[GhostCrypto] deriveSharedKey — HKDF complete, rootSecretSize=${rootSecret.size}")

        // Initialize Double Ratchet
        ratchet = if (asHost) {
            Log.d("GhostChat", "[GhostCrypto] deriveSharedKey — initializing ratchet as INITIATOR (host)")
            DoubleRatchet.initAsInitiator(rootSecret, peer)
        } else {
            // Guest: set up send chain wait
            // MUST reuse the ECDH keypair — responder's DH ratchet key must match key-exchange
            Log.d("GhostChat", "[GhostCrypto] deriveSharedKey — initializing ratchet as RESPONDER (guest), setting sendChainReady deferred")
            sendChainReady = CompletableDeferred()
            DoubleRatchet.initAsResponder(rootSecret, keyPair!!)
        }
        Log.d("GhostChat", "[GhostCrypto] deriveSharedKey success, ratchet initialized, isHost=$asHost")
    }

    /** Export the DH ratchet public key for the key-exchange message */
    fun exportDHRatchetKey(): String? {
        Log.d("GhostChat", "[GhostCrypto] exportDHRatchetKey called, hasRatchet=${ratchet != null}")
        val data = ratchet?.dhPublicKeyData ?: run {
            Log.d("GhostChat", "[GhostCrypto] exportDHRatchetKey — ratchet or dhPublicKeyData is null")
            return null
        }
        Log.d("GhostChat", "[GhostCrypto] exportDHRatchetKey success, dataSize=${data.size}")
        return Base64.encodeToString(data, Base64.NO_WRAP)
    }

    // MARK: - Encryption (Double Ratchet v2 — with serialization queue)

    /** Encrypt a message using Double Ratchet — serialized via mutex */
    suspend fun encrypt(plaintext: String, options: Map<String, Any>? = null): String {
        Log.d("GhostChat", "[GhostCrypto] encrypt called, plaintextLength=${plaintext.length}, hasSendChainReady=${sendChainReady != null}")
        // Wait for send chain to be ready (guest only)
        sendChainReady?.let { deferred ->
            Log.d("GhostChat", "[GhostCrypto] encrypt — waiting for sendChainReady (guest), timeout=${SEND_CHAIN_TIMEOUT_MS}ms")
            val result = withTimeoutOrNull(SEND_CHAIN_TIMEOUT_MS) { deferred.await() }
            if (result == null) {
                Log.e("GhostChat", "[GhostCrypto] encrypt — sendChainReady TIMEOUT after ${SEND_CHAIN_TIMEOUT_MS}ms")
                throw GhostCryptoError.SendChainTimeout()
            }
            Log.d("GhostChat", "[GhostCrypto] encrypt — sendChainReady resolved")
        }

        Log.d("GhostChat", "[GhostCrypto] encrypt — acquiring cryptoMutex")
        return cryptoMutex.withLock {
            Log.d("GhostChat", "[GhostCrypto] encrypt — cryptoMutex acquired")
            encryptImpl(plaintext, options)
        }
    }

    private fun encryptImpl(plaintext: String, options: Map<String, Any>? = null): String {
        val dr = ratchet ?: run {
            Log.e("GhostChat", "[GhostCrypto] encryptImpl — ratchet is null, SendKeyNotDerived")
            throw GhostCryptoError.SendKeyNotDerived()
        }

        messageCounter++
        Log.d("GhostChat", "[GhostCrypto] encryptImpl — messageCounter=$messageCounter")

        // Build message with metadata {m, t, c}
        val meta = JSONObject().apply {
            put("m", plaintext)
            put("t", System.currentTimeMillis())
            put("c", messageCounter)
        }
        // Merge additional fields (id, r) into meta
        options?.forEach { (key, value) ->
            meta.put(key, value)
        }
        val metaString = meta.toString()

        // Padding to 256-byte blocks
        val padded = padMessage(metaString)
        val paddedData = padded.toByteArray(Charsets.UTF_8)
        Log.d("GhostChat", "[GhostCrypto] encryptImpl — padded size=${paddedData.size}")

        // Double Ratchet encrypt -> (encryptedHeader, ciphertext)
        val (encryptedHeader, ciphertext) = dr.encrypt(paddedData)
        Log.d("GhostChat", "[GhostCrypto] encryptImpl — DR encrypt done, headerSize=${encryptedHeader.size}, ciphertextSize=${ciphertext.size}")

        // Combine: 4-byte header length (big-endian) + encryptedHeader + ciphertext
        val headerLen = encryptedHeader.size
        val buffer = ByteBuffer.allocate(4 + headerLen + ciphertext.size)
        buffer.putInt(headerLen)
        buffer.put(encryptedHeader)
        buffer.put(ciphertext)

        val result = Base64.encodeToString(buffer.array(), Base64.NO_WRAP)
        Log.d("GhostChat", "[GhostCrypto] encryptImpl — final base64 size=${result.length}")
        return result
    }

    // MARK: - Decryption (Double Ratchet v2 — with serialization queue)

    /** Decrypt a Double Ratchet message — serialized via mutex */
    suspend fun decrypt(encryptedBase64: String): String {
        Log.d("GhostChat", "[GhostCrypto] decrypt called, base64Length=${encryptedBase64.length}")
        Log.d("GhostChat", "[GhostCrypto] decrypt — acquiring cryptoMutex")
        return cryptoMutex.withLock {
            Log.d("GhostChat", "[GhostCrypto] decrypt — cryptoMutex acquired")
            decryptImpl(encryptedBase64)
        }
    }

    private fun decryptImpl(encryptedBase64: String): String {
        val dr = ratchet ?: run {
            Log.e("GhostChat", "[GhostCrypto] decryptImpl — ratchet is null, ReceiveKeyNotDerived")
            throw GhostCryptoError.ReceiveKeyNotDerived()
        }

        val combined = Base64.decode(encryptedBase64, Base64.DEFAULT)
        Log.d("GhostChat", "[GhostCrypto] decryptImpl — decoded size=${combined.size}")
        require(combined.size > 4) { "Invalid ciphertext" }

        // Parse: 4-byte header length + encrypted header + ciphertext
        val buffer = ByteBuffer.wrap(combined)
        val headerLen = buffer.int
        require(headerLen >= 0 && combined.size > 4 + headerLen) { "Invalid ciphertext" }

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
            Log.e("GhostChat", "[GhostCrypto] decryptImpl — REPLAY ATTACK detected, nonce already seen")
            throw GhostCryptoError.ReplayAttack()
        }

        // Try skipped keys first (out-of-order messages)
        Log.d("GhostChat", "[GhostCrypto] decryptImpl — trying skipped keys first")
        val skippedResult = try {
            dr.tryDecryptWithSkippedKey(encryptedHeader, ciphertext)
        } catch (e: Exception) {
            Log.d("GhostChat", "[GhostCrypto] decryptImpl — skipped key attempt failed: ${e.message}")
            null
        }

        if (skippedResult != null) {
            Log.d("GhostChat", "[GhostCrypto] decryptImpl — decrypted with skipped key, size=${skippedResult.size}")
            val result = processDecryptedData(skippedResult, nonceString)
            resolveSendChainReady()
            return result
        }

        // Normal Double Ratchet decrypt
        Log.d("GhostChat", "[GhostCrypto] decryptImpl — normal DR decrypt")
        val plainData = dr.decrypt(encryptedHeader, ciphertext)
        Log.d("GhostChat", "[GhostCrypto] decryptImpl — DR decrypt success, plaintextSize=${plainData.size}")
        val result = processDecryptedData(plainData, nonceString)
        resolveSendChainReady()
        return result
    }

    /** Resolve send chain ready after successful decrypt (guest DH ratchet triggers) */
    private fun resolveSendChainReady() {
        val deferred = sendChainReady ?: run {
            Log.d("GhostChat", "[GhostCrypto] resolveSendChainReady — no deferred (host or already resolved)")
            return
        }
        if (ratchet != null) {
            Log.d("GhostChat", "[GhostCrypto] resolveSendChainReady — completing deferred, guest send chain now ready")
            deferred.complete(Unit)
            sendChainReady = null
        } else {
            Log.d("GhostChat", "[GhostCrypto] resolveSendChainReady — ratchet is null, cannot resolve")
        }
    }

    /** Process decrypted data: unpad, validate metadata, return message */
    private fun processDecryptedData(data: ByteArray, nonceString: String): String {
        Log.d("GhostChat", "[GhostCrypto] processDecryptedData called, dataSize=${data.size}")
        val paddedText = String(data, Charsets.UTF_8)
        val unpaddedText = unpadMessage(paddedText)
        Log.d("GhostChat", "[GhostCrypto] processDecryptedData — unpadded length=${unpaddedText.length}")

        try {
            val parsed = JSONObject(unpaddedText)

            // Timestamp validation (5 min tolerance for clock skew)
            val timestamp = parsed.optLong("t", 0)
            if (timestamp <= 0) {
                Log.e("GhostChat", "[GhostCrypto] processDecryptedData — timestamp missing or zero")
                throw GhostCryptoError.MessageTooOld()
            }
            val now = System.currentTimeMillis()
            val messageAge = now - timestamp
            Log.d("GhostChat", "[GhostCrypto] processDecryptedData — messageAge=${messageAge}ms, maxAge=${TIMESTAMP_MAX_AGE_MS}ms")
            if (messageAge > TIMESTAMP_MAX_AGE_MS || messageAge < -TIMESTAMP_MAX_AGE_MS) {
                Log.e("GhostChat", "[GhostCrypto] processDecryptedData — message too old, age=${messageAge}ms")
                throw GhostCryptoError.MessageTooOld()
            }

            // Counter validation (mandatory — reject messages without counter)
            val counter = parsed.optLong("c", -1)
            Log.d("GhostChat", "[GhostCrypto] processDecryptedData — counter=$counter, peerMessageCounter=$peerMessageCounter")
            if (counter < 0) {
                Log.e("GhostChat", "[GhostCrypto] processDecryptedData — counter missing")
                throw GhostCryptoError.CounterTooOld()
            }
            val windowStart = maxOf(0L, peerMessageCounter - COUNTER_WINDOW)
            if (counter <= windowStart && peerMessageCounter > 0) {
                Log.e("GhostChat", "[GhostCrypto] processDecryptedData — counter too old, counter=$counter windowStart=$windowStart")
                throw GhostCryptoError.CounterTooOld()
            }
            if (counter > peerMessageCounter) {
                Log.d("GhostChat", "[GhostCrypto] processDecryptedData — updating peerMessageCounter from $peerMessageCounter to $counter")
                peerMessageCounter = counter
            }
            lastDecryptedCounter = counter

            // Save nonce
            receivedNonces[nonceString] = System.currentTimeMillis()
            Log.d("GhostChat", "[GhostCrypto] processDecryptedData — nonce saved, totalNonces=${receivedNonces.size}")

            val message = parsed.optString("m", "")
            if (message.isNotEmpty()) {
                Log.d("GhostChat", "[GhostCrypto] processDecryptedData — returning message, length=${message.length}")
                return message
            }
            Log.d("GhostChat", "[GhostCrypto] processDecryptedData — message field empty, returning raw")
        } catch (e: GhostCryptoError) {
            Log.e("GhostChat", "[GhostCrypto] processDecryptedData — crypto error: ${e.message}")
            throw e
        } catch (_: Exception) {
            // Not JSON — return raw
            Log.d("GhostChat", "[GhostCrypto] processDecryptedData — not JSON, returning raw text")
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
        Log.d("GhostChat", "[GhostCrypto] generateFingerprint called")
        val pub = publicKey ?: run {
            Log.e("GhostChat", "[GhostCrypto] generateFingerprint — publicKey is null")
            throw GhostCryptoError.KeysNotReady()
        }
        val peer = peerPublicKey ?: run {
            Log.e("GhostChat", "[GhostCrypto] generateFingerprint — peerPublicKey is null")
            throw GhostCryptoError.KeysNotReady()
        }

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
        get() {
            val ready = keyPair != null && ratchet != null && peerPublicKey != null
            Log.d("GhostChat", "[GhostCrypto] isReady=$ready (keyPair=${keyPair != null}, ratchet=${ratchet != null}, peerKey=${peerPublicKey != null})")
            return ready
        }

    private fun cleanupExpiredNonces() {
        val now = System.currentTimeMillis()
        receivedNonces.entries.removeAll { now - it.value > NONCE_EXPIRY_MS }
    }

    fun destroy() {
        Log.d("GhostChat", "[GhostCrypto] destroy called, hasKeyPair=${keyPair != null}, hasRatchet=${ratchet != null}, messageCounter=$messageCounter")
        // Best-effort key zeroing on JVM — overwrite encoded bytes before nulling
        try {
            keyPair?.private?.encoded?.fill(0)
        } catch (_: Exception) {}
        keyPair = null
        peerPublicKey = null
        ratchet?.destroy()
        ratchet = null
        receivedNonces.clear()
        messageCounter = 0
        peerMessageCounter = 0
        sendChainReady = null
        Log.d("GhostChat", "[GhostCrypto] destroy complete — all keys zeroed")
    }

    // MARK: - DR State Persistence

    /** Restore Double Ratchet from persisted state (known contacts) */
    fun restoreRatchet(state: DoubleRatchetState, skippedKeys: List<Triple<ByteArray, Int, ByteArray>>) {
        Log.d("GhostChat", "[GhostCrypto] restoreRatchet called, skippedKeysCount=${skippedKeys.size}")
        val dr = DoubleRatchet.fromState(state)
        dr.importSkippedKeys(skippedKeys)
        ratchet = dr
        Log.d("GhostChat", "[GhostCrypto] restoreRatchet success")
    }

    /** Export current DR state for persistent storage (protected by crypto lock) */
    fun exportRatchetState(): DoubleRatchetState? = kotlinx.coroutines.runBlocking {
        cryptoMutex.withLock { ratchet?.exportState() }
    }

    /** Export skipped keys for persistent storage (protected by crypto lock) */
    fun exportSkippedKeys(): List<Triple<ByteArray, Int, ByteArray>> = kotlinx.coroutines.runBlocking {
        cryptoMutex.withLock { ratchet?.exportSkippedKeys() ?: emptyList() }
    }

    /** Export message counters */
    val counters: Pair<Long, Long> get() = Pair(messageCounter, peerMessageCounter)
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
