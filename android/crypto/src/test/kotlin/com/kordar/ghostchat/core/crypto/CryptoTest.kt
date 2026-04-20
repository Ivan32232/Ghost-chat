package com.kordar.ghostchat.core.crypto

import com.google.gson.Gson
import com.google.gson.JsonObject
import org.junit.jupiter.api.*
import org.junit.jupiter.api.Assertions.*
import java.security.PrivateKey
import java.security.PublicKey
import java.util.Base64

@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class CryptoTest {

    private lateinit var vectors: JsonObject

    @BeforeAll
    fun setUp() {
        val json = javaClass.classLoader.getResourceAsStream("test-vectors.json")!!
            .bufferedReader().readText()
        vectors = Gson().fromJson(json, JsonObject::class.java)
    }

    // Helpers
    private fun v(path: String): String {
        val parts = path.split(".")
        var current = vectors
        for (i in 0 until parts.size - 1) {
            current = current.getAsJsonObject(parts[i])
        }
        return current.get(parts.last()).asString
    }

    private fun vi(path: String): Int {
        val parts = path.split(".")
        var current = vectors
        for (i in 0 until parts.size - 1) {
            current = current.getAsJsonObject(parts[i])
        }
        return current.get(parts.last()).asInt
    }

    // 1. ECDH Key Exchange

    @Test
    fun `ECDH shared secret matches test vector`() {
        val alice = CryptoUtils.keyPairFromPrivateBytes(v("ecdh.alice.privateKey").hexToByteArray())
        val bobPub = CryptoUtils.publicKeyFromBytes(v("ecdh.bob.publicKey").hexToByteArray())
        val shared = CryptoUtils.ecdhSharedSecret(alice.privateKey, bobPub)
        assertEquals(v("ecdh.sharedSecret"), shared.toHexString())
    }

    @Test
    fun `ECDH is symmetric`() {
        val alice = CryptoUtils.keyPairFromPrivateBytes(v("ecdh.alice.privateKey").hexToByteArray())
        val bob = CryptoUtils.keyPairFromPrivateBytes(v("ecdh.bob.privateKey").hexToByteArray())
        val s1 = CryptoUtils.ecdhSharedSecret(alice.privateKey, bob.publicKey)
        val s2 = CryptoUtils.ecdhSharedSecret(bob.privateKey, alice.publicKey)
        assertArrayEquals(s1, s2)
    }

    @Test
    fun `public key derivation matches`() {
        val alice = CryptoUtils.keyPairFromPrivateBytes(v("ecdh.alice.privateKey").hexToByteArray())
        assertEquals(v("ecdh.alice.publicKey"), alice.publicKeyBytes.toHexString())
    }

    // 2. Initial Root Key

    @Test
    fun `initial root key derivation matches`() {
        val ikm = v("initialRootKey.ikm").hexToByteArray()
        val derived = CryptoUtils.deriveInitialRootKey(ikm)
        assertEquals(v("initialRootKey.rootKey"), derived.toHexString())
    }

    // 3. Root KDF

    @Test
    fun `root KDF matches`() {
        val rk = v("rootKDF.rootKey").hexToByteArray()
        val dh = v("rootKDF.dhOutput").hexToByteArray()
        val result = CryptoUtils.rootKDF(rk, dh)
        assertEquals(v("rootKDF.newRootKey"), result.newRootKey.toHexString())
        assertEquals(v("rootKDF.chainKey"), result.chainKey.toHexString())
    }

    // 4. Chain KDF

    @Test
    fun `chain KDF matches`() {
        val ck = v("chainKDF.chainKey").hexToByteArray()
        val step0 = CryptoUtils.chainKDF(ck)
        assertEquals(v("chainKDF.messageKey0"), step0.messageKey.toHexString())
        assertEquals(v("chainKDF.nextChainKey0"), step0.nextChainKey.toHexString())

        val step1 = CryptoUtils.chainKDF(step0.nextChainKey)
        assertEquals(v("chainKDF.messageKey1"), step1.messageKey.toHexString())
        assertEquals(v("chainKDF.nextChainKey1"), step1.nextChainKey.toHexString())
    }

    // 5. AES-256-GCM

    @Test
    fun `AES-GCM encrypt matches`() {
        val key = v("aesGcm.key").hexToByteArray()
        val nonce = v("aesGcm.nonce").hexToByteArray()
        val pt = v("aesGcm.plaintext").hexToByteArray()
        val aad = v("aesGcm.aad").hexToByteArray()
        val ctWithTag = CryptoUtils.aesGcmEncrypt(key, nonce, pt, aad)
        val ct = ctWithTag.copyOfRange(0, ctWithTag.size - 16)
        val tag = ctWithTag.copyOfRange(ctWithTag.size - 16, ctWithTag.size)
        assertEquals(v("aesGcm.ciphertext"), ct.toHexString())
        assertEquals(v("aesGcm.tag"), tag.toHexString())
    }

    @Test
    fun `AES-GCM decrypt matches`() {
        val key = v("aesGcm.key").hexToByteArray()
        val nonce = v("aesGcm.nonce").hexToByteArray()
        val ct = v("aesGcm.ciphertext").hexToByteArray()
        val tag = v("aesGcm.tag").hexToByteArray()
        val aad = v("aesGcm.aad").hexToByteArray()
        val decrypted = CryptoUtils.aesGcmDecrypt(key, nonce, ct + tag, aad)
        assertEquals(v("aesGcm.plaintextUtf8"), String(decrypted, Charsets.UTF_8))
    }

    // 6. Message Padding

    @Test
    fun `message padding matches`() {
        val input = v("messagePadding.input")
        val padded = MessagePadding.pad(input, 0x00)
        assertEquals(v("messagePadding.paddedHex"), padded.toHexString())
        assertEquals(vi("messagePadding.paddedLength"), padded.size)
        assertTrue(padded.size % 256 == 0)
    }

    @Test
    fun `message unpadding matches`() {
        val padded = v("messagePadding.paddedHex").hexToByteArray()
        assertEquals(v("messagePadding.input"), MessagePadding.unpad(padded))
    }

    // 7. Wire Format

    @Test
    fun `header construction matches`() {
        val dhPubRaw = v("wireFormat.dhPublicKeyRaw").hexToByteArray()
        val header = WireFormat.buildHeader(dhPubRaw, vi("wireFormat.pn"), vi("wireFormat.n"))
        assertEquals(v("wireFormat.headerHex"), header.toHexString())
        assertEquals(vi("wireFormat.headerLength"), header.size)
    }

    @Test
    fun `header parsing matches`() {
        val headerData = v("wireFormat.headerHex").hexToByteArray()
        val parsed = WireFormat.parseHeader(headerData)
        assertEquals(vi("wireFormat.headerVersion").toByte(), parsed.version)
        assertEquals(v("wireFormat.dhPublicKeyRaw"), parsed.dhPublicKeyRaw.toHexString())
        assertEquals(vi("wireFormat.pn"), parsed.pn)
        assertEquals(vi("wireFormat.n"), parsed.n)
    }

    @Test
    fun `wire message assembly matches`() {
        val header = v("wireFormat.headerHex").hexToByteArray()
        val nonce = v("wireFormat.nonce").hexToByteArray()
        val ct = v("wireFormat.ciphertext").hexToByteArray()
        val tag = v("wireFormat.tag").hexToByteArray()
        val wire = WireFormat.buildMessage(header, nonce, ct, tag)
        assertEquals(v("wireFormat.wireMessageHex"), wire.toHexString())
    }

    @Test
    fun `wire message parsing matches`() {
        val wireData = v("wireFormat.wireMessageHex").hexToByteArray()
        val parsed = WireFormat.parseMessage(wireData)
        assertEquals(v("wireFormat.headerHex"), parsed.header.toHexString())
        assertEquals(v("wireFormat.nonce"), parsed.nonce.toHexString())
        assertEquals(v("wireFormat.ciphertext"), parsed.ciphertext.toHexString())
        assertEquals(v("wireFormat.tag"), parsed.tag.toHexString())
    }

    // 8. Safety Number

    @Test
    fun `safety number matches`() {
        val keyA = v("safetyNumber.identityKeyA").hexToByteArray()
        val keyB = v("safetyNumber.identityKeyB").hexToByteArray()
        assertEquals(v("safetyNumber.fingerprint"), CryptoUtils.safetyNumber(keyA, keyB))
    }

    @Test
    fun `safety number is order-independent`() {
        val keyA = v("safetyNumber.identityKeyA").hexToByteArray()
        val keyB = v("safetyNumber.identityKeyB").hexToByteArray()
        assertEquals(CryptoUtils.safetyNumber(keyA, keyB), CryptoUtils.safetyNumber(keyB, keyA))
    }

    // 9. Full Double Ratchet Session

    @Test
    fun `double ratchet session matches test vectors`() {
        val session = vectors.getAsJsonObject("session")
        val hostEphPriv = CryptoUtils.keyPairFromPrivateBytes(
            session.get("hostEphemeralPrivateKey").asString.hexToByteArray()
        )
        val guestEphPriv = CryptoUtils.keyPairFromPrivateBytes(
            session.get("guestEphemeralPrivateKey").asString.hexToByteArray()
        )

        val shared = CryptoUtils.ecdhSharedSecret(hostEphPriv.privateKey, guestEphPriv.publicKey)
        assertEquals(session.get("sharedSecret").asString, shared.toHexString())

        val sk = CryptoUtils.deriveInitialRootKey(shared)
        assertEquals(session.get("initialRootKey").asString, sk.toHexString())

        val ratchetKeypairs = session.getAsJsonArray("ratchetKeypairs").map {
            CryptoUtils.keyPairFromPrivateBytes(it.asJsonObject.get("privateKey").asString.hexToByteArray())
        }

        // HOST generator: ratchetKeys[2], ratchetKeys[3], ...
        val hostKeyGen = TestKeyPairGenerator(ratchetKeypairs.drop(2))
        val host = DoubleRatchet(
            role = RatchetRole.HOST,
            sharedKey = sk,
            ourKeyPair = ratchetKeypairs[0],
            theirPublicKey = guestEphPriv.publicKey,
            keyGen = hostKeyGen
        )

        // GUEST generator: ratchetKeys[1], ratchetKeys[3]
        val guestKeyGen = TestKeyPairGenerator(listOf(ratchetKeypairs[1], ratchetKeypairs[3]))
        val guest = DoubleRatchet(
            role = RatchetRole.GUEST,
            sharedKey = sk,
            ourKeyPair = guestEphPriv,
            theirPublicKey = null,
            keyGen = guestKeyGen
        )

        val messages = session.getAsJsonArray("messages")
        for (msgEl in messages) {
            val msg = msgEl.asJsonObject
            val sender = msg.get("sender").asString
            val index = msg.get("index").asInt
            val msgJson = msg.get("messageJson").asString
            val expectedMK = msg.get("messageKey").asString
            val expectedWire = msg.get("wireBase64").asString
            val nonce = msg.get("nonce").asString.hexToByteArray()

            if (sender == "HOST") {
                val enc = host.encrypt(msgJson, nonce, 0x00)
                assertEquals(expectedMK, enc.debugMessageKey?.toHexString(),
                    "Message key mismatch at index $index")
                assertEquals(expectedWire, enc.wireBase64,
                    "Wire base64 mismatch at index $index")
                val dec = guest.decrypt(enc.wireBase64)
                assertEquals(msgJson, dec, "Decryption mismatch at index $index")
            } else {
                val enc = guest.encrypt(msgJson, nonce, 0x00)
                assertEquals(expectedMK, enc.debugMessageKey?.toHexString(),
                    "Message key mismatch at index $index")
                assertEquals(expectedWire, enc.wireBase64,
                    "Wire base64 mismatch at index $index")
                val dec = host.decrypt(enc.wireBase64)
                assertEquals(msgJson, dec, "Decryption mismatch at index $index")
            }
        }
    }

    // 10. Out-of-order messages

    @Test
    fun `out-of-order messages decrypt correctly`() {
        val session = vectors.getAsJsonObject("session")
        val hostEphPriv = CryptoUtils.keyPairFromPrivateBytes(
            session.get("hostEphemeralPrivateKey").asString.hexToByteArray()
        )
        val guestEphPriv = CryptoUtils.keyPairFromPrivateBytes(
            session.get("guestEphemeralPrivateKey").asString.hexToByteArray()
        )
        val shared = CryptoUtils.ecdhSharedSecret(hostEphPriv.privateKey, guestEphPriv.publicKey)
        val sk = CryptoUtils.deriveInitialRootKey(shared)
        val rk0 = CryptoUtils.keyPairFromPrivateBytes(
            session.getAsJsonArray("ratchetKeypairs")[0].asJsonObject.get("privateKey").asString.hexToByteArray()
        )

        val host = DoubleRatchet(RatchetRole.HOST, sk, rk0, guestEphPriv.publicKey)
        val guest = DoubleRatchet(RatchetRole.GUEST, sk, guestEphPriv, null)

        val msg0 = host.encrypt("msg-0")
        val msg1 = host.encrypt("msg-1")
        val msg2 = host.encrypt("msg-2")

        // Receive out of order: 2, 0, 1
        assertEquals("msg-2", guest.decrypt(msg2.wireBase64))
        assertEquals("msg-0", guest.decrypt(msg0.wireBase64))
        assertEquals("msg-1", guest.decrypt(msg1.wireBase64))
    }

    // 11. Replay attack rejected

    @Test
    fun `replay attack is rejected`() {
        val session = vectors.getAsJsonObject("session")
        val hostEphPriv = CryptoUtils.keyPairFromPrivateBytes(
            session.get("hostEphemeralPrivateKey").asString.hexToByteArray()
        )
        val guestEphPriv = CryptoUtils.keyPairFromPrivateBytes(
            session.get("guestEphemeralPrivateKey").asString.hexToByteArray()
        )
        val shared = CryptoUtils.ecdhSharedSecret(hostEphPriv.privateKey, guestEphPriv.publicKey)
        val sk = CryptoUtils.deriveInitialRootKey(shared)
        val rk0 = CryptoUtils.keyPairFromPrivateBytes(
            session.getAsJsonArray("ratchetKeypairs")[0].asJsonObject.get("privateKey").asString.hexToByteArray()
        )

        val host = DoubleRatchet(RatchetRole.HOST, sk, rk0, guestEphPriv.publicKey)
        val guest = DoubleRatchet(RatchetRole.GUEST, sk, guestEphPriv, null)

        val enc = host.encrypt("test replay")
        guest.decrypt(enc.wireBase64)

        // Same ciphertext again → must fail
        assertThrows<Exception> { guest.decrypt(enc.wireBase64) }
    }

    // 12. Padding properties

    @Test
    fun `padding always multiple of 256`() {
        for (len in listOf(1, 10, 50, 100, 200, 252, 253, 500, 1000)) {
            val msg = "A".repeat(len)
            val padded = MessagePadding.pad(msg)
            assertTrue(padded.size % 256 == 0, "Not multiple of 256 for len $len")
        }
    }

    @Test
    fun `padding roundtrip`() {
        val messages = listOf("Hello", """{"m":"test"}""", "X".repeat(1000), "")
        for (msg in messages) {
            assertEquals(msg, MessagePadding.unpad(MessagePadding.pad(msg)))
        }
    }
}

class TestKeyPairGenerator(keys: List<CryptoUtils.ECKeyPair>) : KeyPairGenerator {
    private val keys = keys.toMutableList()
    private var index = 0

    override fun generate(): CryptoUtils.ECKeyPair {
        return if (index < keys.size) keys[index++] else CryptoUtils.generateKeyPair()
    }
}
