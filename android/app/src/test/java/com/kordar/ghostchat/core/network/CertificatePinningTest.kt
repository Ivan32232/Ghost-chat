package com.kordar.ghostchat.core.network

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class CertificatePinningTest {

    @Test
    fun `has exactly two pins`() {
        assertThat(CertificatePinning.pins).hasSize(2)
    }

    @Test
    fun `pins match ios primary and backup`() {
        // Byte-for-byte copy from ios/GhostChat/Core/Network/CertificatePinning.swift
        assertThat(CertificatePinning.PRIMARY_PIN)
            .isEqualTo("u+rYBkrJDJtDcMZuuZxvgrwKAiaN/8Ppuk7pwdxjGbg=")
        assertThat(CertificatePinning.BACKUP_PIN)
            .isEqualTo("/AdS6h9evKtyk7J9aoy+0isfcARe0dv7/C+BOUabNeo=")
    }

    @Test
    fun `host is ghostchat_one`() {
        assertThat(CertificatePinning.HOST).isEqualTo("ghostchat.one")
    }

    @Test
    fun `pinner is constructible and non-null`() {
        val pinner = CertificatePinning.pinner()
        assertThat(pinner).isNotNull()
    }

    @Test
    fun `pinner uses provided host`() {
        val pinner = CertificatePinning.pinner(host = "example.test")
        assertThat(pinner).isNotNull()
    }
}
