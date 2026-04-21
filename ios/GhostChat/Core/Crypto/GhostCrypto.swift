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
/// Lifecycle (Phase 7, post ML-KEM integration):
/// 1. `beginHandshake(role:)` → generates ECDH ephemeral; HOST *also* generates an
///    ML-KEM768 keypair (when `PostQuantum.isSupported`) and attaches its public key to
///    the resulting packet.
/// 2. On peer's `KeyExchangePacket`:
///    - GUEST → `completeAsGuest(peer:)` returns an optional `PqExchangePacket`. If the
///      HOST advertised a `pqKey` and the GUEST can encapsulate, the returned packet
///      carries the ciphertext the HOST needs.
///    - HOST → `completeAsHost(peer:)` returns `true` if the session is already ready
///      (ECDH-only path); returns `false` if we're now *awaiting* a PqExchangePacket.
/// 3. HOST only: `completePQ(pqCiphertext:)` decapsulates and finishes the handshake.
/// 4. Once `.ready`, `encrypt` / `decrypt` — envelope-wrapped, timestamp-guarded.
/// 5. `exportState()` / `restore(_:)` for saved-contact persistence.
actor GhostChatCrypto {

    enum Error: Swift.Error, Equatable {
        case notInitialized
        case alreadyHandshook
        case invalidPeerPacket
        case unexpectedState
    }

    private enum InternalState {
        case uninitialized
        case handshakeInProgress(
            ephemeral: P256.KeyAgreement.PrivateKey,
            mlkemPrivate: Data?         // non-nil only when HOST generated an ML-KEM keypair
        )
        case awaitingPq(
            ourEphemeral: P256.KeyAgreement.PrivateKey,
            mlkemPrivate: Data,
            peerECDHPub: P256.KeyAgreement.PublicKey,
            ecdhSharedSecret: Data,
            peerIdentity: Data
        )
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

    /// Generate our ephemeral ECDH keypair and (if we are the HOST and PostQuantum is
    /// supported on this platform) an ML-KEM768 keypair. Returns the `KeyExchangePacket`
    /// to ship to the peer over the DataChannel.
    func beginHandshake(role: RatchetRole) throws -> KeyExchangePacket {
        if case .ready = state { throw Error.alreadyHandshook }
        let eph = P256.KeyAgreement.PrivateKey()

        var mlkemPriv: Data? = nil
        var pqKey: Data? = nil
        if role == .host, PostQuantum.isSupported {
            if let kp = try? PostQuantum.generateKeyPair() {
                mlkemPriv = kp.privateKey
                pqKey = kp.publicKey
            }
        }

        state = .handshakeInProgress(ephemeral: eph, mlkemPrivate: mlkemPriv)
        return KeyExchangePacket(
            publicKey: eph.publicKey.x963Representation,
            identityKey: try identity.publicKeyX963,
            pqKey: pqKey,
            pqSupported: PostQuantum.isSupported
        )
    }

    /// HOST-side completion. Returns `true` when the session is ready after this call;
    /// returns `false` when we're now *awaiting* a `PqExchangePacket` from the GUEST
    /// (i.e., we advertised ML-KEM and the GUEST told us it can encapsulate).
    @discardableResult
    func completeAsHost(peer: KeyExchangePacket) throws -> Bool {
        guard case .handshakeInProgress(let eph, let mlkemPriv) = state else {
            throw Error.notInitialized
        }
        guard peer.type == "key-exchange" else { throw Error.invalidPeerPacket }

        let peerPub = try P256.KeyAgreement.PublicKey(x963Representation: peer.publicKey)
        let shared = try eph.sharedSecretFromKeyAgreement(with: peerPub)
        let ecdhSS = shared.rawData

        let peerSupportsPQ = peer.pqSupported ?? false
        if let mlkemPriv, peerSupportsPQ {
            // Hold off — GUEST will follow up with a PqExchangePacket carrying our pq ciphertext.
            state = .awaitingPq(
                ourEphemeral: eph,
                mlkemPrivate: mlkemPriv,
                peerECDHPub: peerPub,
                ecdhSharedSecret: ecdhSS,
                peerIdentity: peer.identityKey
            )
            return false
        }

        // ECDH-only path (either we didn't advertise PQ or peer can't encapsulate).
        let sessionKey = PostQuantum.hybridDeriveSharedKey(ecdhSharedSecret: ecdhSS, pqSharedSecret: nil)
        let ratchet = DoubleRatchet(
            role: .host,
            sharedKey: SymmetricKey(data: sessionKey),
            ourKeyPair: eph,
            theirPublicKey: peerPub
        )
        state = .ready(ratchet: ratchet, peerIdentity: peer.identityKey)
        return true
    }

    /// Finish the HOST handshake by decapsulating the GUEST's ML-KEM ciphertext.
    func completePQ(pqCiphertext: Data) throws {
        guard case .awaitingPq(let eph, let mlkemPriv, let peerPub, let ecdhSS, let peerIdentity) = state else {
            throw Error.unexpectedState
        }
        let pqSS = try PostQuantum.decapsulate(ciphertext: pqCiphertext, privateKey: mlkemPriv)
        let sessionKey = PostQuantum.hybridDeriveSharedKey(ecdhSharedSecret: ecdhSS, pqSharedSecret: pqSS)
        let ratchet = DoubleRatchet(
            role: .host,
            sharedKey: SymmetricKey(data: sessionKey),
            ourKeyPair: eph,
            theirPublicKey: peerPub
        )
        state = .ready(ratchet: ratchet, peerIdentity: peerIdentity)
    }

    /// GUEST-side completion. Returns a `PqExchangePacket` iff both sides can do ML-KEM
    /// and the HOST sent us its Kyber public key — in that case the caller must forward
    /// the returned packet to the HOST before either side can encrypt.
    @discardableResult
    func completeAsGuest(peer: KeyExchangePacket) throws -> PqExchangePacket? {
        guard case .handshakeInProgress(let eph, _) = state else {
            throw Error.notInitialized
        }
        guard peer.type == "key-exchange" else { throw Error.invalidPeerPacket }

        let peerPub = try P256.KeyAgreement.PublicKey(x963Representation: peer.publicKey)
        let shared = try eph.sharedSecretFromKeyAgreement(with: peerPub)
        let ecdhSS = shared.rawData

        var pqSS: Data? = nil
        var pqOut: PqExchangePacket? = nil
        if let pqKey = peer.pqKey, PostQuantum.isSupported,
           let encap = try? PostQuantum.encapsulate(peerPublic: pqKey) {
            pqSS = encap.sharedSecret
            pqOut = PqExchangePacket(pqCiphertext: encap.ciphertext)
        }

        let sessionKey = PostQuantum.hybridDeriveSharedKey(ecdhSharedSecret: ecdhSS, pqSharedSecret: pqSS)
        let ratchet = DoubleRatchet(
            role: .guest,
            sharedKey: SymmetricKey(data: sessionKey),
            ourKeyPair: eph,
            theirPublicKey: nil
        )
        state = .ready(ratchet: ratchet, peerIdentity: peer.identityKey)
        return pqOut
    }

    var isReady: Bool {
        if case .ready = state { return true } else { return false }
    }

    /// `true` when we've sent our ECDH packet and are waiting for the GUEST's
    /// PqExchangePacket to arrive. Used by ConnectionManager to gate state transitions.
    var isAwaitingPq: Bool {
        if case .awaitingPq = state { return true } else { return false }
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
    /// Used to seed `ContactKeyRotation.deriveNextSeed` at session close.
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

    func restore(from data: Data) throws {
        let bundle = try JSONDecoder().decode(GhostCryptoExport.self, from: data)
        let ratchet = try DoubleRatchet(importing: bundle.ratchetState)
        state = .ready(ratchet: ratchet, peerIdentity: bundle.peerIdentity)
    }
}
