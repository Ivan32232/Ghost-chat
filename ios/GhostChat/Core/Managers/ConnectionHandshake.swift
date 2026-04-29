import Foundation
import GhostCrypto

/// Handshake-coordination extension for `ConnectionManager`. Owns the KeyExchange /
/// PqExchange lifecycle so the manager stays under the 400-LOC cap.
@MainActor
extension ConnectionManager {

    func startKeyExchangeOverDataChannel() async {
        guard let crypto = cryptoRef, let rtc = rtcRef, let role = roleRef else { return }
        do {
            let ratchetRole: RatchetRole = (role == .host) ? .host : .guest
            let pkt = try await crypto.beginHandshake(role: ratchetRole)
            try rtc.send(try JSONEncoder().encode(pkt))
        } catch {
            _set(state: .disconnected)
        }
    }

    func completeHandshake(with peerPkt: KeyExchangePacket) async throws {
        guard let crypto = cryptoRef, let role = roleRef, let rtc = rtcRef else { return }
        _set(peerIdentity: peerPkt.identityKey)
        if role == .host {
            let ready = try await crypto.completeAsHost(peer: peerPkt)
            if ready {
                _set(state: .encrypted)
                _set(safetyNumber: try? await crypto.safetyNumber())
                await forwardOwnPushTokensToPeer()
            }
            // Otherwise HOST sits in awaitingPq until a PqExchangePacket arrives.
        } else {
            let pqOut = try await crypto.completeAsGuest(peer: peerPkt)
            _set(state: .encrypted)
            _set(safetyNumber: try? await crypto.safetyNumber())
            if let pqOut {
                try rtc.send(try JSONEncoder().encode(pqOut))
            }
            await forwardOwnPushTokensToPeer()
        }
    }

    func completePqHandshake(with pkt: PqExchangePacket) async throws {
        guard let crypto = cryptoRef else { return }
        try await crypto.completePQ(pqCiphertext: pkt.pqCiphertext)
        _set(state: .encrypted)
        _set(safetyNumber: try? await crypto.safetyNumber())
        await forwardOwnPushTokensToPeer()
    }
}
