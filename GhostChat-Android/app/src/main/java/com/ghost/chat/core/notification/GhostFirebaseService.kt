package com.ghost.chat.core.notification

import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class GhostFirebaseService : FirebaseMessagingService() {

    companion object {
        private const val TAG = "GhostFCM"

        // Callback for token refresh — wired by ChatViewModel
        var onTokenRefresh: ((String) -> Unit)? = null

        // Callback for incoming push — wired by ChatViewModel
        var onIncomingCall: ((roomId: String, callerName: String) -> Unit)? = null
        var onChatInvite: ((roomId: String, inviterName: String) -> Unit)? = null
        var onMessagePush: ((type: String, senderName: String) -> Unit)? = null

        // Имя контакта, чей чат сейчас открыт (для подавления push)
        var activeContactChatId: String? = null
        var activeContactName: String? = null
    }

    override fun onNewToken(token: String) {
        super.onNewToken(token)
        Log.d(TAG, "FCM token refreshed")
        onTokenRefresh?.invoke(token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        super.onMessageReceived(message)

        val data = message.data
        val type = data["type"] ?: run {
            Log.d(TAG, "onMessageReceived — no 'type' in data payload, keys=${data.keys}")
            return
        }
        Log.d(TAG, "onMessageReceived — type=$type, data=$data")

        when (type) {
            "incoming_call" -> {
                val roomId = data["roomId"] ?: return
                val callerName = data["callerName"] ?: "Ghost Chat"

                // Show full-screen notification to wake user
                NotificationHelper.showIncomingCallNotification(
                    applicationContext, callerName, roomId
                )

                // Notify ChatViewModel (if alive) to join room
                onIncomingCall?.invoke(roomId, callerName)
            }

            "chat-invite" -> {
                val roomId = data["roomId"] ?: return
                val inviterName = data["inviterName"] ?: "Ghost Chat"

                NotificationHelper.showInviteNotification(
                    applicationContext, inviterName, roomId
                )

                onChatInvite?.invoke(roomId, inviterName)
            }

            "new-message" -> {
                val senderName = data["senderName"] ?: "Ghost Chat"

                // Подавляем уведомление если пользователь уже в чате с отправителем
                val suppress = activeContactName != null && activeContactName == senderName
                if (!suppress) {
                    NotificationHelper.showMessageNotification(
                        applicationContext, senderName
                    )
                }

                onMessagePush?.invoke(type, senderName)
            }

            "missed-call" -> {
                val senderName = data["senderName"] ?: "Ghost Chat"

                NotificationHelper.showMissedCallNotification(
                    applicationContext, senderName
                )

                onMessagePush?.invoke(type, senderName)
            }
        }
    }
}
