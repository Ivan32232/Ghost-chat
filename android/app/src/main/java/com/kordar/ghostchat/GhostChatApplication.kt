package com.kordar.ghostchat

import android.app.Application
import com.kordar.ghostchat.core.crypto.IdentityKeyService
import com.kordar.ghostchat.core.push.PushManager
import com.kordar.ghostchat.core.storage.MessageStore
import dagger.hilt.android.HiltAndroidApp
import io.sentry.android.core.SentryAndroid
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Hilt application. Boots the persistent identity keypair, prunes stale skipped
 * Double-Ratchet keys, lazily asks for a fresh FCM token, and wires Sentry with
 * PII stripped.
 */
@HiltAndroidApp
class GhostChatApplication : Application() {

    @Inject lateinit var identity: IdentityKeyService
    @Inject lateinit var messageStore: MessageStore
    @Inject lateinit var pushManager: PushManager

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onCreate() {
        super.onCreate()
        configureSentry()
        scope.launch {
            runCatching { identity.getOrCreateIdentity() }
            runCatching { messageStore.pruneSkipped() }
            runCatching { pushManager.registerForFCM() }
        }
    }

    /**
     * Sentry is only useful once a DSN is supplied — the manifest keeps it empty by default
     * and SentryAndroid drops initialisation entirely in that case. Even when a DSN is set,
     * `beforeSend` strips user / request / device context so only the stack trace and error
     * shape remain.
     */
    private fun configureSentry() {
        SentryAndroid.init(this) { opts ->
            opts.tracesSampleRate = 0.0
            opts.isEnableAutoSessionTracking = false
            opts.isSendDefaultPii = false
            opts.beforeSend = io.sentry.SentryOptions.BeforeSendCallback { event, _ ->
                event.user = null
                event.request = null
                event.contexts.remove("device")
                event.contexts.remove("app")
                event
            }
        }
    }
}
