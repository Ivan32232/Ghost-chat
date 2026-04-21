package com.kordar.ghostchat.core.managers

import android.content.Context
import com.kordar.ghostchat.core.crypto.GhostChatCrypto
import com.kordar.ghostchat.core.crypto.IdentityKeyService
import com.kordar.ghostchat.core.crypto.RatchetRole
import com.kordar.ghostchat.core.network.TURNService
import com.kordar.ghostchat.core.push.PushManager
import com.kordar.ghostchat.core.security.InMemoryKeystore
import kotlinx.coroutines.test.runTest
import org.junit.Test
import org.mockito.kotlin.any
import org.mockito.kotlin.eq
import org.mockito.kotlin.mock
import org.mockito.kotlin.verify
import org.mockito.kotlin.verifyNoInteractions
import org.mockito.kotlin.whenever

class ConnectionManagerRotationTest {

    private fun fakeIdentity(): IdentityKeyService {
        val id = IdentityKeyService(InMemoryKeystore())
        id.getOrCreateIdentity()
        return id
    }

    private suspend fun readyCrypto(): GhostChatCrypto {
        val host = GhostChatCrypto(fakeIdentity())
        val guest = GhostChatCrypto(fakeIdentity())
        val hostPkt = host.beginHandshake(RatchetRole.HOST)
        val guestPkt = guest.beginHandshake(RatchetRole.GUEST)
        val pqOut = guest.completeAsGuest(hostPkt)
        host.completeAsHost(guestPkt)
        if (pqOut != null) {
            host.completePQ(java.util.Base64.getDecoder().decode(pqOut.pqCiphertext))
        }
        return host
    }

    private fun fakeConnection(contactMgr: ContactManager): ConnectionManager {
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
        ).also { it.contactManager = contactMgr }
    }

    @Test
    fun `leave with contactId rotates keys on ContactManager`() = runTest {
        val contactMgr: ContactManager = mock()
        whenever(contactMgr.rotateKeys(any(), any())).thenReturn(true)

        val crypto = readyCrypto()
        val conn = fakeConnection(contactMgr)
        conn._testInjectReadyCrypto(crypto)
        conn.currentContactId = "c-rotate-1"

        conn.leaveAndAwaitRotation()

        verify(contactMgr).rotateKeys(eq("c-rotate-1"), any())
    }

    @Test
    fun `leave without contactId does not call rotateKeys`() = runTest {
        val contactMgr: ContactManager = mock()

        val crypto = readyCrypto()
        val conn = fakeConnection(contactMgr)
        conn._testInjectReadyCrypto(crypto)
        // currentContactId left null on purpose — one-time room, not a saved contact.

        conn.leaveAndAwaitRotation()

        verifyNoInteractions(contactMgr)
    }
}
