package com.ghost.chat.core.crypto

import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.generators.HKDFBytesGenerator
import org.bouncycastle.crypto.params.HKDFParameters
import java.nio.ByteBuffer
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.interfaces.ECPrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec
import java.security.spec.PKCS8EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

// MARK: - Double Ratchet State Machine
// Signal Protocol style: Root chain -> Sending/Receiving chain -> Per-message keys
// DH Ratchet on every sender change, symmetric ratchet per message

/** Index for looking up skipped message keys */
data class SkippedKeyIndex(
    val dhPublicKey: ByteArray,    // Peer's DH ratchet public key (65 bytes x963)
    val messageNumber: Int         // Message number within that chain
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is SkippedKeyIndex) return false
        return dhPublicKey.contentEquals(other.dhPublicKey) && messageNumber == other.messageNumber
    }

    override fun hashCode(): Int {
        return dhPublicKey.contentHashCode() * 31 + messageNumber
    }
}

/** Double Ratchet message header */
data class DRHeader(
    val dhPublicKey: ByteArray,   // Sender's current DH ratchet public key (65 bytes, x963)
    val pn: Int,                  // Previous chain length
    val n: Int                    // Message number in current chain
) {
    fun serialize(): ByteArray {
        // Format: dhKey(65) + pn(4 bytes big-endian) + n(4 bytes big-endian) = 73 bytes
        val buffer = ByteBuffer.allocate(73)
        buffer.put(dhPublicKey)
        buffer.putInt(pn)
        buffer.putInt(n)
        return buffer.array()
    }

    companion object {
        fun deserialize(data: ByteArray): DRHeader {
            require(data.size == 73) { "Invalid header size: ${data.size}" }
            val buffer = ByteBuffer.wrap(data)
            val dhKey = ByteArray(65)
            buffer.get(dhKey)
            val pn = buffer.int
            val n = buffer.int
            return DRHeader(dhKey, pn, n)
        }
    }
}

/** Serializable DR state for persistence in SQLCipher */
data class DoubleRatchetState(
    val dhSendingPrivateKey: ByteArray,     // PKCS8 encoded
    val dhSendingPublicKey: ByteArray,      // X963 (65 bytes)
    val dhReceivingPublicKey: ByteArray?,   // X963 (65 bytes) or null
    val rootKey: ByteArray,                 // 32 bytes
    val sendChainKey: ByteArray?,
    val receiveChainKey: ByteArray?,
    val sendHeaderKey: ByteArray?,
    val receiveHeaderKey: ByteArray?,
    val nextSendHeaderKey: ByteArray?,
    val nextReceiveHeaderKey: ByteArray?,
    val sendMessageNumber: Int,
    val receiveMessageNumber: Int,
    val previousChainLength: Int
) : java.io.Serializable

/** Core Double Ratchet implementation */
class DoubleRatchet private constructor() {

