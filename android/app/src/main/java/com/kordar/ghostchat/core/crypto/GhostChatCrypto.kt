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
 * Lifecycle:
 *   1. [beginHandshake] → returns the packet to send to the peer
 *   2. On peer's packet → [completeAsHost] / [completeAsGuest]
 *   3. [encrypt] / [decrypt] while `isReady`
 *   4. [exportState] to persist for saved contacts, [restore] on reopen
 *
 * Phase 7: every message is wrapped in a [MessageEnvelope] `{m,t,c,id}` before padding +
 * encryption. Receivers extract `env.t` and pass it to [ReplayGuard]'s ±5 min window. Clock
 * is injectable for tests via the [clock] constructor param.
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
    }

    private sealed class State {
        data object Uninitialized : State()
        data class HandshakeInProgress(val ephemeral: Bc.ECKeyPair) : State()
        data class Ready(val ratchet: DoubleRatchet, val peerIdentity: ByteArray) : State()
    }

    private val mutex = Mutex()
    private var state: State = State.Uninitialized
    private var sendCounter: Long = 0L

    val isReady: Boolean
        get() = state is State.Ready

    suspend fun beginHandshake(): KeyExchangePacket = mutex.withLock {
        when (state) {
            is State.Ready -> throw Error.AlreadyHandshook
            else -> Unit
        }
        val ephemeral = Bc.generateKeyPair()
        state = State.HandshakeInProgress(ephemeral)
        KeyExchangePacket(
            publicKey   = ephemeral.publicKeyBytes.toBase64(),
            identityKey = identity.publicKeyX963.toBase64()
        )
    }

    suspend fun completeAsHost(peer: KeyExchangePacket) = complete(peer, RatchetRole.HOST)

    suspend fun completeAsGuest(peer: KeyExchangePacket) = complete(peer, RatchetRole.GUEST)

    private suspend fun complete(peer: KeyExchangePacket, role: RatchetRole) = mutex.withLock {
        val ephemeral = (state as? State.HandshakeInProgress)?.ephemeral
            ?: throw Error.NotInitialized
        if (peer.type != "key-exchange") throw Error.InvalidPeerPacket

        val peerPubBytes   = peer.publicKey.fromBase64()
        val peerIdentityX963 = peer.identityKey.fromBase64()
        val peerPub = Bc.publicKeyFromBytes(peerPubBytes)

        val shared = Bc.ecdhSharedSecret(ephemeral.privateKey, peerPub)
        val rootKey = Bc.deriveInitialRootKey(shared)

        val ratchet = DoubleRatchet(
            role = role,
            sharedKey = rootKey,
            ourKeyPair = ephemeral,
            theirPublicKey = if (role == RatchetRole.HOST) peerPub else null
        )
        state = State.Ready(ratchet, peerIdentityX963)
    }

    // MARK: - Encrypt / Decrypt (envelope-wrapped)

    /**
     * Encrypt chat text or control JSON by first wrapping in a [MessageEnvelope] with
     * the sender's current timestamp and a monotonic per-session counter.
     */
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

    /**
     * Decrypt a wire-format base64 string. Runs ReplayGuard on nonce+counter before
     * decrypt (cheap dedup), then post-decrypt checks the envelope's timestamp window.
     * Returns `env.m`.
     */
    suspend fun decrypt(wireBase64: String): String = decryptEnvelope(wireBase64).m

    /**
     * Decrypt and return the full [MessageEnvelope] (test hook; production callers use
     * [decrypt] which surfaces only `env.m`).
     */
    suspend fun decryptEnvelope(wireBase64: String): MessageEnvelope = mutex.withLock {
        val ready = state as? State.Ready ?: throw Error.NotInitialized

        // Cheap first-line defence: nonce + counter LRU before decrypt. `timestampMs = null`
        // here — the real timestamp lives inside the envelope and is checked post-decrypt.
        runCatching {
            val wireBytes = Base64.getDecoder().decode(wireBase64)
            val parsed = WireFormat.parseMessage(wireBytes)
            val header = WireFormat.parseHeader(parsed.header)
            replayGuard.admit(parsed.nonce, counter = header.n, timestampMs = null, now = clock.nowMs())
        }.onFailure { cause ->
            if (cause is ReplayError) throw cause
            // Malformed wire: let the ratchet decide, don't double-report.
        }

        val envJson = ready.ratchet.decrypt(wireBase64)
        val env = MessageEnvelope.decode(envJson)

        // Post-decrypt timestamp check.
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
        // peerIdentity is a 65-byte x963 — drop 0x04 prefix to match iOS safety number input
        val peerRaw = ready.peerIdentity.copyOfRange(1, ready.peerIdentity.size)
        return Bc.safetyNumber(myRaw, peerRaw)
    }

    suspend fun peerIdentityKey(): ByteArray = mutex.withLock {
        val ready = state as? State.Ready ?: throw Error.NotInitialized
        ready.peerIdentity.copyOf()
    }

    /**
     * Current ratchet root key — the session's post-handshake shared secret.
     * Used to seed [ContactKeyRotation.deriveNextSeed] at session close. Deterministic
     * across iOS ↔ Android for a given session.
     */
    suspend fun sessionSecret(): ByteArray = mutex.withLock {
        val ready = state as? State.Ready ?: throw Error.NotInitialized
        ready.ratchet.currentRootKey
    }

    // MARK: - State persistence

    suspend fun exportState(): ByteArray = mutex.withLock {
        val ready = state as? State.Ready ?: throw Error.NotInitialized
        val blob = GhostCryptoExport(
            ratchetState = ready.ratchet.exportedState.toBase64(),
            peerIdentity = ready.peerIdentity.toBase64()
        )
        Json.encodeToString(GhostCryptoExport.serializer(), blob).toByteArray(Charsets.UTF_8)
    }

    suspend fun restore(data: ByteArray) = mutex.withLock {
        val blob = Json.decodeFromString(
            GhostCryptoExport.serializer(),
            String(data, Charsets.UTF_8)
        )
        val ratchet = DoubleRatchet(blob.ratchetState.fromBase64())
        state = State.Ready(ratchet, blob.peerIdentity.fromBase64())
    }
}

// java.util.Base64 (JVM 1.8+, Android API 26+) — matches iOS `base64EncodedString()` default.
private fun ByteArray.toBase64(): String =
    Base64.getEncoder().encodeToString(this)

private fun String.fromBase64(): ByteArray =
    Base64.getDecoder().decode(this)
