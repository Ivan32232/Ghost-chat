package com.kordar.ghostchat.core.crypto

import com.google.common.truth.Truth.assertThat
import com.kordar.ghostchat.core.security.InMemoryKeystore
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertThrows
import org.junit.Test

class GhostChatCryptoTest {

    private suspend fun handshake(host: GhostChatCrypto, guest: GhostChatCrypto) {
        val hostPkt = host.beginHandshake(RatchetRole.HOST)
        val guestPkt = guest.beginHandshake(RatchetRole.GUEST)
        val pqOut = guest.completeAsGuest(peer = hostPkt)
        host.completeAsHost(peer = guestPkt)
        if (pqOut != null) {
            val ciphertext = java.util.Base64.getDecoder().decode(pqOut.pqCiphertext)
            host.completePQ(ciphertext)
        }
    }

    @Test
    fun `two-party session exchanges encrypted messages`() = runTest {
        val host = GhostChatCrypto(IdentityKeyService(InMemoryKeystore()))
        val guest = GhostChatCrypto(IdentityKeyService(InMemoryKeystore()))
        handshake(host, guest)

        val cipher = host.encrypt("hello guest")
        assertThat(guest.decrypt(cipher)).isEqualTo("hello guest")

        val reply = guest.encrypt("hello host")
        assertThat(host.decrypt(reply)).isEqualTo("hello host")
    }

    @Test
    fun `safety number matches on both sides`() = runTest {
        val host = GhostChatCrypto(IdentityKeyService(InMemoryKeystore()))
        val guest = GhostChatCrypto(IdentityKeyService(InMemoryKeystore()))
        handshake(host, guest)

        assertThat(host.safetyNumber()).isEqualTo(guest.safetyNumber())
    }

    @Test
    fun `export and restore keeps session decryptable`() = runTest {
        val hostIdentity = IdentityKeyService(InMemoryKeystore())
        val host = GhostChatCrypto(hostIdentity)
        val guest = GhostChatCrypto(IdentityKeyService(InMemoryKeystore()))
        handshake(host, guest)

        val first = host.encrypt("one")
        assertThat(guest.decrypt(first)).isEqualTo("one")

        val exportedHost = host.exportState()
        val restored = GhostChatCrypto(hostIdentity)
        restored.restore(exportedHost)

        // guest → restored host
        val reply = guest.encrypt("two")
        assertThat(restored.decrypt(reply)).isEqualTo("two")
    }

    @Test
    fun `encrypt before handshake throws`() = runTest {
        val crypto = GhostChatCrypto(IdentityKeyService(InMemoryKeystore()))
        try {
            crypto.encrypt("nope")
            throw AssertionError("should have thrown NotInitialized")
        } catch (e: GhostChatCrypto.Error.NotInitialized) {
            // expected
        }
    }

    @Test
    fun `begin twice after handshake throws AlreadyHandshook`() = runTest {
        val host = GhostChatCrypto(IdentityKeyService(InMemoryKeystore()))
        val guest = GhostChatCrypto(IdentityKeyService(InMemoryKeystore()))
        handshake(host, guest)
        try {
            host.beginHandshake(RatchetRole.HOST)
            throw AssertionError("should have thrown AlreadyHandshook")
        } catch (e: GhostChatCrypto.Error.AlreadyHandshook) {
            // expected
        }
    }
}
