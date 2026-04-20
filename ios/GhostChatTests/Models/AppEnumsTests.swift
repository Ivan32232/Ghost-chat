import XCTest
@testable import GhostChat

final class AppEnumsTests: XCTestCase {
    func test_connectionState_allCases_roundtrip() throws {
        let states: [ConnectionState] = [.disconnected, .connecting, .signaling, .webRTC, .connected, .encrypted]
        for s in states {
            let data = try JSONEncoder().encode(s)
            XCTAssertEqual(try JSONDecoder().decode(ConnectionState.self, from: data), s)
        }
    }

    func test_callState_allCases_roundtrip() throws {
        let states: [CallState] = [.idle, .outgoingPending, .outgoingRinging, .incoming, .active, .ended]
        for s in states {
            let data = try JSONEncoder().encode(s)
            XCTAssertEqual(try JSONDecoder().decode(CallState.self, from: data), s)
        }
    }

    func test_messageTTL_rawValues() {
        XCTAssertEqual(MessageTTL.thirtySeconds.rawValue, 30)
        XCTAssertEqual(MessageTTL.oneMinute.rawValue, 60)
        XCTAssertEqual(MessageTTL.fiveMinutes.rawValue, 300)
        XCTAssertEqual(MessageTTL.fifteenMinutes.rawValue, 900)
        XCTAssertEqual(MessageTTL.oneHour.rawValue, 3600)
    }

    func test_messageType_rawValues_matchSpec() {
        XCTAssertEqual(MessageType.text.rawValue, 0)
        XCTAssertEqual(MessageType.file.rawValue, 1)
        XCTAssertEqual(MessageType.voice.rawValue, 2)
        XCTAssertEqual(MessageType.system.rawValue, 3)
    }

    func test_autoLockTimeout_zero_isImmediate() {
        XCTAssertEqual(AutoLockTimeout.immediate.rawValue, 0)
    }

    func test_role_roundtrip() throws {
        for r in [Role.host, .guest] {
            let data = try JSONEncoder().encode(r)
            XCTAssertEqual(try JSONDecoder().decode(Role.self, from: data), r)
        }
    }
}
