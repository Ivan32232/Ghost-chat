package com.kordar.ghostchat.core.managers

import com.google.common.truth.Truth.assertThat
import com.kordar.ghostchat.core.security.InMemoryKeystore
import com.kordar.ghostchat.models.AutoLockTimeout
import com.kordar.ghostchat.models.MessageTTL
import org.junit.Test

class SettingsManagerTest {

    @Test
    fun `defaults match iOS`() {
        val mgr = SettingsManager(InMemoryKeystore())
        assertThat(mgr.privacyMode.value).isFalse()
        assertThat(mgr.biometricEnabled.value).isFalse()
        assertThat(mgr.soundEnabled.value).isTrue()
        assertThat(mgr.messageTTL.value).isEqualTo(MessageTTL.FIVE_MINUTES)
        assertThat(mgr.autoLockTimeout.value).isEqualTo(AutoLockTimeout.ONE_MINUTE)
    }

    @Test
    fun `booleans persist across instances`() {
        val store = InMemoryKeystore()
        SettingsManager(store).setPrivacyMode(true)
        val next = SettingsManager(store)
        assertThat(next.privacyMode.value).isTrue()
    }

    @Test
    fun `enums persist across instances`() {
        val store = InMemoryKeystore()
        SettingsManager(store).setMessageTTL(MessageTTL.ONE_HOUR)
        SettingsManager(store).setAutoLockTimeout(AutoLockTimeout.FIVE_MINUTES)
        val next = SettingsManager(store)
        assertThat(next.messageTTL.value).isEqualTo(MessageTTL.ONE_HOUR)
        assertThat(next.autoLockTimeout.value).isEqualTo(AutoLockTimeout.FIVE_MINUTES)
    }
}