    companion object {
        const val MAX_SKIP = 100

        // KDF labels — MUST match web client + iOS exactly
        private val ROOT_KDF_SALT = "ghost-dr-root".toByteArray(Charsets.UTF_8)
        private val ROOT_KDF_INFO = "ghost-dr-rk".toByteArray(Charsets.UTF_8)
        private val CHAIN_KDF_SALT = "ghost-dr-chain".toByteArray(Charsets.UTF_8)
        private val CHAIN_KDF_INFO_CK = "ghost-dr-ck".toByteArray(Charsets.UTF_8)
        private val CHAIN_KDF_INFO_MK = "ghost-dr-mk".toByteArray(Charsets.UTF_8)
        private val INIT_INFO = "ghost-dr-init".toByteArray(Charsets.UTF_8)

        // --- EC Key Helpers ---

        /** Generate a new P-256 key pair */
        fun generateKeyPair(): KeyPair {
            val kpg = KeyPairGenerator.getInstance("EC")
            kpg.initialize(ECGenParameterSpec("secp256r1"))
            return kpg.generateKeyPair()
        }

        /** Export EC public key in X.963 uncompressed format (65 bytes: 04 || X || Y) */
        fun exportPublicKeyX963(pub: ECPublicKey): ByteArray {
            val point = pub.w
            val x = point.affineX.toByteArray().let { padOrTrim(it, 32) }
            val y = point.affineY.toByteArray().let { padOrTrim(it, 32) }
            val result = ByteArray(65)
            result[0] = 0x04
            System.arraycopy(x, 0, result, 1, 32)
            System.arraycopy(y, 0, result, 33, 32)
            return result
        }

        /** Import EC public key from X.963 format (65 bytes) */
        fun importPublicKeyX963(data: ByteArray): ECPublicKey {
            require(data.size == 65 && data[0] == 0x04.toByte()) { "Invalid X963 key format" }
            val x = data.copyOfRange(1, 33)
            val y = data.copyOfRange(33, 65)

            val kf = KeyFactory.getInstance("EC")
            val params = java.security.AlgorithmParameters.getInstance("EC")
            params.init(ECGenParameterSpec("secp256r1"))
            val ecParams = params.getParameterSpec(java.security.spec.ECParameterSpec::class.java)

            val point = java.security.spec.ECPoint(
                java.math.BigInteger(1, x),
                java.math.BigInteger(1, y)
            )
            return kf.generatePublic(ECPublicKeySpec(point, ecParams)) as ECPublicKey
        }

        /** Pad or trim byte array to exactly `len` bytes (for BigInteger serialization) */
        private fun padOrTrim(bytes: ByteArray, len: Int): ByteArray {
            return when {
                bytes.size == len -> bytes
                bytes.size > len -> bytes.copyOfRange(bytes.size - len, bytes.size)
                else -> ByteArray(len - bytes.size) + bytes
            }
        }

        /** Perform ECDH key agreement */
        fun ecdh(privateKey: java.security.PrivateKey, publicKey: ECPublicKey): ByteArray {
            val ka = KeyAgreement.getInstance("ECDH")
            ka.init(privateKey)
            ka.doPhase(publicKey, true)
            return ka.generateSecret()
        }

        // --- KDF Functions ---

        /** HKDF-SHA256 derive */
        fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, outputLen: Int): ByteArray {
            val hkdfGen = HKDFBytesGenerator(SHA256Digest())
            hkdfGen.init(HKDFParameters(ikm, salt, info))
            val output = ByteArray(outputLen)
            hkdfGen.generateBytes(output, 0, outputLen)
            return output
        }

        /** Initial root key derivation from ECDH shared secret */
        fun kdfRootInitial(sharedSecret: ByteArray): ByteArray {
            return hkdf(sharedSecret, ROOT_KDF_SALT, INIT_INFO, 32)
        }

        /** Root chain KDF: (rootKey, dhOutput) -> (newRootKey, chainKey, headerKey, nextHeaderKey) */
        fun kdfRootChain(rootKey: ByteArray, dhOutput: ByteArray): Array<ByteArray> {
            val ikm = rootKey + dhOutput
            val derived = hkdf(ikm, ROOT_KDF_SALT, ROOT_KDF_INFO, 128)
            return arrayOf(
                derived.copyOfRange(0, 32),   // newRootKey
                derived.copyOfRange(32, 64),  // chainKey
                derived.copyOfRange(64, 96),  // headerKey
                derived.copyOfRange(96, 128)  // nextHeaderKey
            )
        }

        /** Symmetric chain KDF: chainKey -> (newChainKey, messageKey) */
        fun kdfChain(chainKey: ByteArray): Pair<ByteArray, ByteArray> {
            val newChainKey = hkdf(chainKey, CHAIN_KDF_SALT, CHAIN_KDF_INFO_CK, 32)
            val messageKey = hkdf(chainKey, CHAIN_KDF_SALT, CHAIN_KDF_INFO_MK, 32)
            return Pair(newChainKey, messageKey)
        }

        // --- AES-GCM ---

        /** AES-256-GCM encrypt (returns nonce + ciphertext + tag) */
        fun aesGcmEncrypt(plaintext: ByteArray, key: ByteArray): ByteArray {
            val nonce = ByteArray(12)
            java.security.SecureRandom().nextBytes(nonce)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
            val ciphertext = cipher.doFinal(plaintext)
            // Combined: nonce(12) + ciphertext+tag
            return nonce + ciphertext
        }

        /** AES-256-GCM decrypt (input: nonce + ciphertext + tag) */
        fun aesGcmDecrypt(combined: ByteArray, key: ByteArray): ByteArray {
            require(combined.size > 12) { "Ciphertext too short" }
            val nonce = combined.copyOfRange(0, 12)
            val ciphertext = combined.copyOfRange(12, combined.size)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
            return cipher.doFinal(ciphertext)
        }

