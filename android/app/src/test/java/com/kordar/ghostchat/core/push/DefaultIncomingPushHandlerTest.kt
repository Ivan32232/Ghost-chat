package com.kordar.ghostchat.core.push

import android.content.Context
import android.telecom.TelecomManager
import com.google.common.truth.Truth.assertThat
import com.kordar.ghostchat.core.managers.CallManager
import com.kordar.ghostchat.models.CallState
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Test
import org.mockito.kotlin.any
import org.mockito.kotlin.doReturn
import org.mockito.kotlin.eq
import org.mockito.kotlin.mock
import org.mockito.kotlin.verify
import org.mockito.kotlin.whenever

class DefaultIncomingPushHandlerTest {

    @Test
    fun `onIncomingCall reports to CallManager and addNewIncomingCall to TelecomManager`() {
        // Make telecom.getPhoneAccount return non-null so the handler skips the
        // PhoneAccount.builder() path (static Android API, unavailable in unit env).
        val existingAccount: android.telecom.PhoneAccount = mock()
        val telecom: TelecomManager = mock {
            on { getPhoneAccount(any()) } doReturn existingAccount
        }
        val ctx: Context = mock {
            on { getSystemService(Context.TELECOM_SERVICE) } doReturn telecom
        }
        val callMgr: CallManager = mock {
            on { state } doReturn MutableStateFlow(CallState.IDLE)
        }

        val handler = DefaultIncomingPushHandler(ctx, callMgr)
        handler.onIncomingCall("R-123", "Alice")

        verify(callMgr).reportIncoming(any(), eq("Alice"))
        verify(telecom).addNewIncomingCall(any(), any())
    }

    @Test
    fun `onInvite only flips CallManager state`() {
        val ctx: Context = mock()
        val callMgr: CallManager = mock {
            on { state } doReturn MutableStateFlow(CallState.IDLE)
        }

        val handler = DefaultIncomingPushHandler(ctx, callMgr)
        handler.onInvite("R-456", "Bob")

        verify(callMgr).reportIncoming(any(), eq("Bob"))
    }

    @Test
    fun `onNotify is noop`() {
        val ctx: Context = mock()
        val callMgr: CallManager = mock()

        val handler = DefaultIncomingPushHandler(ctx, callMgr)
        handler.onNotify("info", "Sender")

        // Nothing must call into CallManager for plain notifies.
        org.mockito.kotlin.verifyNoInteractions(callMgr)
    }
}
