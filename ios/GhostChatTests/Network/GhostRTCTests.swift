import XCTest
@testable import GhostChat

final class GhostRTCCandidateFilterTests: XCTestCase {

    func test_filter_acceptsServerReflexive() {
        let sdp = "candidate:1 1 udp 1677732863 203.0.113.55 51234 typ srflx raddr 192.168.1.2 rport 51234"
        XCTAssertTrue(GhostRTC.shouldAcceptCandidate(sdp))
    }

    func test_filter_acceptsRelay() {
        let sdp = "candidate:4 1 udp 41819903 139.59.58.151 49202 typ relay raddr 0.0.0.0 rport 0"
        XCTAssertTrue(GhostRTC.shouldAcceptCandidate(sdp))
    }

    func test_filter_rejectsHostCandidate() {
        let sdp = "candidate:1 1 udp 2122252543 192.168.1.100 51234 typ host generation 0"
        XCTAssertFalse(GhostRTC.shouldAcceptCandidate(sdp))
    }

    func test_filter_rejectsIPv6LinkLocal() {
        let sdp = "candidate:2 1 udp 2122252542 fe80::1 51234 typ srflx"
        XCTAssertFalse(GhostRTC.shouldAcceptCandidate(sdp))
    }

    func test_filter_caseInsensitiveIPv6() {
        let sdp = "candidate:2 1 udp 2122252542 FE80::abcd 51234 typ srflx"
        XCTAssertFalse(GhostRTC.shouldAcceptCandidate(sdp))
    }

    func test_event_equatable() {
        XCTAssertEqual(GhostRTCEvent.dataChannelOpen, .dataChannelOpen)
        XCTAssertEqual(GhostRTCEvent.iceCandidate(sdp: "x", sdpMid: "0", sdpMLineIndex: 1),
                       .iceCandidate(sdp: "x", sdpMid: "0", sdpMLineIndex: 1))
        XCTAssertNotEqual(GhostRTCEvent.iceCandidate(sdp: "x", sdpMid: "0", sdpMLineIndex: 1),
                          .iceCandidate(sdp: "y", sdpMid: "0", sdpMLineIndex: 1))
    }

    func test_initialization_doesNotCrash() {
        let rtc = GhostRTC(role: .host)
        XCTAssertEqual(rtc.role, .host)
    }

    func test_sendBeforeStart_throws() {
        let rtc = GhostRTC(role: .host)
        XCTAssertThrowsError(try rtc.send(Data([0x01]))) { err in
            XCTAssertEqual(err as? GhostRTC.Error, .notStarted)
        }
    }
}
