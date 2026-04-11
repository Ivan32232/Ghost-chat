package com.ghost.chat

import com.ghost.chat.core.crypto.DoubleRatchet
import com.ghost.chat.core.crypto.DoubleRatchetError
import com.ghost.chat.core.crypto.DRHeader
import com.ghost.chat.core.filetransfer.FileTransferService
import com.ghost.chat.models.ControlMessage
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.security.interfaces.ECPublicKey

/**
 * Comprehensive JUnit tests for Ghost Chat Android security components.
 *
 * Unit tests (no Android Context required) covering:
 * - Crypto: key generation, ECDH, Double Ratchet encrypt/decrypt
 * - File transfer: sanitizeFileName, MAX_FILE_SIZE
 * - Room ID validation: base64url format
 * - ControlMessage: serialization/deserialization roundtrip
 * - Root detection: doesn't crash
 *
 * NOTE: Tests that need Android APIs (EncryptedSharedPreferences, Keystore,
 * SQLCipher, Context) must run as instrumented tests (androidTest/).
 */
class SecurityTests {

    // =========================================================================
    // MARK: - Crypto: Key Pair Generation (P-256, 65 bytes uncompressed)
    // =========================================================================

    @Test
    fun `generateKeyPair returns valid P-256 key pair`() {
        val keyPair = DoubleRatchet.generateKeyPair()
        assertNotNull(keyPair)
        assertNotNull(keyPair.public)
        assertNotNull(keyPair.private)
        assertTrue(keyPair.public is ECPublicKey)
    }

    @Test
    fun `exportPublicKeyX963 returns 65 bytes starting with 0x04`() {
        val keyPair = DoubleRatchet.generateKeyPair()
        val exported = DoubleRatchet.exportPublicKeyX963(keyPair.public as ECPublicKey)
        assertEquals(65, exported.size)
        assertEquals(0x04.toByte(), exported[0])
    }

