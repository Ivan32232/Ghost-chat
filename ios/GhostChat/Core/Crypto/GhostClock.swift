import Foundation

/// Abstracted wall-clock. Lets tests shift time forward/backward deterministically
/// when exercising ReplayGuard's ±5-minute timestamp window. Production uses
/// `SystemClock()`.
protocol GhostClock: Sendable {
    func nowMs() -> Int64
}

struct SystemClock: GhostClock {
    func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
