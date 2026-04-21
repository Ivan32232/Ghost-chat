import XCTest
@testable import GhostChat

final class ChunkTimeoutTrackerTests: XCTestCase {

    private let tinyTimeout: TimeInterval = 0.05 // 50 ms — keeps tests snappy

    func test_arm_fires_onTimeout_afterDeadline() async throws {
        let tracker = ChunkTimeoutTracker(timeout: tinyTimeout, maxRetries: 3)
        let exp = expectation(description: "onTimeout fires")
        var firedId: String?
        tracker.onTimeout = { id in
            firedId = id
            exp.fulfill()
        }
        tracker.arm(fileId: "f1")
        await fulfillment(of: [exp], timeout: 0.3)
        XCTAssertEqual(firedId, "f1")
    }

    func test_progressed_resets_deadline_preventingEarlyFire() async throws {
        let tracker = ChunkTimeoutTracker(timeout: tinyTimeout, maxRetries: 3)
        var fired = 0
        tracker.onTimeout = { _ in fired += 1 }
        tracker.arm(fileId: "f1")
        // Keep progressing so the deadline is constantly pushed out.
        for _ in 0..<5 {
            try await Task.sleep(nanoseconds: 20_000_000) // 20 ms
            tracker.progressed(fileId: "f1")
        }
        // Now stop calling progressed, deadline should fire once.
        try await Task.sleep(nanoseconds: 120_000_000) // 120 ms
        XCTAssertGreaterThanOrEqual(fired, 1)
    }

    func test_cancel_stopsFiring() async throws {
        let tracker = ChunkTimeoutTracker(timeout: tinyTimeout, maxRetries: 3)
        var fired = 0
        tracker.onTimeout = { _ in fired += 1 }
        tracker.arm(fileId: "f1")
        tracker.cancel(fileId: "f1")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fired, 0)
        XCTAssertEqual(tracker.armedCount, 0)
    }

    func test_maxRetries_triggersAbort() async throws {
        let tracker = ChunkTimeoutTracker(timeout: tinyTimeout, maxRetries: 2)
        var timeoutFires = 0
        var abortedId: String?
        let abortExp = expectation(description: "abort")
        tracker.onTimeout = { _ in timeoutFires += 1 }
        tracker.onAbort = { id in
            abortedId = id
            abortExp.fulfill()
        }
        tracker.arm(fileId: "f1")
        await fulfillment(of: [abortExp], timeout: 1.0)
        XCTAssertEqual(abortedId, "f1")
        // We allow 2 retries then abort, so onTimeout fires for retries 1 and 2.
        XCTAssertEqual(timeoutFires, 2)
        XCTAssertEqual(tracker.armedCount, 0)
    }

    func test_progressed_resets_retryCounter() async throws {
        let tracker = ChunkTimeoutTracker(timeout: tinyTimeout, maxRetries: 2)
        var timeoutFires = 0
        var abortedAt: Int?
        tracker.onTimeout = { _ in timeoutFires += 1 }
        tracker.onAbort = { _ in abortedAt = timeoutFires }
        tracker.arm(fileId: "f1")
        // Wait long enough for retry #1 but not the abort.
        try await Task.sleep(nanoseconds: 80_000_000) // 80 ms → fires once
        XCTAssertEqual(timeoutFires, 1)
        tracker.progressed(fileId: "f1") // resets retry counter back to 0
        // Now it should go through 2 more fires before aborting, not just 1.
        try await Task.sleep(nanoseconds: 250_000_000) // 250 ms
        XCTAssertNotNil(abortedAt)
        XCTAssertGreaterThanOrEqual(timeoutFires, 3)
    }

    func test_arm_secondTime_resetsPriorTimer() async throws {
        let tracker = ChunkTimeoutTracker(timeout: tinyTimeout, maxRetries: 3)
        var fired = 0
        tracker.onTimeout = { _ in fired += 1 }
        tracker.arm(fileId: "f1")
        try await Task.sleep(nanoseconds: 20_000_000)
        tracker.arm(fileId: "f1") // reset retry to 0 + fresh deadline
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertGreaterThanOrEqual(fired, 1) // The second arm's deadline eventually fires
    }

    func test_multipleFiles_areIndependent() async throws {
        let tracker = ChunkTimeoutTracker(timeout: tinyTimeout, maxRetries: 3)
        var timedOut: Set<String> = []
        let lock = NSLock()
        tracker.onTimeout = { id in
            lock.lock(); timedOut.insert(id); lock.unlock()
        }
        tracker.arm(fileId: "a")
        tracker.arm(fileId: "b")
        tracker.arm(fileId: "c")
        XCTAssertEqual(tracker.armedCount, 3)
        try await Task.sleep(nanoseconds: 120_000_000)
        lock.lock(); defer { lock.unlock() }
        XCTAssertTrue(timedOut.contains("a"))
        XCTAssertTrue(timedOut.contains("b"))
        XCTAssertTrue(timedOut.contains("c"))
    }

    func test_progressed_onUntrackedFile_isNoop() async throws {
        let tracker = ChunkTimeoutTracker(timeout: tinyTimeout, maxRetries: 3)
        XCTAssertEqual(tracker.armedCount, 0)
        tracker.progressed(fileId: "never-armed") // must not crash or arm
        XCTAssertEqual(tracker.armedCount, 0)
    }
}
