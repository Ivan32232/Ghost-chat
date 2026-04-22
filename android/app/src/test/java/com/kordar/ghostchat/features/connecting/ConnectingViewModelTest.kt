package com.kordar.ghostchat.features.connecting

import com.kordar.ghostchat.models.ConnectionState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-function tests that mirror iOS `ConnectingViewModelTests`. The Kotlin
 * object is the state-machine helper — no ViewModel lifecycle to exercise.
 */
class ConnectingViewModelTest {

    @Test
    fun `disconnected and connecting both map to signaling phase`() {
        assertEquals(ConnectingViewModel.Phase.SIGNALING, ConnectingViewModel.phase(ConnectionState.DISCONNECTED))
        assertEquals(ConnectingViewModel.Phase.SIGNALING, ConnectingViewModel.phase(ConnectionState.CONNECTING))
        assertEquals(ConnectingViewModel.Phase.SIGNALING, ConnectingViewModel.phase(ConnectionState.CONNECTED))
    }

    @Test
    fun `signaling state shows signaling phase`() {
        assertEquals(ConnectingViewModel.Phase.SIGNALING, ConnectingViewModel.phase(ConnectionState.SIGNALING))
    }

    @Test
    fun `web rtc state jumps to key exchange phase`() {
        assertEquals(ConnectingViewModel.Phase.KEY_EXCHANGE, ConnectingViewModel.phase(ConnectionState.WEB_RTC))
    }

    @Test
    fun `encrypted state reaches the final phase`() {
        assertEquals(ConnectingViewModel.Phase.ENCRYPTED, ConnectingViewModel.phase(ConnectionState.ENCRYPTED))
    }

    @Test
    fun `progression through handshake sequence is non-decreasing`() {
        val sequence = listOf(ConnectionState.SIGNALING, ConnectionState.WEB_RTC, ConnectionState.ENCRYPTED)
        val ordinals = sequence.map { ConnectingViewModel.phase(it).ordinal }
        assertEquals(listOf(0, 2, 3), ordinals)
        // Strictly monotonic non-decreasing.
        ordinals.zipWithNext().forEach { (a, b) -> assertTrue(a <= b) }
    }

    @Test
    fun `should advance to chat only when encrypted`() {
        assertTrue(ConnectingViewModel.shouldAdvanceToChat(ConnectionState.ENCRYPTED))
        listOf(
            ConnectionState.DISCONNECTED,
            ConnectionState.CONNECTING,
            ConnectionState.SIGNALING,
            ConnectionState.WEB_RTC,
            ConnectionState.CONNECTED
        ).forEach { assertFalse(ConnectingViewModel.shouldAdvanceToChat(it)) }
    }

    @Test
    fun `disconnected with prior connection is terminal failure`() {
        assertTrue(ConnectingViewModel.isTerminalFailure(ConnectionState.DISCONNECTED, hadConnection = true))
    }

    @Test
    fun `disconnected on fresh arrival is not a failure`() {
        assertFalse(ConnectingViewModel.isTerminalFailure(ConnectionState.DISCONNECTED, hadConnection = false))
    }

    @Test
    fun `non-disconnected states are never terminal failures`() {
        listOf(
            ConnectionState.SIGNALING,
            ConnectionState.WEB_RTC,
            ConnectionState.ENCRYPTED,
            ConnectionState.CONNECTING,
            ConnectionState.CONNECTED
        ).forEach {
            assertFalse(ConnectingViewModel.isTerminalFailure(it, hadConnection = true))
            assertFalse(ConnectingViewModel.isTerminalFailure(it, hadConnection = false))
        }
    }

    @Test
    fun `each phase carries its localized key`() {
        assertEquals("connecting_step_signaling",    ConnectingViewModel.Phase.SIGNALING.localizedKey)
        assertEquals("connecting_step_webrtc",       ConnectingViewModel.Phase.WEB_RTC.localizedKey)
        assertEquals("connecting_step_key_exchange", ConnectingViewModel.Phase.KEY_EXCHANGE.localizedKey)
        assertEquals("connecting_step_encrypted",    ConnectingViewModel.Phase.ENCRYPTED.localizedKey)
    }
}
