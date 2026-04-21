package com.kordar.ghostchat.core.crypto

import com.kordar.ghostchat.core.crypto.CryptoUtils as Bc
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import java.util.Base64
import java.util.UUID
import kotlin.math.abs

/**
 * Stateful wrapper around a single [DoubleRatchet] session. Mirrors the iOS `actor
 * GhostChatCrypto` — all mutating methods are behind a [Mutex] to serialize access.
 *
 * Lifecycle (Phase 7, post ML-KEM integration):
 *   1. [beginHandshake] takes a role. HOST generates an ML-KEM768 keypair and ships its
 *      public key in `pqKey`; GUEST does not advertise a key.
 *   2. On peer's [KeyExchangePacket]:
 *      - GUEST → [completeAsGuest] returns an optional [PqExchangePacket]. When HOST
 *        advertised a Kyber public key *and* we can encapsulate, the returned packet
 *        carries the ciphertext the HOST needs to decapsulate.
 *      - HOST → [completeAsHost] returns `true` if the session is ready (ECDH-only path);
 *        returns `false` if we're now awaiting a PqExchangePacket from the peer.
 *   3. HOST only: [completePQ] decapsulates and finishes the handshake.
 *   4. Once ready, [encrypt] / [decrypt] — envelope-wrapped, timestamp-guarded.
 *   5. [exportState] / [restore] for saved-contact persistence.
 */
