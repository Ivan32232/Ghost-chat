package com.kordar.ghostchat.core.crypto

import com.google.common.truth.Truth.assertThat
import com.kordar.ghostchat.core.security.InMemoryKeystore
import kotlinx.coroutines.test.runTest
import org.junit.Test
import java.util.Base64

class PqHandshakeTest {

    private fun pair(): Pair<GhostChatCrypto, GhostChatCrypto> {
        val host = GhostChatCrypto(IdentityKeyService(InMemoryKeystore()))
        val guest = GhostChatCrypto(IdentityKeyService(InMemoryKeystore()))
        return host to guest
    }

    /** Android ↔ Android: PostQuantum.IS_SUPPORTED is true → real hybrid handshake. */
    @Test
    fun `android-android full hybrid handshake with ml-kem ciphertext`() = runTest {
        val (host, guest) = pair()

        val hostPkt = host.beginHandshake(RatchetRole.HOST)
        val guestPkt = guest.beginHandshake(RatchetRole.GUEST)
        assertThat(hostPkt.pqKey).isNotNull()
        assertThat(hostPkt.pqSupported).isTrue()
        assertThat(guestPkt.pqSupported).isTrue()

        val pqOut = guest.completeAsGuest(hostPkt)
        assertThat(pqOut).isNotNull()

        val hostReady = host.completeAsHost(guestPkt)
        assertThat(hostReady).isFalse() // awaiting PqExchangePacket
        assertThat(host.isAwaitingPq).isTrue()

        val ciphertext = Base64.getDecoder().decode(pqOut!!.pqCiphertext)
        host.completePQ(ciphertext)
        assertThat(host.isReady).isTrue()
        assertThat(guest.isReady).isTrue()

        // End-to-end message works over the hybrid-keyed ratchet.
        val wire = host.encrypt("hybrid")
        assertThat(guest.decrypt(wire)).isEqualTo("hybrid")
    }

    @Test
    fun `hybrid hkdf matches cross-platform vector`() {
        val ecdh = ByteArray(32) { 0xAB.toByte() }
        val pq   = ByteArray(32) { 0xCD.toByte() }
        val out = PostQuantum.hybridDeriveSharedKey(ecdh, pq)
        assertThat(out.toHex()).isEqualTo(
            "207fad0312271a11364d7c3184693501082f1f614ff632987ba8e763df762eae"
        )
    }

    @Test
    fun `hybrid ecdh-only matches cross-platform vector`() {
        val ecdh = ByteArray(32) { 0xAB.toByte() }
        val out = PostQuantum.hybridDeriveSharedKey(ecdh, pqSharedSecret = null)
        assertThat(out.toHex()).isEqualTo(
            "11edf4ea0a6fb4e02b042841e5e72f2c8415cfca1ab9a815b0ffe6fb4fc69e4a"
        )
    }

    @Test
    fun `completePQ on ecdh-only session throws unexpectedState`() = runTest {
        val (host, guest) = pair()
        val hostPkt = host.beginHandshake(RatchetRole.HOST)
        val guestPkt = guest.beginHandshake(RatchetRole.GUEST)
        // Drive GUEST's side with a packet that has pqSupported=false so HOST takes ECDH-only path.
        val guestPktEcdhOnly = guestPkt.copy(pqSupported = false)
        guest.completeAsGuest(hostPkt)
        host.completeAsHost(guestPktEcdhOnly)
        assertThat(host.isReady).isTrue()

        try {
            host.completePQ(ByteArray(1088))
            throw AssertionError("should have thrown UnexpectedState")
        } catch (e: GhostChatCrypto.Error.UnexpectedState) {
            // expected
        }
    }

    private fun ByteArray.toHex(): String =
        joinToString("") { "%02x".format(it) }
}
