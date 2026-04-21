package com.kordar.ghostchat.core.files

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.concurrent.ConcurrentHashMap

/**
 * Per-file chunk timeout tracker with bounded retries.
 *
 * Semantics (mirror iOS `ChunkTimeoutTracker`):
 * - [arm] — start watching an incoming file. Initialises retries to 0 and
 *   schedules a deadline [timeoutMs] ms in the future.
 * - [progressed] — a chunk arrived. Reset the deadline AND reset the retry
 *   counter to 0 (the transfer is making progress).
 * - [cancel] — transfer completed or aborted by peer.
 *
 * When the deadline fires without a [progressed]:
 *   1. If `retries < maxRetries`, bump retries, call [onTimeout] so the caller
 *      can request a retransmit, and arm a fresh deadline.
 *   2. Otherwise call [onAbort] and stop watching the file.
 */
class ChunkTimeoutTracker(
    private val timeoutMs: Long = DEFAULT_TIMEOUT_MS,
    private val maxRetries: Int = DEFAULT_MAX_RETRIES,
    private val scope: CoroutineScope = CoroutineScope(
        SupervisorJob() + Dispatchers.Default
    )
) {
    companion object {
        /** Spec: 30 seconds of silence triggers a timeout. */
        const val DEFAULT_TIMEOUT_MS: Long = 30_000L
        /** Spec: 3 back-to-back timeouts then abort. */
        const val DEFAULT_MAX_RETRIES: Int = 3
    }

    private data class Entry(val job: Job, val retries: Int)

    private val entries = ConcurrentHashMap<String, Entry>()

    /** Fires when [timeoutMs] ms elapsed with no [progressed] and we still
     *  have retry budget. Caller should request a retransmit of missing chunks. */
    var onTimeout: ((String) -> Unit)? = null

    /** Fires after the last retry's deadline fires without progress. The
     *  tracker has already stopped watching this fileId. */
    var onAbort: ((String) -> Unit)? = null

    fun arm(fileId: String) {
        entries[fileId]?.job?.cancel()
        entries[fileId] = Entry(schedule(fileId), 0)
    }

    fun progressed(fileId: String) {
        val current = entries[fileId] ?: return
        current.job.cancel()
        entries[fileId] = Entry(schedule(fileId), 0)
    }

    fun cancel(fileId: String) {
        entries.remove(fileId)?.job?.cancel()
    }

    /** Cancel every armed timer. Called on full session teardown. */
    fun cancelAll() {
        val snapshot = entries.toMap()
        entries.clear()
        for ((_, entry) in snapshot) entry.job.cancel()
    }

    /** Number of files currently being tracked. Test-only / observability. */
    val armedCount: Int get() = entries.size

    // region Private

    private fun schedule(fileId: String): Job = scope.launch {
        delay(timeoutMs)
        // If the coroutine was cancelled while sleeping, `delay` already threw
        // CancellationException and we won't reach here. Explicit check is for
        // defence-in-depth in case cancellation lands between the delay returning
        // and the body resuming.
        if (!isActive) return@launch
        fireTimeout(fileId)
    }

    private fun fireTimeout(fileId: String) {
        val current = entries[fileId] ?: return
        val nextRetries = current.retries + 1
        if (nextRetries > maxRetries) {
            entries.remove(fileId)
            onAbort?.invoke(fileId)
            return
        }
        entries[fileId] = Entry(schedule(fileId), nextRetries)
        onTimeout?.invoke(fileId)
    }

    // endregion
}
