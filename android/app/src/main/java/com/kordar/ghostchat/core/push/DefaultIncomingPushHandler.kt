package com.kordar.ghostchat.core.push

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import com.kordar.ghostchat.core.managers.CallManager
import com.kordar.ghostchat.core.managers.GhostConnectionService
import dagger.hilt.android.qualifiers.ApplicationContext
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Production [IncomingPushHandler]. On an `{"type":"call"}` FCM data message:
 *
 *   1. Register a self-managed [PhoneAccount] pointing at [GhostConnectionService] if
 *      the system doesn't already know about us.
 *   2. Flip [CallManager] into the `INCOMING` state so UI binds immediately.
 *   3. Ask the Telecom framework to surface the system incoming-call UI via
 *      [TelecomManager.addNewIncomingCall]. The rest of the lifecycle is in
 *      [GhostConnectionService].
 *
 * Everything else (`invite`, `notify`) just bumps the local CallManager — in Phase 7.5
 * those get a notification bubble, not a full Telecom surface.
 */
@Singleton
class DefaultIncomingPushHandler @Inject constructor(
    @ApplicationContext private val ctx: Context,
    private val callManager: CallManager
) : IncomingPushHandler {

    companion object {
        /** Stable account id — Telecom uses this to dedupe registrations. */
        const val PHONE_ACCOUNT_ID: String = "ghostchat-voip"
    }

    private val tm: TelecomManager?
        get() = ctx.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager

    override fun onIncomingCall(roomId: String, callerName: String) {
        val telecom = tm ?: return
        val handle = ensurePhoneAccountRegistered(telecom)
        callManager.reportIncoming(UUID.randomUUID(), callerName)
        val extras = Bundle().apply {
            putString(GhostConnectionService.EXTRA_ROOM_ID, roomId)
            putString(GhostConnectionService.EXTRA_CALLER_NAME, callerName)
            putParcelable(
                TelecomManager.EXTRA_INCOMING_CALL_ADDRESS,
                Uri.fromParts("ghostchat", roomId, null)
            )
        }
        runCatching { telecom.addNewIncomingCall(handle, extras) }
    }

    override fun onInvite(roomId: String, callerName: String) {
        // Phase 7 scope: just flip CallManager state; a notification-style UI lands in 7.5.
        callManager.reportIncoming(UUID.randomUUID(), callerName)
    }

    override fun onNotify(type: String, senderName: String) = Unit

    private fun ensurePhoneAccountRegistered(telecom: TelecomManager): PhoneAccountHandle {
        val component = ComponentName(ctx, GhostConnectionService::class.java)
        val handle = PhoneAccountHandle(component, PHONE_ACCOUNT_ID)
        val existing = runCatching { telecom.getPhoneAccount(handle) }.getOrNull()
        if (existing != null) return handle
        val account = PhoneAccount.builder(handle, "Ghost Chat")
            .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
            .build()
        runCatching { telecom.registerPhoneAccount(account) }
        return handle
    }
}
