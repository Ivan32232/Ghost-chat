import XCTest
@testable import GhostChat

@MainActor
final class MessageManagerTests: XCTestCase {

    func test_send_appendsToMessages_withSenderMe() {
        let mgr = MessageManager(defaultTTL: 10)
        let m = mgr.send(text: "hi")
        XCTAssertEqual(mgr.messages.count, 1)
        XCTAssertEqual(mgr.messages.first?.sender, .me)
        XCTAssertEqual(m.text, "hi")
        XCTAssertTrue(m.isPending)
    }

    func test_received_appendsToMessages_withSenderPeer() {
        let mgr = MessageManager(defaultTTL: 10)
        _ = mgr.received(text: "hey")
        XCTAssertEqual(mgr.messages.last?.sender, .peer)
        XCTAssertEqual(mgr.messages.last?.text, "hey")
        XCTAssertFalse(mgr.messages.last?.isPending ?? true)
    }

    func test_markDelivered_updatesFlags() {
        let mgr = MessageManager(defaultTTL: 10)
        let m = mgr.send(text: "x")
        mgr.markDelivered(id: m.id)
        let updated = mgr.messages.first
        XCTAssertTrue(updated?.isDelivered == true)
        XCTAssertFalse(updated?.isPending == true)
    }

    func test_ttl_autoDeletes() async {
        let mgr = MessageManager(defaultTTL: 0.05)
        _ = mgr.send(text: "poof")
        XCTAssertEqual(mgr.messages.count, 1)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(mgr.messages.count, 0)
    }

    func test_remove_stopsTimer() {
        let mgr = MessageManager(defaultTTL: 10)
        let m = mgr.send(text: "x")
        mgr.remove(id: m.id)
        XCTAssertEqual(mgr.messages.count, 0)
    }

    func test_setTTL_appliesToSubsequent() async {
        let mgr = MessageManager(defaultTTL: 10)
        mgr.setTTL(.thirtySeconds)
        let m = mgr.send(text: "next")
        XCTAssertNotNil(m)
        XCTAssertEqual(mgr.messages.count, 1)
    }
}