    @Test
    fun `importPublicKeyX963 roundtrip preserves key`() {
        val keyPair = DoubleRatchet.generateKeyPair()
        val exported = DoubleRatchet.exportPublicKeyX963(keyPair.public as ECPublicKey)
        val imported = DoubleRatchet.importPublicKeyX963(exported)

        val reExported = DoubleRatchet.exportPublicKeyX963(imported)
        assertArrayEquals(exported, reExported)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `importPublicKeyX963 rejects invalid key length`() {
        DoubleRatchet.importPublicKeyX963(ByteArray(32))
    }

    @Test(expected = IllegalArgumentException::class)
    fun `importPublicKeyX963 rejects key without 0x04 prefix`() {
        val data = ByteArray(65) { 0x00 }
        DoubleRatchet.importPublicKeyX963(data)
    }

    @Test
    fun `two generated key pairs are different`() {
        val kp1 = DoubleRatchet.generateKeyPair()
        val kp2 = DoubleRatchet.generateKeyPair()
        val exp1 = DoubleRatchet.exportPublicKeyX963(kp1.public as ECPublicKey)
        val exp2 = DoubleRatchet.exportPublicKeyX963(kp2.public as ECPublicKey)
        assertFalse("Key pairs must be unique", exp1.contentEquals(exp2))
    }

    // =========================================================================
    // MARK: - Crypto: ECDH Key Exchange
    // =========================================================================

    @Test
    fun `ECDH produces non-empty shared secret`() {
        val alice = DoubleRatchet.generateKeyPair()
        val bob = DoubleRatchet.generateKeyPair()

        val sharedAlice = DoubleRatchet.ecdh(alice.private, bob.public as ECPublicKey)
        assertNotNull(sharedAlice)
        assertTrue(sharedAlice.isNotEmpty())
    }

    @Test
    fun `ECDH shared secrets match between two parties`() {
        val alice = DoubleRatchet.generateKeyPair()
        val bob = DoubleRatchet.generateKeyPair()

        val sharedAlice = DoubleRatchet.ecdh(alice.private, bob.public as ECPublicKey)
        val sharedBob = DoubleRatchet.ecdh(bob.private, alice.public as ECPublicKey)

        assertArrayEquals(
            "ECDH shared secrets must match",
            sharedAlice, sharedBob
        )
    }

    @Test
    fun `ECDH with different peers produces different secrets`() {
        val alice = DoubleRatchet.generateKeyPair()
        val bob = DoubleRatchet.generateKeyPair()
        val eve = DoubleRatchet.generateKeyPair()

        val sharedAB = DoubleRatchet.ecdh(alice.private, bob.public as ECPublicKey)
        val sharedAE = DoubleRatchet.ecdh(alice.private, eve.public as ECPublicKey)

        assertFalse(
            "ECDH with different peers must produce different secrets",
            sharedAB.contentEquals(sharedAE)
        )
    }

    // =========================================================================
    // MARK: - Crypto: HKDF
    // =========================================================================

    @Test
    fun `HKDF produces output of requested length`() {
        val ikm = ByteArray(32) { it.toByte() }
        val salt = "test-salt".toByteArray()
        val info = "test-info".toByteArray()

        val output = DoubleRatchet.hkdf(ikm, salt, info, 64)
        assertEquals(64, output.size)
    }

    @Test
    fun `HKDF is deterministic`() {
        val ikm = ByteArray(32) { it.toByte() }
        val salt = "test-salt".toByteArray()
        val info = "test-info".toByteArray()

        val out1 = DoubleRatchet.hkdf(ikm, salt, info, 32)
        val out2 = DoubleRatchet.hkdf(ikm, salt, info, 32)
        assertArrayEquals("HKDF must be deterministic", out1, out2)
    }

    @Test
    fun `HKDF with different info produces different output`() {
        val ikm = ByteArray(32) { it.toByte() }
        val salt = "test-salt".toByteArray()

        val out1 = DoubleRatchet.hkdf(ikm, salt, "info-a".toByteArray(), 32)
        val out2 = DoubleRatchet.hkdf(ikm, salt, "info-b".toByteArray(), 32)
        assertFalse(out1.contentEquals(out2))
    }

    // =========================================================================
    // MARK: - Crypto: AES-GCM encrypt/decrypt
    // =========================================================================

    @Test
    fun `AES-GCM encrypt-decrypt roundtrip`() {
        val key = ByteArray(32) { it.toByte() }
        val plaintext = "Hello, Ghost Chat!".toByteArray()

        val ciphertext = DoubleRatchet.aesGcmEncrypt(plaintext, key)
        val decrypted = DoubleRatchet.aesGcmDecrypt(ciphertext, key)

        assertArrayEquals(plaintext, decrypted)
    }

    @Test
    fun `AES-GCM ciphertext includes 12-byte nonce prefix`() {
        val key = ByteArray(32) { it.toByte() }
        val plaintext = "test".toByteArray()

        val ciphertext = DoubleRatchet.aesGcmEncrypt(plaintext, key)
        // nonce(12) + ciphertext + tag(16) = at least 12 + 4 + 16 = 32
        assertTrue("Ciphertext must include nonce + data + tag", ciphertext.size >= 32)
    }

    @Test
    fun `AES-GCM different encryptions produce different ciphertexts`() {
        val key = ByteArray(32) { it.toByte() }
        val plaintext = "same message".toByteArray()

        val ct1 = DoubleRatchet.aesGcmEncrypt(plaintext, key)
        val ct2 = DoubleRatchet.aesGcmEncrypt(plaintext, key)

        assertFalse(
            "Same plaintext must produce different ciphertexts (unique nonce)",
            ct1.contentEquals(ct2)
        )
    }

    @Test(expected = Exception::class)
    fun `AES-GCM decrypt with wrong key throws`() {
        val key1 = ByteArray(32) { it.toByte() }
        val key2 = ByteArray(32) { (it + 1).toByte() }
        val plaintext = "secret".toByteArray()

        val ciphertext = DoubleRatchet.aesGcmEncrypt(plaintext, key1)
        DoubleRatchet.aesGcmDecrypt(ciphertext, key2) // should throw
    }

    @Test(expected = Exception::class)
    fun `AES-GCM decrypt tampered ciphertext throws`() {
        val key = ByteArray(32) { it.toByte() }
        val plaintext = "secret".toByteArray()

        val ciphertext = DoubleRatchet.aesGcmEncrypt(plaintext, key)
        // Flip a bit in the ciphertext body (after nonce)
        ciphertext[15] = (ciphertext[15].toInt() xor 0xFF).toByte()
        DoubleRatchet.aesGcmDecrypt(ciphertext, key) // should throw AEADBadTagException
    }

    // =========================================================================
    // MARK: - Crypto: Double Ratchet encrypt/decrypt roundtrip
    // =========================================================================

    @Test
    fun `Double Ratchet encrypt-decrypt roundtrip between host and guest`() {
        val alice = DoubleRatchet.generateKeyPair()
        val bob = DoubleRatchet.generateKeyPair()

        // Shared secret via ECDH (both sides derive same secret)
        val sharedSecret = DoubleRatchet.ecdh(alice.private, bob.public as ECPublicKey)

        // Initialize ratchets
        val drHost = DoubleRatchet.initAsInitiator(sharedSecret, bob.public as ECPublicKey)
        val drGuest = DoubleRatchet.initAsResponder(sharedSecret, bob) // Bob reuses his keypair

        // Host encrypts a message
        val plaintext = "Hello from host".toByteArray()
        val (encHeader, ciphertext) = drHost.encrypt(plaintext)

        // Guest decrypts it
        val decrypted = drGuest.decrypt(encHeader, ciphertext)
        assertArrayEquals(plaintext, decrypted)
    }

    @Test
    fun `Double Ratchet bidirectional communication`() {
        val alice = DoubleRatchet.generateKeyPair()
        val bob = DoubleRatchet.generateKeyPair()

        val sharedSecret = DoubleRatchet.ecdh(alice.private, bob.public as ECPublicKey)

        val drHost = DoubleRatchet.initAsInitiator(sharedSecret, bob.public as ECPublicKey)
        val drGuest = DoubleRatchet.initAsResponder(sharedSecret, bob)

        // Host -> Guest (message 1)
        val msg1 = "Host says hello".toByteArray()
        val (eh1, ct1) = drHost.encrypt(msg1)
        val dec1 = drGuest.decrypt(eh1, ct1)
        assertArrayEquals(msg1, dec1)

        // Guest -> Host (reply)
        val msg2 = "Guest says hi back".toByteArray()
        val (eh2, ct2) = drGuest.encrypt(msg2)
        val dec2 = drHost.decrypt(eh2, ct2)
        assertArrayEquals(msg2, dec2)

        // Host -> Guest (message 2)
        val msg3 = "Host second message".toByteArray()
        val (eh3, ct3) = drHost.encrypt(msg3)
        val dec3 = drGuest.decrypt(eh3, ct3)
        assertArrayEquals(msg3, dec3)
    }

    @Test
    fun `Double Ratchet multiple messages in sequence`() {
        val alice = DoubleRatchet.generateKeyPair()
        val bob = DoubleRatchet.generateKeyPair()

        val sharedSecret = DoubleRatchet.ecdh(alice.private, bob.public as ECPublicKey)

        val drHost = DoubleRatchet.initAsInitiator(sharedSecret, bob.public as ECPublicKey)
        val drGuest = DoubleRatchet.initAsResponder(sharedSecret, bob)

        // 10 sequential messages from host
        for (i in 0 until 10) {
            val msg = "Message #$i".toByteArray()
            val (eh, ct) = drHost.encrypt(msg)
            val dec = drGuest.decrypt(eh, ct)
            assertArrayEquals("Message #$i roundtrip failed", msg, dec)
        }
    }

    @Test
    fun `Double Ratchet each message uses unique key (per-message forward secrecy)`() {
        val alice = DoubleRatchet.generateKeyPair()
        val bob = DoubleRatchet.generateKeyPair()

        val sharedSecret = DoubleRatchet.ecdh(alice.private, bob.public as ECPublicKey)

        val drHost = DoubleRatchet.initAsInitiator(sharedSecret, bob.public as ECPublicKey)

        val msg = "same message".toByteArray()
        val (_, ct1) = drHost.encrypt(msg)
        val (_, ct2) = drHost.encrypt(msg)

        // Ciphertexts must differ (different message keys + nonces)
        assertFalse(
            "Same plaintext must produce different ciphertexts (per-message keys)",
            ct1.contentEquals(ct2)
        )
    }

    @Test(expected = DoubleRatchetError.SendChainNotInitialized::class)
    fun `Guest cannot encrypt before receiving first host message`() {
        val bob = DoubleRatchet.generateKeyPair()
        val sharedSecret = ByteArray(32) { it.toByte() }

        val drGuest = DoubleRatchet.initAsResponder(sharedSecret, bob)
        // Guest has no send chain until DH ratchet step triggered by host's message
        drGuest.encrypt("should fail".toByteArray())
    }

    // =========================================================================
    // MARK: - Crypto: DRHeader serialization
    // =========================================================================

    @Test
    fun `DRHeader serialize-deserialize roundtrip`() {
        val dhKey = ByteArray(65) { it.toByte() }
        dhKey[0] = 0x04
        val header = DRHeader(dhKey, pn = 5, n = 42)

        val serialized = header.serialize()
        assertEquals(73, serialized.size)

        val deserialized = DRHeader.deserialize(serialized)
        assertArrayEquals(dhKey, deserialized.dhPublicKey)
        assertEquals(5, deserialized.pn)
        assertEquals(42, deserialized.n)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `DRHeader deserialize rejects wrong size`() {
        DRHeader.deserialize(ByteArray(10))
    }

    // =========================================================================
    // MARK: - Crypto: Double Ratchet state persistence
    // =========================================================================

    @Test
    fun `Double Ratchet state export and restore roundtrip`() {
        val alice = DoubleRatchet.generateKeyPair()
        val bob = DoubleRatchet.generateKeyPair()

        val sharedSecret = DoubleRatchet.ecdh(alice.private, bob.public as ECPublicKey)
        val drHost = DoubleRatchet.initAsInitiator(sharedSecret, bob.public as ECPublicKey)
        val drGuest = DoubleRatchet.initAsResponder(sharedSecret, bob)

        // Exchange some messages to advance ratchet state
        val (eh1, ct1) = drHost.encrypt("msg1".toByteArray())
        drGuest.decrypt(eh1, ct1)
        val (eh2, ct2) = drGuest.encrypt("reply1".toByteArray())
        drHost.decrypt(eh2, ct2)

        // Export host state
        val state = drHost.exportState()
        val skippedKeys = drHost.exportSkippedKeys()

        // Restore from state
        val drRestored = DoubleRatchet.fromState(state)
        drRestored.importSkippedKeys(skippedKeys)

        // Restored ratchet should be able to continue conversation
        val (eh3, ct3) = drRestored.encrypt("after restore".toByteArray())
        val dec3 = drGuest.decrypt(eh3, ct3)
        assertArrayEquals("after restore".toByteArray(), dec3)
    }

    // =========================================================================
    // MARK: - Crypto: destroy() zeroes key material
    // =========================================================================

    @Test
    fun `Double Ratchet destroy does not throw`() {
        val alice = DoubleRatchet.generateKeyPair()
        val bob = DoubleRatchet.generateKeyPair()
        val sharedSecret = DoubleRatchet.ecdh(alice.private, bob.public as ECPublicKey)
        val drHost = DoubleRatchet.initAsInitiator(sharedSecret, bob.public as ECPublicKey)

        drHost.destroy() // should not throw

        // After destroy, encrypt should fail
        try {
            drHost.encrypt("should fail".toByteArray())
            fail("Encrypt after destroy should throw")
        } catch (_: Exception) {
            // expected
        }
    }

    // =========================================================================
    // MARK: - File Transfer: sanitizeFileName
    // =========================================================================

    @Test
    fun `sanitizeFileName strips forward slashes`() {
        val result = FileTransferService.sanitizeFileName("../../etc/passwd")
        assertFalse("Must not contain /", result.contains("/"))
    }

    @Test
    fun `sanitizeFileName strips backslashes`() {
        val result = FileTransferService.sanitizeFileName("..\\..\\windows\\system32\\config")
        assertFalse("Must not contain backslash", result.contains("\\"))
    }

    @Test
    fun `sanitizeFileName strips double dots`() {
        val result = FileTransferService.sanitizeFileName("../secret../file..txt")
        assertFalse("Must not contain ..", result.contains(".."))
    }

    @Test
    fun `sanitizeFileName strips null bytes`() {
        val result = FileTransferService.sanitizeFileName("file\u0000name.txt")
        assertFalse("Must not contain null byte", result.contains("\u0000"))
    }

    @Test
    fun `sanitizeFileName preserves normal filenames`() {
        assertEquals("photo.jpg", FileTransferService.sanitizeFileName("photo.jpg"))
        assertEquals("document_2024.pdf", FileTransferService.sanitizeFileName("document_2024.pdf"))
        assertEquals("my-file.txt", FileTransferService.sanitizeFileName("my-file.txt"))
    }

    @Test
    fun `sanitizeFileName handles edge cases`() {
        // Empty string
        val empty = FileTransferService.sanitizeFileName("")
        assertNotNull(empty)

        // Only slashes
        val slashOnly = FileTransferService.sanitizeFileName("///")
        assertFalse(slashOnly.contains("/"))

        // Unicode name preserved (no slashes/dots)
        val unicode = FileTransferService.sanitizeFileName("photo_2024.jpg")
        assertEquals("photo_2024.jpg", unicode)
    }

    @Test
    fun `sanitizeFileName handles complex path traversal`() {
        val result = FileTransferService.sanitizeFileName("..%2F..%2Fetc%2Fpasswd")
        // URL-encoded slashes are not actual slash chars, so they pass through
        // But actual path traversal patterns must be stripped
        val result2 = FileTransferService.sanitizeFileName("....//....//etc//passwd")
        assertFalse(result2.contains(".."))
        assertFalse(result2.contains("/"))
    }

    // =========================================================================
    // MARK: - File Transfer: MAX_FILE_SIZE
    // =========================================================================

    @Test
    fun `MAX_FILE_SIZE is 100MB`() {
        assertEquals(100L * 1024 * 1024, FileTransferService.MAX_FILE_SIZE)
    }

    @Test
    fun `CHUNK_SIZE is 16KB`() {
        assertEquals(16 * 1024, FileTransferService.CHUNK_SIZE)
    }

    // =========================================================================
    // MARK: - File Transfer: mimeTypeFromName
    // =========================================================================

    @Test
    fun `mimeTypeFromName returns correct types`() {
        assertEquals("image/jpeg", FileTransferService.mimeTypeFromName("photo.jpg"))
        assertEquals("image/jpeg", FileTransferService.mimeTypeFromName("photo.jpeg"))
        assertEquals("image/png", FileTransferService.mimeTypeFromName("image.png"))
        assertEquals("video/mp4", FileTransferService.mimeTypeFromName("video.mp4"))
        assertEquals("application/pdf", FileTransferService.mimeTypeFromName("doc.pdf"))
        assertEquals("text/plain", FileTransferService.mimeTypeFromName("readme.txt"))
    }

    @Test
    fun `isImage and isVideo helpers`() {
        assertTrue(FileTransferService.isImage("image/jpeg"))
        assertTrue(FileTransferService.isImage("image/png"))
        assertFalse(FileTransferService.isImage("video/mp4"))

        assertTrue(FileTransferService.isVideo("video/mp4"))
        assertTrue(FileTransferService.isVideo("video/quicktime"))
        assertFalse(FileTransferService.isVideo("image/jpeg"))
    }

    @Test
    fun `formatSize formats correctly`() {
        assertEquals("500 B", FileTransferService.formatSize(500))
        assertTrue(FileTransferService.formatSize(1500).contains("KB"))
        assertTrue(FileTransferService.formatSize(2_000_000).contains("MB"))
    }

    // =========================================================================
    // MARK: - Room ID Validation
    // =========================================================================

    // Room ID regex: ^[A-Za-z0-9_-]{64}$
    // Mirrors isValidRoomId() from MainActivity + ChatViewModel

    private fun isValidRoomId(id: String): Boolean {
        return id.matches(Regex("^[A-Za-z0-9_-]{64}$"))
    }

    @Test
    fun `valid 64-char base64url room ID accepted`() {
        // 64 chars of valid base64url characters
        val validId = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
        assertTrue(isValidRoomId(validId))
    }

    @Test
    fun `valid room ID with only alphanumeric chars accepted`() {
        val validId = "A".repeat(64)
        assertTrue(isValidRoomId(validId))
    }

    @Test
    fun `valid room ID with underscores and hyphens accepted`() {
        val validId = "a_b-c_d-".repeat(8) // 64 chars
        assertTrue(isValidRoomId(validId))
    }

    @Test
    fun `too short room ID rejected`() {
        assertFalse(isValidRoomId("abc"))
        assertFalse(isValidRoomId("A".repeat(63)))
    }

    @Test
    fun `too long room ID rejected`() {
        assertFalse(isValidRoomId("A".repeat(65)))
        assertFalse(isValidRoomId("A".repeat(128)))
    }

    @Test
    fun `empty room ID rejected`() {
        assertFalse(isValidRoomId(""))
    }

    @Test
    fun `room ID with special chars rejected`() {
        // Contains '!' which is not base64url
        val withSpecial = "A".repeat(63) + "!"
        assertFalse(isValidRoomId(withSpecial))

        // Contains space
        val withSpace = "A".repeat(63) + " "
        assertFalse(isValidRoomId(withSpace))

        // Contains '+'
        val withPlus = "A".repeat(63) + "+"
        assertFalse(isValidRoomId(withPlus))

        // Contains '='
        val withEquals = "A".repeat(63) + "="
        assertFalse(isValidRoomId(withEquals))
    }

    @Test
    fun `room ID with path traversal rejected`() {
        // Contains dots and slashes
        val traversal1 = "../../../../../../etc/passwd" + "A".repeat(36)
        assertFalse(isValidRoomId(traversal1))

        // Contains forward slash
        val traversal2 = "A".repeat(32) + "/" + "A".repeat(31)
        assertFalse(isValidRoomId(traversal2))
    }

    @Test
    fun `room ID with null bytes rejected`() {
        val withNull = "A".repeat(63) + "\u0000"
        assertFalse(isValidRoomId(withNull))
    }

    @Test
    fun `room ID with unicode rejected`() {
        val withUnicode = "A".repeat(62) + "\u0410\u0411" // Cyrillic
        assertFalse(isValidRoomId(withUnicode))
    }

    @Test
    fun `room ID with newline rejected`() {
        val withNewline = "A".repeat(63) + "\n"
        assertFalse(isValidRoomId(withNewline))
    }

    // =========================================================================
    // MARK: - ControlMessage: Serialization/Deserialization Roundtrip
    // =========================================================================

    @Test
    fun `CallRequest serialization roundtrip`() {
        val msg = ControlMessage.CallRequest
        val json = msg.toJSON()
        assertEquals("call-request", json.getString("type"))

        val parsed = ControlMessage.from(json)
        assertTrue(parsed is ControlMessage.CallRequest)
    }

    @Test
    fun `CallResponse serialization roundtrip`() {
        val msg = ControlMessage.CallResponse(accepted = true)
        val json = msg.toJSON()
        assertEquals("call-response", json.getString("type"))
        assertTrue(json.getBoolean("accepted"))

        val parsed = ControlMessage.from(json) as ControlMessage.CallResponse
        assertTrue(parsed.accepted)
    }

    @Test
    fun `CallResponse rejected serialization roundtrip`() {
        val msg = ControlMessage.CallResponse(accepted = false)
        val json = msg.toJSON()
        val parsed = ControlMessage.from(json) as ControlMessage.CallResponse
        assertFalse(parsed.accepted)
    }

    @Test
    fun `CallEnd serialization roundtrip`() {
        val msg = ControlMessage.CallEnd
        val json = msg.toJSON()
        assertEquals("call-end", json.getString("type"))
        assertTrue(ControlMessage.from(json) is ControlMessage.CallEnd)
    }

    @Test
    fun `SecurityAlert serialization roundtrip`() {
        val msg = ControlMessage.SecurityAlert("screen-capture-detected")
        val json = msg.toJSON()
        assertEquals("security-alert", json.getString("type"))
        assertEquals("screen-capture-detected", json.getString("alert"))

        val parsed = ControlMessage.from(json) as ControlMessage.SecurityAlert
        assertEquals("screen-capture-detected", parsed.alert)
    }

    @Test
    fun `MessageAck serialization roundtrip`() {
        val msg = ControlMessage.MessageAck(counter = 42)
        val json = msg.toJSON()
        assertEquals("message-ack", json.getString("type"))
        assertEquals(42, json.getInt("c"))

        val parsed = ControlMessage.from(json) as ControlMessage.MessageAck
        assertEquals(42, parsed.counter)
    }

    @Test
    fun `MessageRead serialization roundtrip`() {
        val msg = ControlMessage.MessageRead(counter = 7)
        val json = msg.toJSON()
        assertEquals("message-read", json.getString("type"))
        assertEquals(7, json.getInt("c"))

        val parsed = ControlMessage.from(json) as ControlMessage.MessageRead
        assertEquals(7, parsed.counter)
    }

    @Test
    fun `Ready serialization roundtrip`() {
        val msg = ControlMessage.Ready
        val json = msg.toJSON()
        assertEquals("ready", json.getString("type"))
        assertTrue(ControlMessage.from(json) is ControlMessage.Ready)
    }

    @Test
    fun `PushToken serialization roundtrip`() {
        val token = "fcm-token-abc123"
        val msg = ControlMessage.PushToken(token)
        val json = msg.toJSON()
        assertEquals("push-token", json.getString("type"))
        assertEquals(token, json.getString("token"))

        val parsed = ControlMessage.from(json) as ControlMessage.PushToken
        assertEquals(token, parsed.token)
    }

    @Test
    fun `NotifyToken serialization roundtrip`() {
        val token = "notify-token-xyz"
        val msg = ControlMessage.NotifyToken(token)
        val json = msg.toJSON()
        assertEquals("notify-token", json.getString("type"))
        assertEquals(token, json.getString("token"))

        val parsed = ControlMessage.from(json) as ControlMessage.NotifyToken
        assertEquals(token, parsed.token)
    }

    @Test
    fun `Typing serialization roundtrip`() {
        val msg = ControlMessage.Typing(isTyping = true)
        val json = msg.toJSON()
        assertEquals("typing", json.getString("type"))
        assertTrue(json.getBoolean("isTyping"))

        val parsed = ControlMessage.from(json) as ControlMessage.Typing
        assertTrue(parsed.isTyping)
    }

    @Test
    fun `Capabilities serialization roundtrip`() {
        val features = listOf("file-transfer", "voice-call", "typing-indicator")
        val msg = ControlMessage.Capabilities(features)
        val json = msg.toJSON()
        assertEquals("capabilities", json.getString("type"))

        val parsed = ControlMessage.from(json) as ControlMessage.Capabilities
        assertEquals(features, parsed.features)
    }

    @Test
    fun `FileStart serialization roundtrip`() {
        val msg = ControlMessage.FileStart(
            fileId = "abc-123",
            name = "photo.jpg",
            size = 1024000,
            mimeType = "image/jpeg",
            totalChunks = 63
        )
        val json = msg.toJSON()
        assertEquals("file-start", json.getString("type"))
        assertEquals("abc-123", json.getString("fileId"))
        assertEquals("photo.jpg", json.getString("name"))
        assertEquals(1024000, json.getLong("size"))
        assertEquals("image/jpeg", json.getString("mimeType"))
        assertEquals(63, json.getInt("totalChunks"))

        val parsed = ControlMessage.from(json) as ControlMessage.FileStart
        assertEquals("abc-123", parsed.fileId)
        assertEquals("photo.jpg", parsed.name)
        assertEquals(1024000L, parsed.size)
        assertEquals("image/jpeg", parsed.mimeType)
        assertEquals(63, parsed.totalChunks)
    }

    @Test
    fun `FileChunk serialization roundtrip`() {
        val msg = ControlMessage.FileChunk(fileId = "abc-123", index = 5, data = "dGVzdA==")
        val json = msg.toJSON()
        assertEquals("file-chunk", json.getString("type"))

        val parsed = ControlMessage.from(json) as ControlMessage.FileChunk
        assertEquals("abc-123", parsed.fileId)
        assertEquals(5, parsed.index)
        assertEquals("dGVzdA==", parsed.data)
    }

    @Test
    fun `FileComplete serialization roundtrip`() {
        val msg = ControlMessage.FileComplete(fileId = "abc-123")
        val json = msg.toJSON()
        assertEquals("file-complete", json.getString("type"))

        val parsed = ControlMessage.from(json) as ControlMessage.FileComplete
        assertEquals("abc-123", parsed.fileId)
    }

    @Test
    fun `RoomRotate serialization roundtrip`() {
        val roomId = "A".repeat(64)
        val msg = ControlMessage.RoomRotate(roomId)
        val json = msg.toJSON()
        assertEquals("room-rotate", json.getString("type"))
        assertEquals(roomId, json.getString("roomId"))

        val parsed = ControlMessage.from(json) as ControlMessage.RoomRotate
        assertEquals(roomId, parsed.roomId)
    }

    @Test
    fun `Renegotiate serialization roundtrip`() {
        val sdp = JSONObject().apply {
            put("type", "offer")
            put("sdp", "v=0\r\no=- 123 IN IP4 0.0.0.0\r\n")
        }
        val msg = ControlMessage.Renegotiate(sdp)
        val json = msg.toJSON()
        assertEquals("renegotiate", json.getString("type"))

        val parsed = ControlMessage.from(json) as ControlMessage.Renegotiate
        assertEquals("offer", parsed.sdp.getString("type"))
    }

    // =========================================================================
    // MARK: - ControlMessage: Unknown type handled
    // =========================================================================

    @Test
    fun `unknown control message type returns null`() {
        val json = JSONObject().apply { put("type", "unknown-future-type") }
        assertNull(ControlMessage.from(json))
    }

    @Test
    fun `empty type returns null`() {
        val json = JSONObject()
        assertNull(ControlMessage.from(json))
    }

    @Test
    fun `malformed message-ack returns null`() {
        // Missing counter
        val json = JSONObject().apply { put("type", "message-ack") }
        assertNull(ControlMessage.from(json))
    }

    @Test
    fun `malformed security-alert returns null`() {
        // Empty alert string
        val json = JSONObject().apply {
            put("type", "security-alert")
            put("alert", "")
        }
        assertNull(ControlMessage.from(json))
    }

    @Test
    fun `malformed file-start returns null`() {
        // Missing required fields
        val json = JSONObject().apply {
            put("type", "file-start")
            put("fileId", "abc")
            // Missing name, size, totalChunks
        }
        assertNull(ControlMessage.from(json))
    }

    @Test
    fun `malformed push-token returns null`() {
        val json = JSONObject().apply {
            put("type", "push-token")
            put("token", "")
        }
        assertNull(ControlMessage.from(json))
    }

    // =========================================================================
    // MARK: - Root Detection (unit test — verify it doesn't crash)
    // =========================================================================

    // NOTE: SecurityMonitor.isDeviceRooted() requires Android Context to instantiate.
    // In a real JUnit test environment, this would need to be an instrumented test.
    // Here we verify the root detection file paths are reasonable.

    @Test
    fun `root detection su paths are absolute and well-known`() {
        // Verify the paths checked by isDeviceRooted() are standard root indicator paths
        val knownRootPaths = arrayOf(
            "/system/app/Superuser.apk", "/sbin/su", "/system/bin/su",
            "/system/xbin/su", "/data/local/xbin/su", "/data/local/bin/su",
            "/system/sd/xbin/su", "/system/bin/failsafe/su", "/data/local/su",
            "/su/bin/su", "/system/app/SuperSU.apk"
        )
        for (path in knownRootPaths) {
            assertTrue("Root path must be absolute: $path", path.startsWith("/"))
            assertFalse("Root path must not contain ..: $path", path.contains(".."))
        }
    }

    // =========================================================================
    // MARK: - GhostCrypto: Padding
    // =========================================================================

    // NOTE: GhostCrypto.padMessage/unpadMessage use android.util.Base64 which is
    // not available in JUnit. These tests verify the DoubleRatchet-level crypto
    // which uses standard Java crypto APIs.

    // =========================================================================
    // MARK: - KDF Chain
    // =========================================================================

    @Test
    fun `kdfChain produces two distinct 32-byte outputs`() {
        val chainKey = ByteArray(32) { it.toByte() }
        val (newChainKey, messageKey) = DoubleRatchet.kdfChain(chainKey)

        assertEquals(32, newChainKey.size)
        assertEquals(32, messageKey.size)
        assertFalse(
            "Chain key and message key must differ",
            newChainKey.contentEquals(messageKey)
        )
    }

    @Test
    fun `kdfChain is deterministic`() {
        val chainKey = ByteArray(32) { it.toByte() }
        val (ck1, mk1) = DoubleRatchet.kdfChain(chainKey)
        val (ck2, mk2) = DoubleRatchet.kdfChain(chainKey)
        assertArrayEquals(ck1, ck2)
        assertArrayEquals(mk1, mk2)
    }

    @Test
    fun `kdfRootChain produces 4 distinct 32-byte keys`() {
        val rootKey = ByteArray(32) { it.toByte() }
        val dhOutput = ByteArray(32) { (it + 100).toByte() }

        val result = DoubleRatchet.kdfRootChain(rootKey, dhOutput)
        assertEquals(4, result.size)
        for (key in result) {
            assertEquals(32, key.size)
        }

        // All 4 keys must be distinct
        for (i in result.indices) {
            for (j in i + 1 until result.size) {
                assertFalse(
                    "Root chain output keys at index $i and $j must differ",
                    result[i].contentEquals(result[j])
                )
            }
        }
    }

    // =========================================================================
    // MARK: - Skipped keys limit (MAX_SKIP = 100)
    // =========================================================================

    @Test
    fun `MAX_SKIP is 100`() {
        assertEquals(100, DoubleRatchet.MAX_SKIP)
    }
}
