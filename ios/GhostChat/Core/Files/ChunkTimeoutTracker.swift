import Foundation

/// Per-file chunk timeout tracker with bounded retries.
///
/// Semantics:
/// - `arm(fileId:)` — start watching an incoming file. Initialises the retry
///   counter to 0 and schedules a deadline `timeout` seconds in the future.
/// - `progressed(fileId:)` — a chunk arrived. Reset the deadline AND reset
///   retry counter to 0 (the transfer is making progress).
/// - `cancel(fileId:)` — transfer completed or was aborted by the peer.
///
/// When the deadline fires without a `progressed`:
///   1. If `retries < maxRetries`, bump `retries`, call `onTimeout(fileId)` so
///      the caller can request a retransmit, and arm a fresh deadline.
///   2. Otherwise call `onAbort(fileId)` and stop watching the file.
///
/// Mirror of Android `ChunkTimeoutTracker` — identical state machine + numbers.
final class ChunkTimeoutTracker {

    /// Seconds of silence that trigger a timeout. Spec: 30 seconds.
    static let defaultTimeout: TimeInterval = 30.0
    /// How many back-to-back timeouts we tolerate before aborting the transfer.
    /// Spec: 3 retries then abort.
    static let defaultMaxRetries: Int = 3

    private struct Entry {
        var deadlineTask: Task<Void, Never>
        var retries: Int
    }

    private let timeout: TimeInterval
    private let maxRetries: Int
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// Called when `timeout` seconds elapsed with no `progressed` and we still
    /// have retry budget. The caller typically requests a retransmit of missing
    /// chunks. Callback is invoked off the main actor — dispatch as needed.
    var onTimeout: ((String) -> Void)?

    /// Called after the last retry's deadline fires without progress. The
    /// tracker has already stopped watching this fileId by the time the
    /// callback runs.
    var onAbort: ((String) -> Void)?

    init(
        timeout: TimeInterval = ChunkTimeoutTracker.defaultTimeout,
        maxRetries: Int = ChunkTimeoutTracker.defaultMaxRetries
    ) {
        self.timeout = timeout
        self.maxRetries = maxRetries
    }

    /// Begin tracking `fileId`. If already tracking it, the prior timer is
    /// cancelled and retry counter reset.
    func arm(fileId: String) {
        lock.lock(); defer { lock.unlock() }
        entries[fileId]?.deadlineTask.cancel()
        entries[fileId] = Entry(deadlineTask: schedule(fileId), retries: 0)
    }

    /// A chunk arrived. Resets the deadline AND the retry counter.
    func progressed(fileId: String) {
        lock.lock(); defer { lock.unlock() }
        guard entries[fileId] != nil else { return }
        entries[fileId]?.deadlineTask.cancel()
        entries[fileId] = Entry(deadlineTask: schedule(fileId), retries: 0)
    }

    /// Transfer finished (success or failure). No further timers.
    func cancel(fileId: String) {
        lock.lock(); defer { lock.unlock() }
        entries[fileId]?.deadlineTask.cancel()
        entries.removeValue(forKey: fileId)
    }

    /// Cancel every armed timer. Called on full session teardown.
    func cancelAll() {
        lock.lock(); defer { lock.unlock() }
        for (_, entry) in entries { entry.deadlineTask.cancel() }
        entries.removeAll()
    }

    /// Number of files currently being tracked. Test-only / observability.
    var armedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    // MARK: - Private

    private func schedule(_ fileId: String) -> Task<Void, Never> {
        let t = timeout
        return Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(t * 1_000_000_000))
            if Task.isCancelled { return }
            self?.fireTimeout(fileId: fileId)
        }
    }

    private func fireTimeout(fileId: String) {
        lock.lock()
        guard var entry = entries[fileId] else { lock.unlock(); return }
        let nextRetries = entry.retries + 1
        if nextRetries > maxRetries {
            entries.removeValue(forKey: fileId)
            lock.unlock()
            onAbort?(fileId)
            return
        }
        entry.retries = nextRetries
        entry.deadlineTask = schedule(fileId)
        entries[fileId] = entry
        lock.unlock()
        onTimeout?(fileId)
    }
}
