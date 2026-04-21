package com.kordar.ghostchat.core.crypto

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class DoubleRatchetStateTest {

    @Test
    fun `roundtrip a fresh session`() {
        val alice = CryptoUtils.generateKeyPair()
        val bob = CryptoUtils.generateKeyPair()
        val shared = CryptoUtils.ecdhSharedSecret(alice.privateKey, bob.publicKey)
        val rk0 = CryptoUtils.deriveInitialRootKey(shared)

        val host = DoubleRatchet(RatchetRole.HOST, rk0, alice, bob.publicKey)
        host.encrypt("hello") // advance state
        val exported = host.exportedState

        val restored = DoubleRatchet(exported)
        val again = restored.exportedState
        assertEquals(exported.toList(), again.toList())
    }

    @Test
    fun `restored host can still decrypt peer messages`() {
        val alice = CryptoUtils.generateKeyPair()
        val bob = CryptoUtils.generateKeyPair()
        val shared = CryptoUtils.ecdhSharedSecret(alice.privateKey, bob.publicKey)
        val rk0 = CryptoUtils.deriveInitialRootKey(shared)

        val host = DoubleRatchet(RatchetRole.HOST, rk0, alice, bob.publicKey)
        val guest = DoubleRatchet(RatchetRole.GUEST, rk0, bob, null)

        // host → guest
        val m1 = host.encrypt("ping").wireBase64
        val got1 = guest.decrypt(m1)
        assertEquals("ping", got1)

        val exported = host.exportedState
        val restored = DoubleRatchet(exported)

        // guest → restored host
        val m2 = guest.encrypt("pong").wireBase64
        val got2 = restored.decrypt(m2)
        assertEquals("pong", got2)
    }
}
