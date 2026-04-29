import XCTest
@testable import GhostChat
import GhostCrypto

/// Tests for the `hasRemotePeer` invariant introduced to fix the navigation
/// regression where host bypassed WaitingView when the local DataChannel
/// flipped to `.open` before any peer actually joined the room.
///
/// The invariant: ChatView is reachable iff
///   `hasRemotePeer == true` ∧ `state == .encrypted` ∧ `peerIdentity != nil`.
@MainActor
final class ConnectionPeerPresenceTests: XCTestCase {

    private func makeManager() -> ConnectionManager {
        let keychain = InMemoryKeychain()
        let identity = IdentityKeyService(keychain: keychain)
        _ = try? identity.getOrCreateIdentity()
        return ConnectionManager(
            signalingURL: URL(string: "wss://example.invalid/ws")!,
            apiBaseURL: URL(string: "https://example.invalid")!,
            identity: identity,
            push: PushManager(baseURL: URL(string: "https://example.invalid")!,
                              pinning: CertificatePinning())
        )
    }

    // MARK: - Initial state

    func test_initialState_hasNoRemotePeer() {
        let conn = makeManager()
        XCTAssertFalse(conn.hasRemotePeer)
    }

    // MARK: - Signaling-driven transitions

    func test_handleSignaling_peerJoined_setsHasRemotePeer() async {
        let conn = makeManager()
        await conn._test_dispatchSignaling(.peerJoined)
        XCTAssertTrue(conn.hasRemotePeer,
                      "host should see hasRemotePeer=true after peerJoined")
    }

    func test_handleSignaling_roomJoined_setsHasRemotePeerForGuest() async {
        // GUEST receiving roomJoined means the server let them into a non-empty room
        // (server enforces — see `server/src/signaling.ts` lines 158, 168). So peer
        // is implicitly present.
        let conn = makeManager()
        await conn._test_dispatchSignaling(.roomJoined(roomId: "abc"))
        XCTAssertTrue(conn.hasRemotePeer)
    }

    func test_handleSignaling_roomCreated_doesNotSetHasRemotePeer() async {
        // HOST just got a room minted — no peer yet.
        let conn = makeManager()
        await conn._test_dispatchSignaling(.roomCreated(roomId: "abc"))
        XCTAssertFalse(conn.hasRemotePeer)
    }

    func test_handleSignaling_peerLeft_clearsHasRemotePeer() async {
        let conn = makeManager()
        await conn._test_dispatchSignaling(.peerJoined)
        XCTAssertTrue(conn.hasRemotePeer)
        await conn._test_dispatchSignaling(.peerLeft)
        XCTAssertFalse(conn.hasRemotePeer)
    }

    // MARK: - RTC-driven transitions must NEVER set hasRemotePeer (the regression)

    func test_handleRTC_dataChannelOpen_doesNotSetHasRemotePeer() async {
        let conn = makeManager()
        await conn._test_dispatchRTC(.dataChannelOpen)
        XCTAssertFalse(conn.hasRemotePeer,
                       "DC open is a local-only event and MUST NOT count as peer presence")
    }

    func test_handleRTC_answerReady_doesNotSetHasRemotePeer() async {
        let conn = makeManager()
        await conn._test_dispatchRTC(.answerReady(sdp: "v=0\r\n"))
        XCTAssertFalse(conn.hasRemotePeer)
    }

    // MARK: - Reset clears the flag

    func test_reset_clearsHasRemotePeer() async {
        let conn = makeManager()
        await conn._test_dispatchSignaling(.peerJoined)
        XCTAssertTrue(conn.hasRemotePeer)
        conn.leave()                       // calls reset() under the hood
        XCTAssertFalse(conn.hasRemotePeer)
    }

    // MARK: - Full integration: invariant chain (E.5)

    func test_invariantChain_neverAdvancesUntilAllConditionsMet() async {
        let conn = makeManager()
        let dummyPeerId = Data(repeating: 0xAB, count: 64)

        // Step 1: createRoom-style start (no peer, no encryption).
        XCTAssertFalse(ConnectingViewModel.shouldAdvanceToChat(
            state: conn.state, hasRemotePeer: conn.hasRemotePeer, peerIdentity: conn.peerIdentity))

        // Step 2: peer arrives (still not encrypted).
        await conn._test_dispatchSignaling(.peerJoined)
        XCTAssertTrue(conn.hasRemotePeer)
        XCTAssertFalse(ConnectingViewModel.shouldAdvanceToChat(
            state: conn.state, hasRemotePeer: conn.hasRemotePeer, peerIdentity: conn.peerIdentity))

        // Step 3: hand-set state to .encrypted with no peerIdentity yet — still must NOT advance.
        conn._set(state: .encrypted)
        XCTAssertFalse(ConnectingViewModel.shouldAdvanceToChat(
            state: conn.state, hasRemotePeer: conn.hasRemotePeer, peerIdentity: conn.peerIdentity))

        // Step 4: handshake completes — peerIdentity now set.
        conn._set(peerIdentity: dummyPeerId)
        XCTAssertTrue(ConnectingViewModel.shouldAdvanceToChat(
            state: conn.state, hasRemotePeer: conn.hasRemotePeer, peerIdentity: conn.peerIdentity),
            "all three conditions met — gate must open")
    }

    func test_hostAlone_withDataChannelOpenOnly_neverAdvances() async {
        // Reproduces the exact P0 regression: host's local DC fires `.open` before
        // any peer joins the room. Pre-fix: this was advancing to ChatView. Post-fix:
        // hasRemotePeer stays false → invariant gate stays closed → user remains on
        // WaitingView.
        let conn = makeManager()
        await conn._test_dispatchRTC(.dataChannelOpen)   // local DC opens
        await conn._test_dispatchRTC(.answerReady(sdp: "v=0\r\n"))

        XCTAssertFalse(conn.hasRemotePeer,
            "host alone must never see hasRemotePeer=true based on RTC events alone")

        // Even if state somehow gets to .encrypted in this isolated environment,
        // the gate must hold closed because no peer was ever seen.
        conn._set(state: .encrypted)
        conn._set(peerIdentity: Data(repeating: 0x77, count: 64))
        XCTAssertFalse(ConnectingViewModel.shouldAdvanceToChat(
            state: conn.state, hasRemotePeer: conn.hasRemotePeer, peerIdentity: conn.peerIdentity),
            "ChatView gate must NOT open without hasRemotePeer (defense-in-depth)")
    }
}
