package com.kordar.ghostchat.core.crypto

import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** Error thrown when a message is rejected by [ReplayGuard]. */
sealed class ReplayError(message: String) : RuntimeException(message) {
    data object NonceReplay : ReplayError("nonce replay")
    data object CounterOutOfWindow : ReplayError("counter out of window")
    data object TimestampOutOfWindow : ReplayError("timestamp out of window")
}

/**
 * Defence-in-depth layer on top of the Double Ratchet's natural replay rejection.
 *
 * The ratchet itself already protects against replay (message keys are one-shot
 * — decrypting the same ciphertext twice fails AES-GCM integrity) and against
 * absurd counter jumps (MK-skipped bound = 100). ReplayGuard adds:
 *
 *  1. **Nonce LRU** — a bounded set of the most-recent AES-GCM nonces we've
 *     decrypted successfully. A duplicate is rejected *before* paying the
 *     ratchet decryption cost.
 *  2. **Counter window** — reject if `counter > lastSeen + counterWindow`.
 *     Protects against a crafted message with absurd `n` that would otherwise
 *     cause thousands of skipped-key derivations.
 *  3. **Timestamp window** — when a timestamp is supplied (plaintext envelope
 *     `t` field) reject if it's too old or too far in the future. Passing
 *     `null` skips this check — used while the wire format doesn't carry a
 *     timestamp yet.
 *
 * In-memory only, session-scoped. Mirror of iOS `ReplayGuard` — identical
 * constants + behaviour.
 */
class ReplayGuard(
    private val counterWindow: Int = DEFAULT_COUNTER_WINDOW,
    private val timestampWindowMs: Long = DEFAULT_TIMESTAMP_WINDOW_MS,
    private val nonceTrackWindowMs: Long = DEFAULT_NONCE_TRACK_WINDOW_MS,
    private val maxNonces: Int = DEFAULT_MAX_NONCES
) {
    companion object {
        const val DEFAULT_COUNTER_WINDOW: Int = 1000
        const val DEFAULT_TIMESTAMP_WINDOW_MS: Long = 5 * 60 * 1000L         // ±5 min
        const val DEFAULT_NONCE_TRACK_WINDOW_MS: Long = 10 * 60 * 1000L      // 10 min
        const val DEFAULT_MAX_NONCES: Int = 10_000
    }

    private data class NonceEntry(val recordedAtMs: Long)

    private val lock = ReentrantLock()
    // NonceWrapper exists so equality compares content, not reference.
    private val nonces = LinkedHashMap<NonceWrapper, NonceEntry>()
    private var lastCounter: Int = 0

    /**
     * Consume a message. Throws [ReplayError] on rejection; returns silently on admit.
     * @param nonce AES-GCM nonce from the wire (12 bytes).
     * @param counter ratchet `n` counter from the wire header.
     * @param timestampMs optional plaintext timestamp (null = skip timestamp check).
     * @param now injectable clock for tests. Defaults to `System.currentTimeMillis()`.
     */
    @Throws(ReplayError::class)
    fun admit(
        nonce: ByteArray,
        counter: Int,
        timestampMs: Long? = null,
        now: Long = System.currentTimeMillis()
    ) = lock.withLock {
        // 1. Timestamp window — before touching state.
        if (timestampMs != null && Math.abs(now - timestampMs) > timestampWindowMs) {
            throw ReplayError.TimestampOutOfWindow
        }

        // 2. Counter window — only guard against wild forward skips; out-of-order
        //    backwards delivery is legitimate in ratchet semantics.
        if (lastCounter > 0 && counter > lastCounter &&
            (counter - lastCounter) > counterWindow) {
            throw ReplayError.CounterOutOfWindow
        }

        // 3. Prune expired nonces.
        cleanupExpiredNonces(now)

        // 4. Nonce replay check.
        val key = NonceWrapper(nonce)
        if (nonces.containsKey(key)) {
            throw ReplayError.NonceReplay
        }

        // 5. Admit — evict oldest if full, record nonce, bump counter.
        if (nonces.size >= maxNonces) {
            evictOldestNonce()
        }
        nonces[key] = NonceEntry(now)
        if (counter > lastCounter) lastCounter = counter
    }

    /** Test-only / observability — current nonce set size. */
    val trackedNonceCount: Int
        get() = lock.withLock { nonces.size }

    private fun cleanupExpiredNonces(now: Long) {
        val iter = nonces.entries.iterator()
        while (iter.hasNext()) {
            val e = iter.next()
            if (now - e.value.recordedAtMs >= nonceTrackWindowMs) iter.remove()
            else break // LinkedHashMap preserves insertion order; rest are newer
        }
    }

    private fun evictOldestNonce() {
        val oldestKey = nonces.entries.minByOrNull { it.value.recordedAtMs }?.key ?: return
        nonces.remove(oldestKey)
    }

    /** Thin wrapper so `ByteArray` compares by content in the map key. */
    private data class NonceWrapper(val bytes: ByteArray) {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is NonceWrapper) return false
            return bytes.contentEquals(other.bytes)
        }
        override fun hashCode(): Int = bytes.contentHashCode()
    }
}
