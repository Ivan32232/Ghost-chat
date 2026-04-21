import XCTest
@testable import GhostChat

final class ReplayGuardTests: XCTestCase {

    private let nowMs: Int64 = 1_713_100_800_000

    func test_freshMessage_admits() throws {
        let g = ReplayGuard()
        XCTAssertNoThrow(try g.admit(nonce: Data(repeating: 0x01, count: 12),
                                     counter: 1, timestampMs: nowMs, now: nowMs))
    }

    func test_duplicateNonce_rejected() throws {
        let g = ReplayGuard()
        let nonce = Data(repeating: 0x01, count: 12)
        try g.admit(nonce: nonce, counter: 1, timestampMs: nowMs, now: nowMs)
        XCTAssertThrowsError(try g.admit(nonce: nonce, counter: 2, timestampMs: nowMs, now: nowMs)) { err in
            XCTAssertEqual(err as? ReplayError, .nonceReplay)
        }
    }

    func test_timestampTooOld_rejected() throws {
        let g = ReplayGuard()
        let old = nowMs - 1000 * 60 * 6 // 6 min old
        XCTAssertThrowsError(try g.admit(nonce: Data(count: 12), counter: 1,
                                         timestampMs: old, now: nowMs)) { err in
            XCTAssertEqual(err as? ReplayError, .timestampOutOfWindow)
        }
    }

    func test_timestampTooFuture_rejected() throws {
        let g = ReplayGuard()
        let future = nowMs + 1000 * 60 * 6
        XCTAssertThrowsError(try g.admit(nonce: Data(count: 12), counter: 1,
                                         timestampMs: future, now: nowMs)) { err in
            XCTAssertEqual(err as? ReplayError, .timestampOutOfWindow)
        }
    }

    func test_noTimestamp_skipsCheck() throws {
        let g = ReplayGuard()
        XCTAssertNoThrow(try g.admit(nonce: Data(count: 12), counter: 1,
                                     timestampMs: nil, now: nowMs))
    }

    func test_counterWindow_allowsSmallForwardSkip() throws {
        let g = ReplayGuard(counterWindow: 50)
        try g.admit(nonce: Data(repeating: 0x01, count: 12), counter: 1,
                    timestampMs: nowMs, now: nowMs)
        XCTAssertNoThrow(try g.admit(nonce: Data(repeating: 0x02, count: 12), counter: 30,
                                     timestampMs: nowMs, now: nowMs))
    }

    func test_counterWindow_rejectsFarForward() throws {
        let g = ReplayGuard(counterWindow: 50)
        try g.admit(nonce: Data(repeating: 0x01, count: 12), counter: 1,
                    timestampMs: nowMs, now: nowMs)
        XCTAssertThrowsError(try g.admit(nonce: Data(repeating: 0x02, count: 12), counter: 10_000,
                                         timestampMs: nowMs, now: nowMs)) { err in
            XCTAssertEqual(err as? ReplayError, .counterOutOfWindow)
        }
    }

    func test_counterWindow_allowsOutOfOrder_backwards() throws {
        // Out-of-order delivery (counter < lastSeen) is legitimate in ratchet —
        // can happen when a message arrives late. It must NOT be rejected as
        // counter-out-of-window; only the nonce/ratchet layer decides replay.
        let g = ReplayGuard(counterWindow: 50)
        try g.admit(nonce: Data(repeating: 0x01, count: 12), counter: 30,
                    timestampMs: nowMs, now: nowMs)
        XCTAssertNoThrow(try g.admit(nonce: Data(repeating: 0x02, count: 12), counter: 5,
                                     timestampMs: nowMs, now: nowMs))
    }

    func test_nonceSet_prunesExpiredOnAdmit() throws {
        let g = ReplayGuard(nonceTrackWindowMs: 100)
        try g.admit(nonce: Data(repeating: 0x01, count: 12), counter: 1,
                    timestampMs: nowMs, now: nowMs)
        // Fast-forward past the window
        try g.admit(nonce: Data(repeating: 0x02, count: 12), counter: 2,
                    timestampMs: nowMs + 200, now: nowMs + 200)
        // First nonce should now be pruned and re-usable
        XCTAssertNoThrow(try g.admit(nonce: Data(repeating: 0x01, count: 12), counter: 3,
                                     timestampMs: nowMs + 300, now: nowMs + 300))
    }

    func test_nonceSet_evictsOldestWhenFull() throws {
        let g = ReplayGuard(maxNonces: 3)
        try g.admit(nonce: Data(repeating: 0xA0, count: 12), counter: 1, now: nowMs)
        try g.admit(nonce: Data(repeating: 0xA1, count: 12), counter: 2, now: nowMs + 1)
        try g.admit(nonce: Data(repeating: 0xA2, count: 12), counter: 3, now: nowMs + 2)
        try g.admit(nonce: Data(repeating: 0xA3, count: 12), counter: 4, now: nowMs + 3)
        XCTAssertEqual(g.trackedNonceCount, 3)
        // The oldest (0xA0) was evicted, so re-admitting it must now succeed:
        XCTAssertNoThrow(try g.admit(nonce: Data(repeating: 0xA0, count: 12), counter: 5, now: nowMs + 4))
    }

    func test_boundaryTimestamp_exactlyAtWindow_accepted() throws {
        // |now - ts| == 5 min exactly should still be accepted (strict > check).
        let g = ReplayGuard()
        let edge = nowMs + 5 * 60 * 1000
        XCTAssertNoThrow(try g.admit(nonce: Data(count: 12), counter: 1,
                                     timestampMs: edge, now: nowMs))
    }

    func test_differentNonces_sameCounter_admitted() throws {
        // Not realistic in practice, but the guard should not conflate nonce + counter.
        let g = ReplayGuard()
        try g.admit(nonce: Data(repeating: 0x01, count: 12), counter: 42,
                    timestampMs: nowMs, now: nowMs)
        XCTAssertNoThrow(try g.admit(nonce: Data(repeating: 0x02, count: 12), counter: 42,
                                     timestampMs: nowMs, now: nowMs))
    }
}
