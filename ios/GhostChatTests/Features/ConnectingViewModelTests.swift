import XCTest
@testable import GhostChat

@MainActor
final class ConnectingViewModelTests: XCTestCase {

    func test_phase_disconnected_mapsToSignaling() {
        XCTAssertEqual(ConnectingViewModel.phase(for: .disconnected), .signaling)
    }

    func test_phase_connecting_mapsToSignaling() {
        XCTAssertEqual(ConnectingViewModel.phase(for: .connecting), .signaling)
        XCTAssertEqual(ConnectingViewModel.phase(for: .connected), .signaling)
    }

    func test_phase_signaling_stateMapsToSignalingPhase() {
        XCTAssertEqual(ConnectingViewModel.phase(for: .signaling), .signaling)
    }

    func test_phase_webRTC_mapsToKeyExchange() {
        XCTAssertEqual(ConnectingViewModel.phase(for: .webRTC), .keyExchange)
    }

    func test_phase_encrypted_mapsToEncrypted() {
        XCTAssertEqual(ConnectingViewModel.phase(for: .encrypted), .encrypted)
    }

    func test_progression_throughAllPhases() {
        // Simulate a real handshake sequence the user should see climb steadily.
        let sequence: [ConnectionState] = [.signaling, .webRTC, .encrypted]
        let phases = sequence.map { ConnectingViewModel.phase(for: $0).rawValue }
        XCTAssertEqual(phases, [0, 2, 3])
        // Strictly non-decreasing — never regress the UI backward.
        XCTAssertTrue(zip(phases, phases.dropFirst()).allSatisfy { $0.0 <= $0.1 })
    }

    // MARK: - shouldAdvanceToChat — three-condition invariant

    private let dummyPeerId: Data = Data(repeating: 0xAB, count: 64)

    func test_shouldAdvanceToChat_returnsTrue_whenAllThreeConditionsMet() {
        XCTAssertTrue(ConnectingViewModel.shouldAdvanceToChat(
            state: .encrypted, hasRemotePeer: true, peerIdentity: dummyPeerId))
    }

    func test_shouldAdvanceToChat_returnsFalse_whenEncryptedButNoRemotePeer() {
        // Defends against the regression that lets host bypass WaitingView.
        XCTAssertFalse(ConnectingViewModel.shouldAdvanceToChat(
            state: .encrypted, hasRemotePeer: false, peerIdentity: dummyPeerId))
    }

    func test_shouldAdvanceToChat_returnsFalse_whenEncryptedButPeerIdentityNil() {
        XCTAssertFalse(ConnectingViewModel.shouldAdvanceToChat(
            state: .encrypted, hasRemotePeer: true, peerIdentity: nil))
    }

    func test_shouldAdvanceToChat_returnsFalse_whenWebRTCEvenWithPeer() {
        XCTAssertFalse(ConnectingViewModel.shouldAdvanceToChat(
            state: .webRTC, hasRemotePeer: true, peerIdentity: dummyPeerId))
    }

    func test_shouldAdvanceToChat_returnsFalse_forNonEncryptedStates() {
        for state in [ConnectionState.disconnected, .connecting, .signaling, .webRTC, .connected] {
            XCTAssertFalse(ConnectingViewModel.shouldAdvanceToChat(
                state: state, hasRemotePeer: true, peerIdentity: dummyPeerId),
                "advance must be false for state=\(state)")
        }
    }

    func test_shouldAdvanceToChat_failsClosed_whenNoConditionMet() {
        XCTAssertFalse(ConnectingViewModel.shouldAdvanceToChat(
            state: .disconnected, hasRemotePeer: false, peerIdentity: nil))
    }

    func test_isTerminalFailure_disconnected_withPriorConnection_isFailure() {
        XCTAssertTrue(ConnectingViewModel.isTerminalFailure(.disconnected, hadConnection: true))
    }

    func test_isTerminalFailure_disconnected_onInitialView_isNotFailure() {
        // First appearance: the transport hasn't started yet, disconnected is
        // just the starting position. We must not bounce the user back to
        // Welcome immediately.
        XCTAssertFalse(ConnectingViewModel.isTerminalFailure(.disconnected, hadConnection: false))
    }

    func test_isTerminalFailure_nonDisconnectedStates_areNeverFailure() {
        for state in [ConnectionState.signaling, .webRTC, .encrypted, .connecting, .connected] {
            XCTAssertFalse(ConnectingViewModel.isTerminalFailure(state, hadConnection: true))
            XCTAssertFalse(ConnectingViewModel.isTerminalFailure(state, hadConnection: false))
        }
    }

    func test_phaseLocalizedKeys_allPresent() {
        XCTAssertEqual(ConnectingViewModel.Phase.signaling.localizedKey, "connecting.step.signaling")
        XCTAssertEqual(ConnectingViewModel.Phase.webRTC.localizedKey, "connecting.step.webrtc")
        XCTAssertEqual(ConnectingViewModel.Phase.keyExchange.localizedKey, "connecting.step.key_exchange")
        XCTAssertEqual(ConnectingViewModel.Phase.encrypted.localizedKey, "connecting.step.encrypted")
    }
}
