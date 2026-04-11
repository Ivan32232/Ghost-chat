package com.ghost.chat.core.call

import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.telecom.*
import android.util.Log

/// Android ConnectionService — analog of iOS CallKit
/// Self-managed connections for VoIP calls (no dialer integration, privacy-first)
class GhostConnectionService : ConnectionService() {

    companion object {
        private const val TAG = "GhostConnectionService"

        // Active connection — only one call at a time
        var activeConnection: GhostConnection? = null
            internal set

        // Callbacks from ChatViewModel
        var onCallAnswer: (() -> Unit)? = null
        var onCallEnd: (() -> Unit)? = null
        var onCallMute: ((Boolean) -> Unit)? = null
    }

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ): Connection {
        val connection = GhostConnection().apply {
            setCallerDisplayName("Ghost Chat", TelecomManager.PRESENTATION_ALLOWED)
            setAddress(
                Uri.parse("ghost://call"),
                TelecomManager.PRESENTATION_ALLOWED
            )
            connectionProperties = Connection.PROPERTY_SELF_MANAGED
            setRinging()
            setInitializing()
            setInitialized()
        }

        // Audio route: earpiece by default
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            connection.audioModeIsVoip = true
        }

        activeConnection = connection
        return connection
    }

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ): Connection {
        val connection = GhostConnection().apply {
            setCallerDisplayName("Ghost Chat", TelecomManager.PRESENTATION_ALLOWED)
            setAddress(
                Uri.parse("ghost://call"),
                TelecomManager.PRESENTATION_ALLOWED
            )
            connectionProperties = Connection.PROPERTY_SELF_MANAGED
            setDialing()
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            connection.audioModeIsVoip = true
        }

        activeConnection = connection
        return connection
    }

    override fun onCreateIncomingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ) {
        Log.w(TAG, "Failed to create incoming connection")
    }

    override fun onCreateOutgoingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ) {
        Log.w(TAG, "Failed to create outgoing connection")
    }
}

/// Single call connection — handles answer/reject/mute/disconnect
class GhostConnection : Connection() {

    init {
        connectionProperties = PROPERTY_SELF_MANAGED
    }

    override fun onAnswer() {
        setActive()
        GhostConnectionService.onCallAnswer?.invoke()
    }

    override fun onReject() {
        setDisconnected(DisconnectCause(DisconnectCause.REJECTED))
        destroy()
        GhostConnectionService.activeConnection = null
        GhostConnectionService.onCallEnd?.invoke()
    }

    override fun onDisconnect() {
        setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
        destroy()
        GhostConnectionService.activeConnection = null
        GhostConnectionService.onCallEnd?.invoke()
    }

    override fun onAbort() {
        setDisconnected(DisconnectCause(DisconnectCause.CANCELED))
        destroy()
        GhostConnectionService.activeConnection = null
    }

    override fun onCallAudioStateChanged(state: CallAudioState?) {
        state?.isMuted?.let { muted ->
            GhostConnectionService.onCallMute?.invoke(muted)
        }
    }

    /// Mark connection as active (call accepted)
    fun markActive() {
        setActive()
    }

    /// End the connection from our side
    fun endCall() {
        setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
        destroy()
        GhostConnectionService.activeConnection = null
    }

    /// Remote party ended the call
    fun remoteEnd() {
        setDisconnected(DisconnectCause(DisconnectCause.REMOTE))
        destroy()
        GhostConnectionService.activeConnection = null
    }
}
