import CryptoKit
import Foundation
import GhostCrypto

/// Wire-format packet exchanged during the ECDH handshake (plaintext, pre-encryption).
struct KeyExchangePacket: Codable, Equatable {
    let type: String           // always "key-exchange"
    let publicKey: Data        // 65-byte x963 ephemeral pub
    let identityKey: Data      // 65-byte x963 identity pub
    let v: Int                 // protocol version
    let pqKey: Data?           // ML-KEM768 public key (HOST + supported only)
    let pqSupported: Bool?     // whether this side can do ML-KEM

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
///
/// Phase 7: every message is wrapped in a `MessageEnvelope {m,t,c,id}` before padding +
/// encryption. Receivers extract `env.t` and pass it to `ReplayGuard.admit` for ±5 min
/// window enforcement. Clock is injectable for tests.
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
    private let clock: GhostClock
    private var sendCounter: UInt64 = 0

    init(identity: IdentityKeyService,
         replayGuard: ReplayGuard = ReplayGuard(),
         clock: GhostClock = SystemClock()) {
        self.identity = identity
        self.replayGuard = replayGuard
        self.clock = clock
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

    // MARK: - Encrypt / Decrypt (envelope-wrapped)

    /// Encrypt chat text or control JSON by first wrapping it in a `MessageEnvelope`
    /// with the sender's current `t` (clock) and a monotonic per-session counter `c`.
    func encrypt(_ plaintext: String) throws -> String {
        guard case .ready(var ratchet, let peer) = state else { throw Error.notInitialized }
        sendCounter += 1
        let env = MessageEnvelope(
            m: plaintext,
            t: clock.nowMs(),
            c: sendCounter,
            id: UUID().uuidString
        )
        let envData = try JSONEncoder.envelope.encode(env)
        let envJson = String(decoding: envData, as: UTF8.self)
        let out = try ratchet.encrypt(plaintext: envJson)
        state = .ready(ratchet: ratchet, peerIdentity: peer)
        return out.wireBase64
    }

    /// Decrypt a wire-format base64 string. Extracts the envelope, runs ReplayGuard on
    /// nonce + counter + envelope timestamp, and returns `env.m`.
    func decrypt(_ wireBase64: String) throws -> String {
        let env = try decryptEnvelope(wireBase64)
        return env.m
    }

    /// Decrypt and return the full `MessageEnvelope` (test hook; production callers
    /// use `decrypt(_:)` which surfaces only `env.m`).
    func decryptEnvelope(_ wireBase64: String) throws -> MessageEnvelope {
        guard case .ready(var ratchet, let peer) = state else { throw Error.notInitialized }

        // Cheap first-line defence: nonce + counter LRU on the ReplayGuard BEFORE decrypt.
        // `timestampMs: nil` here — the authoritative timestamp lives inside the envelope and
        // is checked post-decrypt once we can actually read it.
        if let wireData = Data(base64Encoded: wireBase64),
           let parsed = try? WireFormat.parseMessage(wireData),
           let header = try? WireFormat.parseHeader(parsed.header) {
            try replayGuard.admit(
                nonce: parsed.nonce,
                counter: header.n,
                timestampMs: nil,
                now: clock.nowMs()
            )
        }

        let envJson = try ratchet.decrypt(wireBase64: wireBase64)
        state = .ready(ratchet: ratchet, peerIdentity: peer)

        let envData = Data(envJson.utf8)
        let env = try JSONDecoder().decode(MessageEnvelope.self, from: envData)

        // Post-decrypt timestamp check — the message is authentic (AES-GCM tag valid),
        // but may still be stale and need rejection.
        let now = clock.nowMs()
        if abs(now - env.t) > ReplayGuard.defaultTimestampWindowMs {
            throw ReplayError.timestampOutOfWindow
        }

        return env
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
