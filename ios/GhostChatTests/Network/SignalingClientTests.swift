import XCTest
@testable import GhostChat

/// Unit tests for `SignalingClient` message parsing. Network transport is tested manually.
final class SignalingClientEventTests: XCTestCase {

    func test_signalingEvent_equatable() {
        XCTAssertEqual(SignalingEvent.connected, .connected)
        XCTAssertEqual(SignalingEvent.roomCreated(roomId: "x"), .roomCreated(roomId: "x"))
        XCTAssertNotEqual(SignalingEvent.roomCreated(roomId: "x"), .roomCreated(roomId: "y"))
        XCTAssertEqual(SignalingEvent.peerJoined, .peerJoined)
        XCTAssertEqual(SignalingEvent.peerLeft, .peerLeft)
        XCTAssertEqual(SignalingEvent.rejoinOk, .rejoinOk)
        XCTAssertEqual(SignalingEvent.disconnected, .disconnected)
        let bin = Data([0x01, 0x02])
        XCTAssertEqual(SignalingEvent.signal(rawJSON: bin), .signal(rawJSON: bin))
        XCTAssertEqual(SignalingEvent.error(message: "x"), .error(message: "x"))
    }

    func test_client_disconnect_yieldsDisconnected() async {
        let client = SignalingClient(url: URL(string: "wss://example.invalid/ws")!,
                                      pinning: CertificatePinning(pins: []))
        let expectation = expectation(description: "disconnected")
        Task {
            for await event in client.events {
                if event == .disconnected { expectation.fulfill(); break }
            }
        }
        // Starts connected-queued then we disconnect; no network needed because no task exists.
        client.disconnect()
        await fulfillment(of: [expectation], timeout: 2.0)
    }

    func test_sendWithoutConnect_throws() {
        let client = SignalingClient(url: URL(string: "wss://example.invalid/ws")!,
                                      pinning: CertificatePinning(pins: []))
        XCTAssertThrowsError(try client.createRoom()) { err in
            XCTAssertEqual(err as? SignalingClient.Error, .notConnected)
        }
    }
}
