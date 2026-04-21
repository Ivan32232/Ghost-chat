package com.kordar.ghostchat.core.files

import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

/**
 * Unit tests for [ChunkTimeoutTracker]. Uses real-time `delay` with a tiny
 * timeout (50 ms) so suite runs quickly. Mirror of iOS `ChunkTimeoutTrackerTests`.
 */
class ChunkTimeoutTrackerTest {

    private val tinyTimeout = 50L

    private fun newTracker(maxRetries: Int = 3): ChunkTimeoutTracker = ChunkTimeoutTracker(
        timeoutMs = tinyTimeout,
        maxRetries = maxRetries,
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    )

    @Test
    fun `arm fires onTimeout after deadline`() = runBlocking<Unit> {
        val tracker = newTracker()
        val fired = AtomicInteger(0)
        tracker.onTimeout = { _ -> fired.incrementAndGet() }
        tracker.arm("f1")
        delay(150)
        assertThat(fired.get()).isAtLeast(1)
    }

    @Test
    fun `progressed resets deadline preventing early fire`() = runBlocking<Unit> {
        val tracker = newTracker()
        val fired = AtomicInteger(0)
        tracker.onTimeout = { _ -> fired.incrementAndGet() }
        tracker.arm("f1")
        // Pushing deadline out every 20 ms for 100 ms total — should not fire yet.
        repeat(5) {
            delay(20)
            tracker.progressed("f1")
        }
        assertThat(fired.get()).isEqualTo(0)
        delay(120)
        assertThat(fired.get()).isAtLeast(1)
    }

    @Test
    fun `cancel stops firing`() = runBlocking<Unit> {
        val tracker = newTracker()
        val fired = AtomicInteger(0)
        tracker.onTimeout = { _ -> fired.incrementAndGet() }
        tracker.arm("f1")
        tracker.cancel("f1")
        delay(200)
        assertThat(fired.get()).isEqualTo(0)
        assertThat(tracker.armedCount).isEqualTo(0)
    }

    @Test
    fun `max retries triggers abort`() = runBlocking<Unit> {
        val tracker = newTracker(maxRetries = 2)
        val timeouts = AtomicInteger(0)
        var aborted: String? = null
        tracker.onTimeout = { _ -> timeouts.incrementAndGet() }
        tracker.onAbort = { aborted = it }
        tracker.arm("f1")
        delay(500) // allow 2 timeouts + abort
        assertThat(aborted).isEqualTo("f1")
        assertThat(timeouts.get()).isEqualTo(2)
        assertThat(tracker.armedCount).isEqualTo(0)
    }

    @Test
    fun `progressed resets retry counter`() = runBlocking<Unit> {
        val tracker = newTracker(maxRetries = 2)
        val timeouts = AtomicInteger(0)
        var aborted = false
        tracker.onTimeout = { _ -> timeouts.incrementAndGet() }
        tracker.onAbort = { _ -> aborted = true }
        tracker.arm("f1")
        delay(80)
        assertThat(timeouts.get()).isEqualTo(1)
        tracker.progressed("f1") // resets retries to 0
        delay(250) // now needs 2 more fires before abort, not 1
        assertThat(aborted).isTrue()
        assertThat(timeouts.get()).isAtLeast(3)
    }

    @Test
    fun `arm second time resets prior timer`() = runBlocking<Unit> {
        val tracker = newTracker()
        val fired = AtomicInteger(0)
        tracker.onTimeout = { _ -> fired.incrementAndGet() }
        tracker.arm("f1")
        delay(20)
        tracker.arm("f1") // fresh deadline, retry = 0
        delay(100)
        assertThat(fired.get()).isAtLeast(1)
    }

    @Test
    fun `multiple files are independent`() = runBlocking<Unit> {
        val tracker = newTracker()
        val timedOut = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
        tracker.onTimeout = { id -> timedOut += id }
        tracker.arm("a")
        tracker.arm("b")
        tracker.arm("c")
        assertThat(tracker.armedCount).isEqualTo(3)
        delay(150)
        assertThat(timedOut).containsAtLeast("a", "b", "c")
    }

    @Test
    fun `progressed on untracked file is noop`() = runBlocking<Unit> {
        val tracker = newTracker()
        assertThat(tracker.armedCount).isEqualTo(0)
        tracker.progressed("never-armed")
        assertThat(tracker.armedCount).isEqualTo(0)
    }
}
