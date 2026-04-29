import Foundation

/// Maps the transport-level `ConnectionState` onto a 4-step visual progress
/// indicator shown by `ConnectingView`. Pure, easy to unit-test without
/// bringing up the full connection stack.
@MainActor
final class ConnectingViewModel: ObservableObject {
    /// Ordered list of handshake phases that the progress UI shows, each with a
    /// locale-key describing it to the user.
    enum Phase: Int, CaseIterable, Identifiable {
        case signaling   = 0
        case webRTC      = 1
        case keyExchange = 2
        case encrypted   = 3

        var id: Int { rawValue }

        var localizedKey: String {
            switch self {
            case .signaling:   return "connecting.step.signaling"
            case .webRTC:      return "connecting.step.webrtc"
            case .keyExchange: return "connecting.step.key_exchange"
            case .encrypted:   return "connecting.step.encrypted"
            }
        }
    }

    /// The "currently active" phase given a transport state.
    /// `.connecting` and `.signaling` both map to phase 0 — the user-facing
    /// distinction is meaningless before the WS handshake completes.
    ///
    /// `.webRTC` in the transport stack means DataChannel is open and we're
    /// exchanging keys, so visually we bump the indicator two phases forward
    /// (past "WebRTC", sitting on "Key exchange") for as long as that state
    /// lasts. The moment `crypto` is ready, the transport flips to
    /// `.encrypted` and we land on the final phase.
    static func phase(for state: ConnectionState) -> Phase {
        switch state {
        case .disconnected, .connecting, .connected:
            return .signaling
        case .signaling:
            return .signaling
        case .webRTC:
            return .keyExchange
        case .encrypted:
            return .encrypted
        }
    }

    /// Three-condition invariant: ChatView is reachable iff the transport says
    /// we're encrypted, the signaling layer confirms a remote peer is in the
    /// room, AND the handshake has surfaced a peer identity. All three must
    /// hold — defense in depth against any one of them being prematurely set.
    static func shouldAdvanceToChat(state: ConnectionState,
                                    hasRemotePeer: Bool,
                                    peerIdentity: Data?) -> Bool {
        state == .encrypted && hasRemotePeer && peerIdentity != nil
    }

    /// True if the transport failed — the caller should pop back to Welcome
    /// and surface an error.
    static func isTerminalFailure(_ state: ConnectionState, hadConnection: Bool) -> Bool {
        // `.disconnected` is only a failure AFTER we started connecting. An
        // initial `.disconnected` on view appear is just the pre-start state.
        hadConnection && state == .disconnected
    }
}
