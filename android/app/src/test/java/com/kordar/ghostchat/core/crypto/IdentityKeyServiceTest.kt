package com.kordar.ghostchat.core.crypto

import com.google.common.truth.Truth.assertThat
import com.kordar.ghostchat.core.security.InMemoryKeystore
import org.junit.Test

class IdentityKeyServiceTest {

    @Test
    fun `getOrCreateIdentity returns stable keypair across calls`() {
        val svc = IdentityKeyService(InMemoryKeystore())
        val a = svc.getOrCreateIdentity()
        val b = svc.getOrCreateIdentity()
        assertThat(a.privateKeyBytes).isEqualTo(b.privateKeyBytes)
        assertThat(a.publicKeyBytes).isEqualTo(b.publicKeyBytes)
    }

    @Test
    fun `persists private key in keystore`() {
        val store = InMemoryKeystore()
        val svc = IdentityKeyService(store)
        svc.getOrCreateIdentity()
        val raw = store.get(IdentityKeyService.Keys.PRIVATE_RAW)
        assertThat(raw).isNotNull()
        assertThat(raw!!.size).isEqualTo(32) // P-256 scalar
    }

    @Test
    fun `second service reads same keypair from keystore`() {
        val store = InMemoryKeystore()
        val firstPub = IdentityKeyService(store).publicKeyX963
        val secondPub = IdentityKeyService(store).publicKeyX963
        assertThat(firstPub).isEqualTo(secondPub)
    }

    @Test
    fun `resetIdentity clears cached key and storage`() {
        val store = InMemoryKeystore()
        val svc = IdentityKeyService(store)
        svc.getOrCreateIdentity()
        svc.resetIdentity()
        assertThat(store.get(IdentityKeyService.Keys.PRIVATE_RAW)).isNull()
        val next = svc.getOrCreateIdentity()
        assertThat(next).isNotNull()
    }

    @Test
    fun `x963 public key is 65 bytes with 0x04 prefix`() {
        val svc = IdentityKeyService(InMemoryKeystore())
        val pub = svc.publicKeyX963
        assertThat(pub.size).isEqualTo(65)
        assertThat(pub[0]).isEqualTo(0x04.toByte())
    }

    @Test
    fun `raw public key is 64 bytes without prefix`() {
        val svc = IdentityKeyService(InMemoryKeystore())
        val raw = svc.publicKeyRaw
        assertThat(raw.size).isEqualTo(64)
    }
}