        /** Initialize as initiator (host/Alice) */
        fun initAsInitiator(sharedSecret: ByteArray, peerDHPublicKey: ECPublicKey): DoubleRatchet {
            val dr = DoubleRatchet()
            val keyPair = generateKeyPair()
            dr.dhSending = keyPair
            dr.dhReceiving = peerDHPublicKey

            // Derive initial root key
            val initialRootKey = kdfRootInitial(sharedSecret)

            // Perform first DH ratchet step
            val dhOutput = ecdh(keyPair.private, peerDHPublicKey)

            // Root KDF: rootKey + DH output -> new rootKey + sendChainKey + headerKeys
            val (newRootKey, chainKey, sendHK, nextRecvHK) = kdfRootChain(initialRootKey, dhOutput)

            dr.rootKey = newRootKey
            dr.sendChainKey = chainKey
            dr.receiveChainKey = null
            dr.sendHeaderKey = sendHK
            dr.nextReceiveHeaderKey = nextRecvHK
            dr.receiveHeaderKey = null
            dr.nextSendHeaderKey = null

            return dr
        }

        /** Initialize as responder (guest/Bob) */
        fun initAsResponder(sharedSecret: ByteArray): DoubleRatchet {
            val dr = DoubleRatchet()
            val keyPair = generateKeyPair()
            dr.dhSending = keyPair
            dr.dhReceiving = null

            dr.rootKey = kdfRootInitial(sharedSecret)
            dr.sendChainKey = null
            dr.receiveChainKey = null
            dr.sendHeaderKey = null
            dr.receiveHeaderKey = null
            dr.nextSendHeaderKey = null
            dr.nextReceiveHeaderKey = null

            return dr
        }

