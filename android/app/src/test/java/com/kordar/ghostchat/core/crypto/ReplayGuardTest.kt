package com.kordar.ghostchat.core.crypto

import com.google.common.truth.Truth.assertThat
import org.junit.Assert.assertThrows
import org.junit.Test

class ReplayGuardTest {

    private val nowMs: Long = 1_713_100_800_000L

    @Test
    fun `fresh message admits`() {
        val g = ReplayGuard()
        g.admit(ByteArray(12) { 0x01.toByte() }, counter = 1, timestampMs = nowMs, now = nowMs)
    }

    @Test
    fun `duplicate nonce rejected`() {
        val g = ReplayGuard()
        val nonce = ByteArray(12) { 0x01.toByte() }
        g.admit(nonce, counter = 1, timestampMs = nowMs, now = nowMs)
        val ex = assertThrows(ReplayError.NonceReplay::class.java) {
            g.admit(nonce, counter = 2, timestampMs = nowMs, now = nowMs)
        }
        assertThat(ex).isInstanceOf(ReplayError.NonceReplay::class.java)
    }

    @Test
    fun `timestamp too old rejected`() {
        val g = ReplayGuard()
        val old = nowMs - 6 * 60 * 1000L
        assertThrows(ReplayError.TimestampOutOfWindow::class.java) {
            g.admit(ByteArray(12), counter = 1, timestampMs = old, now = nowMs)
        }
    }

    @Test
    fun `timestamp too future rejected`() {
        val g = ReplayGuard()
        val future = nowMs + 6 * 60 * 1000L
        assertThrows(ReplayError.TimestampOutOfWindow::class.java) {
            g.admit(ByteArray(12), counter = 1, timestampMs = future, now = nowMs)
        }
    }

    @Test
    fun `no timestamp skips check`() {
        val g = ReplayGuard()
        g.admit(ByteArray(12), counter = 1, timestampMs = null, now = nowMs)
    }

    @Test
    fun `counter window allows small forward skip`() {
        val g = ReplayGuard(counterWindow = 50)
        g.admit(ByteArray(12) { 0x01.toByte() }, counter = 1, timestampMs = nowMs, now = nowMs)
        g.admit(ByteArray(12) { 0x02.toByte() }, counter = 30, timestampMs = nowMs, now = nowMs)
    }

    @Test
    fun `counter window rejects far forward`() {
        val g = ReplayGuard(counterWindow = 50)
        g.admit(ByteArray(12) { 0x01.toByte() }, counter = 1, timestampMs = nowMs, now = nowMs)
        assertThrows(ReplayError.CounterOutOfWindow::class.java) {
            g.admit(ByteArray(12) { 0x02.toByte() }, counter = 10_000, timestampMs = nowMs, now = nowMs)
        }
    }

    /**
     * Out-of-order delivery (counter < lastSeen) is legitimate — it happens when
     * a message is delayed. Counter window must not trip on backwards counters.
     */
    @Test
    fun `counter window allows out-of-order backwards`() {
        val g = ReplayGuard(counterWindow = 50)
        g.admit(ByteArray(12) { 0x01.toByte() }, counter = 30, timestampMs = nowMs, now = nowMs)
        g.admit(ByteArray(12) { 0x02.toByte() }, counter = 5, timestampMs = nowMs, now = nowMs)
    }

    @Test
    fun `nonce set prunes expired on admit`() {
        val g = ReplayGuard(nonceTrackWindowMs = 100L)
        g.admit(ByteArray(12) { 0x01.toByte() }, counter = 1, timestampMs = nowMs, now = nowMs)
        // fast-forward past the window
        g.admit(ByteArray(12) { 0x02.toByte() }, counter = 2, timestampMs = nowMs + 200, now = nowMs + 200)
        // First nonce now pruned and reusable:
        g.admit(ByteArray(12) { 0x01.toByte() }, counter = 3, timestampMs = nowMs + 300, now = nowMs + 300)
    }

    @Test
    fun `nonce set evicts oldest when full`() {
        val g = ReplayGuard(maxNonces = 3)
        g.admit(ByteArray(12) { 0xA0.toByte() }, counter = 1, now = nowMs)
        g.admit(ByteArray(12) { 0xA1.toByte() }, counter = 2, now = nowMs + 1)
        g.admit(ByteArray(12) { 0xA2.toByte() }, counter = 3, now = nowMs + 2)
        g.admit(ByteArray(12) { 0xA3.toByte() }, counter = 4, now = nowMs + 3)
        assertThat(g.trackedNonceCount).isEqualTo(3)
        // Oldest (0xA0) evicted, so re-admit succeeds:
        g.admit(ByteArray(12) { 0xA0.toByte() }, counter = 5, now = nowMs + 4)
    }

    @Test
    fun `boundary timestamp exactly at window accepted`() {
        val g = ReplayGuard()
        val edge = nowMs + 5 * 60 * 1000L
        g.admit(ByteArray(12), counter = 1, timestampMs = edge, now = nowMs)
    }

    @Test
    fun `different nonces same counter admitted`() {
        val g = ReplayGuard()
        g.admit(ByteArray(12) { 0x01.toByte() }, counter = 42, timestampMs = nowMs, now = nowMs)
        g.admit(ByteArray(12) { 0x02.toByte() }, counter = 42, timestampMs = nowMs, now = nowMs)
    }
}
