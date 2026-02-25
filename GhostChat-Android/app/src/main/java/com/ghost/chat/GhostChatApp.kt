package com.ghost.chat

import android.app.Application
import com.ghost.chat.core.localization.LocalizationManager
import com.ghost.chat.core.security.KeystoreService

class GhostChatApp : Application() {

    override fun onCreate() {
        super.onCreate()

        // Initialize secure storage
        KeystoreService.init(this)

        // Initialize localization
        LocalizationManager.init(this)
    }
}