class GhostChatCrypto(
    private val identity: IdentityKeyService,
    private val replayGuard: ReplayGuard = ReplayGuard(),
    private val clock: GhostClock = SystemClock
) {

    sealed class Error(message: String) : RuntimeException(message) {
        data object NotInitialized     : Error("crypto not initialized")
        data object AlreadyHandshook   : Error("crypto already handshook")
        data object InvalidPeerPacket  : Error("invalid peer packet")
        data object UnexpectedState    : Error("unexpected state for this operation")
    }

    private sealed class State {
        data object Uninitialized : State()
        data class HandshakeInProgress(
            val ephemeral: Bc.ECKeyPair,
            val mlkemPrivate: ByteArray?
        ) : State()
        data class AwaitingPq(
            val ourEphemeral: Bc.ECKeyPair,
            val mlkemPrivate: ByteArray,
            val peerEcdhPubBytes: ByteArray,
            val ecdhSharedSecret: ByteArray,
            val peerIdentity: ByteArray
        ) : State()
        data class Ready(val ratchet: DoubleRatchet, val peerIdentity: ByteArray) : State()
    }

    private val mutex = Mutex()
    private var state: State = State.Uninitialized
    private var sendCounter: Long = 0L

    val isReady: Boolean
        get() = state is State.Ready

    /** `true` while we've sent our ECDH packet and are waiting on the GUEST's PqExchangePacket. */
    val isAwaitingPq: Boolean
        get() = state is State.AwaitingPq

    suspend fun beginHandshake(role: RatchetRole): KeyExchangePacket = mutex.withLock {
        when (state) {
            is State.Ready -> throw Error.AlreadyHandshook
            else -> Unit
        }
        val ephemeral = Bc.generateKeyPair()
        var mlkemPriv: ByteArray? = null
        var pqKeyB64: String? = null
        if (role == RatchetRole.HOST && PostQuantum.IS_SUPPORTED) {
            val kp = PostQuantum.generateKeyPair()
            mlkemPriv = kp.privateKey
            pqKeyB64 = Base64.getEncoder().encodeToString(kp.publicKey)
        }
        state = State.HandshakeInProgress(ephemeral, mlkemPriv)
        KeyExchangePacket(
            publicKey    = Base64.getEncoder().encodeToString(ephemeral.publicKeyBytes),
            identityKey  = Base64.getEncoder().encodeToString(identity.publicKeyX963),
            pqKey        = pqKeyB64,
            pqSupported  = PostQuantum.IS_SUPPORTED
        )
    }

    /** HOST-side completion. Returns true if session is ready, false if awaiting PQ ciphertext. */
    suspend fun completeAsHost(peer: KeyExchangePacket): Boolean = mutex.withLock {
        val s = state as? State.HandshakeInProgress ?: throw Error.NotInitialized
        if (peer.type != "key-exchange") throw Error.InvalidPeerPacket

        val peerPubBytes = Base64.getDecoder().decode(peer.publicKey)
        val peerIdentityX963 = Base64.getDecoder().decode(peer.identityKey)
        val peerPub = Bc.publicKeyFromBytes(peerPubBytes)
        val ecdhSS = Bc.ecdhSharedSecret(s.ephemeral.privateKey, peerPub)

        val peerSupportsPQ = peer.pqSupported == true
        if (s.mlkemPrivate != null && peerSupportsPQ) {
            state = State.AwaitingPq(
                ourEphemeral    = s.ephemeral,
                mlkemPrivate    = s.mlkemPrivate,
                peerEcdhPubBytes = peerPubBytes,
                ecdhSharedSecret = ecdhSS,
                peerIdentity    = peerIdentityX963
            )
            return@withLock false
        }

        // ECDH-only path.
        val sessionKey = PostQuantum.hybridDeriveSharedKey(ecdhSS, pqSharedSecret = null)
        val ratchet = DoubleRatchet(
            role = RatchetRole.HOST,
            sharedKey = sessionKey,
            ourKeyPair = s.ephemeral,
            theirPublicKey = peerPub
        )
        state = State.Ready(ratchet, peerIdentityX963)
        true
    }

    /** Finish the HOST handshake by decapsulating the GUEST's ML-KEM ciphertext. */
    suspend fun completePQ(pqCiphertext: ByteArray) = mutex.withLock {
        val s = state as? State.AwaitingPq ?: throw Error.UnexpectedState
        val pqSS = PostQuantum.decapsulate(pqCiphertext, s.mlkemPrivate)
        val sessionKey = PostQuantum.hybridDeriveSharedKey(s.ecdhSharedSecret, pqSS)
        val peerPub = Bc.publicKeyFromBytes(s.peerEcdhPubBytes)
        val ratchet = DoubleRatchet(
            role = RatchetRole.HOST,
            sharedKey = sessionKey,
            ourKeyPair = s.ourEphemeral,
            theirPublicKey = peerPub
        )
        state = State.Ready(ratchet, s.peerIdentity)
    }

    /**
     * GUEST-side completion. Returns a [PqExchangePacket] to forward to the HOST iff the
     * HOST advertised a Kyber key and we can encapsulate (PostQuantum.IS_SUPPORTED).
     */
    suspend fun completeAsGuest(peer: KeyExchangePacket): PqExchangePacket? = mutex.withLock {
        val s = state as? State.HandshakeInProgress ?: throw Error.NotInitialized
        if (peer.type != "key-exchange") throw Error.InvalidPeerPacket

        val peerPubBytes = Base64.getDecoder().decode(peer.publicKey)
        val peerIdentityX963 = Base64.getDecoder().decode(peer.identityKey)
        val peerPub = Bc.publicKeyFromBytes(peerPubBytes)
        val ecdhSS = Bc.ecdhSharedSecret(s.ephemeral.privateKey, peerPub)

        var pqSS: ByteArray? = null
        var pqOut: PqExchangePacket? = null
        val peerPqKey = peer.pqKey
        if (peerPqKey != null && PostQuantum.IS_SUPPORTED) {
            val peerPqKeyBytes = Base64.getDecoder().decode(peerPqKey)
            val encap = PostQuantum.encapsulate(peerPqKeyBytes)
            pqSS = encap.sharedSecret
            pqOut = PqExchangePacket(
                pqCiphertext = Base64.getEncoder().encodeToString(encap.ciphertext)
            )
        }

        val sessionKey = PostQuantum.hybridDeriveSharedKey(ecdhSS, pqSharedSecret = pqSS)
        val ratchet = DoubleRatchet(
            role = RatchetRole.GUEST,
            sharedKey = sessionKey,
            ourKeyPair = s.ephemeral,
            theirPublicKey = null
        )
        state = State.Ready(ratchet, peerIdentityX963)
        pqOut
    }

    // MARK: - Encrypt / Decrypt (envelope-wrapped)

    suspend fun encrypt(plaintext: String): String = mutex.withLock {
        val ready = state as? State.Ready ?: throw Error.NotInitialized
        sendCounter += 1
        val env = MessageEnvelope(
            m  = plaintext,
            t  = clock.nowMs(),
            c  = sendCounter,
            id = UUID.randomUUID().toString()
        )
        ready.ratchet.encrypt(MessageEnvelope.encode(env)).wireBase64
    }

    suspend fun decrypt(wireBase64: String): String = decryptEnvelope(wireBase64).m

    suspend fun decryptEnvelope(wireBase64: String): MessageEnvelope = mutex.withLock {
        val ready = state as? State.Ready ?: throw Error.NotInitialized

        runCatching {
            val wireBytes = Base64.getDecoder().decode(wireBase64)
            val parsed = WireFormat.parseMessage(wireBytes)
            val header = WireFormat.parseHeader(parsed.header)
            replayGuard.admit(parsed.nonce, counter = header.n, timestampMs = null, now = clock.nowMs())
        }.onFailure { cause ->
            if (cause is ReplayError) throw cause
        }

        val envJson = ready.ratchet.decrypt(wireBase64)
        val env = MessageEnvelope.decode(envJson)

        val now = clock.nowMs()
        if (abs(now - env.t) > ReplayGuard.DEFAULT_TIMESTAMP_WINDOW_MS) {
            throw ReplayError.TimestampOutOfWindow
        }
        env
    }

    // MARK: - Safety number

    suspend fun safetyNumber(): String = mutex.withLock {
        val ready = state as? State.Ready ?: throw Error.NotInitialized
        val myRaw = identity.publicKeyRaw
        val peerRaw = ready.peerIdentity.copyOfRange(1, ready.peerIdentity.size)
        return Bc.safetyNumber(myRaw, peerRaw)
    }

    suspend fun peerIdentityKey(): ByteArray = mutex.withLock {
        val ready = state as? State.Ready ?: throw Error.NotInitialized
        ready.peerIdentity.copyOf()
    }

    suspend fun sessionSecret(): ByteArray = mutex.withLock {
        val ready = state as? State.Ready ?: throw Error.NotInitialized
        ready.ratchet.currentRootKey
    }

    // MARK: - State persistence

    suspend fun exportState(): ByteArray = mutex.withLock {
        val ready = state as? State.Ready ?: throw Error.NotInitialized
        val blob = GhostCryptoExport(
            ratchetState = Base64.getEncoder().encodeToString(ready.ratchet.exportedState),
            peerIdentity = Base64.getEncoder().encodeToString(ready.peerIdentity)
        )
        Json.encodeToString(GhostCryptoExport.serializer(), blob).toByteArray(Charsets.UTF_8)
    }

    suspend fun restore(data: ByteArray) = mutex.withLock {
        val blob = Json.decodeFromString(
            GhostCryptoExport.serializer(),
            String(data, Charsets.UTF_8)
        )
        val ratchet = DoubleRatchet(Base64.getDecoder().decode(blob.ratchetState))
        state = State.Ready(ratchet, Base64.getDecoder().decode(blob.peerIdentity))
    }
}
