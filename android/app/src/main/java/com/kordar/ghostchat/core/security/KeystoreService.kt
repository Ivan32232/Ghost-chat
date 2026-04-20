package com.kordar.ghostchat.core.security

import android.content.Context
import androidx.security.crypto.EncryptedFile
import androidx.security.crypto.MasterKey
import java.io.File
import java.io.IOException

/**
 * Secure key/value store for small byte-array values (≤ a few KB each).
 *
 * Counterpart to iOS `KeychainServicing` — same surface (`set` / `get` / `delete` /
 * `deleteAll`) so cross-platform code paths stay symmetric. Anything stored here is
 * encrypted on disk with an AndroidKeyStore-backed AES-256-GCM master key.
 *
 * NOT backed by SharedPreferences (forbidden by SPEC). Each logical key is serialised
 * to its own `EncryptedFile` so failures or partial writes stay scoped per entry.
 */
interface KeystoreServicing {
    fun set(key: String, data: ByteArray)
    fun get(key: String): ByteArray?
    fun delete(key: String)
    fun deleteAll()
}

class KeystoreService(
    private val context: Context,
    private val rootDirName: String = "ghostchat-keystore"
) : KeystoreServicing {

    private val rootDir: File by lazy {
        File(context.filesDir, rootDirName).apply { mkdirs() }
    }

    private val masterKey: MasterKey by lazy {
        MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
    }

    override fun set(key: String, data: ByteArray) {
        val file = fileFor(key)
        if (file.exists()) file.delete() // EncryptedFile can't overwrite existing files
        val encrypted = EncryptedFile.Builder(
            context,
            file,
            masterKey,
            EncryptedFile.FileEncryptionScheme.AES256_GCM_HKDF_4KB
        ).build()
        encrypted.openFileOutput().use { it.write(data) }
    }

    override fun get(key: String): ByteArray? {
        val file = fileFor(key)
        if (!file.exists()) return null
        val encrypted = EncryptedFile.Builder(
            context,
            file,
            masterKey,
            EncryptedFile.FileEncryptionScheme.AES256_GCM_HKDF_4KB
        ).build()
        return try {
            encrypted.openFileInput().use { it.readBytes() }
        } catch (t: IOException) {
            null
        }
    }

    override fun delete(key: String) {
        fileFor(key).takeIf { it.exists() }?.delete()
    }

    override fun deleteAll() {
        rootDir.listFiles()?.forEach { it.delete() }
    }

    private fun fileFor(key: String): File = File(rootDir, sanitize(key) + ".enc")

    private fun sanitize(raw: String): String =
        raw.replace(Regex("[^A-Za-z0-9._-]"), "_")
}

/** In-memory counterpart for unit tests — no disk, no Android context required. */
class InMemoryKeystore : KeystoreServicing {
    private val store = mutableMapOf<String, ByteArray>()
    override fun set(key: String, data: ByteArray) { store[key] = data.copyOf() }
    override fun get(key: String): ByteArray? = store[key]?.copyOf()
    override fun delete(key: String) { store.remove(key) }
    override fun deleteAll() { store.clear() }
}
