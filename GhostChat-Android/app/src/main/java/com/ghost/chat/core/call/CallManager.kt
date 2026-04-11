package com.ghost.chat.core.call

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.util.Log

/// CallManager — wraps TelecomManager for system-level call management
/// Analog of iOS CXProvider + CXCallController
object CallManager {

    private const val TAG = "CallManager"
    private const val PHONE_ACCOUNT_ID = "ghost_chat_voip"

    private var telecomManager: TelecomManager? = null
    private var phoneAccountHandle: PhoneAccountHandle? = null
    private var isRegistered = false

    /// Initialize and register PhoneAccount — call once from Application/Activity
    fun initialize(context: Context) {
        if (isRegistered) return

        telecomManager = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
        if (telecomManager == null) {
            Log.w(TAG, "TelecomManager not available")
            return
        }

        val componentName = ComponentName(context, GhostConnectionService::class.java)
        phoneAccountHandle = PhoneAccountHandle(componentName, PHONE_ACCOUNT_ID)

        val phoneAccount = PhoneAccount.builder(phoneAccountHandle!!, "Ghost Chat")
            .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
            .build()

        try {
            telecomManager?.registerPhoneAccount(phoneAccount)
            isRegistered = true
        } catch (e: Exception) {
            Log.w(TAG, "Failed to register PhoneAccount: ${e.message}")
        }
    }

    /// Report an outgoing call to the system
    fun reportOutgoingCall(context: Context) {
        if (!isRegistered) initialize(context)
        val handle = phoneAccountHandle ?: return

        val extras = Bundle().apply {
            putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, handle)
        }

        try {
            telecomManager?.placeCall(Uri.parse("ghost://call"), extras)
        } catch (e: SecurityException) {
            Log.w(TAG, "Permission denied for placeCall: ${e.message}")
        } catch (e: Exception) {
            Log.w(TAG, "Failed to report outgoing call: ${e.message}")
        }
    }

    /// Report an incoming call to the system
    fun reportIncomingCall(context: Context, callerName: String = "Ghost Chat") {
        if (!isRegistered) initialize(context)
        val handle = phoneAccountHandle ?: return

        val extras = Bundle().apply {
            putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, handle)
            putString(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS, "ghost://call")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                putString("android.telecom.extra.CALL_SUBJECT", callerName)
            }
        }

        try {
            telecomManager?.addNewIncomingCall(handle, extras)
        } catch (e: SecurityException) {
            Log.w(TAG, "Permission denied for addNewIncomingCall: ${e.message}")
        } catch (e: Exception) {
            Log.w(TAG, "Failed to report incoming call: ${e.message}")
        }
    }

    /// End the active system call
    fun endCall() {
        GhostConnectionService.activeConnection?.endCall()
    }

    /// Mark the active call as connected
    fun markCallActive() {
        GhostConnectionService.activeConnection?.markActive()
    }

    /// Clean up
    fun destroy() {
        GhostConnectionService.onCallAnswer = null
        GhostConnectionService.onCallEnd = null
        GhostConnectionService.onCallMute = null
    }
}
