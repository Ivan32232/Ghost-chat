package com.kordar.ghostchat.core.push

import com.kordar.ghostchat.core.AppConfig
import dagger.Binds
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object PushModule {

    @Provides
    @Singleton
    fun providePushManager(): PushManager = PushManager(baseUrl = AppConfig.SERVER_HTTPS)
}

/**
 * Phase 7: bind [IncomingPushHandler] to the real [DefaultIncomingPushHandler] that
 * bridges FCM data messages to CallManager + TelecomManager (system call UI).
 */
@Module
@InstallIn(SingletonComponent::class)
abstract class PushBindingModule {

    @Binds
    @Singleton
    abstract fun bindIncomingPushHandler(
        impl: DefaultIncomingPushHandler
    ): IncomingPushHandler
}
