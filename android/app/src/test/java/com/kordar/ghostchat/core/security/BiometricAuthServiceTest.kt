package com.kordar.ghostchat.core.security

import com.google.common.truth.Truth.assertThat
import com.kordar.ghostchat.models.AutoLockTimeout
import org.junit.Assert.assertThrows
import org.junit.Test

class BiometricAuthServiceTest {

    @Test
    fun `authenticate returns Authenticated for main PIN`() {
        val store = InMemoryKeystore()
        val svc = BiometricAuthService(store)
        svc.setMainPIN("1234")
        val result = svc.authenticate("1234")
        assertThat(result).isEqualTo(BiometricAuthService.AuthResult.Authenticated)
    }

    @Test
    fun `authenticate returns AuthenticatedDecoy for decoy PIN`() {
        val store = InMemoryKeystore()
        val svc = BiometricAuthService(store)
        svc.setMainPIN("1234")
        svc.setDecoyPIN("9999")
        assertThat(svc.authenticate("9999"))
            .isEqualTo(BiometricAuthService.AuthResult.AuthenticatedDecoy)
    }

    @Test
    fun `wrong PIN increments failure count`() {
        val store = InMemoryKeystore()
        val svc = BiometricAuthService(store)
        svc.setMainPIN("1234")
        assertThat(svc.authenticate("0000"))
            .isEqualTo(BiometricAuthService.AuthResult.Invalid)
        assertThat(svc.failureCount()).isEqualTo(1)
    }

    @Test
    fun `hitting failureLimit triggers wipe`() {
        val store = InMemoryKeystore()
        var wipeCalled = 0
        val svc = BiometricAuthService(
            store,
            config = BiometricAuthService.Config(failureLimit = 3, onWipe = { wipeCalled++ })
        )
        svc.setMainPIN("1234")
        svc.authenticate("0000") // 1
        svc.authenticate("0000") // 2
        val third = svc.authenticate("0000") // 3 → wipe
        assertThat(third).isEqualTo(BiometricAuthService.AuthResult.Wiped)
        assertThat(wipeCalled).isEqualTo(1)
        assertThat(svc.hasMainPIN()).isFalse()
    }

    @Test
    fun `successful auth resets failure count`() {
        val store = InMemoryKeystore()
        val svc = BiometricAuthService(store)
        svc.setMainPIN("1234")
        svc.authenticate("0000")
        svc.authenticate("0000")
        svc.authenticate("1234")
        assertThat(svc.failureCount()).isEqualTo(0)
    }

    @Test
    fun `invalid PIN format is rejected`() {
        val store = InMemoryKeystore()
        val svc = BiometricAuthService(store)
        assertThrows(IllegalArgumentException::class.java) { svc.setMainPIN("12") }
        assertThrows(IllegalArgumentException::class.java) { svc.setMainPIN("abcd") }
        assertThrows(IllegalArgumentException::class.java) { svc.setMainPIN("1234567") }
    }

    @Test
    fun `biometricEnabled persists through keystore`() {
        val store = InMemoryKeystore()
        val svc = BiometricAuthService(store)
        assertThat(svc.biometricEnabled).isFalse()
        svc.biometricEnabled = true
        assertThat(svc.biometricEnabled).isTrue()
        svc.biometricEnabled = false
        assertThat(svc.biometricEnabled).isFalse()
    }

    @Test
    fun `autoLockTimeout persists through keystore`() {
        val store = InMemoryKeystore()
        val svc = BiometricAuthService(store)
        assertThat(svc.autoLockTimeout).isEqualTo(AutoLockTimeout.ONE_MINUTE) // default
        svc.autoLockTimeout = AutoLockTimeout.THIRTY_SECONDS
        assertThat(svc.autoLockTimeout).isEqualTo(AutoLockTimeout.THIRTY_SECONDS)
    }
}
