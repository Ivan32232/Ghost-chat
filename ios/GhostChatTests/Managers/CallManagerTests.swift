import XCTest
@testable import GhostChat

@MainActor
final class CallManagerTests: XCTestCase {

    func test_initialState_isIdle() {
        let mgr = CallManager()
        XCTAssertEqual(mgr.state, .idle)
        XCTAssertFalse(mgr.isMuted)
        XCTAssertFalse(mgr.isSpeakerOn)
    }

    func test_setMuted_updatesFlag() {
        let mgr = CallManager()
        mgr.setMuted(true)
        XCTAssertTrue(mgr.isMuted)
        mgr.setMuted(false)
        XCTAssertFalse(mgr.isMuted)
    }
}
