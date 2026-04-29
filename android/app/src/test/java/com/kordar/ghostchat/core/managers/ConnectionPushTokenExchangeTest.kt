package com.kordar.ghostchat.core.managers

import android.content.Context
import com.kordar.ghostchat.core.crypto.IdentityKeyService
import com.kordar.ghostchat.core.network.TURNService
import com.kordar.ghostchat.core.push.PushManager
import com.kordar.ghostchat.core.security.InMemoryKeystore
import com.kordar.ghostchat.models.ControlMessage
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.mockito.kotlin.mock

/**
 * Android mirror of iOS ConnectionPushTokenExchangeTests. Verifies that:
 *  - ownTokenControlMessages() reflects whatever push tokens are currently
 *    held on PushManager (local FCM token).
 *  - Inbound ControlMessage.PushToken / .NotifyToken surface to the
 *    peerPushTokens / peerNotifyTokens flows so save-contact persistence
 *    can store them.
 */
class ConnectionPushTokenExchangeTest {

    private fun makeFixture(): Pair<ConnectionManager, PushManager> {
        val ctx: Context = mock()
        val push: PushManager = mock()
        val turn: TURNService = mock()
        val identity = IdentityKeyService(InMemoryKeystore()).also { it.getOrCreateIdentity() }
        val conn = ConnectionManager(
            context = ctx,
            signalingUrl = "wss://example.invalid/ws",
            apiBaseUrl = "https://example.invalid",
            identity = identity,
            push = push,
            turnService = turn
        )
        return conn to push
    }

    // MARK: - Outgoing: control messages built from local tokens

    @Test
    fun `ownTokenControlMessages is empty when no FCM token`() = runTest {
        val (conn, push) = makeFixture()
        org.mockito.kotlin.whenever(push.fcmToken).thenReturn(null)
        assertTrue(conn.ownTokenControlMessages().isEmpty())
    }

    @Test
    fun `ownTokenControlMessages includes pushToken when FCM token present`() = runTest {
        val (conn, push) = makeFixture()
        org.mockito.kotlin.whenever(push.fcmToken).thenReturn("fcm-token-abc")
        val msgs = conn.ownTokenControlMessages()
        assertEquals(1, msgs.size)
        val first = msgs.first()
        assertTrue("expected PushToken, got $first", first is ControlMessage.PushToken)
        assertEquals("fcm-token-abc", (first as ControlMessage.PushToken).token)
    }

    // MARK: - Inbound routing: peer tokens surface on flows

    @Test
    fun `inbound PushToken yields to peerPushTokens flow`() = runTest(UnconfinedTestDispatcher()) {
        val (conn, _) = makeFixture()
        val collector = launch {
            val v = conn.peerPushTokens.first()
            assertEquals("peer-fcm-token", v)
        }
        // UnconfinedTestDispatcher: collector started; tryEmit lands while suspended.
        conn._testRouteControl(ControlMessage.PushToken("peer-fcm-token"))
        collector.join()
    }

    @Test
    fun `inbound NotifyToken yields to peerNotifyTokens flow`() = runTest(UnconfinedTestDispatcher()) {
        val (conn, _) = makeFixture()
        val collector = launch {
            val v = conn.peerNotifyTokens.first()
            assertEquals("peer-notify-token", v)
        }
        conn._testRouteControl(ControlMessage.NotifyToken("peer-notify-token"))
        collector.join()
    }

    // MARK: - SettingsManager.notificationsEnabled (new property)

    @Test
    fun `settings notificationsEnabled defaults false`() {
        val mgr = SettingsManager(InMemoryKeystore())
        assertEquals(false, mgr.notificationsEnabled.value)
    }

    @Test
    fun `settings notificationsEnabled persists to keystore`() {
        val store = InMemoryKeystore()
        SettingsManager(store).setNotificationsEnabled(true)
        val reloaded = SettingsManager(store)
        assertEquals(true, reloaded.notificationsEnabled.value)
    }
}
