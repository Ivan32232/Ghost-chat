package com.kordar.ghostchat.core.push

import com.kordar.ghostchat.core.AppConfig
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

    /**
     * Defaults to [IncomingPushHandler.NoOp]. Replaced in Stage 11 by a real binding that
     * forwards FCM data messages to CallManager's ConnectionService.
     */
    @Provides
    @Singleton
    fun provideIncomingPushHandler(): IncomingPushHandler = IncomingPushHandler.NoOp
}