        /** Restore from persisted state */
        fun fromState(state: DoubleRatchetState): DoubleRatchet {
            val dr = DoubleRatchet()

            // Restore DH keys
            val kf = KeyFactory.getInstance("EC")
            val privateKey = kf.generatePrivate(PKCS8EncodedKeySpec(state.dhSendingPrivateKey))
            val publicKey = importPublicKeyX963(state.dhSendingPublicKey)
            dr.dhSending = KeyPair(publicKey, privateKey)

            dr.dhReceiving = state.dhReceivingPublicKey?.let { importPublicKeyX963(it) }
            dr.rootKey = state.rootKey
            dr.sendChainKey = state.sendChainKey
            dr.receiveChainKey = state.receiveChainKey
            dr.sendHeaderKey = state.sendHeaderKey
            dr.receiveHeaderKey = state.receiveHeaderKey
            dr.nextSendHeaderKey = state.nextSendHeaderKey
            dr.nextReceiveHeaderKey = state.nextReceiveHeaderKey
            dr.sendMessageNumber = state.sendMessageNumber
            dr.receiveMessageNumber = state.receiveMessageNumber
            dr.previousChainLength = state.previousChainLength

            return dr
        }
    }

    // MARK: - State

    private lateinit var dhSending: KeyPair
    private var dhReceiving: ECPublicKey? = null
    private lateinit var rootKey: ByteArray
    private var sendChainKey: ByteArray? = null
    private var receiveChainKey: ByteArray? = null
    private var sendHeaderKey: ByteArray? = null
    private var receiveHeaderKey: ByteArray? = null
    private var nextSendHeaderKey: ByteArray? = null
    private var nextReceiveHeaderKey: ByteArray? = null

    var sendMessageNumber: Int = 0
        private set
    var receiveMessageNumber: Int = 0
        private set
    var previousChainLength: Int = 0
        private set

    val skippedKeys: MutableMap<SkippedKeyIndex, ByteArray> = mutableMapOf()

    /** Export the current DH ratchet public key (X963 format, 65 bytes) */
    val dhPublicKeyData: ByteArray
        get() = exportPublicKeyX963(dhSending.public as ECPublicKey)

    // MARK: - Encrypt

    /** Encrypt a plaintext message. Returns (encryptedHeader, ciphertext) */
    fun encrypt(plaintext: ByteArray): Pair<ByteArray, ByteArray> {
        val chainKey = sendChainKey ?: throw DoubleRatchetError.SendChainNotInitialized()

        // Advance sending chain
        val (newChainKey, messageKey) = kdfChain(chainKey)
        sendChainKey = newChainKey

        // Create header
        val header = DRHeader(
            dhPublicKey = exportPublicKeyX963(dhSending.public as ECPublicKey),
            pn = previousChainLength,
            n = sendMessageNumber
        )
        sendMessageNumber++

        // Encrypt body with message key
        val ciphertext = aesGcmEncrypt(plaintext, messageKey)

        // Always plaintext headers (0x00 prefix)
        // Header encryption disabled: avoids chicken-and-egg where responder
        // has no header key to decrypt initiator's first messages
        val encryptedHeader = ByteArray(1 + 73)
        encryptedHeader[0] = 0x00
        System.arraycopy(header.serialize(), 0, encryptedHeader, 1, 73)

        return Pair(encryptedHeader, ciphertext)
    }

    // MARK: - Decrypt

    /** Decrypt a received message */
    fun decrypt(encryptedHeader: ByteArray, ciphertext: ByteArray): ByteArray {
        // Try to decrypt header
        val (header, usedNextKey) = decryptHeader(encryptedHeader)

        // Check if this is from a new DH ratchet key
        val peerDHKeyData = header.dhPublicKey
        val currentReceiving = dhReceiving

        if (currentReceiving == null || !peerDHKeyData.contentEquals(exportPublicKeyX963(currentReceiving))) {
            // New DH ratchet key from peer
            receiveChainKey?.let { recvCK ->
                dhReceiving?.let { dhRecv ->
                    skipMessageKeys(recvCK, header.pn, exportPublicKeyX963(dhRecv))
                }
            }
            dhRatchetReceive(peerDHKeyData, usedNextKey)
        }

        // Skip missed messages in current receiving chain
        val recvCK = receiveChainKey ?: throw DoubleRatchetError.ReceiveChainNotInitialized()
        skipMessageKeys(recvCK, header.n, peerDHKeyData)

        // Advance receiving chain
        val (newChainKey, messageKey) = kdfChain(receiveChainKey!!)
        receiveChainKey = newChainKey
        receiveMessageNumber = header.n + 1

        // Decrypt body
        return aesGcmDecrypt(ciphertext, messageKey)
    }

    /** Try to decrypt with a stored skipped key first */
    fun tryDecryptWithSkippedKey(encryptedHeader: ByteArray, ciphertext: ByteArray): ByteArray? {
        val header: DRHeader
        try {
            val (h, _) = decryptHeader(encryptedHeader)
            header = h
        } catch (e: Exception) {
            return null
        }

        val index = SkippedKeyIndex(header.dhPublicKey, header.n)
        val messageKey = skippedKeys[index] ?: return null
        skippedKeys.remove(index)

        return aesGcmDecrypt(ciphertext, messageKey)
    }

    // MARK: - DH Ratchet

    private fun dhRatchetReceive(peerDHKeyData: ByteArray, usedNextHeaderKey: Boolean) {
        val peerDHKey = importPublicKeyX963(peerDHKeyData)

        previousChainLength = sendMessageNumber
        sendMessageNumber = 0
        receiveMessageNumber = 0
        dhReceiving = peerDHKey

        // Update header keys
        if (usedNextHeaderKey) {
            receiveHeaderKey = nextReceiveHeaderKey
        }

        // DH with our current key and new peer key -> update receive chain
        val dhOutputRecv = ecdh(dhSending.private, peerDHKey)
        val (rk1, recvCK, _, nextRecvHK) = kdfRootChain(rootKey, dhOutputRecv)
        rootKey = rk1
        receiveChainKey = recvCK
        nextReceiveHeaderKey = nextRecvHK

        // Generate new DH key pair
        dhSending = generateKeyPair()

        // DH with new key and peer key -> update send chain
        val dhOutputSend = ecdh(dhSending.private, peerDHKey)
        val (rk2, sendCK, sendHK, nextSendHK) = kdfRootChain(rootKey, dhOutputSend)
        rootKey = rk2
        sendChainKey = sendCK
        sendHeaderKey = sendHK
        nextSendHeaderKey = nextSendHK
    }

    // MARK: - Header Decryption

    private fun decryptHeader(encryptedHeader: ByteArray): Pair<DRHeader, Boolean> {
        // Check if plaintext header (prefix 0x00)
        if (encryptedHeader.isNotEmpty() && encryptedHeader[0] == 0x00.toByte() && encryptedHeader.size == 74) {
            val headerData = encryptedHeader.copyOfRange(1, 74)
            return Pair(DRHeader.deserialize(headerData), false)
        }

        // Try current receive header key
        receiveHeaderKey?.let { rhk ->
            try {
                val header = decryptHeaderWithKey(encryptedHeader, rhk)
                return Pair(header, false)
            } catch (_: Exception) { }
        }

        // Try next receive header key
        nextReceiveHeaderKey?.let { nrhk ->
            try {
                val header = decryptHeaderWithKey(encryptedHeader, nrhk)
                return Pair(header, true)
            } catch (_: Exception) { }
        }

        throw DoubleRatchetError.HeaderDecryptionFailed()
    }

    private fun decryptHeaderWithKey(data: ByteArray, key: ByteArray): DRHeader {
        val headerData = aesGcmDecrypt(data, key)
        return DRHeader.deserialize(headerData)
    }

    // MARK: - Skipped Keys

    private fun skipMessageKeys(chainKey: ByteArray, targetN: Int, peerDHKey: ByteArray?) {
        peerDHKey ?: return

        var currentCK = chainKey
        var currentN = receiveMessageNumber

        require(targetN - currentN <= MAX_SKIP) { "Too many skipped messages" }

        while (currentN < targetN) {
            val (newCK, messageKey) = kdfChain(currentCK)
            val index = SkippedKeyIndex(peerDHKey, currentN)
            skippedKeys[index] = messageKey
            currentCK = newCK
            currentN++
        }

        receiveChainKey = currentCK
        receiveMessageNumber = currentN

        // Enforce max skip limit
        while (skippedKeys.size > MAX_SKIP) {
            val firstKey = skippedKeys.keys.firstOrNull() ?: break
            skippedKeys.remove(firstKey)
        }
    }

    // MARK: - State Serialization

    /** Export current state as serializable snapshot */
    fun exportState(): DoubleRatchetState {
        return DoubleRatchetState(
            dhSendingPrivateKey = dhSending.private.encoded,
            dhSendingPublicKey = exportPublicKeyX963(dhSending.public as ECPublicKey),
            dhReceivingPublicKey = dhReceiving?.let { exportPublicKeyX963(it) },
            rootKey = rootKey.copyOf(),
            sendChainKey = sendChainKey?.copyOf(),
            receiveChainKey = receiveChainKey?.copyOf(),
            sendHeaderKey = sendHeaderKey?.copyOf(),
            receiveHeaderKey = receiveHeaderKey?.copyOf(),
            nextSendHeaderKey = nextSendHeaderKey?.copyOf(),
            nextReceiveHeaderKey = nextReceiveHeaderKey?.copyOf(),
            sendMessageNumber = sendMessageNumber,
            receiveMessageNumber = receiveMessageNumber,
            previousChainLength = previousChainLength
        )
    }

    /** Export skipped keys for per-contact persistent storage */
    fun exportSkippedKeys(): List<Triple<ByteArray, Int, ByteArray>> {
        return skippedKeys.map { (index, key) ->
            Triple(index.dhPublicKey, index.messageNumber, key)
        }
    }

    /** Import skipped keys from persistent storage */
    fun importSkippedKeys(keys: List<Triple<ByteArray, Int, ByteArray>>) {
        for ((dhKey, msgNum, msgKey) in keys) {
            skippedKeys[SkippedKeyIndex(dhKey, msgNum)] = msgKey
        }
    }

    // MARK: - Cleanup

    /** Securely destroy all key material */
    fun destroy() {
        skippedKeys.clear()
        sendChainKey = null
        receiveChainKey = null
        sendHeaderKey = null
        receiveHeaderKey = null
        nextSendHeaderKey = null
        nextReceiveHeaderKey = null
        dhReceiving = null
    }
}

// MARK: - Errors

sealed class DoubleRatchetError : Exception() {
    class SendChainNotInitialized : DoubleRatchetError() {
        override val message = "Send chain not initialized"
    }
    class ReceiveChainNotInitialized : DoubleRatchetError() {
        override val message = "Receive chain not initialized"
    }
    class InvalidHeader : DoubleRatchetError() {
        override val message = "Invalid DR header"
    }
    class HeaderDecryptionFailed : DoubleRatchetError() {
        override val message = "Header decryption failed"
    }
    class EncryptionFailed : DoubleRatchetError() {
        override val message = "DR encryption failed"
    }
    class TooManySkippedMessages : DoubleRatchetError() {
        override val message = "Too many skipped messages"
    }
}
