package com.kordar.ghostchat.core.managers

import android.content.Context
import com.kordar.ghostchat.core.crypto.IdentityKeyService
import com.kordar.ghostchat.core.network.SignalingEvent
import com.kordar.ghostchat.core.network.TURNService
import com.kordar.ghostchat.core.push.PushManager
import com.kordar.ghostchat.core.security.InMemoryKeystore
import com.kordar.ghostchat.core.webrtc.GhostRTCEvent
import com.kordar.ghostchat.features.connecting.ConnectingViewModel
import com.kordar.ghostchat.models.ConnectionState
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.mockito.kotlin.mock

/**
 * Tests for `hasRemotePeer` invariant — the navigation gate that fixes the
 * regression where the host bypassed WaitingView whenever the local
 * DataChannel flipped to OPEN before any peer joined the room.
 *
 * Mirrors iOS `ConnectionPeerPresenceTests.swift`. Same assertions, same
 * behavioural contract — both platforms must agree on when ChatView is
 * reachable.
 */
class ConnectionManagerPeerPresenceTest {

    private fun fakeIdentity(): IdentityKeyService {
        val id = IdentityKeyService(InMemoryKeystore())
        id.getOrCreateIdentity()
        return id
    }

    private fun makeManager(): ConnectionManager {
        val ctx: Context = mock()
        val push: PushManager = mock()
        val turn: TURNService = mock()
        return ConnectionManager(
            context = ctx,
            signalingUrl = "wss://example.invalid/ws",
            apiBaseUrl = "https://example.invalid",
            identity = fakeIdentity(),
            push = push,
            turnService = turn
        )
    }

    // MARK: - Initial state

    @Test
    fun `initial state has no remote peer`() {
        val conn = makeManager()
        assertFalse(conn.hasRemotePeer.value)
    }

    // MARK: - Signaling-driven transitions

    @Test
    fun `peerJoined sets hasRemotePeer`() = runTest {
        val conn = makeManager()
        conn._testDispatchSignaling(SignalingEvent.PeerJoined)
        assertTrue(
            "host should see hasRemotePeer=true after PeerJoined",
            conn.hasRemotePeer.value
        )
    }

    @Test
    fun `roomJoined sets hasRemotePeer for guest (server enforces non-empty)`() = runTest {
        // Server only lets a guest into a non-empty room (server/src/signaling.ts
        // rejects with "Room not found" / "Room is full"), so receiving roomJoined
        // implicitly means the host is present.
        val conn = makeManager()
        conn._testDispatchSignaling(SignalingEvent.RoomJoined("abc"))
        assertTrue(conn.hasRemotePeer.value)
    }

    @Test
    fun `roomCreated does NOT set hasRemotePeer`() = runTest {
        // HOST just got a room minted — no peer yet.
        val conn = makeManager()
        conn._testDispatchSignaling(SignalingEvent.RoomCreated("abc"))
        assertFalse(conn.hasRemotePeer.value)
    }

    @Test
    fun `peerLeft clears hasRemotePeer`() = runTest {
        val conn = makeManager()
        conn._testDispatchSignaling(SignalingEvent.PeerJoined)
        assertTrue(conn.hasRemotePeer.value)
        conn._testDispatchSignaling(SignalingEvent.PeerLeft)
        assertFalse(conn.hasRemotePeer.value)
    }

    // MARK: - RTC events MUST NOT set hasRemotePeer

    @Test
    fun `dataChannelOpen does NOT set hasRemotePeer`() = runTest {
        val conn = makeManager()
        conn._testDispatchRtc(GhostRTCEvent.DataChannelOpen)
        assertFalse(
            "DC open is a local-only event and MUST NOT count as peer presence",
            conn.hasRemotePeer.value
        )
    }

    @Test
    fun `answerReady does NOT set hasRemotePeer`() = runTest {
        val conn = makeManager()
        conn._testDispatchRtc(GhostRTCEvent.AnswerReady("v=0\r\n"))
        assertFalse(conn.hasRemotePeer.value)
    }

    // MARK: - Reset clears the flag

