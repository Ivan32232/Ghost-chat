package com.kordar.ghostchat.core.crypto

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import java.security.SecureRandom

class PostQuantumTest {

    @Test
    fun `IS_SUPPORTED is true on Android`() {
        assertThat(PostQuantum.IS_SUPPORTED).isTrue()
    }

    // MARK: - KEM primitives (round-trip)

    @Test
    fun `generateKeyPair emits FIPS 203 768-parameter sizes`() {
        val kp = PostQuantum.generateKeyPair()
        assertThat(kp.publicKey.size).isEqualTo(1184)  // ML-KEM768 public
        assertThat(kp.privateKey.size).isEqualTo(2400) // ML-KEM768 private
    }

    @Test
    fun `encapsulate then decapsulate recovers same shared secret`() {
        val kp = PostQuantum.generateKeyPair()
        val enc = PostQuantum.encapsulate(kp.publicKey)
        val decapsulated = PostQuantum.decapsulate(enc.ciphertext, kp.privateKey)
        assertThat(enc.sharedSecret).isEqualTo(decapsulated)
        assertThat(enc.sharedSecret.size).isEqualTo(32)
        assertThat(enc.ciphertext.size).isEqualTo(1088) // ML-KEM768 ct
    }

    @Test
    fun `encapsulation with different randomness produces different ciphertext`() {
        val kp = PostQuantum.generateKeyPair()
        val a = PostQuantum.encapsulate(kp.publicKey, SecureRandom())
        val b = PostQuantum.encapsulate(kp.publicKey, SecureRandom())
        // Same public key, independent encapsulations → different ciphertexts
        assertThat(a.ciphertext).isNotEqualTo(b.ciphertext)
        // But both successfully decapsulate to their own secrets
        assertThat(PostQuantum.decapsulate(a.ciphertext, kp.privateKey)).isEqualTo(a.sharedSecret)
        assertThat(PostQuantum.decapsulate(b.ciphertext, kp.privateKey)).isEqualTo(b.sharedSecret)
    }

    @Test
    fun `different keypairs produce different public keys`() {
        val a = PostQuantum.generateKeyPair()
        val b = PostQuantum.generateKeyPair()
        assertThat(a.publicKey).isNotEqualTo(b.publicKey)
    }

    // MARK: - hybridDeriveSharedKey

    @Test
    fun `hybridDerive ecdhOnly is 32 bytes`() {
        val ecdh = ByteArray(32) { 0xAB.toByte() }
        val out = PostQuantum.hybridDeriveSharedKey(ecdh, pqSharedSecret = null)
        assertThat(out.size).isEqualTo(32)
    }

    @Test
    fun `hybridDerive withPQ differs from ecdhOnly`() {
        val ecdh = ByteArray(32) { 0xAB.toByte() }
        val pq   = ByteArray(32) { 0xCD.toByte() }
        val hyb = PostQuantum.hybridDeriveSharedKey(ecdh, pq)
        val plain = PostQuantum.hybridDeriveSharedKey(ecdh, null)
        assertThat(hyb).isNotEqualTo(plain)
    }

    @Test
    fun `hybridDerive deterministic across calls`() {
        val ecdh = ByteArray(32) { 0x11.toByte() }
        val pq   = ByteArray(32) { 0x22.toByte() }
        val a = PostQuantum.hybridDeriveSharedKey(ecdh, pq)
        val b = PostQuantum.hybridDeriveSharedKey(ecdh, pq)
        assertThat(a).isEqualTo(b)
    }

    /**
     * Cross-platform vector. MUST match iOS `PostQuantumTests
     * test_hybridDerive_crossPlatformVector_withPQ`.
     */
    @Test
    fun `hybridDerive cross-platform vector with PQ matches iOS`() {
        val ecdh = ByteArray(32) { 0xAB.toByte() }
        val pq   = ByteArray(32) { 0xCD.toByte() }
        val out = PostQuantum.hybridDeriveSharedKey(ecdh, pq)
        assertThat(out.toHexString())
            .isEqualTo("207fad0312271a11364d7c3184693501082f1f614ff632987ba8e763df762eae")
    }

    @Test
    fun `hybridDerive cross-platform vector without PQ matches iOS`() {
        val ecdh = ByteArray(32) { 0xAB.toByte() }
        val out = PostQuantum.hybridDeriveSharedKey(ecdh, null)
        assertThat(out.toHexString())
            .isEqualTo("11edf4ea0a6fb4e02b042841e5e72f2c8415cfca1ab9a815b0ffe6fb4fc69e4a")
    }

    /**
     * End-to-end hybrid: ECDH + ML-KEM, combined shared secret. Both sides
     * derive the SAME root after Encapsulate + Decapsulate.
     */
    @Test
    fun `end-to-end hybrid KEM + ECDH derives same root on both sides`() {
        // HOST's side: owns ECDH private + receives GUEST's ECDH public.
        val hostEcdh = CryptoUtils.generateKeyPair()
        val guestEcdh = CryptoUtils.generateKeyPair()
        val sharedEcdh = CryptoUtils.ecdhSharedSecret(hostEcdh.privateKey, guestEcdh.publicKey)
        val sharedEcdhMirror = CryptoUtils.ecdhSharedSecret(guestEcdh.privateKey, hostEcdh.publicKey)
        assertThat(sharedEcdh).isEqualTo(sharedEcdhMirror)

        // PQ leg: HOST generates KEM keypair, GUEST encapsulates against HOST pub.
        val hostKem = PostQuantum.generateKeyPair()
        val encap = PostQuantum.encapsulate(hostKem.publicKey)
        val hostPqSecret = PostQuantum.decapsulate(encap.ciphertext, hostKem.privateKey)
        assertThat(hostPqSecret).isEqualTo(encap.sharedSecret)

        // Both sides combine in the same order.
        val hostRoot  = PostQuantum.hybridDeriveSharedKey(sharedEcdh, hostPqSecret)
        val guestRoot = PostQuantum.hybridDeriveSharedKey(sharedEcdhMirror, encap.sharedSecret)
        assertThat(hostRoot).isEqualTo(guestRoot)
    }
}
