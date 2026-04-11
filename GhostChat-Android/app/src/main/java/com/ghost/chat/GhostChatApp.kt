package com.ghost.chat

import android.app.Application
import com.ghost.chat.core.localization.LocalizationManager
import com.ghost.chat.core.notification.NotificationHelper
import com.ghost.chat.core.security.BiometricAuthService
import com.ghost.chat.core.security.KeystoreService

class GhostChatApp : Application() {

    override fun onCreate() {
        super.onCreate()

        // Initialize secure storage
        KeystoreService.init(this)

        // Detect fresh install — clear any stale data from previous installation
        val prefs = getSharedPreferences("ghost_launch", MODE_PRIVATE)
        if (!prefs.getBoolean("has_launched", false)) {
            try {
                KeystoreService.clear()
                // Delete the encrypted database file directly
                getDatabasePath("ghost_chat.db")?.let { dbFile ->
                    if (dbFile.exists()) dbFile.delete()
                }
            } catch (_: Exception) {}
            prefs.edit().putBoolean("has_launched", true).apply()
            // Re-init KeystoreService after clear (prefs reference was invalidated)
            KeystoreService.init(this, force = true)
        }

        // Determine initial lock state (PIN/biometric check on cold start)
        // Must be after fresh install check so we don't read stale keychain data
        BiometricAuthService.initLockState(this)

        // Initialize localization
        LocalizationManager.init(this)

        // Create notification channels (calls, invites, messages)
        NotificationHelper.createChannels(this)
    }
}
