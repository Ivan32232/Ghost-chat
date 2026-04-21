package com.kordar.ghostchat.core.managers

import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccountHandle
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

/**
 * Self-managed [ConnectionService] surface. The Telecom framework drives the system's
 * incoming-call UI; we just forward the accept/reject/disconnect lifecycle into
 * [CallManager] so the app's internal state machine stays in sync.
 *
 * Phase 7 scope: minimum viable plumbing so FCM `call` data messages surface a real
 * system call UI. Audio-focus, hold/unhold, STK redirect, conference support — all 7.5.
 */
@AndroidEntryPoint
class GhostConnectionService : ConnectionService() {

    companion object {
        const val EXTRA_ROOM_ID: String = "ghostchat.roomId"
        const val EXTRA_CALLER_NAME: String = "ghostchat.callerName"
    }

    @Inject lateinit var callManager: CallManager

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ): Connection = GhostConnection(callManager).also { conn ->
        conn.setRinging()
    }

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ): Connection = GhostConnection(callManager).also { conn ->
        conn.setDialing()
    }

    /** Per-call connection — forwards each Telecom lifecycle hook into [CallManager]. */
    private class GhostConnection(
        private val callManager: CallManager
    ) : Connection() {

        init {
            setConnectionProperties(PROPERTY_SELF_MANAGED)
            setAudioModeIsVoip(true)
        }

        override fun onAnswer() {
            callManager.answered()
            setActive()
        }

        override fun onReject() {
            callManager.end()
            setDisconnected(DisconnectCause(DisconnectCause.REJECTED))
            destroy()
        }

        override fun onDisconnect() {
            callManager.end()
            setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
            destroy()
        }

        override fun onAbort() {
            callManager.end()
            setDisconnected(DisconnectCause(DisconnectCause.UNKNOWN))
            destroy()
        }
    }
}
