package com.kordar.ghostchat.core.crypto

import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.util.Base64

enum class RatchetRole { HOST, GUEST }

interface KeyPairGenerator {
    fun generate(): CryptoUtils.ECKeyPair
}

class RandomKeyPairGenerator : KeyPairGenerator {
    override fun generate(): CryptoUtils.ECKeyPair = CryptoUtils.generateKeyPair()
}

class EncryptedMessage internal constructor(
    val wireBase64: String,
    @VisibleForTesting internal val debugMessageKey: ByteArray? = null
)

class DoubleRatchet(
    role: RatchetRole,
    sharedKey: ByteArray,
    ourKeyPair: CryptoUtils.ECKeyPair,
    theirPublicKey: PublicKey?,
    private val keyGen: KeyPairGenerator = RandomKeyPairGenerator()
) {
    private var dhs: CryptoUtils.ECKeyPair = ourKeyPair
    private var dhr: PublicKey? = theirPublicKey
    private var rk: ByteArray = sharedKey.copyOf()
    private var cks: ByteArray? = null
    private var ckr: ByteArray? = null
    private var ns: Int = 0
    private var nr: Int = 0
    private var pn: Int = 0

    private val mkSkipped = mutableMapOf<String, ByteArray>() // "dhPubRawHex:N" → messageKey
    private val maxSkip = 100
    private var lastDHr: ByteArray? = null

    /**
     * Re-hydrate a ratchet that was previously serialised via [exportedState].
     * Used to persist per-contact sessions in SQLCipher across app restarts.
     */
    constructor(
        stateBytes: ByteArray,
        keyGen: KeyPairGenerator = RandomKeyPairGenerator()
    ) : this(
        role = RatchetRole.HOST,       // placeholder — values overwritten below
        sharedKey = ByteArray(32),
        ourKeyPair = CryptoUtils.generateKeyPair(),
        theirPublicKey = null,
        keyGen = keyGen
    ) {
        val snap = DoubleRatchetState.deserialize(stateBytes)
        dhs = CryptoUtils.keyPairFromPrivateBytes(snap.dhsPrivateBytes)
        dhr = snap.dhrRaw?.let { CryptoUtils.publicKeyFromBytes(it) }
        rk = snap.rk.copyOf()
        cks = snap.cks?.copyOf()
        ckr = snap.ckr?.copyOf()
        ns = snap.ns; nr = snap.nr; pn = snap.pn
        lastDHr = snap.lastDHr?.copyOf()
        mkSkipped.clear()
        mkSkipped.putAll(snap.mkSkipped)
    }

    /** Serialised opaque ratchet state suitable for persistence in SQLCipher. */
    val exportedState: ByteArray
        get() = DoubleRatchetState.serialize(
            DoubleRatchetState.Snapshot(
                dhsPrivateBytes = dhs.privateKeyBytes,
                dhrRaw = lastDHr?.copyOf(), // current remote DH raw if any
                rk = rk.copyOf(),
                cks = cks?.copyOf(),
                ckr = ckr?.copyOf(),
                ns = ns, nr = nr, pn = pn,
                lastDHr = lastDHr?.copyOf(),
                mkSkipped = mkSkipped.mapValues { it.value.copyOf() }
            )
        )

    init {
        when (role) {
            RatchetRole.HOST -> {
                if (theirPublicKey != null) {
                    val dhOutput = CryptoUtils.ecdhSharedSecret(dhs.privateKey, theirPublicKey)
                    val result = CryptoUtils.rootKDF(rk, dhOutput)
                    rk = result.newRootKey
                    cks = result.chainKey
                    lastDHr = publicKeyRaw(theirPublicKey)
                }
            }
            RatchetRole.GUEST -> {
                // Wait for first message
            }
        }
    }

    fun encrypt(
        plaintext: String,
        deterministicNonce: ByteArray? = null,
        deterministicPadByte: Byte? = null
    ): EncryptedMessage {
        val currentCKs = cks ?: throw IllegalStateException("No sending chain")

        val chain = CryptoUtils.chainKDF(currentCKs)
        cks = chain.nextChainKey

        val padded = if (deterministicPadByte != null) {
            MessagePadding.pad(plaintext, deterministicPadByte)
        } else {
            MessagePadding.pad(plaintext)
        }

        val dhPubRaw = dhs.publicKeyRaw
        val header = WireFormat.buildHeader(dhPubRaw, pn, ns)

        val nonce = deterministicNonce ?: ByteArray(12).also { SecureRandom().nextBytes(it) }

        // AES-GCM: BouncyCastle returns ciphertext+tag concatenated
        val ctWithTag = CryptoUtils.aesGcmEncrypt(chain.messageKey, nonce, padded, header)
        val ct = ctWithTag.copyOfRange(0, ctWithTag.size - 16)
        val tag = ctWithTag.copyOfRange(ctWithTag.size - 16, ctWithTag.size)

        val wire = WireFormat.buildMessage(header, nonce, ct, tag)
        ns++

        return EncryptedMessage(
            wireBase64 = Base64.getEncoder().encodeToString(wire),
            debugMessageKey = chain.messageKey
        )
    }

    fun decrypt(wireBase64: String): String {
        val wireData = Base64.getDecoder().decode(wireBase64)
        val parsed = WireFormat.parseMessage(wireData)
        val headerParsed = WireFormat.parseHeader(parsed.header)

        val peerDHPubRaw = headerParsed.dhPublicKeyRaw
        val peerPub = CryptoUtils.publicKeyFromBytes(peerDHPubRaw)

        // Check skipped messages
        val skipKey = peerDHPubRaw.toHexString() + ":" + headerParsed.n
        mkSkipped.remove(skipKey)?.let { mk ->
            return decryptWithKey(mk, parsed)
        }

        // Check if ratchet needed
        val peerRawHex = peerDHPubRaw.toHexString()
        val currentDHrHex = lastDHr?.toHexString()

        if (peerRawHex != currentDHrHex) {
            // Skip missed messages
            if (ckr != null && lastDHr != null) {
                skipMessages(headerParsed.pn, lastDHr!!)
            }

            // DH ratchet
            pn = ns
            ns = 0
            nr = 0
            dhr = peerPub
            lastDHr = peerDHPubRaw.copyOf()

            // Receiving chain
            val dhRecv = CryptoUtils.ecdhSharedSecret(dhs.privateKey, peerPub)
            val recvResult = CryptoUtils.rootKDF(rk, dhRecv)
            rk = recvResult.newRootKey
            ckr = recvResult.chainKey

            // New sending keypair + chain
            dhs = keyGen.generate()
            val dhSend = CryptoUtils.ecdhSharedSecret(dhs.privateKey, peerPub)
            val sendResult = CryptoUtils.rootKDF(rk, dhSend)
            rk = sendResult.newRootKey
            cks = sendResult.chainKey
        }

        // Skip missed messages in current chain
        skipMessages(headerParsed.n, peerDHPubRaw)

        // Chain step
        val currentCKr = ckr ?: throw IllegalStateException("No receiving chain")
        val chain = CryptoUtils.chainKDF(currentCKr)
        ckr = chain.nextChainKey
        nr++

        return decryptWithKey(chain.messageKey, parsed)
    }

    private fun skipMessages(until: Int, dhPubRaw: ByteArray) {
        var currentCKr = ckr ?: return

        while (nr < until) {
            check(mkSkipped.size < maxSkip) { "Too many skipped messages" }
            val chain = CryptoUtils.chainKDF(currentCKr)
            val key = dhPubRaw.toHexString() + ":" + nr
            mkSkipped[key] = chain.messageKey
            currentCKr = chain.nextChainKey
            nr++
        }
        ckr = currentCKr
    }

    private fun decryptWithKey(messageKey: ByteArray, parsed: WireFormat.ParsedMessage): String {
        val ctWithTag = parsed.ciphertext + parsed.tag
        val padded = CryptoUtils.aesGcmDecrypt(messageKey, parsed.nonce, ctWithTag, parsed.header)
        return MessagePadding.unpad(padded)
    }

    private fun publicKeyRaw(key: PublicKey): ByteArray {
        val full = (key as org.bouncycastle.jcajce.provider.asymmetric.ec.BCECPublicKey)
            .q.getEncoded(false)
        return full.copyOfRange(1, 65)
    }
}
