import Foundation

/// Error thrown when a message is rejected by the replay guard.
enum ReplayError: Error, Equatable {
    case nonceReplay              // identical nonce seen previously
    case counterOutOfWindow       // counter >> lastSeen (DoS / huge skip)
    case timestampOutOfWindow     // |now - ts| > windowMs
}

/// Defence-in-depth layer on top of the Double Ratchet's natural replay rejection.
///
/// The ratchet itself already protects against replay (message keys are one-shot —
/// decrypting the same ciphertext twice fails AES-GCM integrity) and against absurd
/// counter jumps (MK-skipped bound = 100). ReplayGuard adds:
///
///  1. **Nonce LRU** — a bounded set of the most-recent AES-GCM nonces we've
///     decrypted successfully. If a duplicate arrives we reject it *before* paying
///     the ratchet decryption cost.
///  2. **Counter window** — reject if `counter > lastSeen + counterWindow`. Protects
///     against a crafted message with absurd `n` that would otherwise cause the
///     receiver to derive thousands of skipped keys.
///  3. **Timestamp window** — when a timestamp is supplied (the application-level
///     `t` field in the plaintext envelope) reject if it's too old or too far in
///     the future. Passing `nil` skips this check — used while the wire format
///     doesn't carry a timestamp yet.
///
/// In-memory only, session-scoped. Mirror of Android `ReplayGuard` — identical
/// constants + behaviour.
final class ReplayGuard {

    static let defaultCounterWindow: UInt32 = 1000
    static let defaultTimestampWindowMs: Int64 = 5 * 60 * 1000        // ±5 min
    static let defaultNonceTrackWindowMs: Int64 = 10 * 60 * 1000      // 10 min
    static let defaultMaxNonces: Int = 10_000

    private struct NonceEntry {
        let recordedAtMs: Int64
    }

    private let counterWindow: UInt32
    private let timestampWindowMs: Int64
    private let nonceTrackWindowMs: Int64
    private let maxNonces: Int
    private let lock = NSLock()

    private var nonces: [Data: NonceEntry] = [:]
    private var lastCounter: UInt32 = 0

    init(
        counterWindow: UInt32 = ReplayGuard.defaultCounterWindow,
        timestampWindowMs: Int64 = ReplayGuard.defaultTimestampWindowMs,
        nonceTrackWindowMs: Int64 = ReplayGuard.defaultNonceTrackWindowMs,
        maxNonces: Int = ReplayGuard.defaultMaxNonces
    ) {
        self.counterWindow = counterWindow
        self.timestampWindowMs = timestampWindowMs
        self.nonceTrackWindowMs = nonceTrackWindowMs
        self.maxNonces = maxNonces
    }

    /// Consume a message. Throws `ReplayError` if rejected; returns silently on success.
    /// - Parameters:
    ///   - nonce: the AES-GCM nonce from the wire (12 bytes).
    ///   - counter: ratchet `n` counter from the wire header.
    ///   - timestampMs: optional plaintext timestamp (nil = skip timestamp check).
    ///   - now: injectable clock for tests. Defaults to `Date().timeIntervalSince1970 * 1000`.
    func admit(nonce: Data, counter: UInt32, timestampMs: Int64? = nil,
               now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws {
        lock.lock(); defer { lock.unlock() }

        // 1. Timestamp window — before touching state so bad input doesn't poison the guard.
        if let ts = timestampMs {
            if abs(now - ts) > timestampWindowMs {
                throw ReplayError.timestampOutOfWindow
            }
        }

        // 2. Counter window — `lastCounter == 0` means no messages seen yet, so any
        //    first counter is allowed. After that, disallow wild forward skips.
        if lastCounter > 0 && counter > lastCounter &&
            UInt32(counter - lastCounter) > counterWindow {
            throw ReplayError.counterOutOfWindow
        }

        // 3. Prune expired nonces before deciding replay.
        cleanupExpiredNonces(now: now)

        // 4. Nonce replay check.
        if nonces[nonce] != nil {
            throw ReplayError.nonceReplay
        }

        // 5. Admit — record the nonce + bump counter. Bound the set by evicting oldest.
        if nonces.count >= maxNonces {
            evictOldestNonce()
        }
        nonces[nonce] = NonceEntry(recordedAtMs: now)
        if counter > lastCounter { lastCounter = counter }
    }

    /// Test-only / observability — current nonce set size.
    var trackedNonceCount: Int {
        lock.lock(); defer { lock.unlock() }
        return nonces.count
    }

    private func cleanupExpiredNonces(now: Int64) {
        nonces = nonces.filter { _, entry in now - entry.recordedAtMs < nonceTrackWindowMs }
    }

    private func evictOldestNonce() {
        guard let oldest = nonces.min(by: { $0.value.recordedAtMs < $1.value.recordedAtMs }) else { return }
        nonces.removeValue(forKey: oldest.key)
    }
}
