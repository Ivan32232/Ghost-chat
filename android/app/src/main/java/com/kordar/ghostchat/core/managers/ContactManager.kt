package com.kordar.ghostchat.core.managers

import com.kordar.ghostchat.core.crypto.IdentityKeyService
import com.kordar.ghostchat.core.security.KeystoreServicing
import com.kordar.ghostchat.core.storage.ContactStore
import com.kordar.ghostchat.core.storage.DatabaseService
import com.kordar.ghostchat.core.storage.MessageStore
import com.kordar.ghostchat.models.Contact
import com.kordar.ghostchat.models.Role
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.security.MessageDigest

/**
 * Contact CRUD + role determination for pending-room auto-connect + panic wipe.
 * Mirror of iOS `ContactManager`.
 */
class ContactManager(
    private val store: ContactStore,
    @Suppress("unused") private val messages: MessageStore, // retained for API parity; used by future flows
    private val identity: IdentityKeyService,
    private val keystore: KeystoreServicing,
    private val database: DatabaseService
) {

    private val _contacts = MutableStateFlow<List<Contact>>(emptyList())
    val contacts: StateFlow<List<Contact>> = _contacts.asStateFlow()

    fun refresh() {
        _contacts.value = runCatching { store.all() }.getOrDefault(emptyList())
    }

    fun save(contact: Contact) {
        store.save(contact); refresh()
    }

    fun delete(id: String) {
        store.delete(id); refresh()
    }

    /**
     * Deterministic HOST/GUEST selection: SHA-256(myIdentity) < SHA-256(peerIdentity) → HOST.
     * Mirror of iOS ContactManager.determineRole.
     */
    fun determineRole(peerIdentity: ByteArray): Role {
        val me = identity.publicKeyRaw
        val digest = MessageDigest.getInstance("SHA-256")
        val myHash = digest.digest(me)
        digest.reset()
        // peerIdentity is 65-byte x963 with 0x04 prefix — drop it to match iOS input
        val peerRaw = peerIdentity.copyOfRange(1, peerIdentity.size)
        val peerHash = digest.digest(peerRaw)
        return if (myHash.toHex() < peerHash.toHex()) Role.HOST else Role.GUEST
    }

    /**
     * Irrecoverably delete all contacts, messages, skipped keys, identity, and every
     * keystore entry.
     */
    fun panicWipe(context: android.content.Context) {
        runCatching { store.deleteAll() }
        runCatching { identity.resetIdentity() }
        runCatching { keystore.deleteAll() }
        runCatching { database.close() }
        DatabaseService.deleteFile(context)
        refresh()
    }

    /**
     * Rotate a saved contact's keys using the just-ended session's shared secret.
     *
     * Both peers derive the same new keypair from the same [sessionSecret] via
     * [com.kordar.ghostchat.core.crypto.ContactKeyRotation.deriveNextSeed] —
     * no wire exchange needed. The prior `publicKey` slides into `previousKey`,
     * and `previousKey` slides into `fallbackKey`, giving us 3 generations of
     * continuity across occasional state desync.
     *
     * The new private scalar is stored in the keystore under a per-contact label
     * so the next connect can use it for the ECDH handshake. Returns `true` when
     * the rotation actually ran (contact existed); `false` otherwise. Mirror of
     * iOS `ContactManager.rotateKeys(contactId:sessionSecret:)`.
     */
    fun rotateKeys(contactId: String, sessionSecret: ByteArray): Boolean {
        val contact = store.fetch(contactId) ?: return false
        val privateKeyKeychainId = "contact.priv.$contactId"
        val currentPrivate = keystore.get(privateKeyKeychainId) ?: ByteArray(0)
        val rotated = com.kordar.ghostchat.core.crypto.ContactKeyRotation.rotate(
            sessionSecret = sessionSecret,
            currentPrivate = currentPrivate,
            previousPublic = contact.publicKey,
            fallbackPublic = contact.previousKey,
            counter = contact.rotationCounter
        )
        keystore.set(privateKeyKeychainId, rotated.newPrivate)
        contact.publicKey = rotated.newPublicX963
        contact.previousKey = rotated.previousPublicX963
        contact.fallbackKey = rotated.fallbackPublicX963
        contact.rotationCounter = rotated.counter
        store.save(contact)
        refresh()
        return true
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
}