    @Test
    fun `leave clears hasRemotePeer via reset`() = runTest {
        val conn = makeManager()
        conn._testDispatchSignaling(SignalingEvent.PeerJoined)
        assertTrue(conn.hasRemotePeer.value)
        conn.leave()
        assertFalse(conn.hasRemotePeer.value)
    }

    // MARK: - Full integration: invariant chain (E.5)

    @Test
    fun `invariant chain never advances until all three conditions met`() = runTest {
        val conn = makeManager()
        val dummyPeerId = ByteArray(64) { 0xAB.toByte() }

        // Step 1: createRoom-style start (no peer, no encryption).
        assertFalse(ConnectingViewModel.shouldAdvanceToChat(
            state = conn.state.value,
            hasRemotePeer = conn.hasRemotePeer.value,
            peerIdentity = conn.peerIdentity.value
        ))

        // Step 2: peer arrives (still not encrypted).
        conn._testDispatchSignaling(SignalingEvent.PeerJoined)
        assertTrue(conn.hasRemotePeer.value)
        assertFalse(ConnectingViewModel.shouldAdvanceToChat(
            state = conn.state.value,
            hasRemotePeer = conn.hasRemotePeer.value,
            peerIdentity = conn.peerIdentity.value
        ))

        // Step 3: state hand-set to ENCRYPTED with no peerIdentity yet — still must NOT advance.
        conn._setState(ConnectionState.ENCRYPTED)
        assertFalse(ConnectingViewModel.shouldAdvanceToChat(
            state = conn.state.value,
            hasRemotePeer = conn.hasRemotePeer.value,
            peerIdentity = conn.peerIdentity.value
        ))

        // Step 4: handshake completes — peerIdentity now set.
        conn._setPeerIdentity(dummyPeerId)
        assertNotNull(conn.peerIdentity.value)
        assertTrue(
            "all three conditions met — gate must open",
            ConnectingViewModel.shouldAdvanceToChat(
                state = conn.state.value,
                hasRemotePeer = conn.hasRemotePeer.value,
                peerIdentity = conn.peerIdentity.value
            )
        )
    }

    @Test
    fun `host alone with DataChannelOpen never advances`() = runTest {
        // Reproduces the exact P0 regression: host's local DC fires OPEN before
        // any peer joins the room. Pre-fix: this advanced to ChatView. Post-fix:
        // hasRemotePeer stays false → invariant gate stays closed → user remains
        // on WaitingView.
        val conn = makeManager()
        conn._testDispatchRtc(GhostRTCEvent.DataChannelOpen)
        conn._testDispatchRtc(GhostRTCEvent.AnswerReady("v=0\r\n"))

        assertFalse(
            "host alone must never see hasRemotePeer=true based on RTC events alone",
            conn.hasRemotePeer.value
        )

        // Even if state somehow gets to ENCRYPTED in this isolated environment,
        // the gate must hold closed because no peer was ever seen.
        conn._setState(ConnectionState.ENCRYPTED)
        conn._setPeerIdentity(ByteArray(64) { 0x77.toByte() })
        assertFalse(
            "ChatView gate must NOT open without hasRemotePeer (defense-in-depth)",
            ConnectingViewModel.shouldAdvanceToChat(
                state = conn.state.value,
                hasRemotePeer = conn.hasRemotePeer.value,
                peerIdentity = conn.peerIdentity.value
            )
        )
    }

    @Test
    fun `progression sequence — peerJoined then encrypted then peerIdentity`() = runTest {
        val conn = makeManager()
        val ids = listOf<ConnectionState>(ConnectionState.SIGNALING, ConnectionState.WEB_RTC, ConnectionState.ENCRYPTED)
        val gate = mutableListOf<Boolean>()

        for (s in ids) {
            conn._setState(s)
            gate.add(ConnectingViewModel.shouldAdvanceToChat(
                state = conn.state.value,
                hasRemotePeer = conn.hasRemotePeer.value,
                peerIdentity = conn.peerIdentity.value
            ))
        }
        // None should pass — peer not seen yet.
        assertEquals(listOf(false, false, false), gate)
    }
}
