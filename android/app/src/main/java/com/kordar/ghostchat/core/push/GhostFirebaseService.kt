package com.kordar.ghostchat.core.push

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

/**
 * Receives FCM data messages. Token rotation forwarded to [PushManager]; inbound
 * data messages dispatched to [IncomingPushHandler] (wired in Stage 11 to
 * CallManager's ConnectionService).
 */
@AndroidEntryPoint
class GhostFirebaseService : FirebaseMessagingService() {

    @Inject lateinit var pushManager: PushManager
    @Inject lateinit var incoming: IncomingPushHandler

    override fun onNewToken(token: String) {
        pushManager.onNewFCMToken(token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        val type = data["type"] ?: "call"
        val roomId = data["roomId"]
        val callerName = data["callerName"] ?: "Ghost Chat"
        when (type) {
            "call"   -> if (roomId != null) incoming.onIncomingCall(roomId, callerName)
            "invite" -> if (roomId != null) incoming.onInvite(roomId, callerName)
            else     -> incoming.onNotify(type, callerName)
        }
    }
}

/**
 * Small indirection so unit tests can stub FCM dispatch. Production impl is registered
 * in Stage 11 and forwards to `CallManager`.
 */
interface IncomingPushHandler {
    fun onIncomingCall(roomId: String, callerName: String)
    fun onInvite(roomId: String, callerName: String)
    fun onNotify(type: String, senderName: String)

    object NoOp : IncomingPushHandler {
        override fun onIncomingCall(roomId: String, callerName: String) = Unit
        override fun onInvite(roomId: String, callerName: String) = Unit
        override fun onNotify(type: String, senderName: String) = Unit
    }
}
