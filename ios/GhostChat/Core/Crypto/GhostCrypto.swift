import CryptoKit
import Foundation
import GhostCrypto

/// Wire-format packet exchanged during the ECDH handshake (plaintext, pre-encryption).
struct KeyExchangePacket: Codable, Equatable {
    let type: String           // always "key-exchange"
    let publicKey: Data        // 65-byte x963 ephemeral pub
    let identityKey: Data      // 65-byte x963 identity pub
    let v: Int                 // protocol version
    let pqKey: Data?           // reserved — Phase 6 ML-KEM
    let pqSupported: Bool?     // reserved — Phase 6

    init(publicKey: Data, identityKey: Data, v: Int = 3, pqKey: Data? = nil, pqSupported: Bool? = nil) {
        self.type = "key-exchange"
        self.publicKey = publicKey
        self.identityKey = identityKey
        self.v = v
        self.pqKey = pqKey
        self.pqSupported = pqSupported
    }
}

/// Opaque persistence blob capturing the full crypto state for a saved-contact session.
struct GhostCryptoExport: Codable, Equatable {
    let ratchetState: Data
    let peerIdentity: Data
}

/// Stateful actor wrapping a single P2P crypto session.
///
/// Lifecycle:
/// 1. `beginHandshake()` → send resulting packet over signaling.
/// 2. On peer's packet arrival → `completeAsHost(peer:)` or `completeAsGuest(peer:)`.
/// 3. Session is encrypted: `encrypt(_:)` / `decrypt(_:)`.
/// 4. `exportState()` to persist for saved contacts; `restore(_:)` on reopen.
actor GhostChatCrypto {

    enum Error: Swift.Error, Equatable {
        case notInitialized
        case alreadyHandshook
        case invalidPeerPacket
    }

    private enum InternalState {
        case uninitialized
        case handshakeInProgress(ephemeral: P256.KeyAgreement.PrivateKey)
        case ready(ratchet: DoubleRatchet, peerIdentity: Data)
    }

    private var state: InternalState = .uninitialized
    private let identity: IdentityKeyService
    private let replayGuard: ReplayGuard

    init(identity: IdentityKeyService, replayGuard: ReplayGuard = ReplayGuard()) {
        self.identity = identity
        self.replayGuard = replayGuard
    }

    // MARK: - Handshake

    /// Generates an ephemeral keypair and returns the packet to send to the peer.
    func beginHandshake() throws -> KeyExchangePacket {
        if case .ready = state { throw Error.alreadyHandshook }
        let eph = P256.KeyAgreement.PrivateKey()
        state = .handshakeInProgress(ephemeral: eph)
        return KeyExchangePacket(
            publicKey: eph.publicKey.x963Representation,
            identityKey: try identity.publicKeyX963
        )
    }

    func completeAsHost(peer: KeyExchangePacket) throws {
        try complete(peer: peer, role: .host)
    }

    func completeAsGuest(peer: KeyExchangePacket) throws {
        try complete(peer: peer, role: .guest)
    }

    private func complete(peer: KeyExchangePacket, role: RatchetRole) throws {
        guard case .handshakeInProgress(let eph) = state else {
            throw Error.notInitialized
        }
        guard peer.type == "key-exchange" else { throw Error.invalidPeerPacket }

        let peerPub = try P256.KeyAgreement.PublicKey(x963Representation: peer.publicKey)
        let shared = try eph.sharedSecretFromKeyAgreement(with: peerPub)
        let rootKey = CryptoUtils.deriveInitialRootKey(sharedSecret: shared)

        let theirPub: P256.KeyAgreement.PublicKey? = (role == .host) ? peerPub : nil
        let ratchet = DoubleRatchet(
            role: role,
            sharedKey: rootKey,
            ourKeyPair: eph,
            theirPublicKey: theirPub
        )
        state = .ready(ratchet: ratchet, peerIdentity: peer.identityKey)
    }

    var isReady: Bool {
        if case .ready = state { return true } else { return false }
    }

    // MARK: - Encrypt / Decrypt

    func encrypt(_ plaintext: String) throws -> String {
        guard case .ready(var ratchet, let peer) = state else { throw Error.notInitialized }
        let out = try ratchet.encrypt(plaintext: plaintext)
        state = .ready(ratchet: ratchet, peerIdentity: peer)
        return out.wireBase64
    }

    func decrypt(_ wireBase64: String) throws -> String {
        guard case .ready(var ratchet, let peer) = state else { throw Error.notInitialized }

        // Defence-in-depth: parse the wire to extract nonce + counter, then run the
        // ReplayGuard BEFORE the ratchet. The guard throws on nonce replay, out-of-
        // window counter, or (when the plaintext envelope has a `t` field we can
        // read — currently unused, reserved for a future wire bump) stale timestamp.
        if let wireData = Data(base64Encoded: wireBase64),
           let parsed = try? WireFormat.parseMessage(wireData),
           let header = try? WireFormat.parseHeader(parsed.header) {
            try replayGuard.admit(nonce: parsed.nonce, counter: header.n, timestampMs: nil)
        }

        let out = try ratchet.decrypt(wireBase64: wireBase64)
        state = .ready(ratchet: ratchet, peerIdentity: peer)
        return out
    }

    // MARK: - Safety number

    func safetyNumber() throws -> String {
        guard case .ready(_, let peerIdentity) = state else { throw Error.notInitialized }
        let peerRaw64 = Data(peerIdentity.dropFirst())
        let myRaw64 = try identity.publicKeyRaw
        return CryptoUtils.safetyNumber(identityKeyA: myRaw64, identityKeyB: peerRaw64)
    }

    func peerIdentityKey() throws -> Data {
        guard case .ready(_, let peerIdentity) = state else { throw Error.notInitialized }
        return peerIdentity
    }

    /// Current ratchet root key — the session's post-handshake shared secret.
    /// Used to seed `ContactKeyRotation.deriveNextSeed` at session close. Deterministic
    /// across iOS ↔ Android for a given session.
    func sessionSecret() throws -> Data {
        guard case .ready(let ratchet, _) = state else { throw Error.notInitialized }
        return ratchet.currentRootKey
    }

    // MARK: - State persistence

    func exportState() throws -> Data {
        guard case .ready(let ratchet, let peer) = state else { throw Error.notInitialized }
        let bundle = GhostCryptoExport(ratchetState: try ratchet.exportedState, peerIdentity: peer)
        return try JSONEncoder().encode(bundle)
    }

    /// Rehydrate a session from a previously exported blob.
    func restore(from data: Data) throws {
        let bundle = try JSONDecoder().decode(GhostCryptoExport.self, from: data)
        let ratchet = try DoubleRatchet(importing: bundle.ratchetState)
        state = .ready(ratchet: ratchet, peerIdentity: bundle.peerIdentity)
    }
}
