package com.kordar.ghostchat.core.crypto

import com.google.common.truth.Truth.assertThat
import com.kordar.ghostchat.core.security.InMemoryKeystore
import kotlinx.coroutines.test.runTest
import org.junit.Test

class GhostCryptoEnvelopeTest {

    /** Manual clock — lets tests shift `now` forward / backward deterministically. */
    class ManualClock(var currentMs: Long) : GhostClock {
        override fun nowMs(): Long = currentMs
    }

    private fun pair(hostClock: GhostClock, guestClock: GhostClock)
    : Pair<GhostChatCrypto, GhostChatCrypto> {
        val host = GhostChatCrypto(
            identity = IdentityKeyService(InMemoryKeystore()),
            clock = hostClock
        )
        val guest = GhostChatCrypto(
            identity = IdentityKeyService(InMemoryKeystore()),
            clock = guestClock
        )
        return host to guest
    }

    private suspend fun handshake(host: GhostChatCrypto, guest: GhostChatCrypto) {
        val hostPkt = host.beginHandshake(RatchetRole.HOST)
        val guestPkt = guest.beginHandshake(RatchetRole.GUEST)
        val pqOut = guest.completeAsGuest(peer = hostPkt)
        host.completeAsHost(peer = guestPkt)
        if (pqOut != null) {
            val ct = java.util.Base64.getDecoder().decode(pqOut.pqCiphertext)
            host.completePQ(ct)
        }
    }

    @Test
    fun `encrypt wraps in envelope and decrypt unwraps`() = runTest {
        val clock = ManualClock(1_713_100_800_000L)
        val (host, guest) = pair(clock, clock)
        handshake(host, guest)

        val wire = host.encrypt("hello")
        assertThat(guest.decrypt(wire)).isEqualTo("hello")
    }

    @Test
    fun `stale timestamp rejected`() = runTest {
        val hostClock = ManualClock(1_713_100_800_000L)
        val guestClock = ManualClock(1_713_100_800_000L + 6 * 60 * 1000L) // +6 min
        val (host, guest) = pair(hostClock, guestClock)
        handshake(host, guest)

        val wire = host.encrypt("stale")
        try {
            guest.decrypt(wire)
            throw AssertionError("should have thrown timestampOutOfWindow")
        } catch (e: ReplayError.TimestampOutOfWindow) {
            // expected
        }
    }

    @Test
    fun `clock within window admits`() = runTest {
        val hostClock = ManualClock(1_713_100_800_000L)
        val guestClock = ManualClock(1_713_100_800_000L + 3 * 60 * 1000L) // +3 min
        val (host, guest) = pair(hostClock, guestClock)
        handshake(host, guest)

        val wire = host.encrypt("in-window")
        assertThat(guest.decrypt(wire)).isEqualTo("in-window")
    }

    @Test
    fun `counter increments monotonically`() = runTest {
        val clock = ManualClock(1_713_100_800_000L)
        val (host, guest) = pair(clock, clock)
        handshake(host, guest)

        val w1 = host.encrypt("a")
        val w2 = host.encrypt("b")
        val w3 = host.encrypt("c")
        val p1 = guest.decryptEnvelope(w1)
        val p2 = guest.decryptEnvelope(w2)
        val p3 = guest.decryptEnvelope(w3)
        assertThat(p1.m).isEqualTo("a")
        assertThat(p2.m).isEqualTo("b")
        assertThat(p3.m).isEqualTo("c")
        assertThat(p1.c).isLessThan(p2.c)
        assertThat(p2.c).isLessThan(p3.c)
        assertThat(p1.t).isEqualTo(clock.currentMs)
    }
}
