import XCTest
@testable import GhostChat

@MainActor
final class WaitingViewModelTests: XCTestCase {

    func test_shareURL_formattedCorrectly() {
        let vm = WaitingViewModel(pasteboardWrite: { _ in })
        let url = vm.shareURL(roomId: "ABC123")
        XCTAssertEqual(url.absoluteString, "https://ghostchat.one/?room=ABC123")
    }

    func test_shareURL_queryEncodesRoomId() {
        // URLComponents doesn't percent-encode `/` or `+` in query values
        // (both are allowed per RFC 3986 sub-delims). As long as the room id
        // is in the query slot and decodable, we're good.
        let vm = WaitingViewModel(pasteboardWrite: { _ in })
        let url = vm.shareURL(roomId: "a-b_c")
        XCTAssertEqual(url.query, "room=a-b_c")
    }

    func test_displayID_shortIdRendersInFull() {
        let vm = WaitingViewModel(pasteboardWrite: { _ in })
        XCTAssertEqual(vm.displayID("abc"), "abc")
        XCTAssertEqual(vm.displayID("1234567890"), "1234567890")
        XCTAssertEqual(vm.displayID("123456789012"), "123456789012") // exactly 12
    }

    func test_displayID_longIdElides() {
        let vm = WaitingViewModel(pasteboardWrite: { _ in })
        // 14 chars → first 8 + "…" + last 4
        XCTAssertEqual(vm.displayID("1234567890abcd"), "12345678…abcd")
    }

    func test_displayID_realRoomId_looksRight() {
        // Real shape: 64-char base64url. We trim to 8 + "…" + 4.
        let vm = WaitingViewModel(pasteboardWrite: { _ in })
        let id = "rBwU4hZ688VvG9V2X4c4wg1234567890abcdefghijklmnopqrstuvwxyzABCD-_"
        XCTAssertEqual(id.count, 64)
        XCTAssertEqual(vm.displayID(id), "rBwU4hZ6…CD-_")
    }

    func test_copy_writesInviteURLToPasteboard() {
        var captured: String?
        let vm = WaitingViewModel(pasteboardWrite: { captured = $0 })
        vm.copy(roomId: "room-XYZ")
        XCTAssertEqual(captured, "https://ghostchat.one/?room=room-XYZ")
    }

    func test_copy_showsCopiedFeedbackFlag() {
        let vm = WaitingViewModel(pasteboardWrite: { _ in })
        XCTAssertFalse(vm.copiedFeedbackVisible)
        vm.copy(roomId: "ROOM")
        XCTAssertTrue(vm.copiedFeedbackVisible)
    }

    func test_testHook_markCopiedFlipsFlag() {
        let vm = WaitingViewModel(pasteboardWrite: { _ in })
        vm._test_markCopied()
        XCTAssertTrue(vm.copiedFeedbackVisible)
    }
}
