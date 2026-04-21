package com.kordar.ghostchat

import android.app.Application
import com.kordar.ghostchat.core.crypto.IdentityKeyService
import com.kordar.ghostchat.core.push.PushManager
import com.kordar.ghostchat.core.storage.MessageStore
import dagger.hilt.android.HiltAndroidApp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Hilt application. Boots the persistent identity keypair, prunes stale skipped
 * Double-Ratchet keys, and lazily asks for a fresh FCM token.
 */
@HiltAndroidApp
class GhostChatApplication : Application() {

    @Inject lateinit var identity: IdentityKeyService
    @Inject lateinit var messageStore: MessageStore
    @Inject lateinit var pushManager: PushManager

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onCreate() {
        super.onCreate()
        scope.launch {
            runCatching { identity.getOrCreateIdentity() }
            runCatching { messageStore.pruneSkipped() }
            runCatching { pushManager.registerForFCM() }
        }
    }
}
