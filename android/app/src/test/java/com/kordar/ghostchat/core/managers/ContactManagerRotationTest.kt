package com.kordar.ghostchat.core.managers

import com.google.common.truth.Truth.assertThat
import com.kordar.ghostchat.core.crypto.CryptoUtils
import com.kordar.ghostchat.core.crypto.IdentityKeyService
import com.kordar.ghostchat.core.security.InMemoryKeystore
import com.kordar.ghostchat.core.storage.ContactStore
import com.kordar.ghostchat.core.storage.DatabaseService
import com.kordar.ghostchat.core.storage.MessageStore
import com.kordar.ghostchat.models.Contact
import org.junit.Test
import org.mockito.kotlin.any
import org.mockito.kotlin.doAnswer
import org.mockito.kotlin.doReturn
import org.mockito.kotlin.mock
import org.mockito.kotlin.whenever

/**
 * Rotation-only coverage for [ContactManager.rotateKeys]. SQLCipher's native
 * library can't load under JVM unit tests (see CLAUDE.md Phase 4 lessons), so
 * we mock the storage layer and verify the Phase-6 rotation behaviour in
 * isolation. Mirror of iOS `ContactManagerTests.test_rotateKeys_…`. The full
 * cross-platform determinism of the HKDF derivation is covered in
 * [com.kordar.ghostchat.core.crypto.ContactKeyRotationTest].
 */
class ContactManagerRotationTest {

    private fun subject(initial: Contact? = null): Fixture {
        val store = mock<ContactStore>()
        val messages = mock<MessageStore>()
        val keystore = InMemoryKeystore()
        val identity = IdentityKeyService(keystore)
        identity.getOrCreateIdentity()
        val database = mock<DatabaseService>()

        val holder = arrayOf<Contact?>(
            initial?.copy(
                identityKey = initial.identityKey.copyOf(),
                publicKey = initial.publicKey.copyOf(),
                previousKey = initial.previousKey?.copyOf(),
                fallbackKey = initial.fallbackKey?.copyOf()
            )
        )
        whenever(store.fetch(any())).doAnswer { holder[0] }
        whenever(store.save(any())).doAnswer {
            val c = it.arguments[0] as Contact
            holder[0] = c.copy(
                identityKey = c.identityKey.copyOf(),
                publicKey = c.publicKey.copyOf(),
                previousKey = c.previousKey?.copyOf(),
                fallbackKey = c.fallbackKey?.copyOf()
            )
            Unit
        }
        whenever(store.all()).doReturn(emptyList())

        val mgr = ContactManager(store, messages, identity, keystore, database)
        return Fixture(mgr, keystore) { holder[0] }
    }

    private data class Fixture(
        val mgr: ContactManager,
        val keystore: InMemoryKeystore,
        val currentContact: () -> Contact?
    )

    @Test
    fun `rotateKeys first rotation slides public into previous, no fallback`() {
        val peer = CryptoUtils.generateKeyPair()
        val firstPublic = peer.publicKeyBytes
        val c = Contact(
            id = "c1", label = "Alice",
            identityKey = byteArrayOf(0x04) + ByteArray(64) { 0x01.toByte() },
            publicKey = firstPublic,
            rotationCounter = 0,
            createdAt = 100_000L
        )
        val f = subject(initial = c)

        val didRun = f.mgr.rotateKeys("c1", ByteArray(32) { 0x42.toByte() })

        assertThat(didRun).isTrue()
        val updated = f.currentContact()!!
        assertThat(updated.rotationCounter).isEqualTo(1)
        assertThat(updated.previousKey).isEqualTo(firstPublic)
        assertThat(updated.fallbackKey).isNull()
        assertThat(updated.publicKey).isNotEqualTo(firstPublic)
        val stored = f.keystore.get("contact.priv.c1")
        assertThat(stored).isNotNull()
        assertThat(stored!!.size).isEqualTo(32)
    }

    @Test
    fun `rotateKeys second rotation slides previous into fallback`() {
        val firstPeer = CryptoUtils.generateKeyPair()
        val c = Contact(
            id = "c1", label = "Bob",
            identityKey = byteArrayOf(0x04) + ByteArray(64) { 0x02.toByte() },
            publicKey = firstPeer.publicKeyBytes,
            rotationCounter = 0,
            createdAt = 100_000L
        )
        val f = subject(initial = c)

        f.mgr.rotateKeys("c1", ByteArray(32) { 0x42.toByte() })
        val afterFirst = f.currentContact()!!.let { it.copy(publicKey = it.publicKey.copyOf()) }
        f.mgr.rotateKeys("c1", ByteArray(32) { 0x43.toByte() })
        val afterSecond = f.currentContact()!!

        assertThat(afterSecond.rotationCounter).isEqualTo(2)
        assertThat(afterSecond.fallbackKey).isEqualTo(firstPeer.publicKeyBytes)
        assertThat(afterSecond.previousKey).isEqualTo(afterFirst.publicKey)
        assertThat(afterSecond.publicKey).isNotEqualTo(afterFirst.publicKey)
    }

    @Test
    fun `rotateKeys no such contact returns false`() {
        val f = subject(initial = null)
        assertThat(f.mgr.rotateKeys("does-not-exist", ByteArray(32))).isFalse()
    }

    /**
     * Two independent manager instances starting from the same contact record
     * and same session secret must converge on the same new publicKey. That's
     * what enables zero-exchange rotation. Byte-identical cross-platform
     * determinism is pinned in
     * `com.kordar.ghostchat.core.crypto.ContactKeyRotationTest
     * .rotated public key cross-platform deterministic`.
     */
    @Test
    fun `rotateKeys deterministic across manager instances`() {
        val init0 = CryptoUtils.generateKeyPair()
        val idKey = byteArrayOf(0x04) + ByteArray(64) { 0x05.toByte() }
        val contact0 = Contact(
            id = "x", label = "", identityKey = idKey,
            publicKey = init0.publicKeyBytes, createdAt = 1L
        )

        val a = subject(initial = contact0)
        val b = subject(initial = contact0)

        val secret = ByteArray(32) { 0xAA.toByte() }
        a.mgr.rotateKeys("x", secret)
        b.mgr.rotateKeys("x", secret)

        assertThat(a.currentContact()!!.publicKey).isEqualTo(b.currentContact()!!.publicKey)
    }
}
