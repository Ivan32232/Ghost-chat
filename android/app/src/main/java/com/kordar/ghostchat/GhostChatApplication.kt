package com.kordar.ghostchat

import android.app.Application
import dagger.hilt.android.HiltAndroidApp

/**
 * Application entry point. Stage 17 adds identity bootstrap and skipped-key pruning.
 * Stage 1 ships a minimal body so assembleDebug succeeds.
 */
@HiltAndroidApp
class GhostChatApplication : Application()
