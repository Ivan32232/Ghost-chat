package com.kordar.ghostchat.core.di

import android.content.Context
import com.kordar.ghostchat.core.AppConfig
import com.kordar.ghostchat.core.audio.SoundLibrary
import com.kordar.ghostchat.core.crypto.GhostChatCrypto
import com.kordar.ghostchat.core.crypto.IdentityKeyService
import com.kordar.ghostchat.core.localization.LocalizationManager
import com.kordar.ghostchat.core.managers.CallManager
import com.kordar.ghostchat.core.managers.ConnectionManager
import com.kordar.ghostchat.core.managers.ContactManager
import com.kordar.ghostchat.core.managers.MessageManager
import com.kordar.ghostchat.core.managers.SettingsManager
import com.kordar.ghostchat.core.network.TURNService
import com.kordar.ghostchat.core.push.PushManager
import com.kordar.ghostchat.core.security.BiometricAuthService
import com.kordar.ghostchat.core.security.KeystoreService
import com.kordar.ghostchat.core.security.KeystoreServicing
import com.kordar.ghostchat.core.security.SecurityMonitor
import com.kordar.ghostchat.core.storage.ContactStore
import com.kordar.ghostchat.core.storage.DatabaseService
import com.kordar.ghostchat.core.storage.MessageStore
import com.kordar.ghostchat.core.webrtc.GhostVoice
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object CoreModule {

    @Provides @Singleton
    fun provideKeystore(@ApplicationContext ctx: Context): KeystoreServicing = KeystoreService(ctx)

    @Provides @Singleton
    fun provideIdentityKeyService(ks: KeystoreServicing): IdentityKeyService = IdentityKeyService(ks)

    @Provides @Singleton
    fun provideDatabaseService(
        @ApplicationContext ctx: Context,
        keystore: KeystoreServicing
    ): DatabaseService = DatabaseService.onDisk(ctx, keystore)

    @Provides @Singleton
    fun provideContactStore(db: DatabaseService): ContactStore = ContactStore(db)

    @Provides @Singleton
    fun provideMessageStore(db: DatabaseService): MessageStore = MessageStore(db)

    @Provides @Singleton
    fun provideSecurityMonitor(): SecurityMonitor = SecurityMonitor()

    @Provides @Singleton
    fun provideBiometricAuthService(ks: KeystoreServicing): BiometricAuthService =
        BiometricAuthService(ks)

    @Provides @Singleton
    fun provideSettingsManager(ks: KeystoreServicing): SettingsManager = SettingsManager(ks)

    @Provides @Singleton
    fun provideLocalizationManager(
        @ApplicationContext ctx: Context,
        ks: KeystoreServicing
    ): LocalizationManager = LocalizationManager(ctx, ks)

    @Provides @Singleton
    fun provideTurnService(): TURNService = TURNService(AppConfig.SERVER_HTTPS)

    @Provides @Singleton
    fun provideGhostVoice(@ApplicationContext ctx: Context): GhostVoice = GhostVoice(ctx)

    @Provides @Singleton
    fun provideCallManager(voice: GhostVoice): CallManager = CallManager(voice)

    @Provides @Singleton
    fun provideConnectionManager(
        @ApplicationContext ctx: Context,
        identity: IdentityKeyService,
        push: PushManager,
        turnService: TURNService,
        contactManager: ContactManager
    ): ConnectionManager = ConnectionManager(
        context = ctx,
        signalingUrl = AppConfig.SERVER_WSS,
        apiBaseUrl = AppConfig.SERVER_HTTPS,
        identity = identity,
        push = push,
        turnService = turnService
    ).also { it.contactManager = contactManager }

    @Provides @Singleton
    fun provideSoundLibrary(
        @ApplicationContext ctx: Context,
        settings: SettingsManager
    ): SoundLibrary = SoundLibrary(ctx) { !settings.soundEnabled.value }

    @Provides @Singleton
    fun provideMessageManager(
        store: MessageStore,
        sounds: SoundLibrary
    ): MessageManager = MessageManager(store).also { it.sounds = sounds }

    @Provides @Singleton
    fun provideContactManager(
        store: ContactStore,
        messages: MessageStore,
        identity: IdentityKeyService,
        keystore: KeystoreServicing,
        database: DatabaseService
    ): ContactManager = ContactManager(store, messages, identity, keystore, database)

    // Note: crypto sessions are per-connection, not singleton — ConnectionManager creates them.
    @Provides
    fun provideGhostChatCrypto(identity: IdentityKeyService): GhostChatCrypto =
        GhostChatCrypto(identity)
}
