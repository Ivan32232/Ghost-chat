import Foundation

/// Plaintext envelope wrapping every message (chat text or control JSON) before
/// padding + encryption. Carries the application-level timestamp and counter the
/// ReplayGuard uses to reject stale replays.
///
/// Wire shape — sorted JSON keys, byte-identical iOS ↔ Android:
/// `{"c":7,"id":"env-1","m":"hello","t":1713100800000}`.
struct MessageEnvelope: Codable, Equatable {
    /// Application payload — either raw chat text or a JSON-encoded `ControlMessage`.
    let m: String
    /// Sender's wall-clock timestamp in milliseconds since the Unix epoch.
    let t: Int64
    /// Monotonic per-session counter minted by the sender (independent of ratchet `n`).
    let c: UInt64
    /// Unique message identifier (UUID-v4 in production, arbitrary string in tests).
    let id: String
}

extension JSONEncoder {
    /// Envelope-only encoder. Sorts keys so iOS and Android produce byte-identical JSON
    /// — critical for the cross-platform test vector and for stable AAD derivation if we
    /// ever fold the envelope hash into the ratchet header.
    static let envelope: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}
