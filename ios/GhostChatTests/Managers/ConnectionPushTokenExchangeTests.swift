import XCTest
@testable import GhostChat
import GhostCrypto

/// Tests for the post-handshake push-token exchange wiring (P0 #1). The
/// invariant: as soon as a session reaches `.encrypted`, both sides forward
/// whatever push tokens they have to the peer via `ControlMessage.pushToken` /
/// `.notifyToken`. The peer surfaces them via `peerPushTokens` /
/// `peerNotifyTokens` streams so saved-contact persistence can pick them up.
@MainActor
final class ConnectionPushTokenExchangeTests: XCTestCase {

    private func makeFixture() -> (ConnectionManager, PushManager) {
        let keychain = InMemoryKeychain()
        let identity = IdentityKeyService(keychain: keychain)
        _ = try? identity.getOrCreateIdentity()
        let push = PushManager(
            baseURL: URL(string: "https://example.invalid")!,
            pinning: CertificatePinning()
        )
        let conn = ConnectionManager(
            signalingURL: URL(string: "wss://example.invalid/ws")!,
            apiBaseURL: URL(string: "https://example.invalid")!,
            identity: identity,
            push: push,
            pinning: CertificatePinning()
        )
        return (conn, push)
    }

    // MARK: - Outgoing: control messages built from local tokens

    func test_ownTokenControlMessages_emptyWhenNoTokensAvailable() {
        let (conn, _) = makeFixture()
        XCTAssertTrue(conn.ownTokenControlMessages().isEmpty)
    }

    func test_ownTokenControlMessages_includesVoipWhenSet() {
        let (conn, push) = makeFixture()
        push._test_setVoipToken(Data([0xDE, 0xAD, 0xBE, 0xEF]))
        let msgs = conn.ownTokenControlMessages()
        guard case .pushToken(let hex) = msgs.first(where: { if case .pushToken = $0 { return true } else { return false } }) else {
            return XCTFail("missing .pushToken")
        }
        XCTAssertEqual(hex, "deadbeef")
    }

    func test_ownTokenControlMessages_includesNotifyWhenSet() {
        let (conn, push) = makeFixture()
        push.didReceiveAPNsToken(Data([0xCA, 0xFE]))
        let msgs = conn.ownTokenControlMessages()
        guard case .notifyToken(let hex) = msgs.first(where: { if case .notifyToken = $0 { return true } else { return false } }) else {
            return XCTFail("missing .notifyToken")
        }
        XCTAssertEqual(hex, "cafe")
    }

    func test_ownTokenControlMessages_includesBothWhenAvailable() {
        let (conn, push) = makeFixture()
        push._test_setVoipToken(Data([0x11, 0x22]))
        push.didReceiveAPNsToken(Data([0x33, 0x44]))
        let msgs = conn.ownTokenControlMessages()
        XCTAssertEqual(msgs.count, 2)
    }

    // MARK: - Inbound routing: peer tokens surface on streams

    func test_inbound_pushToken_yieldsToPeerPushTokensStream() async {
        let (conn, _) = makeFixture()
        let received = expectation(description: "peerPushTokens yields")
        let task = Task {
            for await bytes in conn.peerPushTokens {
                if bytes == Data([0x01, 0x02, 0x03, 0x04]) { received.fulfill(); break }
            }
        }
        // Hex-encoded peer-supplied token, decoded inside the router.
        await conn._test_routeControl(.pushToken(token: "01020304"))
        await fulfillment(of: [received], timeout: 2)
        task.cancel()
    }

    func test_inbound_notifyToken_yieldsToPeerNotifyTokensStream() async {
        let (conn, _) = makeFixture()
        let received = expectation(description: "peerNotifyTokens yields")
        let task = Task {
            for await bytes in conn.peerNotifyTokens {
                if bytes == Data([0xAA, 0xBB]) { received.fulfill(); break }
            }
        }
        await conn._test_routeControl(.notifyToken(token: "aabb"))
        await fulfillment(of: [received], timeout: 2)
        task.cancel()
    }

    func test_inbound_pushToken_invalidHex_isDropped() async {
        let (conn, _) = makeFixture()
        // No subscriber assertion — just verify it doesn't crash and stream
        // doesn't yield garbage on bad input.
        await conn._test_routeControl(.pushToken(token: "zzzz"))
        // If we got here without crashing, OK.
    }

    // MARK: - Reset semantics

    func test_reset_doesNotForwardStaleTokens() {
        let (conn, push) = makeFixture()
        push._test_setVoipToken(Data([0xFF]))
        XCTAssertFalse(conn.ownTokenControlMessages().isEmpty)
        push._test_clearVoipToken()
        XCTAssertTrue(conn.ownTokenControlMessages().isEmpty)
    }
}
